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

(defcustom tmux-control-wheel-enters-scrollback t
  "Non-nil means scrolling up with the mouse wheel enters scrollback view.

The wheel is only intercepted while the live pane shows its normal
screen.  When a full-screen application is running (the alternate
screen, e.g. the copilot TUI, vim, or less), the wheel is forwarded to
that application so it keeps its own mouse scrolling."
  :type 'boolean)

(defvar-local tmux-control--process nil)
(defvar-local tmux-control--terminal nil)
(defvar-local tmux-control--accumulator "")
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
(defvar-local tmux-control--keys-active nil)
(defvar-local tmux-control--live-buffer nil)

(defvar tmux-control--override-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-e") #'tmux-control-scrollback)
    (define-key map (kbd "C-c C-k") #'tmux-control-disconnect)
    (define-key map (kbd "C-c C-l") #'tmux-control-clear-and-repaint)
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
      (tmux-control--send-command "display-message -p '#{pane_id}'" :pane-id)
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
               (let ((index (match-string 1 line))
                     (name (match-string 2 line))
                     (active (string= (match-string 3 line) "1")))
                 (cons index
                       (format "%s: %s%s" index name
                               (if active " (active)" ""))))))
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

Interactively, prompt with completion over the session's windows.
Switching changes the session's active window, so any other client
attached to the same session follows along."
  (interactive (list (tmux-control--read-window-index "Window: ")))
  (tmux-control--ensure-live)
  (setq index (tmux-control--normalize-window-index index))
  (tmux-control--send-command
   (format "select-window -t %s:%s" tmux-control--session index))
  (tmux-control--refresh-active-pane))

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
         (text (tmux-control--capture-pane host socket-name target
                                           tmux-control-scrollback-lines))
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
                                           tmux-control-scrollback-lines))
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

