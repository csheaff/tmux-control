;;; tmux-control.el --- Drive a tmux pane through control mode -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Clay Sheaff

;; Author: Clay Sheaff
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (eat "0.9.4"))
;; Keywords: terminals, tmux
;; URL: https://github.com/csheaff/tmux-control
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; tmux-control turns Emacs into a control-mode client for a tmux pane --
;; the iTerm2 tmux-integration idea, but in Emacs.  Rather than running
;; tmux inside a terminal buffer (where it dies with the frame), it speaks
;; tmux control mode ("tmux -C") to a persistent, possibly remote tmux
;; server over SSH and renders the live pane through Eat's terminal
;; emulator.  The tmux session outlives Emacs: detach, restart Emacs, or
;; reconnect from another machine and the pane is still there.
;;
;; See `tmux-control-connect' to attach.

;;; Code:

(require 'ansi-color)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'eat)

(defgroup tmux-control nil
  "Drive a tmux pane from Emacs using tmux control mode."
  :group 'terminals)

(defcustom tmux-control-default-host nil
  "Default SSH host for `tmux-control-connect'.

When nil or empty, connect to local tmux."
  :type '(choice (const :tag "Local" nil) string))

(defcustom tmux-control-default-socket-name "main"
  "Default tmux socket name."
  :type 'string)

(defcustom tmux-control-default-session "emacs"
  "Default tmux session name."
  :type 'string)

(defcustom tmux-control-remote-tmux-socket-setup
  "fs=$(stat -f -c %T \"$HOME\" 2>/dev/null); case \"$fs\" in nfs|nfs4|lustre|gpfs|cifs|smb*|afs) d=\"/tmp/tmux-$(id -u)-sock\";; *) d=\"$HOME/.tmux-sock\";; esac; mkdir -p \"$d\" && chmod 700 \"$d\" && export TMUX_TMPDIR=\"$d\""
  "Shell snippet used before running tmux on a remote host."
  :type 'string)

(defcustom tmux-control-scrollback-lines 50000
  "Number of pane-history lines to show in scrollback view."
  :type 'integer)

(defcustom tmux-control-pause-after nil
  "Enable tmux control-mode flow control after this many seconds, or nil.

When a positive number, the client asks tmux (via `refresh-client -f
pause-after=N') to pause a pane once the output buffered for this client
falls more than N seconds behind, instead of streaming an unbounded
backlog.  On a pause the live view reseeds from the pane's current screen
and resumes, so a burst of output -- `cat' on a huge file, a noisy build --
jumps to the latest state rather than replaying every intermediate line,
and Emacs stays responsive.

nil (the default) leaves flow control off and streams all output.  Requires
tmux 3.2 or newer; older servers reject the request (logging one command
error) and never pause."
  :type '(choice (const :tag "Off (stream everything)" nil)
                 (integer :tag "Seconds behind before pausing")))

(defcustom tmux-control-scrollback-join-wrapped-lines t
  "Non-nil means join soft-wrapped pane lines in scrollback captures."
  :type 'boolean)

(defcustom tmux-control-compact-scrollback t
  "Non-nil means compact repeated full-screen redraws in scrollback view.

This is useful for TUIs running with tmux `alternate-screen' disabled, where
pane history can contain many repeated copies of the visible screen."
  :type 'boolean)

(defcustom tmux-control-compact-scrollback-window 300
  "Maximum line window used to merge repeated redraw chunks in scrollback view."
  :type 'integer)

(defcustom tmux-control-scrollback-frame-start-regexp nil
  "Regexp matching the top line of a repeated full-screen redraw, or nil.

Scrollback compaction (`tmux-control-compact-scrollback') splits captured
pane history into redraw \"frames\" at lines matching this regexp and then
collapses frames that repeat.  This only helps for TUIs that repaint by
reprinting their whole screen under a tmux running with `alternate-screen'
off, so each repaint is appended to history; the marker that delimits one
repaint is necessarily application-specific.  When nil (the default) no
frame splitting is done, so compaction makes no change and scrollback is
shown verbatim.

For example, the Claude Code TUI repaints a block whose top line begins
with \"[Session]\":

    (setq tmux-control-scrollback-frame-start-regexp \"\\\\`\\\\s-*\\\\[Session\\\\]\")"
  :type '(choice (const :tag "Disabled (verbatim scrollback)" nil) regexp))

(defcustom tmux-control-scrollback-chrome-regexps nil
  "Regexps matching volatile \"chrome\" lines to drop during compaction.

When compacting scrollback (see `tmux-control-scrollback-frame-start-regexp')
a line matching any of these is removed from each redraw frame before
frames are compared, so a status bar, credits line or rule that changes on
every repaint does not defeat de-duplication.  Each regexp is matched
against the line both as-is and trimmed of surrounding whitespace.  The
default is nil, so no lines are dropped.

For the Claude Code TUI, for example:

    (setq tmux-control-scrollback-chrome-regexps
          \\='(\"\\\\`\\\\[Session\\\\]\" \"AI Credits:\" \"\\\\`/ commands\"
            \"\\\\`[─━]\\\\{10,\\\\}\\\\\\='\" \"\\\\`❯\\\\\\='\"))"
  :type '(repeat regexp))

(defcustom tmux-control-wheel-enters-scrollback t
  "Non-nil means scrolling up with the mouse wheel enters scrollback view.

The wheel is only intercepted this way while the live pane shows its
normal screen.  When a full-screen application owns the alternate
screen (e.g. vim or less under a tmux that honors alternate-screen),
or when the application requests mouse events itself, the wheel event
is forwarded to the terminal unchanged."
  :type 'boolean)

(defcustom tmux-control-window-preview t
  "Non-nil means `tmux-control-select-window' shows a live preview chooser.

When enabled, choosing a window interactively opens a two-pane chooser
that lists the session's windows on one side and shows a snapshot of the
highlighted window's visible screen on the other, similar to tmux's own
`choose-tree' menu.  Set to nil to fall back to a plain completion prompt."
  :type 'boolean)

(defcustom tmux-control-window-preview-delay 0.15
  "Idle seconds to wait before refreshing the window preview as you move.

A small debounce keeps navigation snappy when previews require a remote
tmux query over SSH."
  :type 'number)

(defvar-local tmux-control--process nil)
(defvar-local tmux-control--terminal nil)
(defvar-local tmux-control--accumulator "")
(defvar-local tmux-control--display-dirty nil
  "Non-nil when Eat output has been fed but not yet redisplayed.
Set by `tmux-control--feed-terminal' and cleared by
`tmux-control--flush-display', which coalesces a chunk of streamed
%output into a single repaint.")
(defvar-local tmux-control--output-batch nil
  "Reverse-order list of decoded %output payloads awaiting a single feed.
Accumulated by `tmux-control--handle-line' and drained by
`tmux-control--flush-output-batch'.")
(defvar-local tmux-control--utf8-carry ""
  "Unibyte bytes of an incomplete trailing UTF-8 sequence held for the next feed.
tmux can split a multibyte character across two %output messages; the
per-message decoding leaves the halves as raw bytes, so the trailing
incomplete bytes are carried here and prepended to the next chunk by
`tmux-control--feed-terminal'.")
(defvar-local tmux-control--active-pane nil)
(defvar-local tmux-control--fallback-target nil)
(defvar-local tmux-control--host nil)
(defvar-local tmux-control--socket-name nil)
(defvar-local tmux-control--session nil)
(defvar-local tmux-control--scrollback-target nil)
(defvar-local tmux-control--command-queue nil)
(defvar-local tmux-control--current-command-kind :ignore)
(defvar-local tmux-control--collecting-command nil)
(defvar-local tmux-control--command-output nil)
(defvar-local tmux-control--seed-cursor nil
  "Most recent (X . Y) cursor position queried for a screen seed.
X and Y are tmux's 0-indexed cursor column and row on the visible
screen, or nil when the position has not been queried.  Used by the
`:capture' reply handler to place the cursor on the seeded screen.")
(defvar-local tmux-control--capture-trailing-p nil
  "Non-nil when the connected tmux supports `capture-pane -N' (3.1+).
With it, the screen seed preserves trailing background cells so full-width
background fills (tool-call panels, selections, status bars) survive a
reseed; set from the `#{version}' query on connect.")
(defvar-local tmux-control--keys-active nil)
(defvar-local tmux-control--live-buffer nil)
(defvar-local tmux-control--alt-screen-honored t
  "Non-nil when the controlled tmux honors alternate-screen for the active window.
When the active window's effective `alternate-screen' option is off,
tmux keeps the pane on its normal screen even while an application
requests the alternate screen, so Eat's alternate-display state is a
phantom and must be ignored.  Refreshed over the control connection
whenever the active pane changes.")

;; Multi-pane tiling (experimental).  In tiling mode the controller buffer
;; (the process buffer) stops rendering and instead fans the session's
;; %output out to one render buffer per pane, tiled into Emacs windows to
;; match tmux's window layout.  See the "Multi-pane tiling" section below.
(defvar-local tmux-control--controller nil
  "Controller buffer owning the shared tmux process, or nil.
Set in a tiled pane render buffer so its commands (input, select-pane)
route through the controller's single command queue and process.  nil in
the controller buffer itself and in an ordinary single-pane client.")
(defvar-local tmux-control--tiled nil
  "Non-nil in a controller buffer whose window is rendered as tiled panes.")
(defvar-local tmux-control--panes nil
  "In a tiled controller, an alist (PANE-ID . RENDER-BUFFER) in layout order.")
(defvar-local tmux-control--tiled-layout nil
  "Last window-layout string this controller tiled, to skip redundant re-tiles.")
(defvar-local tmux-control--retile-pending nil
  "Non-nil when a %layout-change asked for a re-tile at the next flush.")
(defvar-local tmux-control--retile-timer nil
  "Idle timer coalescing notification-driven re-tiles, or nil.
Re-tiling issues synchronous tmux queries (a blocking SSH round-trip when
remote), so it is debounced off the process filter instead of running
inline on every %layout-change.")
(defvar-local tmux-control--tiled-client-size nil
  "(W . H) char size last requested from tmux for the tiled frame area.
Compared on frame resize so tmux is only re-sized (and the panes re-tiled)
when the area devoted to tiling actually changed.")
(defvar-local tmux-control--suppress-focus-follow nil
  "When non-nil on a controller, pane focus does not drive tmux's select-pane.
Set while a window switch is in flight so the still-selected old window's
focus-follow does not `select-pane' a pane in the old window and yank the
active window back before the re-tile lands.  Cleared when the build finishes.")
(defvar tmux-control--killing-pane nil
  "Bound non-nil while tiling intentionally kills its own pane buffers.
A pane buffer's `kill-buffer-hook' re-tiles to recover a pane killed out
from under the tiling, but must not fire during teardown/reconciliation
kills, which are deliberate.")

(defvar tmux-control--override-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-e") #'tmux-control-scrollback)
    (define-key map (kbd "C-c C-k") #'tmux-control-disconnect)
    (define-key map (kbd "C-c C-l") #'tmux-control-clear-and-repaint)
    (define-key map (kbd "C-c C-o") #'tmux-control-other-pane)
    (define-key map (kbd "C-c C-t") #'tmux-control-toggle-tiling)
    (define-key map [wheel-up] #'tmux-control-wheel-scroll)
    map)
  "High-precedence keymap for tmux-control buffers.")

(defvar tmux-control--emulation-mode-map-alist
  `((tmux-control--keys-active . ,tmux-control--override-map))
  "Emulation map alist used to override Eat minor-mode bindings.")

(defvar tmux-control-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map eat-mode-map)
    (define-key map (kbd "C-c C-e") #'tmux-control-scrollback)
    (define-key map (kbd "C-c C-k") #'tmux-control-disconnect)
    (define-key map (kbd "C-c C-l") #'tmux-control-clear-and-repaint)
    (define-key map (kbd "C-c C-o") #'tmux-control-other-pane)
    (define-key map (kbd "C-c C-t") #'tmux-control-toggle-tiling)
    map)
  "Keymap for `tmux-control-mode'.")

(define-derived-mode tmux-control-mode eat-mode "tmux-control"
  "Major mode for tmux-control buffers."
  (tmux-control--disable-line-numbers)
  (tmux-control--disable-margins))

(defvar tmux-control-scrollback-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "g") #'tmux-control-scrollback-refresh)
    (define-key map (kbd "C-c C-e") #'tmux-control-live)
    (define-key map (kbd "RET") #'tmux-control-live)
    (define-key map (kbd "q") #'tmux-control-live)
    (define-key map [remap eat-semi-char-mode] #'tmux-control-live)
    (define-key map [remap self-insert-command] #'tmux-control-live-self-insert)
    map)
  "Keymap for `tmux-control-scrollback-mode'.")

(define-derived-mode tmux-control-scrollback-mode special-mode
  "tmux-control-scrollback"
  "Major mode for tmux-control scrollback buffers."
  (setq-local truncate-lines nil)
  (tmux-control--disable-line-numbers)
  (tmux-control--disable-margins))

(defun tmux-control--list-sessions (host socket-name)
  "Return existing tmux session names on HOST using SOCKET-NAME.

Return nil when no server is running or the query otherwise fails, so the
caller can offer completion when sessions exist and fall back to free
text (creating a new session) when they do not."
  (let ((args (append (when socket-name (list "-L" socket-name))
                      (list "list-sessions" "-F" "#{session_name}"))))
    (condition-case err
        (let ((text (if (and host (not (string-empty-p host)))
                        (tmux-control--call
                         "ssh"
                         (list host
                               (concat tmux-control-remote-tmux-socket-setup
                                       " && "
                                       (tmux-control--tmux-command-string args))))
                      (tmux-control--call "tmux" args))))
          (split-string (string-trim text) "\n" t))
      (error
       (message "tmux-control: could not list sessions (%s)"
                (error-message-string err))
       nil))))

(defun tmux-control--read-session (host socket-name)
  "Read a session name on HOST using SOCKET-NAME.

Offer completion over existing sessions.  Selecting one attaches to it;
typing a new name creates that session on connect."
  (let ((sessions (tmux-control--list-sessions host socket-name)))
    (completing-read "Session: " sessions nil nil nil nil
                     tmux-control-default-session)))

;;;###autoload
(defun tmux-control-connect (&optional host socket-name session)
  "Connect to a tmux SESSION through control mode.

When HOST is nil or empty, connect locally.  Otherwise connect over SSH.
SOCKET-NAME defaults to `tmux-control-default-socket-name', and SESSION
defaults to `tmux-control-default-session'.

Interactively, the session prompt completes over existing sessions on the
chosen host and socket; entering a name that does not exist creates that
session (tmux attaches if it exists, otherwise creates it)."
  (interactive
   (let* ((host (read-string "Host (empty for local): "
                             nil nil tmux-control-default-host))
          (socket-name (read-string "Socket name: "
                                    nil nil
                                    tmux-control-default-socket-name))
          (session (tmux-control--read-session
                    (unless (string-empty-p host) host)
                    socket-name)))
     (list (unless (string-empty-p host) host)
           socket-name
           session)))
  (setq socket-name (or socket-name tmux-control-default-socket-name))
  (setq session (or session tmux-control-default-session))
  (let* ((local (or (null host) (string-empty-p host)))
         (name (format "tmux-control:%s:%s"
                       (if local "local" host)
                       session))
         (buffer (get-buffer-create (format "*%s*" name)))
         (command (tmux-control--command host socket-name session)))
    (with-current-buffer buffer
      (tmux-control--reset-buffer)
      (setq tmux-control--host host)
      (setq tmux-control--socket-name socket-name)
      (setq tmux-control--session session)
      (setq tmux-control--fallback-target (concat session ":"))
      (setq tmux-control--process
            (make-process
             :name name
             :buffer buffer
             :command command
             :connection-type 'pipe
             :coding 'utf-8-unix
             :noquery t
             :filter #'tmux-control--filter
             :sentinel #'tmux-control--sentinel))
      ;; tmux runs the `new-session' command from our argv as its first
      ;; control-mode command and emits one %begin..%end reply for it before
      ;; any command we send.  Account for that startup reply so the
      ;; positional reply queue stays aligned and later replies -- notably the
      ;; `#{pane_id}' query that drives the initial screen seed -- are matched
      ;; to the correct handler instead of being shifted onto the wrong one.
      (setq tmux-control--command-queue (list :ignore))
      (process-put tmux-control--process 'adjust-window-size-function
                   #'tmux-control--adjust-window-size)
      (setf (eat-term-parameter tmux-control--terminal 'eat--process)
            tmux-control--process)
      (setf (eat-term-parameter tmux-control--terminal 'eat--input-process)
            tmux-control--process)
      (setf (eat-term-parameter tmux-control--terminal 'eat--output-process)
            tmux-control--process)
      (add-hook 'kill-buffer-hook #'tmux-control--kill-process nil t))
    (pop-to-buffer buffer)
    (with-current-buffer buffer
      (tmux-control--resize-to-window)
      ;; Learn the server version first so the screen seed knows whether it
      ;; can ask `capture-pane' to preserve trailing background cells (-N,
      ;; tmux 3.1+).  The reply lands before the :pane-id reply that seeds.
      (tmux-control--send-command "display-message -p '#{version}'" :version)
      (tmux-control--send-command "display-message -p '#{pane_id}'" :pane-id)
      (when (and (integerp tmux-control-pause-after)
                 (> tmux-control-pause-after 0))
        ;; Opt-in control-mode flow control: tmux pauses a lagging pane and
        ;; notifies with %pause instead of streaming an unbounded backlog.
        (tmux-control--send-command
         (format "refresh-client -f pause-after=%d" tmux-control-pause-after)))
      (tmux-control--disable-line-numbers))
    buffer))

(defun tmux-control-disconnect ()
  "Disconnect the current tmux-control client."
  (interactive)
  (when (process-live-p tmux-control--process)
    (delete-process tmux-control--process)))

(defun tmux-control-clear-and-repaint ()
  "Refresh the live view from the current tmux pane screen."
  (interactive)
  (tmux-control--seed-screen))

(defun tmux-control--list-windows (host socket-name session)
  "Return an alist of (INDEX-STRING . LABEL) for SESSION windows.

Queries tmux on HOST using SOCKET-NAME."
  (let* ((fmt "#{window_index}\t#{window_name}\t#{window_active}")
         (args (append (when socket-name (list "-L" socket-name))
                       (list "list-windows" "-t" session "-F" fmt)))
         (text (if (and host (not (string-empty-p host)))
                   (tmux-control--call
                    "ssh"
                    (list host
                          (concat tmux-control-remote-tmux-socket-setup
                                  " && "
                                  (tmux-control--tmux-command-string args))))
                 (tmux-control--call "tmux" args))))
    (delq nil
          (mapcar
           (lambda (line)
             (when (string-match "\\`\\([0-9]+\\)\t\\(.*\\)\t\\([01]\\)\\'" line)
               (let* ((index (match-string 1 line))
                      (name (match-string 2 line))
                      (active (string= (match-string 3 line) "1"))
                      (label (format "%s: %s%s" index name
                                     (if active " (active)" ""))))
                 (cons index
                       (if active
                           (propertize label 'tmux-window-active t)
                         label)))))
           (split-string (string-trim text) "\n" t)))))

(defun tmux-control--list-panes (host socket-name target)
  "Return an alist of (PANE-ID . LABEL) for the active window of TARGET.
Queries tmux on HOST using SOCKET-NAME.  LABEL shows the pane index, its
running command, its title when that differs, and whether it is active."
  (let* ((fmt "#{pane_id}\t#{pane_index}\t#{pane_active}\t#{pane_current_command}\t#{pane_title}")
         (args (append (when socket-name (list "-L" socket-name))
                       (list "list-panes" "-t" target "-F" fmt)))
         (text (if (and host (not (string-empty-p host)))
                   (tmux-control--call
                    "ssh"
                    (list host
                          (concat tmux-control-remote-tmux-socket-setup
                                  " && "
                                  (tmux-control--tmux-command-string args))))
                 (tmux-control--call "tmux" args))))
    (delq nil
          (mapcar
           (lambda (line)
             (when (string-match
                    "\\`\\(%[0-9]+\\)\t\\([0-9]+\\)\t\\([01]\\)\t\\([^\t]*\\)\t\\(.*\\)\\'"
                    line)
               (let* ((pane (match-string 1 line))
                      (index (match-string 2 line))
                      (active (string= (match-string 3 line) "1"))
                      (cmd (match-string 4 line))
                      (title (match-string 5 line))
                      (label (format "%s: %s%s%s"
                                     index cmd
                                     (if (and (not (string-empty-p title))
                                              (not (equal title cmd)))
                                         (format " (%s)" title)
                                       "")
                                     (if active " [active]" ""))))
                 (cons pane label))))
           (split-string (string-trim text) "\n" t)))))

(defun tmux-control--ensure-live ()
  "Signal a `user-error' unless this buffer has a live tmux-control session."
  (unless tmux-control--session
    (user-error "No tmux-control session in this buffer"))
  (unless (process-live-p tmux-control--process)
    (user-error "tmux-control process is not live")))

(defun tmux-control--refresh-active-pane ()
  "Re-query the session's active pane id, repaint the live view, and resize."
  (tmux-control--send-command "display-message -p '#{pane_id}'" :pane-id)
  (tmux-control--resize-to-window))

(defun tmux-control--interpret-alt-screen-reply (output global-p)
  "Interpret a `show-options' OUTPUT for the alternate-screen option.
OUTPUT is the list of reply lines.  When GLOBAL-P is nil this is the
window-level query: a value of \"on\"/\"off\" resolves the option and any
other (empty) reply means the window inherits it.  When GLOBAL-P is non-nil
this is the global default, which is on unless explicitly \"off\".
Returns (:honored . BOOL) when resolved, or the symbol `:inherit' when a
window-level reply is empty and the caller must query the global default.
Pure: no side effects, for unit testing the two-stage option protocol."
  (let ((val (car (cl-remove-if #'string-empty-p
                                (mapcar #'string-trim output)))))
    (cond
     (global-p (cons :honored (not (equal val "off"))))
     ((member val '("on" "off")) (cons :honored (string= val "on")))
     (t :inherit))))

(defun tmux-control--refresh-alt-screen-option ()
  "Re-query whether the active window honors the alternate-screen option.
Sends a control-mode `show-options' query for the active pane; the reply
updates `tmux-control--alt-screen-honored' so `tmux-control--alt-screen-p'
can distinguish a real alternate screen from a phantom one created when
tmux runs with `alternate-screen off'."
  (when (and tmux-control--active-pane
             (process-live-p tmux-control--process))
    (tmux-control--send-command
     (format "show-options -wv -t %s alternate-screen" tmux-control--active-pane)
     :alt-screen-opt)))

(defun tmux-control--read-window-index (prompt)
  "Read a window index for the current session using PROMPT with completion."
  (unless tmux-control--session
    (user-error "No tmux-control session in this buffer"))
  (let* ((windows (tmux-control--list-windows tmux-control--host
                                              tmux-control--socket-name
                                              tmux-control--session))
         (choices (mapcar (lambda (w) (cons (cdr w) (car w))) windows))
         (choice (completing-read prompt choices nil t)))
    (or (cdr (assoc choice choices))
        (car (split-string choice ":")))))

(defun tmux-control--normalize-window-index (index)
  "Return INDEX as a validated window-index string or signal a `user-error'."
  (when (integerp index)
    (setq index (number-to-string index)))
  (unless (and (stringp index) (string-match-p "\\`[0-9]+\\'" index))
    (user-error "Invalid tmux window index: %S" index))
  index)

(defun tmux-control--quote-tmux-arg (string)
  "Return STRING quoted for the tmux command parser."
  (concat "\"" (replace-regexp-in-string "[\"\\]" "\\\\\\&" string) "\""))

(defun tmux-control-select-window (&optional index)
  "Switch the live tmux-control view to window INDEX in the same session.

Interactively, open a preview chooser (see `tmux-control-window-preview')
or, when that is disabled, prompt with completion over the session's
windows.  Switching changes the session's active window, so any other
client attached to the same session follows along.

When INDEX is given non-interactively, switch to it directly."
  (interactive (list nil))
  (tmux-control--ensure-live)
  (cond
   (index
    (tmux-control--do-select-window
     (tmux-control--normalize-window-index index)))
   (tmux-control-window-preview
    (tmux-control--open-window-chooser))
   (t
    (tmux-control--do-select-window
     (tmux-control--normalize-window-index
      (tmux-control--read-window-index "Window: "))))))

(defun tmux-control--do-select-window (index)
  "Select tmux window INDEX in the current buffer's session.
When part of a tiling, the %session-window-changed notification re-tiles
to the new window's panes, so only the single-pane view reseeds here."
  (tmux-control--ensure-live)
  (let ((ctrl (tmux-control--tiling-controller)))
    ;; Suppress focus-follow across the switch: until the re-tile rebuilds,
    ;; the old window's pane stays selected, and its focus-follow would
    ;; `select-pane' it -- pulling the active window back to the old one.
    (when ctrl
      (with-current-buffer ctrl
        (setq tmux-control--suppress-focus-follow t)))
    (tmux-control--send-command
     (format "select-window -t %s:%s" tmux-control--session index))
    (unless ctrl
      (tmux-control--refresh-active-pane))))

(defun tmux-control-new-window (&optional name)
  "Create a new window in the current tmux-control session and switch to it.

With a NAME, give the new window that name."
  (interactive
   (list (let ((n (read-string "New window name (empty for default): ")))
           (unless (string-empty-p n) n))))
  (tmux-control--ensure-live)
  (tmux-control--send-command
   (concat (format "new-window -t %s:" tmux-control--session)
           (when (and name (not (string-empty-p name)))
             (concat " -n " (tmux-control--quote-tmux-arg name)))))
  (tmux-control--refresh-active-pane))

(defun tmux-control-kill-window (&optional index)
  "Kill window INDEX in the current tmux-control session.

Interactively, prompt with completion and confirm.  Killing the last
window in the session ends the session and disconnects this client."
  (interactive
   (let ((index (tmux-control--read-window-index "Kill window: ")))
     (unless (yes-or-no-p (format "Kill tmux window %s? " index))
       (user-error "Aborted"))
     (list index)))
  (tmux-control--ensure-live)
  (setq index (tmux-control--normalize-window-index index))
  (tmux-control--send-command
   (format "kill-window -t %s:%s" tmux-control--session index))
  (tmux-control--refresh-active-pane))

(defun tmux-control-rename-window (&optional index name)
  "Rename window INDEX in the current tmux-control session to NAME.

Interactively, prompt with completion for the window and read the new
name.  Renaming does not change which window is active, so the live view
is left untouched."
  (interactive
   (let* ((index (tmux-control--read-window-index "Rename window: "))
          (name (read-string (format "New name for window %s: " index))))
     (list index name)))
  (tmux-control--ensure-live)
  (when (or (null name) (string-empty-p name))
    (user-error "Window name must not be empty"))
  (setq index (tmux-control--normalize-window-index index))
  (tmux-control--send-command
   (format "rename-window -t %s:%s %s"
           tmux-control--session index
           (tmux-control--quote-tmux-arg name))))

(defun tmux-control-other-pane ()
  "Switch the live view to the next pane in the current window.
Only the active pane is mirrored in the live terminal, so in a split-pane
window -- for example a Claude Code agent team -- this steps to the next
pane (the next teammate).  tmux reports the change with %window-pane-changed
and the view repaints on the newly active pane.  Bound to \\`C-c C-o'.
See `tmux-control-select-pane' to jump to a pane by name."
  (interactive)
  (tmux-control--ensure-live)
  (tmux-control--send-command "select-pane -t :.+"))

(defun tmux-control--read-pane ()
  "Read a pane id of the current window using completion over its panes."
  (let* ((panes (tmux-control--list-panes tmux-control--host
                                          tmux-control--socket-name
                                          tmux-control--session))
         (choices (mapcar (lambda (p) (cons (cdr p) (car p))) panes)))
    (unless choices
      (user-error "No panes to choose from"))
    (or (cdr (assoc (completing-read "Pane: " choices nil t) choices))
        (user-error "No such pane"))))

(defun tmux-control-select-pane (&optional pane)
  "Switch the live view to another pane in the current window.
Interactively, complete over the window's panes -- a Claude Code agent
team shows each teammate as a pane, labelled by its command and title --
and focus the chosen one.  With PANE (a pane id) given non-interactively,
switch to it directly.  Switching sets the window's active pane, which
tmux reports so the view repaints on it."
  (interactive (list nil))
  (tmux-control--ensure-live)
  (let ((pane (or pane (tmux-control--read-pane))))
    (tmux-control--send-command (format "select-pane -t %s" pane))))


(defun tmux-control-scrollback ()
  "Show tmux pane history in a separate scrollback buffer as normal Emacs text.

Use `tmux-control-live' to return to the live interactive pane."
  (interactive)
  (unless tmux-control--session
    (user-error "No tmux-control session in this buffer"))
  (let* ((host tmux-control--host)
         (socket-name tmux-control--socket-name)
         (session tmux-control--session)
         (target (or tmux-control--active-pane tmux-control--fallback-target))
         (trailing tmux-control--capture-trailing-p)
         (text (tmux-control--capture-pane host socket-name target
                                           tmux-control-scrollback-lines
                                           trailing))
         (live-buffer (current-buffer))
         (scrollback-buffer-name (format "*%s-scrollback*" (buffer-name)))
         (scrollback-buffer (get-buffer-create scrollback-buffer-name)))
    (with-current-buffer scrollback-buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (tmux-control--prepare-scrollback-text text))
        (unless (bolp)
          (insert "\n"))
        (tmux-control-scrollback-mode)
        (tmux-control--disable-line-numbers)
        (setq-local tmux-control--host host)
        (setq-local tmux-control--socket-name socket-name)
        (setq-local tmux-control--session session)
        (setq-local tmux-control--scrollback-target target)
        (setq-local tmux-control--capture-trailing-p trailing)
        (setq-local tmux-control--live-buffer live-buffer)
        (setq-local header-line-format
                    (format " %s socket:%s session:%s target:%s    g:refresh  q/l/RET:live"
                            (or host "local")
                            socket-name
                            session
                            target))
        (goto-char (point-max))))
    (switch-to-buffer scrollback-buffer)
    (when-let* ((window (get-buffer-window scrollback-buffer)))
      (set-window-margins window 0 0))
    (goto-char (point-max))
    (when (get-buffer-window scrollback-buffer)
      (recenter -1))))

(defun tmux-control-scrollback-refresh ()
  "Refresh the current tmux-control scrollback view."
  (interactive)
  (unless (derived-mode-p 'tmux-control-scrollback-mode)
    (user-error "Not in tmux-control scrollback mode"))
  (let* ((line (line-number-at-pos))
         (column (current-column))
         (at-end (eobp))
         (text (tmux-control--capture-pane tmux-control--host
                                           tmux-control--socket-name
                                           tmux-control--scrollback-target
                                           tmux-control-scrollback-lines
                                           tmux-control--capture-trailing-p))
         (inhibit-read-only t))
    (when-let* ((window (get-buffer-window (current-buffer))))
      (set-window-margins window 0 0))
    (erase-buffer)
    (insert (tmux-control--prepare-scrollback-text text))
    (unless (bolp)
      (insert "\n"))
    (if at-end
        (progn
          (goto-char (point-max))
          (when (get-buffer-window (current-buffer))
            (recenter -1)))
      (goto-char (point-min))
      (forward-line (1- line))
      (move-to-column column))))

(defun tmux-control-live ()
  "Return from scrollback view to the live interactive tmux pane."
  (interactive)
  (unless (derived-mode-p 'tmux-control-scrollback-mode)
    (user-error "Not in tmux-control scrollback mode"))
  (let ((live-buf tmux-control--live-buffer))
    (if (buffer-live-p live-buf)
        (let ((scrollback-buf (current-buffer)))
          (switch-to-buffer live-buf)
          (kill-buffer scrollback-buf))
      (tmux-control-connect tmux-control--host
                            tmux-control--socket-name
                            tmux-control--session))))

(defun tmux-control-live-self-insert ()
  "Return to the live pane and send the typed character to it.
Bound to ordinary text keys in scrollback view so that simply starting
to type your next command resumes the live pane and forwards the
keystroke, rather than dropping it."
  (interactive)
  (let ((event last-command-event))
    (tmux-control-live)
    (when (and (characterp event)
               (derived-mode-p 'tmux-control-mode)
               tmux-control--terminal
               (eat-term-live-p tmux-control--terminal))
      (eat-self-input 1 event))))

(defun tmux-control--alt-screen-effective-p (honored eat-alt-display-p)
  "Combine HONORED with EAT-ALT-DISPLAY-P into the effective alt-screen state.
HONORED is whether the active tmux window honors the `alternate-screen'
option; EAT-ALT-DISPLAY-P is whether Eat currently reports the alternate
display.  Returns a normalized boolean: the pane is truly on the alternate
screen only when both hold.  Pure: no side effects, for unit testing the
phantom-alternate-screen gating."
  (and honored eat-alt-display-p t))

(defun tmux-control--alt-screen-p ()
  "Return non-nil when the live pane truly shows the alternate display.
This is the full-screen display used by TUI applications such as vim or
less when the controlled tmux honors the alternate screen.  It is non-nil
only when BOTH Eat reports the alternate display AND the active window's
effective `alternate-screen' option is on (`tmux-control--alt-screen-honored').
When that option is off, tmux keeps the pane on its normal screen and
forwards a phantom alternate-screen request to the control client, so
Eat's state alone is unreliable.  Read locally, with no tmux query."
  (and tmux-control--alt-screen-honored
       tmux-control--terminal
       (eat-term-live-p tmux-control--terminal)
       (tmux-control--alt-screen-effective-p
        tmux-control--alt-screen-honored
        (cond
         ((fboundp 'eat-term-in-alternative-display-p)
          (eat-term-in-alternative-display-p tmux-control--terminal))
         ((fboundp 'eat--t-term-main-display)
          (eat--t-term-main-display tmux-control--terminal))))))

(defun tmux-control--pane-grabs-mouse-p ()
  "Return non-nil when the pane's application has requested mouse tracking.
Such applications (full-screen TUIs, but also normal-screen programs like
`less -X') expect to receive wheel events themselves."
  (and (boundp 'eat--mouse-grabbing-type)
       eat--mouse-grabbing-type
       t))

(defun tmux-control--wheel-detectable-p ()
  "Return non-nil when Eat exposes the screen state used for wheel gating."
  (or (fboundp 'eat-term-in-alternative-display-p)
      (fboundp 'eat--t-term-main-display)))

(defun tmux-control--wheel-should-enter-scrollback-p
    (direction enabled detectable alt-screen grabs-mouse)
  "Return non-nil when a wheel event should open the Emacs scrollback view.
DIRECTION is the wheel `event-basic-type'.  ENABLED is
`tmux-control-wheel-enters-scrollback'.  DETECTABLE is whether Eat's screen
state can be read.  ALT-SCREEN is whether the pane truly shows the alternate
display.  GRABS-MOUSE is whether the application requested mouse tracking.
Scrollback is entered only on wheel-up over a readable normal-screen pane
that has not grabbed the mouse.  Pure: the decision behind
`tmux-control-wheel-scroll', extracted for unit testing."
  (and enabled
       (eq direction 'wheel-up)
       detectable
       (not alt-screen)
       (not grabs-mouse)))

(defun tmux-control-wheel-scroll (event)
  "Handle a mouse wheel EVENT in a live tmux-control buffer.

When scrolling up over a pane that shows its normal screen and whose
application has not requested mouse tracking, enter the Emacs scrollback
buffer (when `tmux-control-wheel-enters-scrollback').  This is the
Emacs-side analog of tmux's default wheel-up binding, which opens
copy-mode scrollback for normal-screen panes.

In every other case -- a genuine full-screen (alternate-screen)
application, a mouse-aware application, or wheel-down -- the event is
forwarded to the terminal unchanged so the application keeps its own
handling.

The scrollback interception is only active when Eat's screen state can
be read, so the live behavior is otherwise unchanged."
  (interactive "e")
  (let ((window (posn-window (event-start event)))
        (direction (event-basic-type event)))
    (if (window-live-p window)
        (with-current-buffer (window-buffer window)
          (cond
           ((and (derived-mode-p 'tmux-control-mode)
                 (tmux-control--wheel-should-enter-scrollback-p
                  direction
                  tmux-control-wheel-enters-scrollback
                  (tmux-control--wheel-detectable-p)
                  (tmux-control--alt-screen-p)
                  (tmux-control--pane-grabs-mouse-p)))
            (select-window window)
            (tmux-control-scrollback))
           (t
            (with-selected-window window
              (eat-self-input 1 event)))))
      (eat-self-input 1 event))))

(defun tmux-control--disable-line-numbers ()
  "Disable line numbers in tmux-control buffers."
  (setq-local display-line-numbers nil)
  (when (fboundp 'display-line-numbers-mode)
    (display-line-numbers-mode -1))
  (when (fboundp 'linum-mode)
    (linum-mode -1))
  (setq-local display-line-numbers nil))

(defun tmux-control--disable-margins ()
  "Remove display margins so the terminal owns its first and last columns.
A nonzero `left-margin-width' inherited from the user's defaults would
clip the leftmost terminal column (e.g. a prompt glyph)."
  (setq-local left-margin-width 0)
  (setq-local right-margin-width 0)
  (dolist (window (get-buffer-window-list (current-buffer) nil t))
    (set-window-margins window 0 0)))

(defun tmux-control--eat-semi-char-mode-advice (orig-fn &rest args)
  "Make `eat-semi-char-mode' return tmux-control scrollback buffers live."
  (if (derived-mode-p 'tmux-control-scrollback-mode)
      (progn
        (tmux-control-live)
        (unless (bound-and-true-p eat--semi-char-mode)
          (eat-semi-char-mode)))
    (apply orig-fn args)))

(advice-remove #'eat-semi-char-mode
               #'tmux-control--eat-semi-char-mode-advice)
(advice-add #'eat-semi-char-mode
            :around #'tmux-control--eat-semi-char-mode-advice)

(defun tmux-control--reset-buffer ()
  "Reset the current buffer for a fresh tmux-control session."
  ;; A reconnect into a buffer that was tiled would `kill-all-local-variables'
  ;; (via `tmux-control-mode') and orphan its pane render buffers; tear the
  ;; tiling down first so they are killed and the state is clean.
  (when tmux-control--tiled
    (tmux-control--teardown-tiling (current-buffer) t))
  (let ((inhibit-read-only t))
    (when (process-live-p tmux-control--process)
      (delete-process tmux-control--process))
    (remove-hook 'kill-buffer-hook #'tmux-control--kill-process t)
    (erase-buffer)
    (tmux-control-mode)
    (setq-local emulation-mode-map-alists
                (cons tmux-control--emulation-mode-map-alist
                      (delq tmux-control--emulation-mode-map-alist
                            emulation-mode-map-alists)))
    (setq tmux-control--keys-active t)
    (setq tmux-control--accumulator "")
    (setq tmux-control--display-dirty nil)
    (setq tmux-control--output-batch nil)
    (setq tmux-control--utf8-carry "")
    (setq tmux-control--capture-trailing-p nil)
    (setq tmux-control--active-pane nil)
    (setq tmux-control--alt-screen-honored t)
    (setq tmux-control--command-queue nil)
    (setq tmux-control--current-command-kind :ignore)
    (setq tmux-control--collecting-command nil)
    (setq tmux-control--command-output nil)
    (setq tmux-control--seed-cursor nil)
    (setq tmux-control--terminal (eat-term-make (current-buffer) (point-min)))
    (setq eat-terminal tmux-control--terminal)
    (eat-semi-char-mode)
    (setf (eat-term-parameter tmux-control--terminal 'input-function)
          #'tmux-control--send-input)
    (setf (eat-term-parameter tmux-control--terminal 'set-cursor-function)
          (if (fboundp 'eat--set-cursor) #'eat--set-cursor #'ignore))
    (setf (eat-term-parameter tmux-control--terminal 'grab-mouse-function)
          (if (fboundp 'eat--grab-mouse) #'eat--grab-mouse #'ignore))
    (setf (eat-term-parameter tmux-control--terminal 'ring-bell-function)
          (if (fboundp 'eat--bell) #'eat--bell #'ignore))
    (setf (eat-term-parameter tmux-control--terminal 'manipulate-selection-function)
          (if (fboundp 'eat--manipulate-kill-ring)
              #'eat--manipulate-kill-ring
            #'ignore))
    (tmux-control--disable-line-numbers)))

(defun tmux-control--stop-live-process ()
  "Stop the live tmux control process without killing the tmux session."
  (when (process-live-p tmux-control--process)
    (delete-process tmux-control--process))
  (setq tmux-control--process nil)
  (setq tmux-control--terminal nil)
  (setq eat-terminal nil)
  (setq tmux-control--keys-active nil)
  (remove-hook 'kill-buffer-hook #'tmux-control--kill-process t))

(defun tmux-control--command (host socket-name session)
  "Return process command for HOST, SOCKET-NAME, and SESSION."
  (let ((tmux-args `("tmux" "-L" ,socket-name "-C"
                     "new-session" "-A" "-s" ,session)))
    (if (or (null host) (string-empty-p host))
        tmux-args
      (list "ssh" host
            (concat tmux-control-remote-tmux-socket-setup
                    "; exec "
                    (mapconcat #'shell-quote-argument tmux-args " "))))))

(defun tmux-control--tmux-command-string (args)
  "Return a shell command string for tmux ARGS."
  (mapconcat #'shell-quote-argument (cons "tmux" args) " "))

(defun tmux-control--capture-pane (host socket-name target lines
                                        &optional preserve-trailing)
  "Return plain text from tmux pane on HOST using SOCKET-NAME and TARGET.
With PRESERVE-TRAILING non-nil add `capture-pane -N' so trailing background
cells (full-width fills such as a TUI tool panel or status bar) are kept;
the caller must only set it when the server supports -N (tmux 3.1+)."
  (let ((args (append (when socket-name
                        (list "-L" socket-name))
                      (list "capture-pane" "-p" "-e")
                      (when tmux-control-scrollback-join-wrapped-lines
                        (list "-J"))
                      (when preserve-trailing
                        (list "-N"))
                      (list "-S" (format "-%d" lines))
                      (when target
                        (list "-t" target)))))
    (if (and host (not (string-empty-p host)))
        (tmux-control--call
         "ssh"
         (list host
               (concat tmux-control-remote-tmux-socket-setup
                       " && "
                       (tmux-control--tmux-command-string args))))
      (tmux-control--call "tmux" args))))

(defun tmux-control--call (program args)
  "Call PROGRAM with ARGS and return stdout.

Always run PROGRAM on the local machine.  `default-directory' is pinned
to a local directory and `call-process' (not `process-file') is used so
the call never routes through TRAMP, even when invoked from a buffer
whose `default-directory' is remote."
  (let ((stderr-file (make-temp-file "tmux-control-stderr-"))
        (default-directory temporary-file-directory))
    (unwind-protect
        (with-temp-buffer
          (let ((exit-code
                 (apply #'call-process program nil (list t stderr-file) nil args)))
            (if (equal exit-code 0)
                (buffer-string)
              (let ((stderr (with-temp-buffer
                              (insert-file-contents stderr-file)
                              (string-trim (buffer-string)))))
                (error "%s failed: %s"
                       program
                       (if (string-empty-p stderr)
                           (format "exit %s" exit-code)
                         stderr))))))
      (when (file-exists-p stderr-file)
        (delete-file stderr-file)))))

(defun tmux-control--trim-trailing-blank-lines (text)
  "Trim trailing blank lines from TEXT."
  (replace-regexp-in-string "[[:blank:]\n\r]+\\'" "\n" text))

(defun tmux-control--colorize-scrollback (text)
  "Convert ANSI escapes in TEXT to face text properties.
Apply colors across the whole multi-line string so SGR state
carries correctly across line boundaries, then remove any
remaining non-printing control sequences (for example OSC
hyperlinks) that are not colors.  The result carries colors as
text properties and contains no escape characters, so the
scrollback compaction heuristics -- which compare characters and
ignore text properties -- keep working unchanged."
  (tmux-control--strip-ansi
   (let ((ansi-color-context nil))
     (ansi-color-apply text))))

(defun tmux-control--prepare-scrollback-text (text)
  "Prepare captured pane TEXT for the scrollback buffer.
Compaction runs only when it is both enabled and given a frame marker to
work with: without `tmux-control-scrollback-frame-start-regexp' it can
de-duplicate nothing, and its line trimming would needlessly strip the
trailing background cells `capture-pane -N' preserves for full-width
fills.  So a default (unconfigured) scrollback is shown verbatim, colors
and trailing backgrounds intact."
  (let ((text (tmux-control--colorize-scrollback text)))
    (tmux-control--trim-trailing-blank-lines
     (if (and tmux-control-compact-scrollback
              tmux-control-scrollback-frame-start-regexp)
         (tmux-control--compact-repeated-redraw-lines text)
       text))))


;;;; Window chooser with live preview

(defvar-local tmux-control--chooser-host nil)
(defvar-local tmux-control--chooser-socket nil)
(defvar-local tmux-control--chooser-session nil)
(defvar-local tmux-control--chooser-live-buffer nil)
(defvar-local tmux-control--chooser-preview-buffer nil)
(defvar-local tmux-control--chooser-saved-config nil)
(defvar-local tmux-control--chooser-cache nil)
(defvar-local tmux-control--chooser-last-index nil)
(defvar-local tmux-control--chooser-trailing nil)
(defvar-local tmux-control--window-chooser-keys-active nil)
(defvar tmux-control--window-preview-timer nil
  "Idle timer that refreshes the window preview, or nil.")

(defvar tmux-control--window-chooser-override-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "n") #'tmux-control--window-chooser-next)
    (define-key map (kbd "p") #'tmux-control--window-chooser-previous)
    (define-key map (kbd "C-n") #'tmux-control--window-chooser-next)
    (define-key map (kbd "C-p") #'tmux-control--window-chooser-previous)
    (define-key map (kbd "<down>") #'tmux-control--window-chooser-next)
    (define-key map (kbd "<up>") #'tmux-control--window-chooser-previous)
    (define-key map (kbd "RET") #'tmux-control--window-chooser-select)
    (define-key map (kbd "C-m") #'tmux-control--window-chooser-select)
    (define-key map (kbd "q") #'tmux-control--window-chooser-abort)
    (define-key map (kbd "C-g") #'tmux-control--window-chooser-abort)
    (define-key map [mouse-1] #'tmux-control--window-chooser-mouse-select)
    (define-key map [double-mouse-1] #'tmux-control--window-chooser-mouse-select)
    map)
  "High-precedence keymap for the tmux-control window chooser.
Installed through `emulation-mode-map-alists' so its bindings win over
modal-editing packages such as `xah-fly-keys' or `evil' that otherwise
own ordinary letters in a read-only buffer.")

(defvar tmux-control--window-chooser-emulation-alist
  `((tmux-control--window-chooser-keys-active
     . ,tmux-control--window-chooser-override-map))
  "Emulation map alist that activates the window-chooser override map.")

(define-derived-mode tmux-control-window-chooser-mode special-mode
  "tmux-window-chooser"
  "Major mode for the tmux-control window chooser buffer."
  (setq-local emulation-mode-map-alists
              (cons tmux-control--window-chooser-emulation-alist
                    (delq tmux-control--window-chooser-emulation-alist
                          emulation-mode-map-alists)))
  (setq tmux-control--window-chooser-keys-active t)
  (setq-local cursor-type nil)
  (setq-local truncate-lines t)
  (hl-line-mode 1)
  ;; The user's global `hl-line' background may be too subtle to mark the
  ;; selection, and the cursor is hidden, so remap the current-line
  ;; highlight to the theme's prominent `region' face just in this buffer.
  (face-remap-add-relative 'hl-line 'region)
  (tmux-control--disable-line-numbers)
  (tmux-control--disable-margins))

(defun tmux-control--chooser-line-index ()
  "Return the window index stored on the current chooser line, or nil."
  (get-text-property (line-beginning-position) 'tmux-window-index))

(defun tmux-control--window-chooser-next ()
  "Move to the next window entry in the chooser."
  (interactive)
  (let ((start (point)))
    (forward-line 1)
    (if (tmux-control--chooser-line-index)
        (beginning-of-line)
      (goto-char start))))

(defun tmux-control--window-chooser-previous ()
  "Move to the previous window entry in the chooser."
  (interactive)
  (forward-line -1)
  (beginning-of-line))

(defun tmux-control--chooser-goto-active ()
  "Move point to the line of the active window entry, if any.
The active entry's label carries a `tmux-window-active' text
property (added by `tmux-control--list-windows').  Fall back to the
first entry when no active window is marked."
  (goto-char (point-min))
  (let ((pos (point-min))
        (found nil))
    (while (and (not found) (< pos (point-max)))
      (if (get-text-property pos 'tmux-window-active)
          (setq found pos)
        (setq pos (or (next-single-property-change pos 'tmux-window-active)
                      (point-max)))))
    (when found
      (goto-char found)
      (beginning-of-line))))

(defun tmux-control--capture-window-screen (host socket-name session index
                                                 &optional preserve-trailing)
  "Capture the visible screen of SESSION:INDEX active pane as colored text.
Run tmux on HOST using SOCKET-NAME, or locally when HOST is nil/empty.
With PRESERVE-TRAILING add `capture-pane -N' (tmux 3.1+) so full-width
background fills survive in the preview."
  (let* ((target (format "%s:%s" session index))
         (args (append (when socket-name (list "-L" socket-name))
                       (list "capture-pane" "-p" "-e")
                       (when preserve-trailing (list "-N"))
                       (list "-t" target))))
    (if (and host (not (string-empty-p host)))
        (tmux-control--call
         "ssh"
         (list host
               (concat tmux-control-remote-tmux-socket-setup
                       " && "
                       (tmux-control--tmux-command-string args))))
      (tmux-control--call "tmux" args))))

(defun tmux-control--render-window-preview (host socket-name session index
                                                 &optional preserve-trailing)
  "Return colored preview text for SESSION:INDEX, or an error placeholder."
  (condition-case err
      (tmux-control--colorize-scrollback
       (tmux-control--capture-window-screen host socket-name session index
                                            preserve-trailing))
    (error (format "[preview unavailable: %s]" (error-message-string err)))))

(defun tmux-control--chooser-update-preview ()
  "Render the highlighted window into the preview buffer, using a cache."
  (let ((index tmux-control--chooser-last-index)
        (preview tmux-control--chooser-preview-buffer)
        (host tmux-control--chooser-host)
        (socket tmux-control--chooser-socket)
        (session tmux-control--chooser-session)
        (trailing tmux-control--chooser-trailing))
    (when (and index (buffer-live-p preview))
      (let ((rendered
             (or (cdr (assoc index tmux-control--chooser-cache))
                 (let ((text (tmux-control--render-window-preview
                              host socket session index trailing)))
                   (push (cons index text) tmux-control--chooser-cache)
                   text))))
        (with-current-buffer preview
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert rendered)
            (goto-char (point-min))))))))

(defun tmux-control--chooser-maybe-preview ()
  "When the highlighted window changed, schedule a debounced preview refresh."
  (let ((index (tmux-control--chooser-line-index)))
    (unless (equal index tmux-control--chooser-last-index)
      (setq tmux-control--chooser-last-index index)
      (when (timerp tmux-control--window-preview-timer)
        (cancel-timer tmux-control--window-preview-timer))
      (let ((buffer (current-buffer)))
        (setq tmux-control--window-preview-timer
              (run-with-idle-timer
               tmux-control-window-preview-delay nil
               (lambda ()
                 (when (buffer-live-p buffer)
                   (with-current-buffer buffer
                     (tmux-control--chooser-update-preview))))))))))

(defun tmux-control--window-chooser-dispose ()
  "Tear down any existing chooser buffers and preview timer.
Unlike `tmux-control--window-chooser-cleanup', this does not assume the
current buffer is the chooser and does not restore a window
configuration.  It enforces a single live chooser by removing leftovers
before a new one opens."
  (when (timerp tmux-control--window-preview-timer)
    (cancel-timer tmux-control--window-preview-timer)
    (setq tmux-control--window-preview-timer nil))
  (let ((kill-buffer-query-functions nil))
    (dolist (name '("*tmux-control-window-chooser*"
                    "*tmux-control-window-preview*"))
      (let ((buf (get-buffer name)))
        (when (buffer-live-p buf)
          (kill-buffer buf))))))

(defun tmux-control--window-chooser-cleanup ()
  "Tear down the chooser: cancel timers, restore windows, remove buffers."
  (when (timerp tmux-control--window-preview-timer)
    (cancel-timer tmux-control--window-preview-timer)
    (setq tmux-control--window-preview-timer nil))
  (let ((saved tmux-control--chooser-saved-config)
        (preview tmux-control--chooser-preview-buffer)
        (chooser (current-buffer)))
    (when (window-configuration-p saved)
      (set-window-configuration saved))
    (when (buffer-live-p preview)
      (let ((kill-buffer-query-functions nil))
        (kill-buffer preview)))
    (when (buffer-live-p chooser)
      (let ((kill-buffer-query-functions nil))
        (kill-buffer chooser)))))

(defun tmux-control--window-chooser-select ()
  "Select the highlighted window and return to the live pane."
  (interactive)
  (let ((index (tmux-control--chooser-line-index))
        (live tmux-control--chooser-live-buffer))
    (unless index
      (user-error "No window on this line"))
    (tmux-control--window-chooser-cleanup)
    (if (buffer-live-p live)
        (with-current-buffer live
          (tmux-control--do-select-window
           (tmux-control--normalize-window-index index)))
      (user-error "tmux-control buffer is gone"))))

(defun tmux-control--window-chooser-mouse-select (event)
  "Select the window clicked in the chooser via EVENT."
  (interactive "e")
  (mouse-set-point event)
  (tmux-control--window-chooser-select))

(defun tmux-control--window-chooser-abort ()
  "Cancel window selection and restore the previous layout."
  (interactive)
  (tmux-control--window-chooser-cleanup)
  (message "Window selection canceled"))

(defun tmux-control--open-window-chooser ()
  "Open the two-pane window chooser for the current tmux-control session.
On any failure to build the two-pane layout (for example a frame too
small to split), restore the previous layout and fall back to plain
completion so the user is never stranded in a half-built chooser."
  (let* ((host tmux-control--host)
         (socket tmux-control--socket-name)
         (session tmux-control--session)
         (trailing tmux-control--capture-trailing-p)
         (live-buffer (current-buffer))
         (windows (tmux-control--list-windows host socket session)))
    (unless windows
      (user-error "No windows to choose from"))
    (tmux-control--window-chooser-dispose)
    (let ((chooser (get-buffer-create "*tmux-control-window-chooser*"))
          (preview (get-buffer-create "*tmux-control-window-preview*"))
          (saved (current-window-configuration)))
      (condition-case err
          (progn
            (with-current-buffer preview
              (let ((inhibit-read-only t))
                (erase-buffer))
              (unless (derived-mode-p 'special-mode)
                (special-mode))
              (setq-local truncate-lines t)
              (setq-local header-line-format " Preview")
              (tmux-control--disable-line-numbers))
            (with-current-buffer chooser
              (tmux-control-window-chooser-mode)
              (let ((inhibit-read-only t))
                (erase-buffer)
                (insert (mapconcat
                         (lambda (w)
                           (propertize (cdr w) 'tmux-window-index (car w)))
                         windows "\n")))
              (tmux-control--chooser-goto-active)
              (setq tmux-control--chooser-host host
                    tmux-control--chooser-socket socket
                    tmux-control--chooser-session session
                    tmux-control--chooser-trailing trailing
                    tmux-control--chooser-live-buffer live-buffer
                    tmux-control--chooser-preview-buffer preview
                    tmux-control--chooser-saved-config saved
                    tmux-control--chooser-cache nil
                    tmux-control--chooser-last-index nil)
              (setq-local header-line-format
                          " Select window  —  move: arrows / n,p / mouse   RET: select   q or C-g: cancel")
              (add-hook 'post-command-hook
                        #'tmux-control--chooser-maybe-preview nil t))
            (delete-other-windows)
            (switch-to-buffer chooser)
            (let ((preview-window (split-window-right)))
              (set-window-buffer preview-window preview)
              (set-window-parameter preview-window 'no-other-window t))
            (tmux-control--chooser-maybe-preview))
        (error
         (when (window-configuration-p saved)
           (set-window-configuration saved))
         (let ((kill-buffer-query-functions nil))
           (when (buffer-live-p preview) (kill-buffer preview))
           (when (buffer-live-p chooser) (kill-buffer chooser)))
         (message "tmux-control: window chooser unavailable (%s); using completion"
                  (error-message-string err))
         (when (buffer-live-p live-buffer)
           (with-current-buffer live-buffer
             (tmux-control--do-select-window
              (tmux-control--normalize-window-index
               (tmux-control--read-window-index "Window: "))))))))))

(defun tmux-control--compact-repeated-redraw-lines (text)
  "Compact repeated full-screen redraw chunks in TEXT."
  (let (out)
    (dolist (chunk (tmux-control--scrollback-chunks text))
      (setq chunk (tmux-control--strip-scrollback-chrome chunk))
      (when (tmux-control--line-list-has-content-p chunk)
        (setq out (tmux-control--merge-scrollback-chunk out chunk))))
    (tmux-control--squeeze-blank-lines
     (string-join out "\n"))))

(defun tmux-control--scrollback-chunks (text)
  "Split captured pane TEXT into likely TUI redraw chunks."
  (let (chunks current)
    (dolist (line (mapcar #'string-trim-right
                          (split-string text "\n")))
      (when (and current
                 (tmux-control--scrollback-frame-start-line-p line))
        (push (nreverse current) chunks)
        (setq current nil))
      (push line current))
    (when current
      (push (nreverse current) chunks))
    (nreverse chunks)))

(defun tmux-control--scrollback-frame-start-line-p (line)
  "Return non-nil when LINE looks like the start of a TUI redraw frame.
Matches against `tmux-control-scrollback-frame-start-regexp'; always nil
when that option is unset, so compaction does nothing without a configured
frame marker."
  (and tmux-control-scrollback-frame-start-regexp
       (string-match-p tmux-control-scrollback-frame-start-regexp line)))

(defun tmux-control--strip-scrollback-chrome (lines)
  "Remove obvious TUI chrome from captured LINES."
  (tmux-control--trim-blank-line-list
   (seq-remove #'tmux-control--scrollback-chrome-line-p lines)))

(defun tmux-control--scrollback-chrome-line-p (line)
  "Return non-nil when LINE matches any `tmux-control-scrollback-chrome-regexps'.
Each pattern is tried against LINE as-is and trimmed of surrounding
whitespace, so an anchored pattern matches regardless of indentation.
Returns nil when no chrome patterns are configured."
  (let ((trimmed (string-trim line)))
    (seq-some (lambda (re)
                (or (string-match-p re line)
                    (string-match-p re trimmed)))
              tmux-control-scrollback-chrome-regexps)))

(defun tmux-control--merge-scrollback-chunk (out chunk)
  "Merge CHUNK into OUT without duplicating repeated redraw content."
  (setq chunk (tmux-control--trim-blank-line-list chunk))
  (cond
   ((null chunk) out)
   ((null out) chunk)
   ((tmux-control--line-list-contains-p out chunk) out)
   (t
    (let ((overlap (tmux-control--line-list-overlap out chunk)))
      (if (> overlap 0)
          ;; A clean suffix/prefix overlap: extend OUT with the new tail.
          (append out (nthcdr overlap chunk))
        ;; No clean overlap.  The chunk may still embed a previously seen
        ;; full-screen redraw body wrapped in new volatile lines (an
        ;; evolving prompt, a status bar).  Drop those already-seen
        ;; interior runs, then append whatever genuinely new lines remain.
        (let ((remainder (tmux-control--trim-blank-line-list
                          (tmux-control--strip-seen-runs out chunk))))
          (cond
           ((null remainder) out)
           ((tmux-control--line-list-contains-p out remainder) out)
           (t
            (append out
                    (unless (or (string-empty-p (string-trim (car (last out))))
                                (string-empty-p (string-trim (car remainder))))
                      '(""))
                    remainder)))))))))

(defconst tmux-control--scrollback-min-redraw-run 6
  "Minimum contiguous line-run length treated as a repeated redraw body.
Shorter repeats are preserved, so ordinary repeated command output (a
small table, a two-line banner) is never silently dropped.")

(defun tmux-control--redraw-run-distinctive-p (lines)
  "Return non-nil when LINES are substantial enough to be a redraw body.
Requires several nonblank lines with enough distinct content, so that
generic filler (blank lines, repeated rule characters) is not mistaken
for a repeated full-screen panel."
  (let ((nonblank (seq-filter (lambda (line)
                                (not (string-empty-p (string-trim line))))
                              lines)))
    (and (>= (length nonblank) 4)
         (>= (length (seq-uniq (mapcar #'string-trim nonblank))) 3))))

(defun tmux-control--seen-run-length (haystack chunk start n)
  "Return the length of the longest already-seen redraw run of CHUNK at START.
Considers runs from START up to N, returning the longest contiguous run
that is distinctive (`tmux-control--redraw-run-distinctive-p') and already
present in HAYSTACK, or nil when no qualifying run starts at START."
  (let ((len (min (- n start) tmux-control-compact-scrollback-window))
        (found nil))
    (while (and (>= len tmux-control--scrollback-min-redraw-run)
                (not found))
      (let ((candidate (cl-subseq chunk start (+ start len))))
        (when (and (tmux-control--redraw-run-distinctive-p candidate)
                   (cl-search candidate haystack :test #'string=))
          (setq found len)))
      (setq len (1- len)))
    found))

(defun tmux-control--strip-seen-runs (out chunk)
  "Remove from CHUNK contiguous line runs already present in recent OUT.
Only long, distinctive runs are removed, so repeated full-screen TUI
redraw bodies collapse to a single copy while genuinely new lines (and
ordinary short repeats) are kept.  OUT is searched only within the recent
`tmux-control-compact-scrollback-window' lines."
  (let* ((haystack (last out tmux-control-compact-scrollback-window))
         (n (length chunk))
         (i 0)
         (result '()))
    (while (< i n)
      (let ((run-len (tmux-control--seen-run-length haystack chunk i n)))
        (if run-len
            (setq i (+ i run-len))
          (push (nth i chunk) result)
          (setq i (1+ i)))))
    (nreverse result)))

(defun tmux-control--line-list-contains-p (haystack needle)
  "Return non-nil when HAYSTACK contains NEEDLE as contiguous lines."
  (and (<= (length needle) (length haystack))
       (cl-search needle haystack :test #'string=)))

(defun tmux-control--line-list-overlap (left right)
  "Return largest safe suffix/prefix overlap between LEFT and RIGHT."
  (let* ((max (min (length left)
                   (length right)
                   tmux-control-compact-scrollback-window))
         (overlap 0))
    (while (and (> max 0) (= overlap 0))
      (let ((candidate (cl-subseq right 0 max)))
        (when (and (equal (last left max) candidate)
                   (tmux-control--line-list-safe-overlap-p candidate))
          (setq overlap max)))
      (setq max (1- max)))
    overlap))

(defun tmux-control--line-list-safe-overlap-p (lines)
  "Return non-nil when LINES are distinctive enough to use as overlap."
  (>= (cl-count-if (lambda (line)
                     (not (string-empty-p (string-trim line))))
                   lines)
      2))

(defun tmux-control--line-list-has-content-p (lines)
  "Return non-nil when LINES contain at least one nonblank line."
  (cl-some (lambda (line)
             (not (string-empty-p (string-trim line))))
           lines))

(defun tmux-control--trim-blank-line-list (lines)
  "Trim leading and trailing blank lines from LINES."
  (while (and lines
              (string-empty-p (string-trim (car lines))))
    (setq lines (cdr lines)))
  (setq lines (nreverse lines))
  (while (and lines
              (string-empty-p (string-trim (car lines))))
    (setq lines (cdr lines)))
  (nreverse lines))

(defun tmux-control--squeeze-blank-lines (text)
  "Collapse runs of more than two blank lines in TEXT."
  (replace-regexp-in-string "\\(?:[[:blank:]]*\n\\)\\{3,\\}" "\n\n" text))

(defun tmux-control--filter (process chunk)
  "Handle tmux control mode output CHUNK from PROCESS."
  (when (buffer-live-p (process-buffer process))
    (with-current-buffer (process-buffer process)
      (setq tmux-control--accumulator
            (concat tmux-control--accumulator chunk))
      (let ((start 0)
            line-end
            ;; Capture follow-windows before any output is fed this pass, so
            ;; windows tracking the live cursor are identified before it moves.
            (sync-windows (tmux-control--current-sync-windows)))
        (while (setq line-end (string-match "\n" tmux-control--accumulator start))
          (let ((line (substring tmux-control--accumulator start line-end)))
            (when (and (> (length line) 0)
                       (= (aref line (1- (length line))) ?\r))
              (setq line (substring line 0 -1)))
            (tmux-control--handle-line line))
          (setq start (1+ line-end)))
        (setq tmux-control--accumulator
              (substring tmux-control--accumulator start))
        ;; Feed any output still batched at the end of the chunk, then do a
        ;; single redisplay -- not one per %output message.  In tiling mode
        ;; the controller renders nothing itself; it flushes each pane's
        ;; render buffer instead.
        (if tmux-control--tiled
            (tmux-control--flush-tiled-panes)
          (tmux-control--flush-output-batch)
          (tmux-control--flush-display sync-windows))
        ;; A %layout-change seen this chunk asked for a re-tile.  Debounce it
        ;; off the filter -- re-tiling makes blocking (possibly SSH) tmux
        ;; queries, so running it inline would freeze Emacs on every layout
        ;; change, and a resize emits a burst of them.
        (when tmux-control--retile-pending
          (setq tmux-control--retile-pending nil)
          (tmux-control--schedule-retile (current-buffer)))))))

(defun tmux-control--schedule-retile (controller)
  "Schedule a debounced re-tile of CONTROLLER on the idle timer.
Coalesces a burst of layout changes into one rebuild, run when Emacs next
idles so the blocking tmux queries do not stall output rendering."
  (when (buffer-live-p controller)
    (with-current-buffer controller
      (when (timerp tmux-control--retile-timer)
        (cancel-timer tmux-control--retile-timer))
      (setq tmux-control--retile-timer
            (run-with-idle-timer
             0.06 nil
             (lambda ()
               (when (buffer-live-p controller)
                 (with-current-buffer controller
                   (setq tmux-control--retile-timer nil)
                   (when tmux-control--tiled
                     (tmux-control--build-tiling controller))))))))))

(defun tmux-control--flush-output-batch ()
  "Feed any batched %output payloads to Eat as a single write.
Consecutive %output notifications are accumulated by
`tmux-control--handle-line' and decoded into one string here, so a flood
costs one `eat-term-process-output' call per run of output rather than one
per message."
  (when tmux-control--output-batch
    (let ((out (apply #'concat (nreverse tmux-control--output-batch))))
      (setq tmux-control--output-batch nil)
      (tmux-control--feed-terminal out))))

(defun tmux-control--batch-pane-output (pane payload)
  "Queue PANE's encoded output PAYLOAD for rendering.
In single-pane mode the live terminal mirrors only the active pane, so
output for other panes is dropped (rendering them all into one terminal
would interleave them); when no active pane is resolved yet the first
output bootstraps it.  In tiling mode the controller fans output out to
the matching pane's render buffer instead, so every pane updates at once."
  (if tmux-control--tiled
      (let ((buf (cdr (assoc pane tmux-control--panes))))
        (when (buffer-live-p buf)
          (let ((decoded (tmux-control--decode-output payload)))
            (with-current-buffer buf
              (push decoded tmux-control--output-batch)))))
    (unless tmux-control--active-pane
      (setq tmux-control--active-pane pane))
    (when (equal pane tmux-control--active-pane)
      (push (tmux-control--decode-output payload)
            tmux-control--output-batch))))

(defun tmux-control--handle-line (line)
  "Handle one tmux control protocol LINE."
  (cond
   ;; Fast path: outside a command reply, batch consecutive %output
   ;; payloads.  They are flushed before the next control line (to preserve
   ;; ordering) and at the end of each filter chunk.
   ((and (not tmux-control--collecting-command)
         (string-match "\\`%output \\(%[0-9]+\\)\\(?: \\(.*\\)\\)?\\'" line))
    (tmux-control--batch-pane-output (match-string 1 line)
                                     (or (match-string 2 line) "")))
   ((and (not tmux-control--collecting-command)
         (string-match "\\`%extended-output \\(%[0-9]+\\) [^:]*: ?\\(.*\\)\\'" line))
    ;; With flow control on (`tmux-control-pause-after'), tmux delivers
    ;; output as "%extended-output PANE AGE ... : VALUE" instead of %output.
    ;; The value is escaped exactly like %output; the age and reserved
    ;; fields before the colon are ignored.
    (tmux-control--batch-pane-output (match-string 1 line)
                                     (match-string 2 line)))
   (t
    ;; Any control line: flush pending output first so it lands before the
    ;; state change (a resize, a seed, a pane switch) that follows it.
    (tmux-control--flush-output-batch)
    (cond
     ((string-prefix-p "%begin " line)
      (setq tmux-control--current-command-kind
            (or (pop tmux-control--command-queue) :ignore))
      (setq tmux-control--collecting-command t)
      (setq tmux-control--command-output nil))
     ((string-prefix-p "%end " line)
      (tmux-control--finish-command-output))
     ((string-prefix-p "%error " line)
      (setq tmux-control--collecting-command nil)
      (setq tmux-control--command-output nil)
      (setq tmux-control--current-command-kind :ignore)
      (tmux-control--message "tmux command failed"))
     ((or (string= line "%exit") (string-prefix-p "%exit " line))
      ;; tmux is closing the control connection (the session was killed,
      ;; the server exited, or the client was detached).  The process
      ;; sentinel will tear the buffer down; surface tmux's reason, if any,
      ;; so the disconnect is not silent.
      (let ((reason (string-trim (substring line (length "%exit")))))
        (tmux-control--message
         (if (string-empty-p reason)
             "tmux session ended"
           (format "tmux session ended: %s" reason)))))
     ((string-match "\\`%pause \\(%[0-9]+\\)\\'" line)
      (tmux-control--handle-pause (match-string 1 line)))
     ((string-prefix-p "%continue " line)
      ;; tmux resumed streaming the pane; nothing further to do.
      nil)
     (tmux-control--collecting-command
      (push line tmux-control--command-output))
     ((string-match "\\`%window-pane-changed [^ ]+ \\(%[0-9]+\\)\\'" line)
      ;; The window's active pane changed (a split, a select-pane, a closed
      ;; pane).  In single-pane mode only the active pane is mirrored, so
      ;; follow it: repaint from its current screen.  In tiling mode every
      ;; pane is already shown, so just record the pointer (no reseed, no
      ;; flicker); the matching Emacs window can be focused on demand.
      (setq tmux-control--active-pane (match-string 1 line))
      (unless tmux-control--tiled
        (tmux-control--seed-screen)
        (tmux-control--refresh-alt-screen-option)
        (tmux-control--refresh-pane-size)))
     ((string-prefix-p "%layout-change " line)
      ;; The window's pane structure or sizes changed (a split, a resize, a
      ;; closed pane).  In tiling mode re-derive the tiling; in single-pane
      ;; mode just reconcile the active pane's size.
      (if tmux-control--tiled
          (setq tmux-control--retile-pending t)
        (tmux-control--refresh-pane-size)))
     ((and tmux-control--tiled
           (string-prefix-p "%session-window-changed " line))
      ;; The session's active window changed (switched here or by another
      ;; client).  In tiling mode re-tile to the new window's panes.  In
      ;; single-pane mode this notification is ignored -- window switches go
      ;; through `tmux-control--do-select-window', which reseeds directly --
      ;; so the single-pane path is unchanged.
      (setq tmux-control--retile-pending t))))))

(defun tmux-control--finish-command-output ()
  "Handle the end of a tmux command reply."
  (pcase tmux-control--current-command-kind
    (:pane-id
     (let ((pane (cl-find-if (lambda (line)
                               (string-match-p "\\`%[0-9]+\\'" line))
                             tmux-control--command-output)))
       (when pane
         (setq tmux-control--active-pane pane)
         (tmux-control--seed-screen)
         (tmux-control--refresh-alt-screen-option)
         (tmux-control--refresh-pane-size))))
    (:pane-size
     (let ((size (tmux-control--parse-pane-size tmux-control--command-output)))
       (when (and size
                  (tmux-control--apply-eat-size (car size) (cdr size)))
         ;; The grid changed under already-rendered output, so repaint
         ;; the visible screen at the corrected width.
         (tmux-control--seed-screen))))
    (:alt-screen-opt
     (let ((res (tmux-control--interpret-alt-screen-reply
                 tmux-control--command-output nil)))
       (if (eq res :inherit)
           ;; Empty reply means the window inherits the option; resolve it
           ;; from the global-window default.
           (tmux-control--send-command "show-options -gwv alternate-screen"
                                       :alt-screen-opt-global)
         (setq tmux-control--alt-screen-honored (cdr res)))))
    (:alt-screen-opt-global
     (setq tmux-control--alt-screen-honored
           (cdr (tmux-control--interpret-alt-screen-reply
                 tmux-control--command-output t))))
    (:version
     (setq tmux-control--capture-trailing-p
           (tmux-control--capture-n-supported-p
            (car (cl-remove-if #'string-empty-p
                               (mapcar #'string-trim
                                       tmux-control--command-output))))))
    (:cursor-pos
     (setq tmux-control--seed-cursor
           (tmux-control--parse-cursor-pos tmux-control--command-output)))
    (:capture
     (tmux-control--write-terminal
      (tmux-control--screen-seed-sequence
       (mapconcat #'identity
                  (nreverse tmux-control--command-output)
                  "\n")
       tmux-control--seed-cursor))))
  (setq tmux-control--collecting-command nil)
  (setq tmux-control--current-command-kind :ignore)
  (setq tmux-control--command-output nil))

(defun tmux-control--seed-screen ()
  "Seed the Eat buffer with the current tmux pane contents.
Query the pane's real cursor position first, so the seeded screen places
the cursor exactly where tmux has it instead of guessing from the prompt.
tmux replies in command order, so the `:cursor-pos' reply lands before
the `:capture' reply that paints the screen and consumes it."
  (when tmux-control--active-pane
    ;; Start each seed without a cursor: the :cursor-pos reply fills it in
    ;; before :capture, and if that query fails the seed falls back to the
    ;; bottom-left rather than reusing a stale position from an old seed.
    (setq tmux-control--seed-cursor nil)
    (tmux-control--send-command
     (format "display-message -p -t %s \"#{cursor_x},#{cursor_y}\""
             tmux-control--active-pane)
     :cursor-pos)
    (tmux-control--send-command
     (format "capture-pane -p -e%s -t %s"
             ;; -N keeps trailing background cells so full-width fills survive.
             (if tmux-control--capture-trailing-p " -N" "")
             tmux-control--active-pane)
     :capture)))

(defun tmux-control--handle-pause (pane)
  "Resync after tmux paused PANE for lagging, then resume streaming it.
With `tmux-control-pause-after' set, tmux stops sending a pane's buffered
output once this client falls too far behind and sends %pause.  Reseed
from the pane's current screen to skip the backlog tmux dropped, then ask
tmux to continue so live output resumes from the present."
  (cond
   ;; In tiling mode reseed the paused pane's own render buffer; the
   ;; controller renders nothing, so `tmux-control--seed-screen' here would
   ;; paint the invisible controller terminal and leave the pane stale.
   (tmux-control--tiled
    (let ((buf (cdr (assoc pane tmux-control--panes))))
      (when (buffer-live-p buf)
        (tmux-control--seed-pane-buffer-sync buf))))
   ((equal pane tmux-control--active-pane)
    (tmux-control--seed-screen)))
  ;; tmux's command parser rejects a bare "%0:continue" argument, so quote it.
  (tmux-control--send-command
   (format "refresh-client -A %s"
           (tmux-control--quote-tmux-arg (concat pane ":continue")))))

(defconst tmux-control--ansi-control-regexp
  (concat "\e][^\a\e]*\\(?:\a\\|\e\\\\\\)"      ; OSC: ESC ] ... (BEL or ST)
          "\\|\e\\[[0-9:;<=>?]*[ -/]*[@-~]")    ; CSI: ESC [ ... final (incl. SGR)
  "Regexp matching non-printing ANSI OSC/CSI control sequences.")

(defun tmux-control--strip-ansi (string)
  "Return STRING with non-printing ANSI control sequences removed."
  (replace-regexp-in-string tmux-control--ansi-control-regexp "" string))

(defun tmux-control--display-width (string)
  "Return the display width of STRING, ignoring ANSI control sequences."
  (string-width (tmux-control--strip-ansi string)))

(defun tmux-control--screen-seed-sequence (text &optional cursor)
  "Return terminal escapes to paint captured visible-screen TEXT.
CURSOR, when non-nil, is a (X . Y) cons of tmux's 0-indexed cursor column
and row on the visible screen; the cursor is placed there (clamped to the
grid).  When nil -- the position could not be queried -- the cursor falls
back to the bottom-left of the screen."
  (let* ((size (and tmux-control--terminal
                    (eat-term-live-p tmux-control--terminal)
                    (eat-term-size tmux-control--terminal)))
         (width (or (car-safe size) 80))
         (height (or (cdr-safe size) 24))
         (lines (split-string text "\n"))
         (lines (if (and lines (string-empty-p (car (last lines))))
                    (butlast lines)
                  lines))
         (lines (last lines (min height (length lines))))
         (row 1)
         (out '("\e[H\e[2J")))
    (dolist (line lines)
      ;; Clip to terminal width by visible columns, ignoring the
      ;; non-printing color escapes; only over-wide lines (rare and
      ;; transient) fall back to a stripped truncation.
      (when (> (tmux-control--display-width line) width)
        (setq line (truncate-string-to-width
                    (tmux-control--strip-ansi line) width nil nil "")))
      ;; Erase the row to the default background BEFORE painting, then paint
      ;; the captured line.  Doing the reset-and-erase first preserves the
      ;; line's own background -- including the trailing cells `capture-pane
      ;; -N' keeps for a full-width fill (a tool panel, a selection, a status
      ;; bar) -- instead of clearing it away after the text.  Lines are not
      ;; right-trimmed, so those trailing background cells reach Eat.
      (push (format "\e[%d;1H\e[m\e[K%s" row line) out)
      (setq row (1+ row)))
    ;; Place the cursor where tmux reports it (converted to 1-based and
    ;; clamped to the grid), or at the bottom-left when unknown.  Reset
    ;; attributes first so a line's lingering background does not tint it.
    (let ((cursor-row (if cursor (min height (max 1 (1+ (cdr cursor)))) height))
          (cursor-column (if cursor (min width (max 1 (1+ (car cursor)))) 1)))
      (push (format "\e[m\e[%d;%dH" cursor-row cursor-column) out))
    (apply #'concat (nreverse out))))

(defun tmux-control--decode-output (payload)
  "Decode tmux control mode output PAYLOAD."
  (let ((i 0)
        (len (length payload))
        (out nil))
    (while (< i len)
      (if (and (= (aref payload i) ?\\)
               (<= (+ i 3) (1- len))
               (tmux-control--octal-digit-p (aref payload (1+ i)))
               (tmux-control--octal-digit-p (aref payload (+ i 2)))
               (tmux-control--octal-digit-p (aref payload (+ i 3))))
          (progn
            (push (+ (* 64 (- (aref payload (1+ i)) ?0))
                     (* 8 (- (aref payload (+ i 2)) ?0))
                     (- (aref payload (+ i 3)) ?0))
                  out)
            (setq i (+ i 4)))
        (push (aref payload i) out)
        (setq i (1+ i))))
    (apply #'string (nreverse out))))

(defun tmux-control--octal-digit-p (char)
  "Return non-nil when CHAR is an octal digit."
  (and (<= ?0 char) (<= char ?7)))

(defun tmux-control--keep-cursor-visible (windows)
  "Ensure the terminal cursor line is fully visible in WINDOWS.
Eat positions the view by counting screen lines, but tall glyphs
\(e.g. a prompt ornament rendered with a fallback font) make some
rows exceed the default line height, so the line-counted view can
overflow the window body in pixels and clip the active bottom row.
Pull the window start forward by pixels until the cursor line fits,
keeping the live terminal bottom in view.  The start never advances
onto the cursor's own line, so the view can never go blank.  WINDOWS
are the live-following windows Eat just synchronized; scrollback
windows are excluded so they are not yanked to the bottom."
  (dolist (window windows)
    (when (windowp window)
      (let* ((body (window-body-height window t))
             (cursor (window-point window))
             (line-end (save-excursion (goto-char cursor)
                                       (line-end-position)))
             (start (window-start window))
             (guard 0))
        (while (and (< guard 256)
                    (< start line-end)
                    (> (cdr (window-text-pixel-size window start line-end))
                       body))
          (setq start (save-excursion (goto-char start)
                                      (forward-line 1)
                                      (point)))
          (setq guard (1+ guard)))
        (set-window-start window start t)))))

(defvar tmux-control--suppress-responses nil
  "When non-nil, drop terminal replies Eat would send back to the pane.
Bound around `eat-term-process-output' in `tmux-control--write-terminal'
so the reactive query responses (device-attributes, cursor-position, and
color reports) Eat generates while rendering tmux output are not injected
into the pane as input.")

(defconst tmux-control--eight-bit-char-regexp
  (format "[%c-%c]" #x3fff80 #x3fffff)
  "Regexp matching any Emacs eight-bit (raw byte) character.")

(defun tmux-control--utf8-complete-len (bytes)
  "Return the byte length of the longest complete-UTF-8 prefix of BYTES.
BYTES is a unibyte string.  A trailing incomplete multibyte sequence -- a
lead byte without all its continuation bytes -- is excluded so it can be
carried over and finished by the next chunk.  Pure, for unit testing."
  (let* ((n (length bytes))
         (i (1- n)))
    ;; Walk back over at most three continuation bytes (10xxxxxx).
    (while (and (>= i 0)
                (< (- n i) 4)
                (= (logand (aref bytes i) #xc0) #x80))
      (setq i (1- i)))
    (if (< i 0)
        n
      (let ((b (aref bytes i)))
        (cond
         ((< b #x80) n)                      ; ASCII: whole string is complete
         ((= (logand b #xc0) #x80) n)        ; only continuation bytes: leave as-is
         (t                                  ; a lead byte at I
          (let ((need (cond ((>= b #xf0) 4) ((>= b #xe0) 3) (t 2))))
            (if (>= (- n i) need) n i))))))))

(defun tmux-control--utf8-decode-stream (carry output)
  "Reassemble a UTF-8 stream across chunks; return (DECODED . NEW-CARRY).
CARRY is a unibyte string of bytes held back from the previous chunk (an
incomplete trailing multibyte sequence).  OUTPUT is the next text, which
may itself contain raw eight-bit bytes left when tmux split a multibyte
character across two %output messages.  DECODED is the complete-UTF-8
prefix as characters; NEW-CARRY is the leftover incomplete tail to prepend
next time.  Pure, for unit testing."
  (let* ((bytes (concat carry (encode-coding-string output 'utf-8)))
         (len (tmux-control--utf8-complete-len bytes)))
    (cons (decode-coding-string (substring bytes 0 len) 'utf-8)
          (substring bytes len))))

(defun tmux-control--current-sync-windows ()
  "Return the windows that should scroll-follow the live terminal cursor.
Must be called BEFORE feeding new output: Eat identifies a following
window by its point sitting on the current cursor, so once output moves
the cursor the association is lost.  Captured at the start of a render
pass and replayed by `tmux-control--flush-display'."
  (and (fboundp 'eat--synchronize-scroll-windows)
       tmux-control--terminal
       (eat-term-live-p tmux-control--terminal)
       (eat--synchronize-scroll-windows)))

(defun tmux-control--feed-terminal (output)
  "Process decoded terminal OUTPUT into Eat without redisplaying.

Marks the display dirty so a later `tmux-control--flush-display' repaints
once.  Batching the repaint -- one flush per process-filter chunk rather
than one per %output notification -- keeps high-volume output (a flood
such as `yes' or `seq 1 100000') from paying the full redisplay and
cursor-visibility cost on every message while draining.

While Eat parses OUTPUT it may generate replies to terminal queries the
pane's program emitted (device attributes, cursor-position and color
reports).  In a control-mode client those replies must not be sent back:
tmux is the terminal the program talks to and already answers the queries
programs block on (it replied to DA and DSR even with no client attached
in testing), so a reply from here is at best a duplicate and at worst --
for queries tmux passes through, such as OSC 10/11 color requests --
arrives long after the program stopped reading and lands as garbage on
the shell's command line.  Bind `tmux-control--suppress-responses' so
`tmux-control--send-input' drops those sends while rendering.

tmux can split a multibyte character across two %output messages; the
per-message UTF-8 decoding then leaves the halves as raw eight-bit bytes,
which Eat (working on characters) renders as octal escapes.  Reassemble
the UTF-8 stream across feeds first -- carrying an incomplete trailing
sequence in `tmux-control--utf8-carry' -- so split characters are made
whole before they reach Eat."
  (when (and tmux-control--terminal (eat-term-live-p tmux-control--terminal))
    (let ((inhibit-read-only t)
          (tmux-control--suppress-responses t))
      (if (and (= 0 (length tmux-control--utf8-carry))
               (not (string-match-p tmux-control--eight-bit-char-regexp output)))
          ;; Fast path: no pending partial char and no raw bytes.
          (eat-term-process-output tmux-control--terminal output)
        (let ((res (tmux-control--utf8-decode-stream
                    tmux-control--utf8-carry output)))
          (setq tmux-control--utf8-carry (cdr res))
          (eat-term-process-output tmux-control--terminal (car res))))
      (setq tmux-control--display-dirty t))))

(defun tmux-control--flush-display (sync-windows)
  "Redisplay Eat once when output has been fed since the last flush.
SYNC-WINDOWS is the result of `tmux-control--current-sync-windows' taken
before the output was fed; those windows are scrolled to follow the new
cursor position and their cursor line is kept visible."
  (when (and tmux-control--display-dirty
             tmux-control--terminal
             (eat-term-live-p tmux-control--terminal))
    (setq tmux-control--display-dirty nil)
    (let ((inhibit-read-only t))
      (eat-term-redisplay tmux-control--terminal)
      (when (and sync-windows
                 (boundp 'eat--synchronize-scroll-function))
        (funcall eat--synchronize-scroll-function sync-windows)
        ;; In a tiled pane, anchor to the top of the current terminal screen
        ;; so a full-screen TUI (e.g. a Claude Code panel) shows from its top
        ;; instead of being scrolled with its top cut off when tall
        ;; box-drawing glyphs make the rows overflow the body in pixels.
        (when tmux-control--controller
          (tmux-control--anchor-windows-to-screen-top sync-windows))
        (tmux-control--keep-cursor-visible sync-windows))
      (run-hooks 'eat-update-hook))))

(defun tmux-control--anchor-windows-to-screen-top (windows)
  "Set each of WINDOWS to start at the top of the terminal's current screen.
The current screen is the last `eat-term' height rows of the buffer, so
this reveals a full-screen TUI from its top while still showing the latest
screen of a scrolling pane.  `tmux-control--keep-cursor-visible' runs after
and only pulls the start forward when the cursor would otherwise fall below
the body (e.g. a tall prompt glyph on a scrolling log), so the follow-bottom
behavior is preserved."
  (let ((height (and tmux-control--terminal
                     (eat-term-live-p tmux-control--terminal)
                     (cdr (eat-term-size tmux-control--terminal)))))
    (when (and height (> height 0))
      (let ((top (save-excursion
                   (goto-char (point-max))
                   (forward-line (- (1- height)))
                   (line-beginning-position))))
        (dolist (window windows)
          (when (window-live-p window)
            (set-window-start window top t)))))))

(defun tmux-control--write-terminal (output)
  "Process decoded terminal OUTPUT into Eat and redisplay immediately.
For one-shot writes (screen seed, resize repaint) that are not part of a
streamed flood; live %output is fed via `tmux-control--feed-terminal' and
flushed once per filter chunk."
  (when (and tmux-control--terminal (eat-term-live-p tmux-control--terminal))
    ;; A full repaint stands alone; drop any partial multibyte char carried
    ;; from streamed output so it cannot prefix the repaint.
    (setq tmux-control--utf8-carry "")
    (let ((sync-windows (tmux-control--current-sync-windows)))
      (tmux-control--feed-terminal output)
      (tmux-control--flush-display sync-windows))))

(defconst tmux-control--send-keys-chunk-bytes 1024
  "Maximum number of input bytes per `send-keys -H' control command.
tmux silently rejects an over-long control command, so a large paste sent
as a single `send-keys' is dropped.  Input is split into chunks of at most
this many bytes, each its own command.  The pane receives the bytes in
order, so a split -- even in the middle of a multibyte character -- is
invisible to the application.")

(defun tmux-control--send-input (_terminal string)
  "Send STRING as input to the active tmux pane.
Sends are dropped while `tmux-control--suppress-responses' is bound, so
the terminal query replies Eat generates while rendering output are not
injected into the pane (see `tmux-control--write-terminal').  Genuine
user keystrokes arrive outside that dynamic extent and are sent.

The UTF-8 byte stream is split into `tmux-control--send-keys-chunk-bytes'
chunks so a large paste is not dropped as one over-long `send-keys'."
  (when (and (process-live-p tmux-control--process)
             (> (length string) 0)
             (not tmux-control--suppress-responses))
    (let ((target (or tmux-control--active-pane tmux-control--fallback-target)))
      (if target
          (let* ((bytes (encode-coding-string string 'utf-8-unix))
                 (n (length bytes))
                 (size tmux-control--send-keys-chunk-bytes)
                 (i 0))
            (while (< i n)
              (let ((end (min n (+ i size))))
                (tmux-control--send-command
                 (format "send-keys -t %s -H %s"
                         target
                         (tmux-control--bytes-to-hex-args bytes i end)))
                (setq i end))))
        (tmux-control--message "No active tmux pane yet")))))

(defun tmux-control--bytes-to-hex-args (bytes start end)
  "Return BYTES from START (inclusive) to END (exclusive) as hex args.
The result is space-separated two-digit hexadecimal, as `send-keys -H'
expects."
  (let ((hex nil)
        (i start))
    (while (< i end)
      (push (format "%02x" (aref bytes i)) hex)
      (setq i (1+ i)))
    (string-join (nreverse hex) " ")))

(defun tmux-control--string-to-hex-args (string)
  "Return STRING encoded as space-separated UTF-8 hexadecimal bytes."
  (let ((bytes (encode-coding-string string 'utf-8-unix)))
    (tmux-control--bytes-to-hex-args bytes 0 (length bytes))))

(defun tmux-control--send-command (command &optional kind)
  "Send tmux control mode COMMAND.

KIND identifies the command reply handler.  When called from a tiled pane
render buffer (`tmux-control--controller' set), the command is enqueued on
the controller's single command queue and written to the shared process,
so every reply stays matched to the right handler on one queue."
  (let ((ctrl (or tmux-control--controller (current-buffer))))
    (when (buffer-live-p ctrl)
      (with-current-buffer ctrl
        (when (process-live-p tmux-control--process)
          (setq tmux-control--command-queue
                (append tmux-control--command-queue
                        (list (or kind :ignore))))
          (process-send-string tmux-control--process
                               (concat command "\n")))))))

(defun tmux-control--adjust-window-size (process windows)
  "Resize tmux and Eat for PROCESS according to WINDOWS."
  (when (buffer-live-p (process-buffer process))
    (with-current-buffer (process-buffer process)
      (when (and tmux-control--terminal windows)
        (let* ((window (car windows))
               (width (max 1 (window-max-chars-per-line window)))
               (height (max 1 (with-selected-window window
                                (floor (window-screen-lines))))))
          (tmux-control--resize width height)
          (cons width height))))))

(defun tmux-control--resize-to-window ()
  "Resize tmux and Eat to the selected window."
  (when-let* ((window (get-buffer-window (current-buffer) t)))
    (set-window-margins window 0 0)
    (tmux-control--resize
     (max 1 (window-max-chars-per-line window))
     (max 1 (with-selected-window window
              (floor (window-screen-lines)))))))

(defun tmux-control--resize (width height)
  "Resize the local renderer and request WIDTH by HEIGHT from tmux.
The renderer is sized to the requested dimensions immediately, but tmux
may keep the pane at another size (for example when another, larger client
is attached under `window-size latest').  `tmux-control--refresh-pane-size'
then reconciles the Eat grid with the pane's real size so cursor-addressed
redraws stay aligned."
  (when (and tmux-control--terminal (eat-term-live-p tmux-control--terminal))
    (let ((inhibit-read-only t))
      (eat-term-resize tmux-control--terminal width height)
      (eat-term-redisplay tmux-control--terminal)
      (when (fboundp 'eat--synchronize-scroll-windows)
        (tmux-control--keep-cursor-visible
         (eat--synchronize-scroll-windows)))))
  (tmux-control--send-command (format "refresh-client -C %dx%d" width height))
  (tmux-control--refresh-pane-size))

(defun tmux-control--apply-eat-size (width height)
  "Resize the Eat grid to WIDTH by HEIGHT when it differs from the current.
Return non-nil when a resize actually happened, so callers can repaint."
  (when (and tmux-control--terminal (eat-term-live-p tmux-control--terminal))
    (let ((size (eat-term-size tmux-control--terminal)))
      (unless (and size
                   (= (car size) width)
                   (= (cdr size) height))
        (let ((inhibit-read-only t))
          (eat-term-resize tmux-control--terminal width height)
          (eat-term-redisplay tmux-control--terminal)
          (when (fboundp 'eat--synchronize-scroll-windows)
            (tmux-control--keep-cursor-visible
             (eat--synchronize-scroll-windows))))
        t))))

(defun tmux-control--parse-pane-size (output)
  "Parse a WxH pane size from control-mode reply OUTPUT lines.
OUTPUT is the raw (reverse-order) reply line list.  Return a (WIDTH . HEIGHT)
cons of positive integers, or nil when no well-formed positive size is found."
  (let ((val (car (cl-remove-if #'string-empty-p
                                (mapcar #'string-trim output)))))
    (when (and val (string-match "\\`\\([0-9]+\\)x\\([0-9]+\\)\\'" val))
      (let ((w (string-to-number (match-string 1 val)))
            (h (string-to-number (match-string 2 val))))
        (when (and (> w 0) (> h 0))
          (cons w h))))))

(defun tmux-control--parse-cursor-pos (output)
  "Parse \"X,Y\" cursor coordinates from control-mode reply OUTPUT lines.
OUTPUT is the raw (reverse-order) reply line list.  Return a (X . Y) cons
of tmux's 0-indexed cursor column and row, or nil when no well-formed pair
is found.  Pure: no side effects, for unit testing the seed cursor query."
  (let ((val (car (cl-remove-if #'string-empty-p
                                (mapcar #'string-trim output)))))
    (when (and val (string-match "\\`\\([0-9]+\\),\\([0-9]+\\)\\'" val))
      (cons (string-to-number (match-string 1 val))
            (string-to-number (match-string 2 val))))))

(defun tmux-control--capture-n-supported-p (version)
  "Return non-nil when tmux VERSION supports `capture-pane -N' (3.1 or later).
VERSION is a `#{version}' string such as \"3.6a\" or \"next-3.5\"; the first
MAJOR.MINOR it contains is compared against 3.1.  Pure, for unit testing."
  (when (and version (string-match "\\([0-9]+\\)\\.\\([0-9]+\\)" version))
    (let ((major (string-to-number (match-string 1 version)))
          (minor (string-to-number (match-string 2 version))))
      (or (> major 3) (and (= major 3) (>= minor 1))))))

(defun tmux-control--refresh-pane-size ()
  "Query the active pane's real size and sync the Eat grid to it.
A control client cannot always force the pane to the requested size, so
the renderer follows tmux's actual pane dimensions.  The reply is handled
by the `:pane-size' branch of `tmux-control--finish-command-output'."
  (when (and tmux-control--active-pane
             (process-live-p tmux-control--process))
    (tmux-control--send-command
     (format "display-message -p -t %s \"#{pane_width}x#{pane_height}\""
             tmux-control--active-pane)
     :pane-size)))

(defun tmux-control--sentinel (process message)
  "Handle PROCESS exit with MESSAGE."
  (when (buffer-live-p (process-buffer process))
    (with-current-buffer (process-buffer process)
      ;; If the session died while tiled, tear the tiling down so its pane
      ;; render buffers are not left orphaned without a process.
      (when tmux-control--tiled
        (tmux-control--teardown-tiling (current-buffer)))
      (unless (string-match-p "\\`finished\\|exited" message)
        (tmux-control--message (string-trim-right message)))
      (setq tmux-control--process nil))))

(defun tmux-control--kill-process ()
  "Delete the tmux control process and any tiled pane buffers."
  (when tmux-control--panes
    (dolist (np tmux-control--panes)
      (when (buffer-live-p (cdr np))
        (let ((kill-buffer-query-functions nil))
          (kill-buffer (cdr np)))))
    (setq tmux-control--panes nil))
  (when (process-live-p tmux-control--process)
    (delete-process tmux-control--process)))

(defun tmux-control--message (message)
  "Append MESSAGE to the current tmux-control buffer."
  (let ((inhibit-read-only t))
    (goto-char (point-max))
    (insert (propertize (format "\n[tmux-control] %s\n" message)
                        'face 'font-lock-comment-face))))


;;;; Multi-pane tiling (experimental)
;;
;; A tmux window can hold several panes at once.  The single-pane client
;; above mirrors only the active pane; the tiling layer renders ALL of the
;; current window's panes at once, each in its own Eat buffer, with the
;; Emacs windows split to match tmux's own layout -- the iTerm "show every
;; pane" view.  It reuses the per-buffer rendering machinery (each pane
;; buffer is an ordinary `tmux-control-mode' buffer with its own terminal,
;; UTF-8 carry, and active-pane = its own id) and a single shared control
;; process owned by the controller buffer, which routes %output per pane.
;;
;; tmux's `window_layout' string encodes the pane geometry as a recursive
;; tree:
;;
;;   checksum,WxH,X,Y,paneid          a single leaf pane
;;   checksum,WxH,X,Y{a,b,...}        a row: children left-to-right (h split)
;;   checksum,WxH,X,Y[a,b,...]        a column: children top-to-bottom (v split)
;;
;; where each child is itself a node.  The parser below turns that string
;; into a tree of plist nodes that the tiler walks to build Emacs windows.

(defun tmux-control--layout-strip-checksum (layout)
  "Strip a leading \"checksum,\" from a tmux LAYOUT string.
The `window_layout' format prefixes the geometry with a hex checksum and a
comma.  Dimensions always contain an \"x\" before any comma, so a checksum
\(hex digits immediately followed by a comma) is unambiguous and an
already-stripped string is returned unchanged."
  (if (string-match "\\`[0-9a-f]+," layout)
      (substring layout (match-end 0))
    layout))

(defun tmux-control--parse-layout-int (s i)
  "Parse a non-negative integer from string S at index I.
Return (N . NEXT-INDEX); signal an error when no digit is present."
  (let ((start i)
        (len (length s)))
    (while (and (< i len) (<= ?0 (aref s i) ?9))
      (setq i (1+ i)))
    (when (= start i)
      (error "tmux-control: expected integer at %d" i))
    (cons (string-to-number (substring s start i)) i)))

(defun tmux-control--parse-layout-dims (s i)
  "Parse \"WxH,X,Y\" from string S at index I.
Return ((W H X Y) . NEXT-INDEX)."
  (let (w h x y r)
    (setq r (tmux-control--parse-layout-int s i) w (car r) i (cdr r))
    (unless (and (< i (length s)) (= (aref s i) ?x))
      (error "tmux-control: expected x in layout dims"))
    (setq i (1+ i))
    (setq r (tmux-control--parse-layout-int s i) h (car r) i (cdr r))
    (unless (and (< i (length s)) (= (aref s i) ?,))
      (error "tmux-control: expected , after height"))
    (setq i (1+ i))
    (setq r (tmux-control--parse-layout-int s i) x (car r) i (cdr r))
    (unless (and (< i (length s)) (= (aref s i) ?,))
      (error "tmux-control: expected , after x"))
    (setq i (1+ i))
    (setq r (tmux-control--parse-layout-int s i) y (car r) i (cdr r))
    (cons (list w h x y) i)))

(defun tmux-control--parse-layout-node (s i)
  "Parse one layout node from string S at index I.
Return (NODE . NEXT-INDEX).  NODE is a plist:
  leaf:  (:type leaf  :w W :h H :x X :y Y :id ID)
  split: (:type split :dir h|v :w W :h H :x X :y Y :children (NODE...))."
  (let* ((dims (tmux-control--parse-layout-dims s i))
         (geom (car dims))
         (w (nth 0 geom)) (h (nth 1 geom))
         (x (nth 2 geom)) (y (nth 3 geom)))
    (setq i (cdr dims))
    (let ((ch (and (< i (length s)) (aref s i))))
      (cond
       ((eq ch ?{)
        (let ((lst (tmux-control--parse-layout-list s (1+ i) ?})))
          (cons (list :type 'split :dir 'h :w w :h h :x x :y y
                      :children (car lst))
                (cdr lst))))
       ((eq ch ?\[)
        (let ((lst (tmux-control--parse-layout-list s (1+ i) ?\])))
          (cons (list :type 'split :dir 'v :w w :h h :x x :y y
                      :children (car lst))
                (cdr lst))))
       ((eq ch ?,)
        (let ((r (tmux-control--parse-layout-int s (1+ i))))
          (cons (list :type 'leaf :w w :h h :x x :y y
                      :id (number-to-string (car r)))
                (cdr r))))
       (t (error "tmux-control: malformed layout node at %d" i))))))

(defun tmux-control--parse-layout-list (s i close)
  "Parse a comma-separated node list from S at I until CLOSE character.
Return (CHILDREN . NEXT-INDEX) with NEXT-INDEX positioned past CLOSE."
  (let ((children '())
        (len (length s))
        (done nil))
    (while (not done)
      (let ((r (tmux-control--parse-layout-node s i)))
        (push (car r) children)
        (setq i (cdr r)))
      (cond
       ((>= i len) (error "tmux-control: unterminated layout list"))
       ((= (aref s i) ?,) (setq i (1+ i)))
       ((= (aref s i) close) (setq i (1+ i) done t))
       (t (error "tmux-control: unexpected char in layout list at %d" i))))
    (cons (nreverse children) i)))

(defun tmux-control--parse-layout (layout)
  "Parse a tmux window-layout LAYOUT string into a node tree.
Return the root node plist, or nil when LAYOUT is empty or malformed.
See `tmux-control--parse-layout-node' for the node shape."
  (if (or (null layout) (string-empty-p (string-trim layout)))
      nil
    (condition-case nil
        (car (tmux-control--parse-layout-node
              (tmux-control--layout-strip-checksum (string-trim layout))
              0))
      (error nil))))

(defun tmux-control--layout-leaves (node)
  "Return the leaf nodes under layout NODE, left-to-right then top-to-bottom.
The order follows the children order tmux records, which is exactly the
left/top-to-right/bottom reading order used to lay out the panes."
  (cond
   ((null node) nil)
   ((eq (plist-get node :type) 'leaf) (list node))
   (t (apply #'append
             (mapcar #'tmux-control--layout-leaves
                     (plist-get node :children))))))

;;; Synchronous tmux queries used to build a tiling.

(defun tmux-control--run-tmux (args)
  "Run tmux ARGS (a list, without the -L socket) and return stdout.
Targets the current buffer's host/socket, going over SSH when a host is
set, exactly like the other one-shot CLI queries.  Must be called in a
controller or pane render buffer where those locals are bound."
  (let ((full (append (when tmux-control--socket-name
                        (list "-L" tmux-control--socket-name))
                      args)))
    (if (and tmux-control--host (not (string-empty-p tmux-control--host)))
        (tmux-control--call
         "ssh"
         (list tmux-control--host
               (concat tmux-control-remote-tmux-socket-setup " && "
                       (tmux-control--tmux-command-string full))))
      (tmux-control--call "tmux" full))))

(defun tmux-control--query-window-state ()
  "Return (LAYOUT . PANES) for the active window in one tmux query.
LAYOUT is the `window_layout' string; PANES is an alist (PANE-ID . INFO)
with INFO a plist of :left :top :width :height :active :cmd :title :cursor.
Folding the layout, every pane's geometry, and every pane's cursor into a
single `list-panes' call avoids a separate `display-message' for the layout
and one per pane for the cursor -- each a blocking (possibly SSH) round-trip
that previously ran for every re-tile."
  (let* ((fmt (concat "#{window_layout}\t#{pane_id}\t#{pane_left}\t#{pane_top}\t"
                      "#{pane_width}\t#{pane_height}\t#{pane_active}\t"
                      "#{cursor_x}\t#{cursor_y}\t#{pane_current_command}\t"
                      "#{pane_title}"))
         (text (tmux-control--run-tmux
                (list "list-panes" "-t" tmux-control--session "-F" fmt)))
         (layout nil)
         (panes nil))
    (dolist (line (split-string (string-trim text) "\n" t))
      (let ((f (split-string line "\t")))
        (when (>= (length f) 11)
          (unless layout (setq layout (nth 0 f)))
          (push (cons (nth 1 f)
                      (list :left (string-to-number (nth 2 f))
                            :top (string-to-number (nth 3 f))
                            :width (string-to-number (nth 4 f))
                            :height (string-to-number (nth 5 f))
                            :active (string= (nth 6 f) "1")
                            :cursor (cons (string-to-number (nth 7 f))
                                          (string-to-number (nth 8 f)))
                            :cmd (nth 9 f)
                            :title (nth 10 f)))
                panes))))
    (cons layout (nreverse panes))))

(defun tmux-control--capture-pane-screen (pane)
  "Return PANE's visible screen as colored text (no scrollback history)."
  (tmux-control--run-tmux
   (append (list "capture-pane" "-p" "-e")
           (when tmux-control--capture-trailing-p (list "-N"))
           (list "-t" pane))))

(defun tmux-control--query-cursor (pane)
  "Return PANE's cursor as an (X . Y) cons, or nil."
  (tmux-control--parse-cursor-pos
   (list (string-trim
          (tmux-control--run-tmux
           (list "display-message" "-p" "-t" pane
                 "#{cursor_x},#{cursor_y}"))))))

;;; Per-pane render buffers.

(defvar-local tmux-control--pane-info nil
  "Plist of a tiled render buffer's tmux pane metadata, for its mode line.")

(defun tmux-control--pane-mode-line ()
  "Return a concise mode-line string for a tiled pane render buffer.
Leads with the pane id (so teammates in a split window are easy to tell
apart), then the running command and, when distinct, the pane title."
  (let* ((info tmux-control--pane-info)
         ;; Pane ids contain "%", which is a mode-line format construct, so
         ;; double it to display literally.
         (pane (replace-regexp-in-string
                "%" "%%" (or tmux-control--active-pane "?")))
         (cmd (plist-get info :cmd))
         (title (plist-get info :title)))
    (concat " "
            (propertize (format "[%s]" pane) 'face 'mode-line-emphasis)
            (when (and cmd (not (string-empty-p cmd))) (concat " " cmd))
            (when (and title (not (string-empty-p title)) (not (equal title cmd)))
              (concat " — " title)))))

(defun tmux-control--make-pane-buffer (pane-id leaf controller meta)
  "Create and return a render buffer for PANE-ID, sized from layout LEAF.
CONTROLLER owns the shared process; META carries the session locals to
copy in.  The buffer is an ordinary `tmux-control-mode' buffer with its
own Eat terminal whose `active pane' is PANE-ID, so the existing input and
render helpers target this pane without modification; it has no process of
its own and routes commands through CONTROLLER."
  (let* ((w (max 1 (plist-get leaf :w)))
         (h (max 1 (plist-get leaf :h)))
         (host (plist-get meta :host))
         (name (format "*tmux-control:%s:%s:%s*"
                       (if (and host (not (string-empty-p host))) host "local")
                       (plist-get meta :session)
                       pane-id))
         (process (plist-get meta :process))
         (buffer (get-buffer-create name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t)) (erase-buffer))
      (tmux-control-mode)
      (setq-local emulation-mode-map-alists
                  (cons tmux-control--emulation-mode-map-alist
                        (delq tmux-control--emulation-mode-map-alist
                              emulation-mode-map-alists)))
      (setq tmux-control--keys-active t
            tmux-control--controller controller
            tmux-control--process process
            tmux-control--host host
            tmux-control--socket-name (plist-get meta :socket)
            tmux-control--session (plist-get meta :session)
            tmux-control--capture-trailing-p (plist-get meta :trailing)
            tmux-control--fallback-target (plist-get meta :fallback)
            tmux-control--active-pane pane-id
            tmux-control--pane-info (plist-get leaf :info)
            tmux-control--accumulator ""
            tmux-control--output-batch nil
            tmux-control--display-dirty nil
            tmux-control--utf8-carry ""
            tmux-control--alt-screen-honored t
            tmux-control--seed-cursor nil)
      (setq tmux-control--terminal (eat-term-make buffer (point-min)))
      (setq eat-terminal tmux-control--terminal)
      (eat-term-resize tmux-control--terminal w h)
      (eat-semi-char-mode)
      (setf (eat-term-parameter tmux-control--terminal 'input-function)
            #'tmux-control--send-input)
      (setf (eat-term-parameter tmux-control--terminal 'set-cursor-function)
            (if (fboundp 'eat--set-cursor) #'eat--set-cursor #'ignore))
      (setf (eat-term-parameter tmux-control--terminal 'grab-mouse-function)
            (if (fboundp 'eat--grab-mouse) #'eat--grab-mouse #'ignore))
      (setf (eat-term-parameter tmux-control--terminal 'ring-bell-function)
            (if (fboundp 'eat--bell) #'eat--bell #'ignore))
      (setf (eat-term-parameter tmux-control--terminal 'manipulate-selection-function)
            (if (fboundp 'eat--manipulate-kill-ring)
                #'eat--manipulate-kill-ring #'ignore))
      (setf (eat-term-parameter tmux-control--terminal 'eat--process) process)
      (setf (eat-term-parameter tmux-control--terminal 'eat--input-process) process)
      (setf (eat-term-parameter tmux-control--terminal 'eat--output-process) process)
      (setq-local mode-line-format '(:eval (tmux-control--pane-mode-line)))
      ;; Fringes and a scroll bar would steal columns from the body, so the
      ;; Eat grid (sized to the tmux pane) would not fit and full-width TUI
      ;; borders (e.g. a Claude Code panel) would clip.  Drop them so the
      ;; body uses every column; the grid is then fitted to the body on tile.
      (setq-local left-fringe-width 0)
      (setq-local right-fringe-width 0)
      (setq-local vertical-scroll-bar nil)
      (setq-local horizontal-scroll-bar nil)
      ;; Focusing this pane in Emacs makes it tmux's active pane too.
      (add-hook 'window-selection-change-functions
                #'tmux-control--pane-window-selected nil t)
      ;; If this buffer is killed out from under the tiling (e.g. C-x k),
      ;; re-tile to recreate it -- the pane still exists in tmux.
      (add-hook 'kill-buffer-hook #'tmux-control--pane-buffer-killed nil t)
      (tmux-control--disable-line-numbers)
      (tmux-control--disable-margins))
    buffer))

(defun tmux-control--pane-buffer-killed ()
  "Recover a tiled pane buffer killed by the user, by scheduling a re-tile."
  (unless tmux-control--killing-pane
    (let ((ctrl tmux-control--controller))
      (when (and (buffer-live-p ctrl)
                 (buffer-local-value 'tmux-control--tiled ctrl))
        (tmux-control--schedule-retile ctrl)))))

(defun tmux-control--pane-window-selected (frame)
  "Tell tmux to select the pane of FRAME's newly selected tiled window.
Installed buffer-locally on `window-selection-change-functions' in each
pane render buffer so focusing a pane in Emacs makes it tmux's active
pane too (other clients follow, and an untile reseeds the focused pane).
The resulting %window-pane-changed only moves the pointer in tiling mode,
so there is no reseed or flicker."
  (let ((win (frame-selected-window frame)))
    (when (window-live-p win)
      (let ((buffer (window-buffer win)))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (when (and tmux-control--controller
                       tmux-control--active-pane
                       (buffer-live-p tmux-control--controller)
                       (process-live-p tmux-control--process)
                       (not (buffer-local-value 'tmux-control--suppress-focus-follow
                                                 tmux-control--controller))
                       ;; Skip when this pane is already tmux's active pane
                       ;; (e.g. a re-tile re-selected the same window), so a
                       ;; rebuild does not re-assert select-pane and tug a
                       ;; shared session's active pane on every layout change.
                       (not (equal tmux-control--active-pane
                                   (buffer-local-value
                                    'tmux-control--active-pane
                                    tmux-control--controller))))
              (tmux-control--send-command
               (format "select-pane -t %s" tmux-control--active-pane)))))))))

(defun tmux-control--seed-pane-buffer-sync (buffer)
  "Paint BUFFER's terminal from its pane's current screen (synchronous CLI).
Used on (re)tile; live %output keeps the pane current afterward.  The cursor
comes from the batched window-state query (stored in `tmux-control--pane-info'),
so only the screen capture costs a round-trip here."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and tmux-control--terminal (eat-term-live-p tmux-control--terminal))
        (let* ((pane tmux-control--active-pane)
               (cursor (or (plist-get tmux-control--pane-info :cursor)
                           (ignore-errors (tmux-control--query-cursor pane))))
               (text (ignore-errors (tmux-control--capture-pane-screen pane))))
          (when text
            (setq tmux-control--seed-cursor cursor)
            ;; Clear the scrollback (\e[3J) before painting, not just the
            ;; screen, so a reseed (e.g. after a resize) does not leave the
            ;; previous, now-reflowed frame stacked above the fresh one -- an
            ;; app on a tmux with `alternate-screen off' repaints by appending.
            (tmux-control--write-terminal
             (concat "\e[3J"
                     (tmux-control--screen-seed-sequence text cursor)))))))))

;;; Window arrangement from the parsed layout tree.

(defun tmux-control--tile-arrange-node (node window panes collect)
  "Subdivide WINDOW to match layout NODE, assigning PANES buffers to leaves.
COLLECT is called as (PANE-ID WINDOW) for each leaf placed.  Splits follow
tmux's geometry: a row (`:dir h') splits side by side, a column (`:dir v')
stacks; each non-last child is given its tmux char size and the last child
takes the remaining window."
  (pcase (plist-get node :type)
    ('leaf
     (let* ((pane (plist-get node :pane))
            (buf (cdr (assoc pane panes))))
       (when (and (window-live-p window) (buffer-live-p buf))
         (set-window-buffer window buf t)
         (set-window-parameter window 'tmux-control-pane pane)
         ;; Reclaim every column for the terminal: no margins, fringes, or
         ;; scroll bar, so the window body matches the tmux pane width and
         ;; full-width TUI borders are not clipped.
         (set-window-margins window 0 0)
         (set-window-fringes window 0 0)
         (set-window-scroll-bars window 0 nil 0 nil)
         (funcall collect pane window))))
    ('split
     (let ((dir (plist-get node :dir))
           (kids (plist-get node :children))
           (win window))
       (while (cdr kids)
         (let* ((child (car kids))
                (size (if (eq dir 'h)
                          (max window-min-width (plist-get child :w))
                        ;; +1 row for the child window's mode line, so its
                        ;; body height ends up near the tmux pane height.
                        (max window-min-height (1+ (plist-get child :h)))))
                (new (split-window win size (if (eq dir 'h) 'right 'below))))
           (tmux-control--tile-arrange-node child win panes collect)
           (setq win new kids (cdr kids))))
       (tmux-control--tile-arrange-node (car kids) win panes collect)))))

(defun tmux-control--tile-arrange (controller tree panes)
  "Tile CONTROLLER's frame to match layout TREE, showing PANES buffers.
Devotes the whole frame to the tiling (`delete-other-windows').  Returns
an alist (PANE-ID . WINDOW), or nil when the windows could not be built."
  ;; Prefer the selected window when it already shows the controller or one
  ;; of our pane buffers, so a re-tile never reaches onto a different frame
  ;; (an all-frames `get-buffer-window' could) and clobber its layout.
  (let ((root (or (let ((b (window-buffer (selected-window))))
                    (when (or (eq b controller) (rassq b panes))
                      (selected-window)))
                  (cl-some (lambda (np) (get-buffer-window (cdr np) t)) panes)
                  (get-buffer-window controller t)
                  (selected-window))))
    (condition-case err
        (progn
          (select-window root)
          (delete-other-windows root)
          (let ((acc '()))
            (tmux-control--tile-arrange-node
             tree (selected-window) panes
             (lambda (pane win) (push (cons pane win) acc)))
            (nreverse acc)))
      (error
       (tmux-control--message
        (format "tiling: could not arrange windows (%s)"
                (error-message-string err)))
       nil))))

(defun tmux-control--selected-pane-id (panes)
  "Return the pane id whose render buffer is in the selected window, or nil."
  (car (rassq (window-buffer (selected-window)) panes)))

(defun tmux-control--tiling-controller ()
  "Return the controller buffer when this buffer is part of a live tiling.
Works from the controller itself or from one of its pane render buffers;
returns nil otherwise."
  (cond
   (tmux-control--tiled (current-buffer))
   ((and tmux-control--controller
         (buffer-live-p tmux-control--controller)
         (buffer-local-value 'tmux-control--tiled tmux-control--controller))
    tmux-control--controller)))

;;; Building / refreshing / tearing down a tiling.

(defun tmux-control--flush-tiled-panes ()
  "Flush each tiled pane's batched output into its own terminal and redisplay.
Runs in the controller buffer at the end of a filter chunk; each pane
buffer captured its scroll-following windows just before its own feed."
  (dolist (np tmux-control--panes)
    (let ((buf (cdr np)))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (when tmux-control--output-batch
            (let ((sync (tmux-control--current-sync-windows)))
              (tmux-control--flush-output-batch)
              (tmux-control--flush-display sync))))))))

(defun tmux-control--build-tiling (controller)
  "Build or refresh the tiled view of CONTROLLER's current tmux window.
Queries the live layout and pane geometry, reconciles the per-pane render
buffers (reusing survivors, creating new panes, killing gone ones),
arranges the Emacs windows to match, and seeds each pane from its current
screen.  Safe to call repeatedly; a %layout-change routes here."
  (when (buffer-live-p controller)
    (with-current-buffer controller
      (when (process-live-p tmux-control--process)
        ;; One batched query: layout + every pane's geometry and cursor,
        ;; read atomically so the layout and the pane list never disagree.
        (let* ((state (ignore-errors (tmux-control--query-window-state)))
               (layout (car state))
               (geometry (cdr state))
               (tree (tmux-control--parse-layout layout))
               (leaves (tmux-control--layout-leaves tree)))
          (cond
           ((or (null tree) (null leaves) (null geometry))
            (tmux-control--message "tiling: could not read the window layout"))
           ((and (equal layout tmux-control--tiled-layout)
                 tmux-control--panes
                 (cl-every (lambda (np)
                             (and (buffer-live-p (cdr np))
                                  (get-buffer-window (cdr np) t)))
                           tmux-control--panes))
            ;; Layout unchanged and every pane window is intact -- skip a
            ;; redundant rebuild (avoids flicker and focus loss on spurious
            ;; notifications).
            nil)
           (t
            ;; Resolve each layout leaf to its real pane id by coordinate.
            (let ((unmatched nil))
              (dolist (leaf leaves)
                (let ((hit (cl-find-if
                            (lambda (g)
                              (and (= (plist-get (cdr g) :left) (plist-get leaf :x))
                                   (= (plist-get (cdr g) :top) (plist-get leaf :y))))
                            geometry)))
                  (if hit
                      (progn (plist-put leaf :pane (car hit))
                             (plist-put leaf :info (cdr hit)))
                    (setq unmatched t))))
              ;; A leaf with no geometry match means the layout and pane list
              ;; we read disagree (a rare transient).  Rather than tile a
              ;; partial mapping that leaves a pane blank, try again shortly.
              (if unmatched
                  (tmux-control--schedule-retile controller)
                (let* ((old-panes tmux-control--panes)
                   (meta (list :host tmux-control--host
                               :socket tmux-control--socket-name
                               :session tmux-control--session
                               :trailing tmux-control--capture-trailing-p
                               :process tmux-control--process
                               :fallback tmux-control--fallback-target))
                   (focus-pane (tmux-control--selected-pane-id old-panes))
                   (new-panes '())
                   ;; Only newly created or resized panes need a (synchronous,
                   ;; possibly remote) reseed; reused same-size panes keep
                   ;; streaming live, which cuts round-trips and flicker.
                   (to-seed '()))
              (dolist (leaf leaves)
                (let ((pane (plist-get leaf :pane)))
                  (when pane
                    (let* ((existing (cdr (assoc pane old-panes)))
                           (reuse (buffer-live-p existing))
                           (buf (if reuse existing
                                  (tmux-control--make-pane-buffer
                                   pane leaf controller meta)))
                           (w (max 1 (plist-get leaf :w)))
                           (h (max 1 (plist-get leaf :h)))
                           (seed (not reuse)))
                      (with-current-buffer buf
                        (setq tmux-control--pane-info (plist-get leaf :info))
                        (when (and tmux-control--terminal
                                   (eat-term-live-p tmux-control--terminal))
                          (let ((sz (eat-term-size tmux-control--terminal)))
                            (unless (and sz (= (car sz) w) (= (cdr sz) h))
                              (setq seed t)
                              (eat-term-resize tmux-control--terminal w h)))))
                      (push (cons pane buf) new-panes)
                      (when seed (push buf to-seed))))))
              (setq new-panes (nreverse new-panes))
              ;; Kill render buffers for panes that no longer exist.
              (dolist (op old-panes)
                (unless (assoc (car op) new-panes)
                  (when (buffer-live-p (cdr op))
                    (let ((kill-buffer-query-functions nil)
                          (tmux-control--killing-pane t))
                      (kill-buffer (cdr op))))))
              (setq tmux-control--panes new-panes
                    tmux-control--tiled t
                    tmux-control--tiled-layout layout)
              (let ((pane-windows
                     (tmux-control--tile-arrange controller tree new-panes)))
                (if (null pane-windows)
                    ;; Arrangement failed; abandon tiling cleanly.
                    (tmux-control--teardown-tiling controller)
                  ;; Each grid is already sized to its tmux pane (the source
                  ;; of truth for what the app draws); fringe/scroll-bar
                  ;; removal makes the body span the full pane width, so it
                  ;; fits without shrinking the grid (which would drop a row).
                  (dolist (buf to-seed)
                    (tmux-control--seed-pane-buffer-sync buf))
                  (let ((fw (and focus-pane
                                 (cdr (assoc focus-pane pane-windows)))))
                    (when (window-live-p fw) (select-window fw)))
                  ;; The new window is shown; let focus drive tmux again so
                  ;; the focused pane becomes active in the switched-to window.
                  (setq tmux-control--suppress-focus-follow nil)))))))))))))

(defun tmux-control--teardown-tiling (controller &optional keep-windows)
  "Tear down CONTROLLER's tiling: clear state and kill pane render buffers.
Unless KEEP-WINDOWS, restore the controller into a single full-frame
window.  Does not reseed; callers that resume single-pane do that."
  (when (buffer-live-p controller)
    (with-current-buffer controller
      (when (timerp tmux-control--retile-timer)
        (cancel-timer tmux-control--retile-timer)
        (setq tmux-control--retile-timer nil))
      (let ((panes tmux-control--panes))
        (setq tmux-control--tiled nil
              tmux-control--panes nil
              tmux-control--tiled-layout nil
              tmux-control--retile-pending nil
              tmux-control--suppress-focus-follow nil)
        (unless keep-windows
          (let ((win (or (cl-some (lambda (np) (get-buffer-window (cdr np) t))
                                  panes)
                         (get-buffer-window controller t)
                         (selected-window))))
            (when (window-live-p win)
              (select-window win)
              (set-window-buffer win controller)
              (delete-other-windows win))))
        (dolist (np panes)
          (when (buffer-live-p (cdr np))
            (let ((kill-buffer-query-functions nil)
                  (tmux-control--killing-pane t))
              (kill-buffer (cdr np)))))))))

;;; Interactive entry points.

(defun tmux-control--tiling-frame-size (frame)
  "Return a (W . H) char size for the tiling area of FRAME.
Tiling devotes the whole frame, so this is the frame's text area minus the
minibuffer row -- the size tmux is asked to lay the window's panes out in."
  (cons (max 1 (frame-text-cols frame))
        (max 1 (- (frame-text-lines frame) 1))))

(defun tmux-control-tile ()
  "Tile every pane of the current tmux window into Emacs windows.
Each pane is rendered live in its own buffer, arranged to match tmux's
own layout -- the iTerm \"show every pane\" view -- which is handy for a
split-pane window such as a Claude Code agent team.  Devotes the whole
frame to the session.  `tmux-control-untile' (or \\`C-c C-t') returns to
the single-pane view."
  (interactive)
  (tmux-control--ensure-live)
  (when tmux-control--controller
    (user-error "This is a tiled pane; use C-c C-t to untile"))
  (when tmux-control--tiled
    (user-error "Already tiling this session"))
  (let ((size (tmux-control--tiling-frame-size (selected-frame))))
    ;; Ask tmux to size the window to the Emacs area we tile into; the
    ;; resulting %layout-change re-tiles to the exact pane sizes.
    (setq tmux-control--tiled-client-size size)
    (tmux-control--send-command
     (format "refresh-client -C %dx%d" (car size) (cdr size)))
    (tmux-control--build-tiling (current-buffer))))

(defun tmux-control--reassert-tiling-size (controller frame)
  "Ask tmux to match CONTROLLER's tiling area on FRAME when it has resized.
Only acts when the frame's tiling area actually changed, so it ignores the
internal window splits a re-tile makes (those keep the frame size)."
  (when (and (buffer-live-p controller)
             (buffer-local-value 'tmux-control--tiled controller)
             (process-live-p
              (buffer-local-value 'tmux-control--process controller)))
    (with-current-buffer controller
      (let ((size (tmux-control--tiling-frame-size frame)))
        (unless (equal size tmux-control--tiled-client-size)
          (setq tmux-control--tiled-client-size size)
          (tmux-control--send-command
           (format "refresh-client -C %dx%d" (car size) (cdr size)))
          ;; tmux's %layout-change will also schedule a re-tile, but schedule
          ;; one regardless so the grids are refit even if the size is clamped.
          (tmux-control--schedule-retile controller))))))

(defun tmux-control--on-frame-size-change (frame)
  "Re-assert tmux size for any tiled controller showing panes on FRAME.
Installed on `window-size-change-functions' so resizing the Emacs frame
while tiled re-divides the tmux window to match instead of clipping the
panes against a now-smaller Emacs window."
  (dolist (buf (buffer-list))
    (and (buffer-local-value 'tmux-control--tiled buf)
         (cl-some (lambda (np)
                    (let ((w (and (buffer-live-p (cdr np))
                                  (get-buffer-window (cdr np) t))))
                      (and w (eq (window-frame w) frame))))
                  (buffer-local-value 'tmux-control--panes buf))
         (tmux-control--reassert-tiling-size buf frame))))

(add-hook 'window-size-change-functions #'tmux-control--on-frame-size-change)

(defun tmux-control-untile ()
  "Return from the tiled multi-pane view to the single-pane live view."
  (interactive)
  (let ((controller (or tmux-control--controller
                        (and tmux-control--tiled (current-buffer)))))
    (unless (and controller (buffer-live-p controller)
                 (buffer-local-value 'tmux-control--tiled controller))
      (user-error "Not tiling"))
    (tmux-control--teardown-tiling controller)
    (with-current-buffer controller
      ;; Re-query the session's real active pane synchronously (the cached
      ;; one can be stale after window switches) BEFORE anything repaints, so
      ;; every subsequent seed and any live %output route to the right pane.
      (let ((pane (ignore-errors
                    (string-trim
                     (tmux-control--run-tmux
                      (list "display-message" "-p" "#{pane_id}"))))))
        (when (and pane (string-match-p "\\`%[0-9]+\\'" pane))
          (setq tmux-control--active-pane pane)))
      (tmux-control--resize-to-window)
      ;; Hard-clear the terminal (it still holds the frozen pre-tiling
      ;; screen) and paint the active pane synchronously, so the single-pane
      ;; view is exactly one clean screen rather than old content plus new.
      (tmux-control--write-terminal "\e[3J\e[H\e[2J")
      (tmux-control--seed-pane-buffer-sync controller))))

(defun tmux-control-toggle-tiling ()
  "Toggle between the tiled multi-pane view and the single-pane view.
Bound to \\`C-c C-t'."
  (interactive)
  (if (or tmux-control--controller tmux-control--tiled)
      (tmux-control-untile)
    (tmux-control-tile)))

(provide 'tmux-control)

;;; tmux-control.el ends here