(defun tmux-control--alt-screen-p ()
  "Return non-nil when the live pane shows the alternate (full-screen) display.
This is the screen used by TUI applications such as the copilot TUI,
vim, or less.  Uses Eat's public predicate when available, falling back
to the internal accessor for older Eat versions.  Read locally, with no
tmux query."
  (and tmux-control--terminal
       (eat-term-live-p tmux-control--terminal)
       (cond
        ((fboundp 'eat-term-in-alternative-display-p)
         (eat-term-in-alternative-display-p tmux-control--terminal))
        ((fboundp 'eat--t-term-main-display)
         (eat--t-term-main-display tmux-control--terminal)))
       t))

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

(defun tmux-control-wheel-scroll (event)
  "Handle a mouse wheel EVENT in a live tmux-control buffer.

When `tmux-control-wheel-enters-scrollback' is enabled and the pane is on
its normal screen with no application mouse tracking, scrolling up enters
the scrollback buffer.  Otherwise the event is forwarded to the terminal
so full-screen or mouse-aware applications keep their own scrolling.  The
feature is only active when Eat's screen state can be read, so the live
behavior is otherwise unchanged."
  (interactive "e")
  (let ((window (posn-window (event-start event))))
    (if (and tmux-control-wheel-enters-scrollback
             (window-live-p window)
             (with-current-buffer (window-buffer window)
               (and (derived-mode-p 'tmux-control-mode)
                    (tmux-control--wheel-detectable-p)
                    (not (tmux-control--alt-screen-p))
                    (not (tmux-control--pane-grabs-mouse-p)))))
        (progn
          (select-window window)
          (tmux-control-scrollback))
      (if (window-live-p window)
          (with-selected-window window
            (eat-self-input 1 event))
        (eat-self-input 1 event)))))

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
    (setq tmux-control--active-pane nil)
    (setq tmux-control--command-queue nil)
    (setq tmux-control--current-command-kind :ignore)
    (setq tmux-control--collecting-command nil)
    (setq tmux-control--command-output nil)
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

(defun tmux-control--capture-pane (host socket-name target lines)
  "Return plain text from tmux pane on HOST using SOCKET-NAME and TARGET."
  (let ((args (append (when socket-name
                        (list "-L" socket-name))
                      (list "capture-pane" "-p" "-e")
                      (when tmux-control-scrollback-join-wrapped-lines
                        (list "-J"))
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
  "Prepare captured pane TEXT for the scrollback buffer."
  (let ((text (tmux-control--colorize-scrollback text)))
    (tmux-control--trim-trailing-blank-lines
     (if tmux-control-compact-scrollback
         (tmux-control--compact-repeated-redraw-lines text)
       text))))

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
  "Return non-nil when LINE looks like the start of a TUI redraw frame."
  (string-match-p "\\`\\s-*\\[Session\\]" line))

(defun tmux-control--strip-scrollback-chrome (lines)
  "Remove obvious TUI chrome from captured LINES."
  (tmux-control--trim-blank-line-list
   (seq-remove #'tmux-control--scrollback-chrome-line-p lines)))

(defun tmux-control--scrollback-chrome-line-p (line)
  "Return non-nil when LINE looks like repeated TUI chrome."
  (let ((trimmed (string-trim line)))
    (or (string-match-p "\\`\\[Session\\]" trimmed)
        (string-match-p "AI Credits:" line)
        (string-prefix-p "/ commands" trimmed)
        (string-match-p "\\`[─━]\\{10,\\}\\'" trimmed)
        (string-match-p "\\`❯\\'" trimmed))))

(defun tmux-control--merge-scrollback-chunk (out chunk)
  "Merge CHUNK into OUT without duplicating repeated redraw content."
  (setq chunk (tmux-control--trim-blank-line-list chunk))
  (cond
   ((null chunk) out)
   ((null out) chunk)
   ((tmux-control--line-list-contains-p out chunk) out)
   (t
    (let ((overlap (tmux-control--line-list-overlap out chunk)))
      (append out
              (unless (or (> overlap 0)
                          (string-empty-p (string-trim (car (last out))))
                          (string-empty-p (string-trim (car chunk))))
                '(""))
              (nthcdr overlap chunk))))))

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
            line-end)
        (while (setq line-end (string-match "\n" tmux-control--accumulator start))
          (let ((line (substring tmux-control--accumulator start line-end)))
            (when (and (> (length line) 0)
                       (= (aref line (1- (length line))) ?\r))
              (setq line (substring line 0 -1)))
            (tmux-control--handle-line line))
          (setq start (1+ line-end)))
        (setq tmux-control--accumulator
              (substring tmux-control--accumulator start))))))

(defun tmux-control--handle-line (line)
  "Handle one tmux control protocol LINE."
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
   (tmux-control--collecting-command
    (push line tmux-control--command-output))
   ((string-match "\\`%output \\(%[0-9]+\\)\\(?: \\(.*\\)\\)?\\'" line)
    (let ((pane (match-string 1 line))
          (payload (or (match-string 2 line) "")))
      (setq tmux-control--active-pane pane)
      (tmux-control--write-terminal (tmux-control--decode-output payload))))
   ((string-match "\\`%window-pane-changed [^ ]+ \\(%[0-9]+\\)\\'" line)
    (setq tmux-control--active-pane (match-string 1 line)))))

(defun tmux-control--finish-command-output ()
  "Handle the end of a tmux command reply."
  (pcase tmux-control--current-command-kind
    (:pane-id
     (let ((pane (cl-find-if (lambda (line)
                               (string-match-p "\\`%[0-9]+\\'" line))
                             tmux-control--command-output)))
       (when pane
         (setq tmux-control--active-pane pane)
         (tmux-control--seed-screen))))
    (:capture
     (tmux-control--write-terminal
      (tmux-control--screen-seed-sequence
       (mapconcat #'identity
                  (nreverse tmux-control--command-output)
                  "\n")))))
  (setq tmux-control--collecting-command nil)
  (setq tmux-control--current-command-kind :ignore)
  (setq tmux-control--command-output nil))

(defun tmux-control--seed-screen ()
  "Seed the Eat buffer with the current tmux pane contents."
  (when tmux-control--active-pane
    (tmux-control--send-command
     (format "capture-pane -p -e -t %s"
             tmux-control--active-pane)
     :capture)))

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

(defun tmux-control--screen-seed-sequence (text)
  "Return terminal escapes to paint captured visible-screen TEXT."
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
         (cursor-row height)
         (cursor-column 1)
         (out '("\e[H\e[2J")))
    (dolist (line lines)
      (setq line (string-trim-right line))
      ;; Clip to terminal width by visible columns, ignoring the
      ;; non-printing color escapes; only over-wide lines (rare and
      ;; transient) fall back to a stripped truncation.
      (when (> (tmux-control--display-width line) width)
        (setq line (truncate-string-to-width
                    (tmux-control--strip-ansi line) width nil nil "")))
      (let ((plain (tmux-control--strip-ansi line)))
        (when (string-match "❯[[:blank:]]*" plain)
          (setq cursor-row row)
          (setq cursor-column
                (1+ (string-width (substring plain 0 (match-end 0)))))))
      ;; Reset attributes before erasing so a line's background color does
      ;; not bleed into the cleared remainder of the row.
      (push (format "\e[%d;1H%s\e[m\e[K" row line) out)
      (setq row (1+ row)))
    (push (format "\e[%d;%dH" cursor-row (max 1 cursor-column)) out)
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

(defun tmux-control--write-terminal (output)
  "Write decoded terminal OUTPUT to Eat."
  (when (and tmux-control--terminal (eat-term-live-p tmux-control--terminal))
    (let ((inhibit-read-only t)
          (sync-windows (and (fboundp 'eat--synchronize-scroll-windows)
                             (eat--synchronize-scroll-windows))))
      (eat-term-process-output tmux-control--terminal output)
      (eat-term-redisplay tmux-control--terminal)
      (when (and sync-windows
                 (boundp 'eat--synchronize-scroll-function))
        (funcall eat--synchronize-scroll-function sync-windows)
        (tmux-control--keep-cursor-visible sync-windows))
      (run-hooks 'eat-update-hook))))

(defun tmux-control--send-input (_terminal string)
  "Send STRING as input to the active tmux pane."
  (when (and (process-live-p tmux-control--process)
             (> (length string) 0))
    (let ((target (or tmux-control--active-pane tmux-control--fallback-target)))
      (if target
          (tmux-control--send-command
           (format "send-keys -t %s -H %s"
                   target
                   (tmux-control--string-to-hex-args string)))
        (tmux-control--message "No active tmux pane yet")))))

(defun tmux-control--string-to-hex-args (string)
  "Return STRING encoded as space-separated UTF-8 hexadecimal bytes."
  (let* ((bytes (encode-coding-string string 'utf-8-unix))
         (hex nil))
    (dotimes (i (length bytes))
      (push (format "%02x" (aref bytes i)) hex))
    (string-join (nreverse hex) " ")))

(defun tmux-control--send-command (command &optional kind)
  "Send tmux control mode COMMAND.

KIND identifies the command reply handler."
  (when (process-live-p tmux-control--process)
    (setq tmux-control--command-queue
          (append tmux-control--command-queue
                  (list (or kind :ignore))))
    (process-send-string tmux-control--process (concat command "\n"))))

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
  "Resize the local renderer and tmux client to WIDTH by HEIGHT."
  (when (and tmux-control--terminal (eat-term-live-p tmux-control--terminal))
    (let ((inhibit-read-only t))
      (eat-term-resize tmux-control--terminal width height)
      (eat-term-redisplay tmux-control--terminal)
      (when (fboundp 'eat--synchronize-scroll-windows)
        (tmux-control--keep-cursor-visible
         (eat--synchronize-scroll-windows)))))
  (tmux-control--send-command (format "refresh-client -C %dx%d" width height)))

(defun tmux-control--sentinel (process message)
  "Handle PROCESS exit with MESSAGE."
  (when (buffer-live-p (process-buffer process))
    (with-current-buffer (process-buffer process)
      (unless (string-match-p "\\`finished\\|exited" message)
        (tmux-control--message (string-trim-right message)))
      (setq tmux-control--process nil))))

(defun tmux-control--kill-process ()
  "Delete the tmux control process for the current buffer."
  (when (process-live-p tmux-control--process)
    (delete-process tmux-control--process)))

(defun tmux-control--message (message)
  "Append MESSAGE to the current tmux-control buffer."
  (let ((inhibit-read-only t))
    (goto-char (point-max))
    (insert (propertize (format "\n[tmux-control] %s\n" message)
                        'face 'font-lock-comment-face))))

(provide 'tmux-control)

;;; tmux-control.el ends here
