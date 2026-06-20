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
(require 'mwheel)
(require 'seq)
(require 'subr-x)
(require 'eat)

;; Optional: `consult' drives the per-candidate preview for the `inline'
;; window-preview style.  Soft -- referenced only when bound.
(declare-function consult--read "consult" (candidates &rest options))

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

(defcustom tmux-control-scrollback-lines 10000
  "Maximum number of pane-history lines the scrollback view will load.

Scrollback loads lazily: opening it captures only
`tmux-control-scrollback-initial-lines' (instant), and scrolling toward
the top extends the capture `tmux-control-scrollback-extend-lines' at a
time until this maximum is reached.  So the cost of capturing,
colorizing and (when `tmux-control-compact-scrollback' is on) collapsing
is paid only for the history you actually look at -- the open is no
longer bounded by this number.  Raise it if you routinely scroll back
very far; it only caps how deep the lazy extension will go."
  :type 'integer)

(defcustom tmux-control-scrollback-initial-lines 500
  "Pane-history lines captured when scrollback first opens.

Kept small so the view appears immediately rather than after capturing,
colorizing and inserting the full `tmux-control-scrollback-lines'.  More
history loads on demand as you scroll up (see
`tmux-control-scrollback-extend-lines').  A few hundred lines comfortably
fills a screen with margin."
  :type 'integer)

(defcustom tmux-control-scrollback-extend-lines 2000
  "Pane-history lines added each time scrollback extends toward the top.

When you scroll within a screen of the top of the loaded history,
scrollback captures this many older lines and prepends them (up to
`tmux-control-scrollback-lines'), keeping your viewport fixed.  Larger
values extend in fewer, chunkier steps; smaller values extend more
smoothly but more often."
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

(defcustom tmux-control-scrollback-join-wrapped-lines nil
  "Non-nil means join soft-wrapped pane lines in scrollback captures.
Joining (`capture-pane -J') glues rows tmux wrapped back into single
logical lines, which copy cleanly and re-flow to any window width.  Off
by default because tmux already re-wraps pane history to the pane's
CURRENT width, so a raw capture always fits the live view's window
exactly -- while joining resurrects rows at the width they were
PAINTED: after a frame resize, a TUI's full-width rows (content, box
padding, border) come back at the old width, and Emacs wraps them into
fragments, phantom blank lines, and stranded border glyphs."
  :type 'boolean)

(defcustom tmux-control-compact-scrollback nil
  "Non-nil means compact repeated full-screen redraws in the scrollback view.

A TUI that repaints by reprinting its whole screen -- which happens under tmux
with `alternate-screen' disabled -- leaves many near-identical copies of its
screen in pane history.  When enabled, tmux-control auto-detects the repeated
frame and collapses it to a single copy plus whatever changed between repaints,
so scrolling back shows the progression instead of dozens of copies.

Off by default, so scrollback is shown VERBATIM -- exactly as tmux captured it.
Two reasons that is the right default for most setups: tmux keeps
`alternate-screen' ON by default, so full-screen TUIs use the alternate screen
and never flow into scrollback as repeated frames in the first place; and on
dense, evolving output (an agent streaming a long answer, where each \"frame\"
grows rather than repeats) the collapse can elide more than intended and read
as garbled.  Verbatim is always faithful.

Turn it on if you run `alternate-screen off' and want repeated redraws
suppressed.  In the pager you can also toggle it for the current view with
\\<tmux-control-scrollback-mode-map>\\[tmux-control-scrollback-toggle-compaction],
so it is easy to flip on when a particular history is repetitive and off when a
collapse looks wrong.  For a specific TUI you can override the auto-detected
frame boundary and drop volatile per-frame lines with
`tmux-control-scrollback-frame-start-regexp' and
`tmux-control-scrollback-chrome-regexps'."
  :type 'boolean)

(defcustom tmux-control-compact-scrollback-window 300
  "Maximum line window used to merge repeated redraw chunks in scrollback view."
  :type 'integer)

(defcustom tmux-control-scrollback-frame-start-regexp nil
  "Regexp matching the top line of a repeated full-screen redraw, or nil.

Scrollback compaction (`tmux-control-compact-scrollback') splits captured pane
history into redraw \"frames\" and collapses frames that repeat.  When this is
nil (the default) the frame top is auto-detected from repeated content, which
handles most repainting TUIs with no configuration.  Set this to pin the frame
boundary for a particular TUI when auto-detection picks a poor line (for
example a busy app whose very top line changes every frame).

For example, to force the Claude Code TUI's frames to split on a top line
beginning with \"[Session]\":

    (setq tmux-control-scrollback-frame-start-regexp \"\\\\`\\\\s-*\\\\[Session\\\\]\")"
  :type '(choice (const :tag "Auto-detect the frame top" nil) regexp))

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

(defcustom tmux-control-command-timeout 10
  "Seconds to wait for tmux to reply to a control-mode command.

Replies on the control connection are matched to commands strictly in
order, so a single reply that never arrives -- a hung server, a
half-dead SSH link -- would otherwise wedge the whole command queue
silently: every later command waits behind it forever, and the client
just stops reacting with no indication why.  When the oldest pending
command has waited longer than this, a warning naming the wait is
surfaced in the session buffer and the echo area, pointing at
`tmux-control-reconnect'.  The queue is left untouched (a late reply
must still match its command), so this detects and reports the wedge
rather than guessing at recovery.

nil disables the watchdog."
  :type '(choice (const :tag "Disabled" nil) number))

(defcustom tmux-control-window-buffers t
  "Non-nil gives each visited tmux window its own render buffer.

Switching windows then swaps buffers instead of repainting one buffer in
place, so each window keeps its accumulated Emacs-side scrollback across
switches -- and a visited window keeps STREAMING while you look at
another, so flipping back shows everything it printed in the meantime,
not just its current screen.  Memory grows only with windows you have
actually visited; never-visited windows cost nothing.

When nil, the single live buffer repaints in place on every switch (the
historical behavior): cheaper, but a switch discards the previous
window's scrollback and anything printed while it was in the
background."
  :type 'boolean)

(defcustom tmux-control-wheel-enters-scrollback t
  "Non-nil means scrolling up with the mouse wheel enters scrollback view.

The wheel is only intercepted this way while the live pane shows its
normal screen.  When a full-screen application owns the alternate
screen (e.g. vim or less under a tmux that honors alternate-screen),
or when the application requests mouse events itself, the wheel event
is forwarded to the terminal unchanged."
  :type 'boolean)

(defcustom tmux-control-wheel-scrolls-live-history nil
  "Non-nil means wheel-up first scrolls the live view's own retained history.

iTerm-style continuous scrollback.  Eat keeps the output that has streamed
since you connected as ordinary buffer text above the live screen, already
rendered with its colors.  With this enabled, scrolling up over a
normal-screen pane scrolls *that* -- instantly, in the same buffer, with no
mode switch and no capture round trip -- and incoming output no longer yanks
the view back to the bottom while you read (it resumes following when you
scroll back down or type).  Only once you reach the top of that retained
history does wheel-up open the full `tmux-control-scrollback' pager for the
deeper, pre-session history that lives in tmux rather than Eat.

When nil (the default), wheel-up opens the pager immediately, as before --
the behavior is byte-identical, including the scroll-follow logic.  This is
opt-in because it changes how the live view itself responds to the wheel.

Has no effect unless `tmux-control-wheel-enters-scrollback' is also non-nil."
  :type 'boolean)

(defcustom tmux-control-pane-aware-find-file t
  "Non-nil means file commands in a tmux-control buffer start at the pane's dir.

`tmux-control-find-file' and friends normally open at the live pane's own
current directory, on the pane's host -- so from a buffer mirroring a tmux
pane on a remote host, finding a file roots at `/ssh:HOST:PANE-CWD/' and you
type only the filename, instead of spelling out a full TRAMP path.  Other
commands (`compile', `grep', and so on) are untouched and still run locally.
Set this nil to make those commands open at the buffer's own (local)
directory instead, like ordinary `find-file'."
  :type 'boolean)

(defcustom tmux-control-window-preview t
  "How `tmux-control-select-window' previews windows as you choose.

- t (default) opens a two-pane chooser that lists the session's windows on
  one side and shows a snapshot of the highlighted window's visible screen on
  the other, like tmux's own `choose-tree' menu.
- `inline' keeps selection in the minibuffer (so your completion UI -- vertico,
  ido, default -- is used) but previews the highlighted window *in place* in
  the live buffer instead of splitting the frame; cancelling restores the
  window you came from.  Live preview needs `consult' (it drives the
  per-candidate preview); without it this degrades to a plain prompt.
- nil prompts with plain completion and no preview."
  :type '(choice (const :tag "Two-pane chooser" t)
                 (const :tag "Minibuffer + inline preview" inline)
                 (const :tag "Plain completion, no preview" nil)))

(defcustom tmux-control-session-preview t
  "Non-nil previews sessions in place as you choose one with completion.
When `tmux-control-select-session' prompts, each *already-connected* session is
shown in the live window as you move through the candidates (an unconnected
session is not previewed -- it would have to be connected first); cancelling
restores the session you came from.  Like the window `inline' preview, this
needs `consult' and degrades to a plain prompt without it.  Set to nil for a
plain prompt."
  :type 'boolean)

(defcustom tmux-control-window-preview-delay 0.15
  "Idle seconds to wait before refreshing the window preview as you move.

A small debounce keeps navigation snappy when previews require a remote
tmux query over SSH."
  :type 'number)

(defcustom tmux-control-window-tab-bar t
  "Non-nil shows a header-line tab bar of the session's windows.

In the single-pane live view the header line lists every window in the
session like a row of tabs -- index and name -- with the current window
highlighted, a marker on any background window that has produced output
since you last visited it, and a bell marker when a window rang its bell.
Click a tab to switch to that window.  It is the iTerm-style \"tabs\" view of
a tmux session, and the natural companion to `tmux-control-next-window' and
friends.  Set to nil to hide it."
  :type 'boolean)

(defcustom tmux-control-session-activity t
  "Non-nil flags other connected sessions that have unseen output.
When you are looking at one session and another connected session produces
output, its name appears with a dot at the left of the header line -- the
session-level \"which one wants me?\" signal, the companion to the window
tab bar's per-window dot.  The strip is empty when no other session has
unseen output, so an idle setup shows no extra chrome; click a name to
switch to it.  Set to nil to disable."
  :type 'boolean)

(defface tmux-control-tab-active
  '((t :inherit highlight :weight bold))
  "Face for the current window's tab in the `tmux-control' tab bar.")

(defface tmux-control-tab-inactive
  '((t :inherit shadow))
  "Face for an inactive window's tab in the `tmux-control' tab bar.")

(defface tmux-control-tab-activity
  '((t :inherit warning :weight bold))
  "Face for an inactive window with unseen output, in the tab bar.")

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
(defvar-local tmux-control--self-reseed-pending 0
  "Count of reseeds this client just initiated, awaiting their echoed events.
Incremented by `tmux-control--refresh-active-pane' whenever tmux-control
itself switches the active window (select-window, next/previous/last-window,
new-window, kill-window) -- each such switch already reseeds, and tmux echoes
back a `%session-window-changed' the handler must NOT reseed a second time.
Each echoed event consumes one pending count, so several rapid self-switches
are each matched (a single flag could only absorb one, misclassifying the
rest as external and double-painting).  An *external* switch (another client,
a tmux key binding, a script) increments nothing, so its event finds the
count at zero and reseeds -- which is how the live view and scrollback follow
external switches instead of stranding on the old pane.  Paired with
`tmux-control--self-reseed-until' so a self-switch that yields no event (a
no-op select, a background kill) cannot leave a count stuck and swallow a
later external switch.")
(defvar-local tmux-control--self-reseed-until 0
  "Float-time deadline bounding `tmux-control--self-reseed-pending'.
Refreshed alongside that counter.  Once it passes, any leftover pending count
is treated as stale and cleared, so a self-initiated reseed that produced no
`%session-window-changed' never permanently suppresses external switches.")
(defvar-local tmux-control--fallback-target nil)
(defvar-local tmux-control--host nil)
(defvar-local tmux-control--socket-name nil)
(defvar-local tmux-control--session nil)
(defvar-local tmux-control--scrollback-target nil)
(defvar-local tmux-control--scrollback-size nil
  "(WIDTH . HEIGHT) the scrollback view was last captured for, or nil.")
(defvar-local tmux-control--scrollback-resize-timer nil
  "Debounce timer for re-capturing scrollback after a window resize.")
(defvar-local tmux-control--scrollback-left-bottom nil
  "Non-nil once the scrollback pager has been scrolled up off the bottom.
You enter the pager by scrolling UP, so it opens at the bottom; the
wheel-down-leaves-to-live rule must not fire until you have actually
moved up into history and are scrolling back down -- otherwise a
wheel-down right after entering (or while the capture is still pending,
when the one-line \"capturing…\" placeholder makes the bottom trivially
visible) bounces you straight back to the live view.  Reset when the
pager opens.")
(defvar-local tmux-control--scrollback-depth 0
  "Pane-history lines currently loaded into this scrollback buffer.
The buffer's top line sits this many lines back in the pane's history.
Grows as `tmux-control--scrollback-extend' prepends older lines, up to
`tmux-control-scrollback-lines'.")
(defvar-local tmux-control--scrollback-extending nil
  "Non-nil while an extend capture is in flight, to coalesce scrolls.")
(defvar-local tmux-control--scrollback-at-top nil
  "Non-nil once extension has reached the oldest available pane-history line.
Set when an extend capture returns fewer lines than requested -- there is
nothing older to load -- so the scroll watcher stops firing futile
captures.  Reset when the pager opens or is refreshed.")
(defvar-local tmux-control--command-queue nil
  "Pending control-mode command entries, oldest first.
Each entry is a cons (KIND . SEND-TIME): the reply-handler kind enqueued
by `tmux-control--send-command' and the `float-time' it was sent, read
by the command watchdog to spot a connection that has stopped replying.")
(defvar-local tmux-control--current-command-kind :ignore)
(defvar-local tmux-control--collecting-command nil)
(defvar-local tmux-control--command-output nil)
(defvar-local tmux-control--command-block-number nil
  "Command number from the current reply's %begin line, as a string.
A %end or %error line closes the block only when its number matches;
a captured pane whose CONTENT contains a line starting with \"%end \"
(someone viewing a control-mode transcript, say) must not terminate
the block early.")
(defvar-local tmux-control--command-watchdog-timer nil
  "Pending watchdog timer for the command queue, or nil.")
(defvar-local tmux-control--command-watchdog-warned nil
  "Non-nil after the watchdog has warned about the current stuck episode.
Cleared when a reply arrives or the queue drains, so one wedge produces
one warning rather than one per check interval.")
(defvar-local tmux-control--homeless nil
  "Non-nil in a controller buffer whose own tmux window has closed.
The buffer keeps owning the process and the session state, but it no
longer renders any window: its window id and active pane are nil, and
this flag keeps the window-list refresh from re-claiming the session's
current window for it (that window has -- or will get -- its own render
buffer; two buffers claiming one window routes output to the hidden one
and freezes the visible one).  Cleared by a (re)connect.")

(defvar-local tmux-control--disconnecting nil
  "Non-nil while this session's control process is being shut down on purpose.
Set by `tmux-control-disconnect' right before deleting the process and
consumed by the sentinel: a deliberate disconnect stays quiet, while an
unexpected death -- a dropped SSH connection, a killed tmux server --
announces itself and points at `tmux-control-reconnect'.  The other
deliberate shutdown paths (buffer teardown, a reconnect's reset) detach
the sentinel entirely instead of setting this flag.")
(defvar-local tmux-control--seed-cursor nil
  "Most recent (X . Y) cursor position queried for a screen seed.
X and Y are tmux's 0-indexed cursor column and row on the visible
screen, or nil when the position has not been queried.  Used by the
`:capture' reply handler to place the cursor on the seeded screen.")
(defvar-local tmux-control--seed-cursor-visible :unknown
  "Most recent cursor visibility queried for a screen seed.
The value is `:visible' when tmux reports a visible cursor, `:hidden'
when hidden, and `:unknown' when the state has not been queried.  Used by
the `:capture' reply handler to keep Eat's cursor visibility in sync with
tmux.")
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

;; Per-window render buffers (`tmux-control-window-buffers').  The connect
;; buffer keeps the process and session state and renders its own tmux
;; window; every other window the user visits gets a sibling render buffer
;; that routes through it, and a window switch swaps buffers instead of
;; repainting in place -- so each window keeps its scrollback, and visited
;; windows keep streaming in the background.
(defvar-local tmux-control--window-buffers nil
  "On the connect (controller) buffer: alist (WINDOW-ID . RENDER-BUFFER).
WINDOW-ID is tmux's stable @id string.  Includes the connect buffer
itself under its own window id once that id is known.")
(defvar-local tmux-control--window-id nil
  "The tmux @window-id this buffer renders, or nil before it is known.")
(defvar-local tmux-control--requested-client-size nil
  "On the controller: the (WIDTH . HEIGHT) last asked of refresh-client.
Compared against the :pane-size reconciliation reply to notice a window
whose size tmux is not letting this client drive.")
(defvar-local tmux-control--size-pin-warned nil
  "Non-nil after warning that tmux is not following our size requests.
One warning per episode; cleared when a reconciliation matches again.")
(defvar-local tmux-control--session-display nil
  "On the controller: the render buffer the live view last swapped to.
What `tmux-control--session-display-buffer' readers (the session
switcher, `tmux-control--connect-or-switch') treat as the session's
on-screen buffer.  It tracks swaps, not the frame: a render buffer
displayed by hand leaves it stale until the next swap.  The swap itself
\(`tmux-control--display-window-buffer') therefore keys off the windows
really showing the session's buffers -- never off this pointer, nor off
`tmux-control--current-window', whose index updates via a separate,
slower :windows reply and lags rapid switches (the window preview menu,
two fast `C-c C-n').")

;; Multi-pane tiling (experimental).  In tiling mode the controller buffer
;; (the process buffer) stops rendering and instead fans the session's
;; %output out to one render buffer per pane, tiled into Emacs windows to
;; match tmux's window layout.  See the "Multi-pane tiling" section below.
(defvar-local tmux-control--controller nil
  "Controller buffer owning the shared tmux process, or nil.
Set in a tiled pane render buffer -- and in a per-window render buffer --
so its commands (input, select-pane) route through the controller's
single command queue and process.  nil in the controller buffer itself.")
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
(defvar-local tmux-control--unmatched-retries 0
  "Consecutive re-tiles where a layout leaf matched no pane.
Bounds the retry so a persistent mismatch cannot reschedule forever.")
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
    (define-key map (kbd "C-c C-n") #'tmux-control-next-window)
    (define-key map (kbd "C-c C-p") #'tmux-control-previous-window)
    (define-key map (kbd "C-c C-r") #'tmux-control-reconnect)
    (define-key map (kbd "C-c C-s") #'tmux-control-select-session)
    (define-key map (kbd "C-c C-f") #'tmux-control-toggle-flock)
    ;; NB: ESC is deliberately NOT bound here.  It belongs in the major
    ;; mode map (low precedence) so a modal package's own ESC binding
    ;; wins -- see `tmux-control-mode-map'.
    (define-key map [wheel-up] #'tmux-control-wheel-scroll)
    (define-key map [wheel-down] #'tmux-control-wheel-down)
    map)
  "High-precedence keymap for tmux-control buffers.
Active in semi-char mode (`tmux-control--keys-active').  In char mode it
is swapped for `tmux-control--char-mode-map' so its C-c chords stop
shadowing the pane's own C-c.")

(defvar tmux-control--char-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map [wheel-up] #'tmux-control-wheel-scroll)
    (define-key map [wheel-down] #'tmux-control-wheel-down)
    map)
  "High-precedence keymap for tmux-control buffers in char mode.
Char mode exists to send EVERY key to the pane -- C-c above all, the
interrupt reflex -- so the full override map's C-c chords must not be
consulted there.  Only the wheel stays ours: it is not a key the
application would see, and wheel-up-into-scrollback should work the
same in both modes (the handler already forwards the event to a
mouse-grabbing application).")

(defvar tmux-control--emulation-mode-map-alist
  `((tmux-control--keys-active . ,tmux-control--override-map)
    (tmux-control--char-mode-keys . ,tmux-control--char-mode-map))
  "Emulation map alist used to override Eat minor-mode bindings.
Exactly one of the two gate variables is non-nil at a time: the full
override map in semi-char mode, the wheel-only map in char mode.")

(defvar-local tmux-control--char-mode-keys nil
  "Non-nil while this tmux-control buffer is in Eat char mode.
Gates `tmux-control--char-mode-map' on, while `tmux-control--keys-active'
gates the full override map off; toggled by the eat-char-mode /
eat-semi-char-mode advices.")

(defvar-local tmux-control--windows nil
  "Cached window list for the tab bar.
A list of plists (:index INDEX :name NAME :active BOOL :bell BOOL),
refreshed asynchronously from tmux.")
(defvar-local tmux-control--current-window nil
  "Index string of the session's currently active window, for the tab bar.")
(defvar-local tmux-control--activity nil
  "Hash table of window-index -> t for background windows with unseen output.
A window's panes producing %output while it is not the current window set its
entry; arriving at the window clears it.  Drives the tab bar activity marker.")
(defvar-local tmux-control--pane-window nil
  "Hash table of pane-id -> window-index for the whole session.
Lets streamed %output be attributed to a window for the activity marker.")
(defvar-local tmux-control--activity-quiet-until 0
  "Float-time before which background-activity flagging is suppressed.
Set around client-driven full repaints (connect, switch, resize) so the
resulting prompt/redraw burst in every pane does not flag every window.")
(defvar-local tmux-control--session-activity nil
  "Non-nil when this session produced output while it was off screen.
The session-level analog of `tmux-control--activity': set on the hot output
path when the session is not visible, cleared when it is shown again.  Drives
the cross-session activity strip (see `tmux-control-session-activity').")

(defvar tmux-control-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map eat-mode-map)
    (define-key map (kbd "C-c C-e") #'tmux-control-scrollback)
    (define-key map (kbd "C-c C-k") #'tmux-control-disconnect)
    (define-key map (kbd "C-c C-l") #'tmux-control-clear-and-repaint)
    (define-key map (kbd "C-c C-o") #'tmux-control-other-pane)
    (define-key map (kbd "C-c C-t") #'tmux-control-toggle-tiling)
    (define-key map (kbd "C-c C-n") #'tmux-control-next-window)
    (define-key map (kbd "C-c C-p") #'tmux-control-previous-window)
    (define-key map (kbd "C-c C-r") #'tmux-control-reconnect)
    (define-key map (kbd "C-c C-s") #'tmux-control-select-session)
    (define-key map (kbd "C-c C-f") #'tmux-control-toggle-flock)
    ;; A bare ESC press should reach the pane immediately; see
    ;; `tmux-control-send-escape'.  Bound ONLY here, in the major mode
    ;; map, on purpose: a modal package (xah-fly-keys, evil, viper) that
    ;; binds ESC to leave insert mode installs it in a minor-mode map,
    ;; which outranks the major mode map -- so for those users ESC keeps
    ;; switching modes (the regression this placement fixes), while for
    ;; everyone else, where nothing else claims ESC, it sends to the pane.
    ;; It must NOT go in `tmux-control--override-map' (an emulation map):
    ;; that beats minor-mode maps and would swallow the modal binding.
    (define-key map [escape] #'tmux-control-send-escape)
    ;; Route every "paste" gesture through tmux's own paste buffer.  Eat's
    ;; map covers C-y, M-y, S-insert and mouse yank, but a GUI/macOS
    ;; paste -- `s-v' (Cmd-V), the `[paste]' event, the Edit > Paste
    ;; menu -- stays bound to plain `yank', which inserts into the
    ;; terminal buffer instead of sending to the pane.  And a client-side
    ;; send cannot know whether the pane requested bracketed paste, so a
    ;; multi-line paste executed line by line; tmux knows, so the paste
    ;; rides `set-buffer' + `paste-buffer -p' (see
    ;; `tmux-control--paste-to-pane').  The eat-yank remaps catch C-y/M-y
    ;; through Eat's own minor-mode bindings.
    (define-key map [remap yank] #'tmux-control-yank)
    (define-key map [remap clipboard-yank] #'tmux-control-yank)
    (define-key map [remap eat-yank] #'tmux-control-yank)
    (define-key map [remap yank-pop] #'tmux-control-yank-from-kill-ring)
    (define-key map [remap eat-yank-from-kill-ring] #'tmux-control-yank-from-kill-ring)
    ;; Open files at the live pane's own directory (on the pane's host), so
    ;; finding a file from a buffer mirroring a remote pane does not mean
    ;; spelling out a full TRAMP path.  Eat's semi-char mode leaves C-x and
    ;; M-x for Emacs, so the ordinary file keys reach these.  See
    ;; `tmux-control-pane-aware-find-file'.
    (define-key map [remap find-file] #'tmux-control-find-file)
    (define-key map [remap find-file-other-window] #'tmux-control-find-file-other-window)
    (define-key map [remap dired] #'tmux-control-dired)
    map)
  "Keymap for `tmux-control-mode'.")

(define-derived-mode tmux-control-mode eat-mode "tmux-control"
  "Major mode for tmux-control buffers."
  (tmux-control--disable-line-numbers)
  (tmux-control--disable-margins)
  ;; Arriving at a live buffer always shows the live screen, however the
  ;; buffer got into the window; see `tmux-control--snap-to-live-screen'.
  (add-hook 'window-buffer-change-functions
            #'tmux-control--snap-to-live-screen nil t))

(defvar tmux-control-scrollback-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "g") #'tmux-control-scrollback-refresh)
    (define-key map (kbd "c") #'tmux-control-scrollback-toggle-compaction)
    (define-key map (kbd "C-c C-r") #'tmux-control-reconnect)
    (define-key map (kbd "C-c C-e") #'tmux-control-live)
    (define-key map (kbd "RET") #'tmux-control-live)
    (define-key map (kbd "q") #'tmux-control-live)
    (define-key map [escape] #'tmux-control-live)
    (define-key map [wheel-down] #'tmux-control-scrollback-wheel-down)
    (define-key map [remap eat-semi-char-mode] #'tmux-control-live)
    (define-key map [remap self-insert-command] #'tmux-control-live-self-insert)
    map)
  "Keymap for `tmux-control-scrollback-mode'.")

(defvar tmux-control--scrollback-override-map
  (let ((map (make-sparse-keymap)))
    (define-key map [wheel-down] #'tmux-control-scrollback-wheel-down)
    map)
  "High-precedence keymap for the scrollback pager.
A global minor mode that binds the wheel -- `pixel-scroll-precision-mode'
in particular -- outranks the pager's own keymap, so the bottom-of-history
exit would never fire for real wheel events.  An emulation map outranks
the minor mode (the same reason the live buffer's wheel-up binding lives
in `tmux-control--override-map').  Only wheel-down is bound: everything
else, including wheel-up, falls through to the user's normal scrolling --
and above the bottom the handler re-dispatches wheel-down there too.")

(defvar-local tmux-control--scrollback-keys-active nil)

(defvar tmux-control--scrollback-emulation-map-alist
  `((tmux-control--scrollback-keys-active
     . ,tmux-control--scrollback-override-map))
  "Emulation map alist for scrollback pager buffers.")

(define-derived-mode tmux-control-scrollback-mode special-mode
  "tmux-control-scrollback"
  "Major mode for tmux-control scrollback buffers."
  (setq-local truncate-lines nil)
  (setq-local emulation-mode-map-alists
              (cons tmux-control--scrollback-emulation-map-alist
                    (delq tmux-control--scrollback-emulation-map-alist
                          emulation-mode-map-alists)))
  (setq tmux-control--scrollback-keys-active t)
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
   (let* ((host (read-string
                 "Host (empty for local): "
                 ;; Offer the default host as *editable initial input*, not as
                 ;; `read-string's default value: a default value would make an
                 ;; empty RET return the default, so a configured
                 ;; `tmux-control-default-host' could never be cleared to mean
                 ;; local.  Pre-filled instead, RET keeps it and clearing it
                 ;; (then RET) connects locally, matching the prompt.
                 tmux-control-default-host))
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
      ;; Arming the watchdog here also flags a connection that never
      ;; produces its startup reply (a hung server, a stalled SSH link).
      (setq tmux-control--command-queue (list (cons :ignore (float-time))))
      (tmux-control--arm-command-watchdog)
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
      ;; Tab bar: track the session's windows and which window holds each pane,
      ;; so the header line can show tabs and flag background activity.
      ;; Header line: the window tab bar and/or the cross-session activity
      ;; strip (independent features sharing one row).  Both must ignore the
      ;; connect seed's repaint burst, so quiet activity for either.
      (when (or tmux-control-window-tab-bar tmux-control-session-activity)
        (setq-local header-line-format '(:eval (tmux-control--header-line)))
        ;; The connect seed repaints every pane; don't let that flag everything.
        (tmux-control--quiet-activity 1.5))
      (when tmux-control-window-tab-bar
        (setq tmux-control--activity (make-hash-table :test 'equal)))
      ;; The window list and pane->window map feed the tab bar AND the
      ;; per-window buffer routing; request them when either is on, so
      ;; output routing works with the tab bar disabled too.
      (when (or tmux-control-window-tab-bar tmux-control-window-buffers)
        (tmux-control--refresh-windows)
        (tmux-control--refresh-pane-window-map))
      (when (and (integerp tmux-control-pause-after)
                 (> tmux-control-pause-after 0))
        ;; Opt-in control-mode flow control: tmux pauses a lagging pane and
        ;; notifies with %pause instead of streaming an unbounded backlog.
        (tmux-control--send-command
         (format "refresh-client -f pause-after=%d" tmux-control-pause-after)))
      (tmux-control--disable-line-numbers))
    buffer))

(defun tmux-control--session-live-buffer (host session)
  "Return the live tmux-control buffer already showing HOST/SESSION, or nil.
Mirrors `tmux-control-connect's buffer naming so a session that is already
connected is reused instead of respawned."
  (let* ((local (or (null host) (string-empty-p host)))
         (buffer (get-buffer (format "*tmux-control:%s:%s*"
                                     (if local "local" host) session))))
    (when (and buffer
               (buffer-live-p buffer)
               (process-live-p (buffer-local-value 'tmux-control--process buffer)))
      buffer)))

(defun tmux-control--connect-or-switch (host socket-name session)
  "Show SESSION on HOST/SOCKET-NAME, reusing a live connection if there is one.
Each tmux session is its own tmux-control buffer with its own control
connection (so each keeps its scrollback and tab-bar state); switching means
showing that buffer, or connecting it the first time.

The view switches *in place*: the target replaces the current session in the
selected window (like flipping a terminal tab) instead of splitting the frame,
even when `tmux-control-connect' would otherwise pop a new window."
  (let ((buffer (tmux-control--session-live-buffer host session))
        (display-buffer-overriding-action '((display-buffer-same-window))))
    (if buffer
        ;; Show the session as it currently is: its current window's render
        ;; buffer when per-window buffers are on, not necessarily the
        ;; controller.
        (pop-to-buffer (tmux-control--session-display-buffer buffer))
      (tmux-control-connect host socket-name session))))

(defun tmux-control--select-session-inline (host socket sessions current)
  "Choose a session in the minibuffer, previewing connected ones in place.
Each already-connected session is shown in the live window as you move through
the candidates; an unconnected one is not previewed.  Cancelling restores the
session you came from.  Uses `consult'."
  (let* ((window (selected-window))
         (orig-buffer (window-buffer window))
         (choices (mapcar (lambda (s)
                            (cons (if (equal s current) (concat s " (current)") s) s))
                          sessions))
         (choice (tmux-control--read-with-preview
                  (format "Session (current: %s): " current) choices
                  (lambda (s)
                    (when-let* ((buf (tmux-control--session-live-buffer host s)))
                      (when (window-live-p window) (set-window-buffer window buf))))
                  (lambda ()
                    (when (and (window-live-p window) (buffer-live-p orig-buffer))
                      (set-window-buffer window orig-buffer)))
                  'tmux-control-session)))
    (when (and choice (not (string-empty-p choice)))
      (tmux-control--connect-or-switch host socket choice))))

;;;###autoload
(defun tmux-control-select-session ()
  "Switch the view to another tmux session on the same host and socket.
Completes over the sessions that currently exist there, requiring a match so
a typo cannot accidentally spawn a new session; an existing connection is
reused, otherwise the session is connected.  Bound to \\`C-c C-s'.  To
*create* a session, use `tmux-control-connect' (which attaches or creates).
With `tmux-control-session-preview' (and `consult'), connected sessions are
previewed in place as you choose.  See also `tmux-control-next-session'."
  (interactive)
  (unless tmux-control--session
    (user-error "Not in a tmux-control session buffer"))
  (let* ((host tmux-control--host)
         (socket tmux-control--socket-name)
         (current tmux-control--session)
         (sessions (tmux-control--list-sessions host socket)))
    (if (and tmux-control-session-preview (fboundp 'consult--read))
        (tmux-control--select-session-inline host socket sessions current)
      (let ((choice (completing-read
                     (format "Session (current: %s): " current)
                     sessions nil t)))
        (when (and choice (not (string-empty-p choice)))
          (tmux-control--connect-or-switch host socket choice))))))

(defun tmux-control--cycle-session (delta)
  "Switch to the session DELTA steps from the current one (wrapping).
Cycles over the sessions that exist on this buffer's host and socket, in
tmux's own list order, connecting the target on demand."
  (unless tmux-control--session
    (user-error "Not in a tmux-control session buffer"))
  (let* ((host tmux-control--host)
         (socket tmux-control--socket-name)
         (sessions (tmux-control--list-sessions host socket)))
    (cond
     ((null sessions) (tmux-control--message "No sessions to switch to"))
     ((not (cdr sessions)) (tmux-control--message "Only one session"))
     (t (let* ((n (length sessions))
               (cur (or (cl-position tmux-control--session sessions :test #'equal) 0))
               (next (nth (mod (+ cur delta) n) sessions)))
          (tmux-control--connect-or-switch host socket next))))))

;;;###autoload
(defun tmux-control-next-session ()
  "Switch to the next tmux session on this host/socket, wrapping around."
  (interactive)
  (tmux-control--cycle-session 1))

;;;###autoload
(defun tmux-control-previous-session ()
  "Switch to the previous tmux session on this host/socket, wrapping around."
  (interactive)
  (tmux-control--cycle-session -1))

;;; Flock view: every connected session at once -----------------------------
;;
;; Because each session is its own buffer with its own always-live control
;; connection (it streams %output whether or not it is on screen), showing
;; several at once is just an Emacs window arrangement over buffers that are
;; already live -- no extra connections, no per-pane routing.  The flock view
;; tiles one cell per connected session and sizes each session to its cell.

(defun tmux-control--live-session-buffers ()
  "Return one displayable buffer per live tmux-control session, sorted by name.
Each session is represented by its current window's render buffer when
per-window buffers are on (the controller, otherwise).  Excludes tiling
pane buffers and tiled controllers (which render nothing)."
  (sort
   (mapcar
    #'tmux-control--session-display-buffer
    (seq-filter
     (lambda (b)
       (and (buffer-live-p b)
            (buffer-local-value 'tmux-control--session b)
            (not (buffer-local-value 'tmux-control--controller b))
            (not (buffer-local-value 'tmux-control--tiled b))
            (process-live-p (buffer-local-value 'tmux-control--process b))))
     (buffer-list)))
   (lambda (a b) (string< (buffer-name a) (buffer-name b)))))

(defun tmux-control--flock-grid (buffers)
  "Arrange BUFFERS one-per-cell in a near-square grid in the current frame."
  (delete-other-windows)
  (let* ((n (length buffers))
         (cols (max 1 (ceiling (sqrt n))))
         (rows (max 1 (ceiling (/ (float n) cols))))
         (row-wins (list (selected-window)))
         (remaining buffers))
    ;; Stacked rows: split the most-recently-created bottom window each time.
    (dotimes (_ (1- rows))
      (push (split-window (car row-wins) nil 'below) row-wins))
    (setq row-wins (nreverse row-wins))
    (dolist (rw row-wins)
      (when remaining
        (let* ((cnt (min cols (length remaining)))
               (cell-wins (list rw)))
          (dotimes (_ (1- cnt))
            (push (split-window (car cell-wins) nil 'right) cell-wins))
          (dolist (cw (nreverse cell-wins))
            (when remaining (set-window-buffer cw (pop remaining)))))))
    (balance-windows)))

(defun tmux-control--flock-resize-all ()
  "Resize every session shown in the current frame to fit its cell."
  (dolist (w (window-list nil 'no-minibuffer))
    (let ((buf (window-buffer w)))
      (when (process-live-p (buffer-local-value 'tmux-control--process buf))
        (with-selected-window w
          (with-current-buffer buf
            (tmux-control--resize-to-window)))))))

(defun tmux-control--connect-all-sessions ()
  "Connect every session on this buffer's host/socket that isn't live yet.
Used by `tmux-control-flock' with a prefix argument so the flock shows the
whole host, not just the sessions you happened to open.  Connections are
made without disturbing the window layout (the flock re-arranges it next);
their screens seed asynchronously, like any connect."
  (unless tmux-control--session
    (user-error "Run this from a tmux-control session buffer"))
  (let ((host tmux-control--host)
        (socket tmux-control--socket-name))
    (save-window-excursion
      (dolist (session (tmux-control--list-sessions host socket))
        (unless (tmux-control--session-live-buffer host session)
          (tmux-control-connect host socket session))))))

;;;###autoload
(defun tmux-control-flock (&optional connect-all)
  "Show every connected tmux session at once, one per cell, all live.
Each cell is an ordinary session buffer (its mode line and window tab bar
label it), so you can read, switch windows in, or type into any session
without leaving the overview.  Devotes the whole frame to the grid;
`tmux-control-unflock' (or `tmux-control-toggle-flock') returns to the
single session under point.

By default this tiles the sessions you have already connected (with
`tmux-control-connect' / `tmux-control-select-session').  With a prefix
argument CONNECT-ALL, first connect every session on this buffer's
host/socket so the flock shows them all."
  (interactive "P")
  (when connect-all
    (tmux-control--connect-all-sessions))
  (let ((buffers (tmux-control--live-session-buffers)))
    (cond
     ((null buffers)
      (user-error "No live tmux-control sessions to flock"))
     ((not (cdr buffers))
      (user-error
       (substitute-command-keys
        "Only one connected session — \\`C-u \\[tmux-control-toggle-flock]' flocks all on this host")))
     (t
      (tmux-control--flock-grid buffers)
      (tmux-control--flock-resize-all)
      (set-frame-parameter nil 'tmux-control--flock t)
      (message "Flock: %d sessions — C-c C-f returns to one" (length buffers))))))

;;;###autoload
(defun tmux-control-unflock ()
  "Leave the flock view, showing only the session under point."
  (interactive)
  (let ((buf (current-buffer)))
    (delete-other-windows)
    (set-frame-parameter nil 'tmux-control--flock nil)
    (when (process-live-p (buffer-local-value 'tmux-control--process buf))
      (tmux-control--resize-to-window))))

;;;###autoload
(defun tmux-control-toggle-flock (&optional connect-all)
  "Toggle the all-sessions flock view.  Bound to \\`C-c C-f'.
With a prefix argument CONNECT-ALL, connect every session on this host
before flocking (see `tmux-control-flock')."
  (interactive "P")
  (if (frame-parameter nil 'tmux-control--flock)
      (tmux-control-unflock)
    (tmux-control-flock connect-all)))

(defun tmux-control--sessions-frame ()
  "Return the dedicated sessions frame, creating it if there isn't one.
The caller raises and focuses it (see `tmux-control-flock-other-frame')."
  (let ((frame (seq-find (lambda (fr) (frame-parameter fr 'tmux-control-sessions-frame))
                         (frame-list))))
    (if (frame-live-p frame)
        frame
      (make-frame '((name . "tmux-control — sessions")
                    (tmux-control-sessions-frame . t))))))

;;;###autoload
(defun tmux-control-flock-other-frame (&optional connect-all)
  "Flock every connected session in a separate, reusable frame.
Creates (or raises) a dedicated \"sessions\" frame and runs
`tmux-control-flock' there, so you can watch every session beside your code
\(or on another monitor) instead of giving the current frame to the grid --
the flock devotes a whole frame, so a second frame is the clean way to keep
a code buffer in view.  Re-run it to refresh and raise that frame.

\(A single session needs none of this: the single-pane view is just a buffer,
so put one beside your code with an ordinary window split or `C-x 5 b'.)

With a prefix argument CONNECT-ALL, connect every session on this buffer's
host/socket first (run it from a session buffer so the host is known)."
  (interactive "P")
  ;; Connect-all needs this buffer's host/socket, so do it before leaving for
  ;; the (buffer-agnostic) sessions frame.
  (when connect-all
    (tmux-control--connect-all-sessions))
  (select-frame-set-input-focus (tmux-control--sessions-frame))
  (tmux-control-flock))

(defun tmux-control-disconnect ()
  "Disconnect the current tmux-control client."
  (interactive)
  (when (process-live-p tmux-control--process)
    (let ((ctrl (process-buffer tmux-control--process)))
      (when (buffer-live-p ctrl)
        (with-current-buffer ctrl
          (setq tmux-control--disconnecting t))))
    (delete-process tmux-control--process)))

(defun tmux-control-reconnect ()
  "Re-establish this session's control connection in place.

The tmux session itself is untouched -- it keeps running server-side;
only the control client is replaced.  Use this after a dropped SSH
connection (a closed laptop lid, a network change) or when the
connection is stuck.  The buffer's saved host, socket and session are
reused, so there is nothing to re-enter.

Works from the live view, a per-window render buffer, a tiled pane
buffer, or the scrollback pager."
  (interactive)
  (let ((ctrl (cond
               ((derived-mode-p 'tmux-control-scrollback-mode)
                (if (buffer-live-p tmux-control--live-buffer)
                    (with-current-buffer tmux-control--live-buffer
                      (tmux-control--wb-controller))
                  ;; The live buffer is gone; the pager still carries the
                  ;; connection parameters as buffer-locals.
                  (current-buffer)))
               ((derived-mode-p 'tmux-control-mode)
                (tmux-control--wb-controller))
               (t (user-error "Not in a tmux-control buffer")))))
    (let ((host (buffer-local-value 'tmux-control--host ctrl))
          (socket (buffer-local-value 'tmux-control--socket-name ctrl))
          (session (buffer-local-value 'tmux-control--session ctrl)))
      (unless session
        (user-error "No tmux-control session recorded in this buffer"))
      ;; Replace the current view in place, exactly like the session
      ;; switcher: a reconnect should never split the frame.
      (let ((display-buffer-overriding-action '((display-buffer-same-window))))
        (tmux-control-connect host socket session)))))

(defun tmux-control-clear-and-repaint ()
  "Refresh the live view from the current tmux pane screen."
  (interactive)
  (tmux-control--seed-screen))

(defun tmux-control--walk-keymap (keymap fn &optional prefix)
  "Call FN with a (KEY-VECTOR . COMMAND) cons for each binding in KEYMAP.
Recurses into prefix keymaps (accumulating PREFIX) so chords like
\\`C-c C-n' are reported whole, and expands `[remap CMD]' entries into a
`[remap CMD]' key vector.  Skips anything that is not a command.
Includes bindings inherited from KEYMAP's parent (`map-keymap' descends
into it); use `tmux-control--walk-own-keymap' to stop at the parent."
  (map-keymap
   (lambda (event binding)
     (cond
      ((eq event 'remap)
       (map-keymap
        (lambda (cmd new)
          (when (commandp new)
            (funcall fn (cons (vector 'remap cmd) new))))
        binding))
      ((keymapp binding)
       (tmux-control--walk-keymap binding fn (vconcat prefix (vector event))))
      ((commandp binding)
       (funcall fn (cons (vconcat prefix (vector event)) binding)))))
   keymap))

(defun tmux-control--walk-own-keymap (keymap fn)
  "Call FN with a (KEY-VECTOR . COMMAND) cons for KEYMAP's OWN bindings.
Like `tmux-control--walk-keymap' but stops at KEYMAP's parent rather than
descending into it, so a mode map's inherited `eat-mode-map' bindings are
not reported as tmux-control's.  Reads the keymap structure directly
without mutating it (the parent is spliced as the entry-list tail; walk
the own entries until that tail is reached).  Prefix sub-keymaps have no
parent of their own, so they are walked in full by
`tmux-control--walk-keymap'."
  (let ((parent (keymap-parent keymap))
        (tail (cdr keymap)))
    (while (and (consp tail) (not (eq tail parent)))
      (let ((entry (car tail)))
        (when (consp entry)
          (let ((event (car entry))
                (binding (cdr entry)))
            (cond
             ((and (eq event 'remap) (keymapp binding))
              (map-keymap
               (lambda (cmd new)
                 (when (commandp new)
                   (funcall fn (cons (vector 'remap cmd) new))))
               binding))
             ((keymapp binding)
              (tmux-control--walk-keymap binding fn (vector event)))
             ((commandp binding)
              (funcall fn (cons (vector event) binding)))))))
      (setq tail (cdr tail)))))

(defun tmux-control--audit-rows ()
  "Return audit rows (KEY-DESC INTENDED ACTUAL STATUS) for this buffer.
For every key tmux-control binds in the maps active here, resolve what
the key ACTUALLY runs now and compare it with tmux-control's intended
command.  STATUS is `active' when they agree and `overridden' when the
user's configuration (a minor-mode or modal-package map) wins.  Must run
in the tmux-control buffer being audited."
  (let ((maps (if (derived-mode-p 'tmux-control-scrollback-mode)
                  (list tmux-control-scrollback-mode-map)
                (append (list tmux-control-mode-map)
                        (when tmux-control--keys-active
                          (list tmux-control--override-map))
                        (when tmux-control--char-mode-keys
                          (list tmux-control--char-mode-map)))))
        (seen (make-hash-table :test 'equal))
        rows)
    (dolist (map maps)
      ;; Walk each map's OWN bindings only: `tmux-control--walk-own-keymap'
      ;; stops at the parent, so the mode map's inherited `eat-mode-map'
      ;; bindings are not reported as tmux-control's -- and it reads the
      ;; keymap without mutating it (no transient parent-detach on a
      ;; shared global map).
      (tmux-control--walk-own-keymap
       map
       (lambda (pair)
         (let* ((key (car pair))
                (intended (cdr pair))
                (desc (key-description key)))
           (unless (gethash desc seen)
             (puthash desc t seen)
             (let ((actual (key-binding key)))
               (push (list desc intended actual
                           (if (eq actual intended) 'active 'overridden))
                     rows)))))))
    (sort rows (lambda (a b) (string< (car a) (car b))))))

(defun tmux-control-audit-keys ()
  "Report how tmux-control's key bindings resolve in this buffer.

For every key tmux-control binds, show its intended command and what the
key ACTUALLY runs here.  A binding the package needs but your config
shadows (a silently broken feature) shows as `overridden'; so does a key
tmux-control intentionally yields to your config (e.g. ESC, which defers
to a modal package's command-mode key) -- the report states facts, you
judge which overrides are wanted.

Run it in the live buffer you care about; under a modal package
\(xah-fly-keys, evil, viper) the active keymaps differ by state, so run
it once in insert state and once in command state to see both."
  (interactive)
  (unless (or (derived-mode-p 'tmux-control-mode)
              (derived-mode-p 'tmux-control-scrollback-mode))
    (user-error "Not in a tmux-control buffer"))
  (let* ((rows (tmux-control--audit-rows))
         (overridden (cl-count 'overridden rows :key #'cadddr))
         (width (apply #'max 10 (mapcar (lambda (r) (length (car r))) rows)))
         ;; Emacs `format' has no `*' dynamic-width field, so bake WIDTH in.
         (row-fmt (format "%%-%ds  %%-32s  %%s%%s\n" width)))
    (with-help-window "*tmux-control key audit*"
      (princ (format "tmux-control key audit -- %s\n" (buffer-name)))
      (princ (format "%d bindings, %d overridden by your configuration.\n\n"
                     (length rows) overridden))
      (princ (format row-fmt "KEY" "INTENDED" "ACTUAL HERE" ""))
      (princ (make-string (+ width 2 32 2 24) ?-))
      (princ "\n")
      (dolist (r rows)
        (princ (format row-fmt
                       (nth 0 r)
                       (nth 1 r)
                       (nth 2 r)
                       (if (eq (nth 3 r) 'overridden) "   <- overridden" ""))))
      (princ "\n")
      (princ "\"overridden\" means another keymap (often a minor mode or a\n")
      (princ "modal package) wins this key here.  That is a broken feature if\n")
      (princ "you expected the tmux-control command -- or intended if the key\n")
      (princ "is one tmux-control yields on purpose (ESC defers to a modal\n")
      (princ "package's command-mode key).  Under a modal package, run this in\n")
      (princ "both insert and command state; the active maps differ.\n"))))

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
  "Return an alist of (PANE-ID . LABEL) for every pane in session TARGET.
Queries tmux on HOST using SOCKET-NAME, across ALL of the session's
windows (an agent fleet shows every agent, whichever window it lives
in).  LABEL shows the pane's window and index, its running command, its
title when that differs, and whether it is the session's active pane."
  (let* ((fmt "#{pane_id}\t#{window_index}\t#{window_name}\t#{pane_index}\t#{pane_active}\t#{window_active}\t#{pane_current_command}\t#{pane_title}")
         (args (append (when socket-name (list "-L" socket-name))
                       (list "list-panes" "-s" "-t" target "-F" fmt)))
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
                    "\\`\\(%[0-9]+\\)\t\\([0-9]+\\)\t\\([^\t]*\\)\t\\([0-9]+\\)\t\\([01]\\)\t\\([01]\\)\t\\([^\t]*\\)\t\\(.*\\)\\'"
                    line)
               (let* ((pane (match-string 1 line))
                      (widx (match-string 2 line))
                      (wname (match-string 3 line))
                      (pidx (match-string 4 line))
                      (pane-active (string= (match-string 5 line) "1"))
                      (win-active (string= (match-string 6 line) "1"))
                      (cmd (match-string 7 line))
                      (title (match-string 8 line))
                      (label (format "%s:%s.%s %s%s%s"
                                     widx wname pidx cmd
                                     (if (and (not (string-empty-p title))
                                              (not (equal title cmd)))
                                         (format " (%s)" title)
                                       "")
                                     (if (and pane-active win-active)
                                         " [active]" ""))))
                 (cons pane label))))
           (split-string (string-trim text) "\n" t)))))

(defun tmux-control--ensure-live ()
  "Signal a `user-error' unless this buffer has a live tmux-control session."
  (unless tmux-control--session
    (user-error "No tmux-control session in this buffer"))
  (unless (process-live-p tmux-control--process)
    (user-error "tmux-control process is not live")))

(defun tmux-control--refresh-active-pane (&optional self-initiated)
  "Re-query the session's active pane id, repaint the live view, and resize.
SELF-INITIATED non-nil means this client is switching the active window
itself; record one pending self-reseed so the `%session-window-changed' tmux
echoes back for our own switch does not reseed a second time.  Counting
\(rather than a single flag) lets several rapid self-switches each be matched
to their own echoed event; the paired deadline bounds the count so a switch
that yields no event cannot leave it stuck.  The deadline is generous enough
to cover the notification round-trip even over SSH.  Called without
SELF-INITIATED from that handler to follow an external switch, where
recording a pending reseed would wrongly swallow the next external switch."
  (tmux-control--quiet-activity)
  (when self-initiated
    (setq tmux-control--self-reseed-pending (1+ tmux-control--self-reseed-pending)
          tmux-control--self-reseed-until (+ (float-time) 1.0)))
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

(defun tmux-control--window-choices ()
  "Return an alist of (DISPLAY . INDEX) for the current session's windows."
  (unless tmux-control--session
    (user-error "No tmux-control session in this buffer"))
  (mapcar (lambda (w) (cons (cdr w) (car w)))
          (tmux-control--list-windows tmux-control--host
                                      tmux-control--socket-name
                                      tmux-control--session)))

(defun tmux-control--read-window-index (prompt)
  "Read a window index for the current session using PROMPT with completion."
  (let* ((choices (tmux-control--window-choices))
         (choice (completing-read prompt choices nil t)))
    (or (cdr (assoc choice choices))
        (car (split-string choice ":")))))

(defun tmux-control--read-with-preview (prompt choices preview restore &optional category)
  "Read a value from CHOICES with PROMPT, previewing each candidate live.
CHOICES is an alist of (DISPLAY . VALUE).  PREVIEW is called with a VALUE as
you move through candidates (a live in-place preview); RESTORE is called with
no arguments if you cancel, to undo the previews.  Returns the selected VALUE
\(the caller commits it), or nil.  Uses `consult' for the live preview;
without it, a plain completion prompt with no preview."
  (if (not (fboundp 'consult--read))
      (cdr (assoc (completing-read prompt choices nil t) choices))
    (let ((committed nil))
      (unwind-protect
          (prog1 (cdr (assoc
                       (consult--read
                        (mapcar #'car choices)
                        :prompt prompt :require-match t :sort nil
                        :category (or category 'tmux-control)
                        :state (lambda (action cand)
                                 (when (and (eq action 'preview) cand)
                                   (when-let* ((value (cdr (assoc cand choices))))
                                     (funcall preview value)))))
                       choices))
            (setq committed t))
        (unless committed (funcall restore))))))

(defun tmux-control--select-window-inline ()
  "Choose a window in the minibuffer, previewing each candidate in place.
With `consult' the live view switches to the highlighted window as you move and
is restored to the window you came from if you cancel; without it, a plain
prompt."
  (let* ((choices (tmux-control--window-choices))
         (buffer (current-buffer))
         ;; Restore on cancel to the freshly-queried active window (its candidate
         ;; carries `tmux-window-active'), not `tmux-control--current-window' --
         ;; that is only maintained when the tab bar is on.
         (original (or (cdr (seq-find
                             (lambda (c) (get-text-property 0 'tmux-window-active (car c)))
                             choices))
                       tmux-control--current-window))
         (idx (tmux-control--read-with-preview
               "Window: " choices
               (lambda (i) (when (buffer-live-p buffer)
                             (with-current-buffer buffer (tmux-control--do-select-window i))))
               (lambda () (when (and original (buffer-live-p buffer))
                            (with-current-buffer buffer
                              (tmux-control--do-select-window original))))
               'tmux-control-window)))
    (when idx
      (with-current-buffer buffer
        (tmux-control--do-select-window (tmux-control--normalize-window-index idx))))))

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
   ((eq tmux-control-window-preview 'inline)
    (tmux-control--select-window-inline))
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
      (if tmux-control-window-buffers
          (progn
            (tmux-control--quiet-activity)
            ;; The target is KNOWN here (menu pick, tab click, chooser), so
            ;; swap the display NOW -- zero round trips -- instead of
            ;; waiting for tmux to echo %session-window-changed.  The echo
            ;; still arrives and re-runs the swap idempotently, and remains
            ;; the only driver for switches we did not initiate.  Falls
            ;; through quietly when the window list has not delivered an id
            ;; for INDEX yet; the echo then does the swap as before.
            (when-let* ((idx (if (integerp index)
                                 (number-to-string index)
                               index))
                        (id (and (stringp idx)
                                 (with-current-buffer
                                     (tmux-control--wb-controller)
                                   (tmux-control--window-id-for-index idx)))))
              (tmux-control--display-window-buffer id)))
        (tmux-control--refresh-active-pane t)))))

(defun tmux-control--switch-window (verb)
  "Switch the live view to another window via tmux command VERB.
VERB is a session-relative selector command -- \"next-window\",
\"previous-window\", or \"last-window\" -- which tmux resolves against the
session's own window order and current/last pointers, so cycling wraps and
\"last\" toggles exactly as tmux itself does.  Mirrors
`tmux-control--do-select-window': the single-pane view reseeds in place on the
new window's active pane, while a tiled view re-tiles from the
%session-window-changed notification.  Switching changes the session's current
window, so any other client attached to the session follows along."
  (tmux-control--ensure-live)
  (let ((ctrl (tmux-control--tiling-controller)))
    ;; Suppress focus-follow across the switch (see `tmux-control--do-select-window').
    (when ctrl
      (with-current-buffer ctrl
        (setq tmux-control--suppress-focus-follow t)))
    (tmux-control--send-command
     (format "%s -t %s" verb tmux-control--session))
    (unless ctrl
      ;; See `tmux-control--do-select-window' on the per-window-buffers case.
      (if tmux-control-window-buffers
          (tmux-control--quiet-activity)
        (tmux-control--refresh-active-pane t)))))

;;;###autoload
(defun tmux-control-next-window ()
  "Switch the live view to the next window in the session, wrapping around.
Like flipping to the next tab.  Other clients follow along.  Bound to
\\`C-c C-n'.  See also `tmux-control-previous-window' and
`tmux-control-last-window'."
  (interactive)
  (tmux-control--switch-window "next-window"))

;;;###autoload
(defun tmux-control-previous-window ()
  "Switch the live view to the previous window in the session, wrapping around.
Like flipping to the previous tab.  Other clients follow along.  Bound to
\\`C-c C-p'."
  (interactive)
  (tmux-control--switch-window "previous-window"))

;;;###autoload
(defun tmux-control-last-window ()
  "Switch the live view to the most recently selected window.
Toggles back and forth between the two most recent windows, like tmux's own
`last-window'.  Other clients follow along."
  (interactive)
  (tmux-control--switch-window "last-window"))

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
  ;; Per-window buffers: the echoed %session-window-changed creates and
  ;; displays the new window's buffer; re-querying the active pane here
  ;; would aim THIS buffer at the new window's pane while it still renders
  ;; its own window -- the foreign-pane corruption the window-switch
  ;; commands already guard against (see `tmux-control--do-select-window').
  (if tmux-control-window-buffers
      (tmux-control--quiet-activity)
    (tmux-control--refresh-active-pane t)))

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
  ;; Mirror tmux-control-new-window: with per-window buffers the
  ;; %window-close/%session-window-changed echoes do all the work.
  (if tmux-control-window-buffers
      (tmux-control--quiet-activity)
    (tmux-control--refresh-active-pane t)))

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

;;;; Window tab bar
;;
;; A header-line row of the session's windows, like iTerm's tmux tabs: the
;; current window highlighted, background windows that produced output since
;; you last saw them flagged, and a bell marked.  The window list and the
;; pane->window map are refreshed asynchronously over the existing control
;; connection -- never a blocking CLI call from the process filter -- so a busy
;; remote session is not stalled by tab-bar upkeep.

(defun tmux-control--refresh-windows ()
  "Asynchronously refresh the cached window list that feeds the tab bar."
  (when (and (or tmux-control-window-tab-bar tmux-control-window-buffers)
             (process-live-p tmux-control--process))
    (tmux-control--send-command
     (format "list-windows -t %s -F '#{window_index}\t#{window_name}\t#{window_active}\t#{window_bell_flag}\t#{window_id}'"
             tmux-control--session)
     :windows)))

(defun tmux-control--refresh-pane-window-map ()
  "Asynchronously refresh the pane-id -> window map for output routing."
  (when (and (or tmux-control-window-tab-bar tmux-control-window-buffers)
             (process-live-p tmux-control--process))
    (tmux-control--send-command
     (format "list-panes -s -t %s -F '#{pane_id}\t#{window_index}\t#{window_id}'"
             tmux-control--session)
     :pane-window)))

(defun tmux-control--update-windows (lines)
  "Parse a list-windows reply LINES into `tmux-control--windows'.
Records the active window as the current one and clears its activity marker,
then refreshes the header line.  With per-window buffers on, also claims the
active window for the controller buffer the first time its id is learned --
the controller renders its own window, so a switch back to it swaps here."
  (let (parsed active active-id)
    (dolist (line lines)
      (when (string-match "\\`\\([0-9]+\\)\t\\(.*\\)\t\\([01]\\)\t\\([01]\\)\\(?:\t\\(@[0-9]+\\)\\)?\\'" line)
        (let ((idx (match-string 1 line))
              (act (string= (match-string 3 line) "1"))
              (id (match-string 5 line)))
          (push (list :index idx
                      :name (match-string 2 line)
                      :active act
                      :bell (string= (match-string 4 line) "1")
                      :id id)
                parsed)
          (when act (setq active idx active-id id)))))
    ;; Reply line order is not guaranteed (the filter collects command output
    ;; in reverse); sort by numeric index so tabs read left-to-right 0,1,2,...
    (setq tmux-control--windows
          (sort parsed
                (lambda (a b)
                  (< (string-to-number (plist-get a :index))
                     (string-to-number (plist-get b :index))))))
    (when active
      (setq tmux-control--current-window active)
      (when (hash-table-p tmux-control--activity)
        (remhash active tmux-control--activity)))
    ;; The controller doubles as the render buffer for the window it was
    ;; connected on; bind it to that window's id once known.  ONLY that
    ;; once: a controller whose own window later closed has a nil id too,
    ;; and re-binding it here -- this runs on every window-list refresh --
    ;; silently re-homed it onto the session's current window, ORPHANING
    ;; that window's render buffer from the registry: output then routed
    ;; to the hidden controller while the user watched the orphan freeze
    ;; (chaos-soak find; `tmux-control--homeless' marks the difference).
    (when (and tmux-control-window-buffers
               active-id
               (null tmux-control--controller)   ; we are the controller
               (null tmux-control--window-id)
               (not tmux-control--homeless))
      (setq tmux-control--window-id active-id)
      (tmux-control--register-window-buffer active-id (current-buffer)))
    (force-mode-line-update)))

(defun tmux-control--update-pane-window-map (lines)
  "Parse a list-panes reply LINES into `tmux-control--pane-window'.
Each value is a cons (WINDOW-INDEX . WINDOW-ID); the id may be nil on a
reply from before the format carried it."
  (let ((map (make-hash-table :test 'equal)))
    (dolist (line lines)
      (when (string-match "\\`\\(%[0-9]+\\)\t\\([0-9]+\\)\\(?:\t\\(@[0-9]+\\)\\)?\\'" line)
        (puthash (match-string 1 line)
                 (cons (match-string 2 line) (match-string 3 line))
                 map)))
    (setq tmux-control--pane-window map)))

(defun tmux-control--quiet-activity (&optional secs)
  "Suppress background-activity flagging for SECS seconds (default 0.8).
Called around client-driven full repaints -- connect, window switch, resize --
so the resulting prompt/redraw burst in every pane does not flag every window
as if its agent had done something.  The burst can trail the triggering event
by a few hundred ms (the refresh-client round-trip plus a prompt redraw), so
the window is deliberately generous."
  (setq tmux-control--activity-quiet-until (+ (float-time) (or secs 0.8))))

(defun tmux-control--note-pane-activity (pane)
  "Flag PANE's window as having unseen output when it is not the current one.
A no-op when the tab bar is disabled (its only consumer), so the hot %output
path costs nothing then, and during the quiet period after a full repaint
\(see `tmux-control--quiet-activity')."
  (when (and tmux-control-window-tab-bar
             (not tmux-control--tiled)
             tmux-control--current-window
             (> (float-time) tmux-control--activity-quiet-until)
             (hash-table-p tmux-control--pane-window))
    (let* ((entry (gethash pane tmux-control--pane-window))
           (win (car-safe entry))
           (win-id (cdr-safe entry)))
      (when (and win
                 (not (equal win tmux-control--current-window))
                 ;; A background window whose render buffer is on screen
                 ;; (another Emacs window or frame) is being watched, not
                 ;; waiting -- don't flag it.
                 (not (and win-id
                           (when-let* ((buf (tmux-control--window-buffer
                                             win-id)))
                             (get-buffer-window buf t)))))
        (unless (hash-table-p tmux-control--activity)
          (setq tmux-control--activity (make-hash-table :test 'equal)))
        (unless (gethash win tmux-control--activity)
          (puthash win t tmux-control--activity)
          (force-mode-line-update))))))

(defun tmux-control--note-session-activity ()
  "Flag the current session as having unseen output when it is off screen.
The session-level analog of `tmux-control--note-pane-activity': a cheap no-op
when the feature is off, during the post-repaint quiet period, when the flag
is already set, or when the session is visible (you can already see it).
Refreshes every header line so the session you *are* looking at shows the
flagged one in its strip."
  (when (and tmux-control-session-activity
             (not tmux-control--session-activity)
             (> (float-time) tmux-control--activity-quiet-until)
             ;; "Visible" means whichever buffer represents the session on
             ;; screen -- the current window's render buffer when per-window
             ;; buffers are on, not necessarily this controller.
             (not (get-buffer-window (tmux-control--session-display-buffer)
                                     'visible)))
    (setq tmux-control--session-activity t)
    (force-mode-line-update t)))

(defun tmux-control--session-strip-tab (buffer)
  "Return a clickable header-line tab for the flagged session in BUFFER."
  (let* ((name (buffer-local-value 'tmux-control--session buffer))
         (tab (propertize (format " ●%s" name)
                          'face 'tmux-control-tab-activity
                          'mouse-face 'highlight
                          'help-echo (format "Switch to session %s (unseen output)"
                                             name)))
         (map (make-sparse-keymap)))
    (define-key map [header-line mouse-1]
      (lambda (_event)
        (interactive "e")
        (let ((display-buffer-overriding-action '((display-buffer-same-window))))
          (pop-to-buffer (tmux-control--session-display-buffer buffer)))))
    (put-text-property 0 (length tab) 'keymap map tab)
    tab))

(defun tmux-control--flagged-other-session-buffers ()
  "Live session buffers other than the current one that have unseen output.
Tests the activity flag first so most buffers are rejected by one cheap
check, and sorts only the (usually few) flagged buffers -- not the whole
buffer list -- so it is cheap to call from the header-line :eval on every
redisplay."
  (let ((self-ctrl (tmux-control--wb-controller))
        flagged)
    (dolist (b (buffer-list))
      (when (and (not (eq b self-ctrl))
                 (buffer-local-value 'tmux-control--session-activity b)
                 (buffer-local-value 'tmux-control--session b)
                 (not (buffer-local-value 'tmux-control--controller b))
                 (not (buffer-local-value 'tmux-control--tiled b))
                 (process-live-p (buffer-local-value 'tmux-control--process b)))
        (push b flagged)))
    (sort flagged (lambda (a b) (string< (buffer-name a) (buffer-name b))))))

(defun tmux-control--session-strip ()
  "Header-line segment naming other connected sessions with unseen output.
Empty when none (so an idle setup shows no extra chrome) and in the tiled
view.  Rendered in the visible session's header line; clears this session's
own flag (held on its controller) as a side effect, since you are looking
at it."
  (if (or (not tmux-control-session-activity) tmux-control--tiled)
      ""
    (let ((ctrl (tmux-control--wb-controller)))
      (when (and (buffer-live-p ctrl)
                 (buffer-local-value 'tmux-control--session-activity ctrl))
        (with-current-buffer ctrl
          (setq tmux-control--session-activity nil))))
    (mapconcat #'tmux-control--session-strip-tab
               (tmux-control--flagged-other-session-buffers) "")))

(defun tmux-control--tab-keymap (index)
  "Return a header-line keymap that switches to window INDEX on a click."
  (let ((map (make-sparse-keymap)))
    (define-key map [header-line mouse-1]
      (lambda (_event)
        (interactive "e")
        (tmux-control--do-select-window index)))
    map))

(defun tmux-control--window-tab-bar (&optional no-keymap)
  "Return the header-line string of the session's windows as tabs.
Empty in a tiled view (each pane already carries its own mode-line label) and
before the first window list arrives.  With NO-KEYMAP the tabs are not
clickable -- used for the read-only scrollback header, which renders the live
buffer's tabs purely for orientation.  In a per-window render buffer the
window list and activity state live on the controller; render from there."
  (if (and tmux-control--controller
           (buffer-live-p tmux-control--controller)
           (null tmux-control--windows))
      (with-current-buffer tmux-control--controller
        (tmux-control--window-tab-bar no-keymap))
    (if (or tmux-control--tiled (null tmux-control--windows))
        ""
    (mapconcat
     (lambda (w)
       (let* ((idx (plist-get w :index))
              (name (plist-get w :name))
              (active (plist-get w :active))
              (busy (and (not active)
                         (hash-table-p tmux-control--activity)
                         (gethash idx tmux-control--activity)))
              (mark (cond ((plist-get w :bell) " !")
                          (busy " ●")
                          (t "")))
              (face (cond (active 'tmux-control-tab-active)
                          (busy 'tmux-control-tab-activity)
                          (t 'tmux-control-tab-inactive)))
              (tab (propertize (format " %s:%s%s " idx name mark)
                               'face face
                               'mouse-face 'highlight
                               'help-echo (format "Switch to tmux window %s (%s)"
                                                  idx name))))
         (unless no-keymap
           (put-text-property 0 (length tab) 'keymap
                              (tmux-control--tab-keymap idx) tab))
         tab))
     tmux-control--windows
     ""))))

(defun tmux-control--header-line ()
  "Compose the live buffer's header line.
The cross-session activity strip (other sessions wanting attention) sits to
the left of the window tab bar, with a separator only between the two when
both are non-empty; each self-gates on its option, so the row is empty when
neither has anything to show."
  (let ((strip (tmux-control--session-strip))
        (tabs (if tmux-control-window-tab-bar (tmux-control--window-tab-bar) "")))
    (if (and (> (length strip) 0) (> (length tabs) 0))
        (concat strip (propertize " │" 'face 'tmux-control-tab-inactive) tabs)
      (concat strip tabs))))

(defun tmux-control--scrollback-header ()
  "Header line for the scrollback view.
Keeps the session's window tabs visible (read from the live buffer, for
orientation) and appends a scroll-mode hint, so entering scrollback does not
look like the tabs vanished.  Falls back to a plain info line when the tab bar
is disabled or no live buffer is available."
  (let* ((live tmux-control--live-buffer)
         ;; Show the CURRENT mode, then what `c' switches to, so it never
         ;; reads as if verbatim were active while compaction is on.
         (cmode (if tmux-control-compact-scrollback
                    "compacted·c:verbatim"
                  "verbatim·c:compact"))
         (tabs (and tmux-control-window-tab-bar
                    (buffer-live-p live)
                    (with-current-buffer live
                      (tmux-control--window-tab-bar t)))))
    (if (and tabs (> (length tabs) 0))
        (concat tabs (propertize (format "  ⇡ scrollback  g:refresh  %s  q/RET:live "
                                         cmode)
                                 'face 'tmux-control-tab-inactive))
      (format " %s socket:%s session:%s target:%s    g:refresh  %s  q/l/RET:live"
              (or tmux-control--host "local")
              tmux-control--socket-name
              tmux-control--session
              tmux-control--scrollback-target
              cmode))))

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
  "Read a pane id with completion over ALL of the session's panes.
Each candidate is labelled with its window and index, so an agent
fleet's panes are distinguishable across windows."
  (let* ((panes (tmux-control--list-panes tmux-control--host
                                          tmux-control--socket-name
                                          tmux-control--session))
         (choices (mapcar (lambda (p) (cons (cdr p) (car p))) panes)))
    (unless choices
      (user-error "No panes to choose from"))
    (or (cdr (assoc (completing-read "Pane: " choices nil t) choices))
        (user-error "No such pane"))))

(defun tmux-control-select-pane (&optional pane)
  "Switch the live view to another pane, by name.
Interactively, complete over the SESSION's panes -- an agent team shows
each teammate as a pane, labelled by its command and title -- and focus
the chosen one.  With PANE (a pane id) given non-interactively, switch
to it directly.

A pane in another window is a real jump: tmux's `select-pane' alone
sets that window's active pane WITHOUT switching the session's current
window -- and when the session is already current there, it produces no
notification a display swap could follow -- so the session is switched
to the pane's window first (the tab bar, other clients, and the
per-window view all follow), then the pane is focused within it.  The
jump triggers when the pane's window differs from the window of the
buffer the command ran in OR from the session's current window: the two
disagree after a render buffer is displayed by hand, and either
mismatch makes the bare command invisible.  A pane of the window that
is both on screen and current just becomes the active pane, and the
view repaints on it.

The window hop relies on the pane->window map, which is fetched
asynchronously at connect; in the brief moment before it arrives (or
with both `tmux-control-window-tab-bar' and
`tmux-control-window-buffers' disabled, which leave it unfetched) an
unmapped pane falls back to the bare `select-pane'."
  (interactive (list nil))
  (tmux-control--ensure-live)
  (let* ((pane (or pane (tmux-control--read-pane)))
         (viewed tmux-control--window-id)
         (ctrl (tmux-control--wb-controller))
         (entry (with-current-buffer ctrl
                  (and (hash-table-p tmux-control--pane-window)
                       (gethash pane tmux-control--pane-window))))
         (idx (car-safe entry))
         (wid (cdr-safe entry))
         (current (buffer-local-value 'tmux-control--current-window ctrl)))
    (when (and idx
               (or (and current (not (equal idx current)))
                   (and wid viewed (not (equal wid viewed)))))
      (tmux-control--do-select-window idx))
    (tmux-control--send-command (format "select-pane -t %s" pane))))

(defun tmux-control--remote-file-method (host)
  "Return the TRAMP method to reach HOST, honoring the user's TRAMP config.
Resolves the method TRAMP would itself use for HOST -- a per-host default
from `tramp-default-method-alist', otherwise `tramp-default-method' -- so a
remote pane's files open through the method the user configured (for example
\"rpc\" for tramp-rpc, or \"sshx\") rather than a hardcoded \"ssh\".  Falls
back to `tramp-default-method', then \"ssh\", if TRAMP is unavailable."
  ;; `tramp-find-method' returns a string carrying a `tramp-default' text
  ;; property; strip it so the constructed `default-directory' is a clean
  ;; string.
  (substring-no-properties
   (or (and (require 'tramp nil t)
            (fboundp 'tramp-find-method)
            ;; `tramp-find-method' wants a bare host; drop any user@ part.
            (ignore-errors
              (tramp-find-method
               nil nil
               (if (string-match "@\\([^@]*\\)\\'" host)
                   (match-string 1 host)
                 host))))
       (bound-and-true-p tramp-default-method)
       "ssh")))

(defun tmux-control--pane-directory ()
  "Return the live pane's working directory as a `default-directory' string.
Queries tmux for the active pane's `#{pane_current_path}'.  For a remote
session the path is wrapped as a TRAMP `/METHOD:HOST:...' directory -- METHOD
being whatever the user configured for that host (see
`tmux-control--remote-file-method'), so it rides the user's own TRAMP method
\(tramp-rpc, sshx, ...) -- so file commands open on the host the pane runs on;
for a local session it is the plain directory.  Returns nil when there is no
pane or the path cannot be read, so callers fall back to the buffer's own
directory."
  (when (and (derived-mode-p 'tmux-control-mode)
             (or tmux-control--active-pane tmux-control--fallback-target))
    (let* ((pane (or tmux-control--active-pane tmux-control--fallback-target))
           (path (ignore-errors
                   (string-trim
                    (tmux-control--run-tmux
                     (list "display-message" "-p" "-t" pane
                           "#{pane_current_path}"))))))
      (when (and path (not (string-empty-p path)))
        (let ((dir (file-name-as-directory path)))
          (if (and tmux-control--host (not (string-empty-p tmux-control--host)))
              (concat "/" (tmux-control--remote-file-method tmux-control--host)
                      ":" tmux-control--host ":" dir)
            dir))))))

(defun tmux-control--call-in-pane-directory (command arg)
  "Call interactive COMMAND with `default-directory' at the pane's directory.
With ARG non-nil (a prefix argument), or when
`tmux-control-pane-aware-find-file' is nil, call COMMAND with this buffer's
own (local) directory instead -- like the plain command."
  (let ((default-directory
         (or (and (not arg)
                  tmux-control-pane-aware-find-file
                  (tmux-control--pane-directory))
             default-directory)))
    (call-interactively command)))

(defun tmux-control-find-file (&optional arg)
  "Find a file starting at the live pane's directory, on the pane's host.
A tmux-control buffer renders a pane that has its own current directory --
often a project or a remote host's working tree -- so opening a file roots
the prompt there (`/ssh:HOST:PANE-CWD/' for a remote session) and you type
just the filename instead of a full TRAMP path.  With a prefix ARG, start at
this buffer's own (local) directory instead.  Bound to the `find-file' key
\(\\[find-file]) in tmux-control buffers; honors
`tmux-control-pane-aware-find-file'."
  (interactive "P")
  (tmux-control--call-in-pane-directory #'find-file arg))

(defun tmux-control-find-file-other-window (&optional arg)
  "Like `tmux-control-find-file', but show the file in another window.
Keeps the live pane visible beside the file.  With a prefix ARG, start at
this buffer's own (local) directory.  Bound to \\[find-file-other-window]."
  (interactive "P")
  (tmux-control--call-in-pane-directory #'find-file-other-window arg))

(defun tmux-control-dired (&optional arg)
  "Open Dired on the live pane's directory, on the pane's host.
With a prefix ARG, use this buffer's own (local) directory.  Bound to
\\[dired]."
  (interactive "P")
  (tmux-control--call-in-pane-directory #'dired arg))

(defun tmux-control--scrollback-capture-command (target lines trailing
                                                        &optional end-back)
  "Build the in-band capture-pane command for the scrollback view.
TARGET, LINES and TRAILING mirror `tmux-control--capture-pane''s flags.
LINES is the start depth (`-S -LINES', that many lines back).  END-BACK,
when non-nil, caps the end at that many lines back (`-E -END-BACK'), so a
delta strictly older than the already-loaded history can be captured for
lazy extension; without it the capture runs to the bottom as before."
  (concat "capture-pane -p -e"
          (when tmux-control-scrollback-join-wrapped-lines " -J")
          (when trailing " -N")
          (format " -S -%d" lines)
          (when end-back (format " -E -%d" end-back))
          (when target (format " -t %s" target))))

(defun tmux-control--scrollback-populate (buffer text &optional line column)
  "Fill scrollback BUFFER with prepared TEXT and restore the view.
With LINE and COLUMN, return point there (a refresh away from the
bottom); otherwise follow the bottom.  Runs from a query callback or
synchronously; BUFFER may have been killed in between."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (at-end (null line)))
        (when-let* ((window (get-buffer-window buffer t)))
          (set-window-margins window 0 0))
        (erase-buffer)
        (insert (tmux-control--prepare-scrollback-text text))
        (unless (bolp)
          (insert "\n"))
        (cond
         (at-end
          (goto-char (point-max))
          (when-let* ((window (get-buffer-window buffer t)))
            (with-selected-window window
              (goto-char (point-max))
              (recenter -1))))
         (t
          (goto-char (point-min))
          (forward-line (1- line))
          (move-to-column (or column 0))
          (when-let* ((window (get-buffer-window buffer t)))
            (set-window-point window (point)))))
        ;; The full content has landed: arm lazy extension.  It was held off
        ;; (extending = t) from the moment the pager opened so the one-line
        ;; "capturing…" placeholder -- which makes the top trivially visible --
        ;; could not trip the scroll watcher into a spurious extend before the
        ;; initial chunk even arrived.  Clear it LAST, after the point/window
        ;; moves above whose redisplay would otherwise fire the watcher.
        (setq tmux-control--scrollback-extending nil)))))

(defun tmux-control--scrollback-scroll-watch (window start)
  "Extend scrollback when WINDOW has scrolled near the top (START).
Installed buffer-locally on `window-scroll-functions'.  When the view
comes within a screenful of the top of the loaded history, load more --
deferred to a timer so nothing captures or modifies the buffer from
inside redisplay."
  (let ((buffer (window-buffer window)))
    (when (and (buffer-live-p buffer)
               (with-current-buffer buffer
                 (and (derived-mode-p 'tmux-control-scrollback-mode)
                      (not tmux-control--scrollback-extending)
                      (not tmux-control--scrollback-at-top)
                      (< tmux-control--scrollback-depth
                         tmux-control-scrollback-lines)
                      ;; Within one window-height of the top.  Test it with a
                      ;; bounded `forward-line' from the top (at most a
                      ;; window-height of line moves) rather than
                      ;; `count-lines' to START, which is O(buffer-size) and
                      ;; would run on every scroll event of a long history.
                      (<= (min start (point-max))
                          (save-excursion
                            (goto-char (point-min))
                            (forward-line (max 20 (window-body-height window)))
                            (point))))))
      ;; Guard against a burst of scroll events scheduling many extends.
      (with-current-buffer buffer
        (setq tmux-control--scrollback-extending t))
      (run-at-time 0 nil #'tmux-control--scrollback-extend buffer))))

(defun tmux-control--scrollback-extend (buffer)
  "Capture the next older chunk of history and prepend it to BUFFER.
Loads `tmux-control-scrollback-extend-lines' more lines (capped at
`tmux-control-scrollback-lines') strictly above what is already shown,
keeping the viewport fixed.  Over the live control connection, async;
a dead connection just stops extending (the snapshot stays put)."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let* ((old-depth tmux-control--scrollback-depth)
             (new-depth (min tmux-control-scrollback-lines
                             (+ old-depth tmux-control-scrollback-extend-lines)))
             (target tmux-control--scrollback-target)
             (trailing tmux-control--capture-trailing-p)
             (live tmux-control--live-buffer)
             (proc (and (buffer-live-p live)
                        (buffer-local-value 'tmux-control--process live))))
        (if (or tmux-control--scrollback-at-top
                (<= new-depth old-depth)
                (not (process-live-p proc)))
            ;; Nothing more to load (already at the oldest line, at the cap,
            ;; or disconnected): clear the latch and stop.  Guarding on
            ;; `at-top' here as well as in the scroll watcher keeps a direct
            ;; call from re-capturing tmux's clamped oldest line and
            ;; prepending it as a duplicate.
            (setq tmux-control--scrollback-extending nil)
          ;; Own the in-flight latch: callers (the scroll watcher) set it too,
          ;; to coalesce a burst before the deferred extend runs, but setting
          ;; it here as well keeps a direct call self-contained -- every exit
          ;; path below clears it.
          (setq tmux-control--scrollback-extending t)
          (with-current-buffer live
            (tmux-control--query
             ;; Strictly older than the current top line (OLD-DEPTH back):
             ;; from NEW-DEPTH back down to OLD-DEPTH+1 back.  This delta is
             ;; pure history (its end is above the visible screen), so the
             ;; reply's line count is exactly how many older lines exist.
             (tmux-control--scrollback-capture-command
              target new-depth trailing (1+ old-depth))
             (lambda (reply-lines)
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (let ((got (length reply-lines)))
                     (when reply-lines
                       ;; Advance depth by the lines ACTUALLY received, not
                       ;; the lines requested: tmux clamps the capture to the
                       ;; oldest available line, so a short reply means the
                       ;; loaded top really sits OLD-DEPTH+GOT back, and the
                       ;; next extend must continue from there to stay
                       ;; seam-accurate.
                       (tmux-control--scrollback-prepend
                        (string-join reply-lines "\n") (+ old-depth got)))
                     ;; Fewer lines than asked for: that was the top of the
                     ;; available history -- stop extending until reopen or
                     ;; refresh, instead of re-querying an empty range on
                     ;; every further scroll.
                     (when (< got (- new-depth old-depth))
                       (setq tmux-control--scrollback-at-top t)))
                   (setq tmux-control--scrollback-extending nil)))))))))))

(defun tmux-control--scrollback-prepend (text new-depth)
  "Prepend colorized older history TEXT to the current scrollback buffer.
Keeps the viewport on the same content -- the window start sits on a
marker that the insertion at point-min shifts forward with the text --
and records the loaded depth as NEW-DEPTH."
  (let* ((window (get-buffer-window (current-buffer) t))
         ;; Insertion-type t so the anchor tracks the content line it sits on
         ;; even when the view is at the very top (window-start = point-min):
         ;; a nil-type marker would stay at the old point-min and the view
         ;; would jump to the freshly loaded older lines instead of staying
         ;; pinned where you were reading.
         (anchor (and window (copy-marker (window-start window) t)))
         (inhibit-read-only t))
    (save-excursion
      (goto-char (point-min))
      (let ((prepared (tmux-control--prepare-scrollback-text text)))
        (insert prepared)
        (unless (or (string-suffix-p "\n" prepared)
                    (bolp))
          (insert "\n"))))
    (when (and window (marker-position anchor))
      (set-window-start window anchor t))
    (setq tmux-control--scrollback-depth new-depth)))

(defun tmux-control--scrollback-request (buffer target lines trailing
                                                &optional restore-line
                                                restore-column)
  "Capture pane history for scrollback BUFFER and populate it.
Prefers an IN-BAND capture-pane query over the live control connection
-- no extra tmux or ssh process, and Emacs never blocks on the round
trip (which spans the network for a remote session).  Falls back to the
out-of-band CLI capture when the connection is gone, so the pager still
works for a post-mortem look.  TARGET, LINES, TRAILING as in
`tmux-control--capture-pane'; RESTORE-LINE/RESTORE-COLUMN as in
`tmux-control--scrollback-populate'."
  (let* ((live tmux-control--live-buffer)
         (proc (and (buffer-live-p live)
                    (buffer-local-value 'tmux-control--process live))))
    (if (process-live-p proc)
        (with-current-buffer live
          (tmux-control--query
           (tmux-control--scrollback-capture-command target lines trailing)
           (lambda (reply-lines)
             (if reply-lines
                 (tmux-control--scrollback-populate
                  buffer (string-join reply-lines "\n")
                  restore-line restore-column)
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (let ((inhibit-read-only t))
                     (erase-buffer)
                     (insert "[tmux-control] capture failed\n"))))))))
      (tmux-control--scrollback-populate
       buffer
       (tmux-control--capture-pane tmux-control--host
                                   tmux-control--socket-name
                                   target lines trailing)
       restore-line restore-column))))

(defun tmux-control-scrollback ()
  "Show tmux pane history in a separate scrollback buffer as normal Emacs text.

The capture rides the live control connection (asynchronously -- a
remote session's round trip never freezes Emacs); the buffer shows a
capturing notice until it lands.  Use `tmux-control-live' to return to
the live interactive pane."
  (interactive)
  (unless tmux-control--session
    (user-error "No tmux-control session in this buffer"))
  (let* ((host tmux-control--host)
         (socket-name tmux-control--socket-name)
         (session tmux-control--session)
         (target (or tmux-control--active-pane tmux-control--fallback-target))
         (trailing tmux-control--capture-trailing-p)
         (live-buffer (current-buffer))
         (scrollback-buffer-name (format "*%s-scrollback*" (buffer-name)))
         (scrollback-buffer (get-buffer-create scrollback-buffer-name)))
    ;; Size the pane to the window the pager is about to use BEFORE
    ;; capturing, so the capture is wrapped to the width it will be read
    ;; at.  Normally a no-op -- the live view keeps the pane sized to this
    ;; same window -- but the pane lags when the frame was resized while
    ;; the live view was not on screen (e.g. inside a previous pager), and
    ;; the capture would arrive at the stale width.  Same connection, in
    ;; order: tmux re-wraps before it serves the capture.
    (when (and (process-live-p tmux-control--process)
               (get-buffer-window live-buffer t))
      (tmux-control--resize-to-window))
    (with-current-buffer scrollback-buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "[tmux-control] capturing %d lines…\n"
                        (min tmux-control-scrollback-initial-lines
                             tmux-control-scrollback-lines)))
        (tmux-control-scrollback-mode)
        (tmux-control--disable-line-numbers)
        (setq-local tmux-control--host host)
        (setq-local tmux-control--socket-name socket-name)
        (setq-local tmux-control--session session)
        (setq-local tmux-control--scrollback-target target)
        (setq-local tmux-control--capture-trailing-p trailing)
        (setq-local tmux-control--live-buffer live-buffer)
        ;; Lazy load: this first capture is only the initial chunk; scrolling
        ;; toward the top extends it (see `tmux-control--scrollback-extend').
        (setq-local tmux-control--scrollback-depth
                    (min tmux-control-scrollback-initial-lines
                         tmux-control-scrollback-lines))
        ;; Hold extension OFF until the initial chunk lands (the populate
        ;; callback clears this) so the "capturing…" placeholder, which makes
        ;; the top trivially visible, cannot trip the watcher into loading a
        ;; second chunk before the first has even arrived.
        (setq-local tmux-control--scrollback-extending t)
        (setq-local tmux-control--scrollback-at-top nil)
        (add-hook 'window-scroll-functions
                  #'tmux-control--scrollback-scroll-watch nil t)
        ;; Fresh pager: not yet scrolled up into history, so a wheel-down
        ;; cannot leave to live yet (see `tmux-control-scrollback-wheel-down').
        (setq-local tmux-control--scrollback-left-bottom nil)
        ;; Keep the window tabs visible.  Hide the text cursor in this read-only
        ;; history pager: point pins at the bottom and, under pixel-scroll
        ;; (point does not move on wheel), the cursor scrolls off-screen and
        ;; looks like it vanished -- so show none at all, like a terminal's
        ;; scrollback.  The user's cursor preference for live and other buffers
        ;; is untouched.
        (setq-local cursor-type nil)
        (setq-local cursor-in-non-selected-windows nil)
        (setq-local header-line-format '(:eval (tmux-control--scrollback-header)))
        (goto-char (point-max))))
    (switch-to-buffer scrollback-buffer)
    (when-let* ((window (get-buffer-window scrollback-buffer)))
      (set-window-margins window 0 0))
    (with-current-buffer scrollback-buffer
      ;; Record the size this capture is for, so the resize follower
      ;; (`tmux-control--scrollback-follow-resize') re-captures only on a
      ;; real change.  The pane already matches: the live view sized it to
      ;; this same Emacs window.
      (when-let* ((window (get-buffer-window scrollback-buffer t)))
        (setq tmux-control--scrollback-size
              (tmux-control--scrollback-window-size window)))
      (tmux-control--scrollback-request
       scrollback-buffer target
       (min tmux-control-scrollback-initial-lines
            tmux-control-scrollback-lines)
       trailing))))

(defun tmux-control-scrollback-refresh ()
  "Refresh the current tmux-control scrollback view.
Re-captures however much history is currently loaded (the lazily-extended
`tmux-control--scrollback-depth'), not the full maximum, so a refresh
preserves the depth you have scrolled into instead of collapsing back to
the initial chunk or ballooning to the cap."
  (interactive)
  (unless (derived-mode-p 'tmux-control-scrollback-mode)
    (user-error "Not in tmux-control scrollback mode"))
  (let ((line (line-number-at-pos))
        (column (current-column))
        (at-end (eobp)))
    ;; A refresh may reveal more history again (e.g. the cap was raised), so
    ;; let extension resume.
    (setq tmux-control--scrollback-at-top nil)
    ;; Hold extension off while the reload is in flight; the populate callback
    ;; clears it once the content lands (as on first open).
    (setq tmux-control--scrollback-extending t)
    (tmux-control--scrollback-request
     (current-buffer)
     tmux-control--scrollback-target
     ;; Re-capture the current depth, but never above the cap -- guards a
     ;; configuration where the initial chunk is larger than the maximum.
     (min tmux-control-scrollback-lines
          (max tmux-control--scrollback-depth
               tmux-control-scrollback-initial-lines))
     tmux-control--capture-trailing-p
     (unless at-end line)
     (unless at-end column))))

(defun tmux-control--scrollback-window-size (window)
  "Return WINDOW's terminal dimensions as (WIDTH . HEIGHT).
The same measure the live view sizes tmux to, so scrollback and live
agree on the pane size for the Emacs window they share."
  (cons (max 1 (window-max-chars-per-line window))
        (max 1 (with-selected-window window
                 (floor (window-screen-lines))))))

(defun tmux-control--scrollback-follow-resize (frame)
  "Re-capture scrollback views on FRAME whose window changed size.
The raw rows scrollback shows fit exactly the width they were captured
for; when the window resizes they would stay at the old width (narrower
text in a widened window, soft-wrap overflow in a narrowed one).  tmux
re-wraps pane history whenever the pane resizes, so ask tmux for the
new size and capture again.  Debounced: a drag-resize fires many size
changes for one gesture.  Installed on `window-size-change-functions'."
  (dolist (window (window-list frame 'never))
    (let ((buffer (window-buffer window)))
      (when (buffer-local-value 'tmux-control--scrollback-target buffer)
        (with-current-buffer buffer
          (when (derived-mode-p 'tmux-control-scrollback-mode)
            (let ((size (tmux-control--scrollback-window-size window)))
              (cond
               ((null tmux-control--scrollback-size)
                (setq tmux-control--scrollback-size size))
               ((not (equal size tmux-control--scrollback-size))
                (setq tmux-control--scrollback-size size)
                (when (timerp tmux-control--scrollback-resize-timer)
                  (cancel-timer tmux-control--scrollback-resize-timer))
                (setq tmux-control--scrollback-resize-timer
                      (run-with-timer
                       0.3 nil
                       #'tmux-control--scrollback-resize-recapture
                       buffer)))))))))))

(defun tmux-control--scrollback-resize-recapture (buffer)
  "Resize tmux to scrollback BUFFER's window and capture again.
The resize and the capture ride the same control connection in order,
so the capture is guaranteed to see the re-wrapped history.  Resizing
through the live buffer also keeps its renderer (and the sibling
window buffers) in step, so returning to the live view needs no second
resize.  A dead connection skips both: the post-mortem pager stays a
static snapshot."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq tmux-control--scrollback-resize-timer nil)
      (when-let* ((window (get-buffer-window buffer t))
                  (live tmux-control--live-buffer))
        (when (and (buffer-live-p live)
                   (process-live-p
                    (buffer-local-value 'tmux-control--process live)))
          (let ((size (tmux-control--scrollback-window-size window)))
            (setq tmux-control--scrollback-size size)
            (with-current-buffer live
              (tmux-control--resize (car size) (cdr size))))
          (tmux-control-scrollback-refresh))))))

(add-hook 'window-size-change-functions
          #'tmux-control--scrollback-follow-resize)

(defun tmux-control-scrollback-toggle-compaction ()
  "Toggle redraw-compaction in this scrollback view and re-render.
Compaction collapses repeated full-screen redraws (common with TUIs under
`alternate-screen off'), but on dense, heavily-repainted output its
de-duplication can elide more than you want; this flips to the verbatim
capture -- every line as tmux has it -- and back, without leaving the
pager.  Buffer-local, so it does not change the global default."
  (interactive)
  (unless (derived-mode-p 'tmux-control-scrollback-mode)
    (user-error "Not in tmux-control scrollback mode"))
  (setq-local tmux-control-compact-scrollback
              (not tmux-control-compact-scrollback))
  (message "tmux-control scrollback: compaction %s"
           (if tmux-control-compact-scrollback "on" "verbatim (off)"))
  (tmux-control-scrollback-refresh))

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

(defun tmux-control--dispatch-wheel (event)
  "Scroll normally for wheel EVENT, honoring `pixel-scroll-precision-mode'.
The pager binds wheel-down locally, which would otherwise shadow the
user's configured wheel behavior; route the event back to it."
  (if (and (bound-and-true-p pixel-scroll-precision-mode)
           (fboundp 'pixel-scroll-precision))
      (pixel-scroll-precision event)
    (mwheel-scroll event)))

(defun tmux-control-scrollback-wheel-down (event)
  "Scroll the pager down; from the bottom, return to the live view.
This is tmux's own copy-mode rule: scrolling back down to the bottom of
history leaves scrollback and you are live again -- no key to remember,
the gesture that took you in takes you back out.

But you ENTER the pager by scrolling up, so it opens at the bottom; the
leave-to-live step only fires once you have actually scrolled up into
history and are scrolling back down (`tmux-control--scrollback-left-bottom').
Otherwise a wheel-down right after entering -- the momentum tail of the
up-flick, a stray tick, or one arriving while the capture is still
pending and the one-line \"capturing…\" placeholder makes the bottom
trivially visible -- would bounce you straight back out, repeatedly
\(field report: an apparent loop).

Above the bottom, the wheel scrolls as it always did (EVENT is
re-dispatched to the user's configured scrolling, pixel-precision
included)."
  (interactive "e")
  (let ((window (posn-window (event-start event))))
    (if (window-live-p window)
        (with-selected-window window
          (with-current-buffer (window-buffer window)
            ;; "At the bottom" must count a PARTIALLY visible last line:
            ;; pixel-precision scrolling routinely parks the window with the
            ;; final line a few pixels clipped, and `pos-visible-in-window-p'
            ;; answers nil there forever.
            (if (and (derived-mode-p 'tmux-control-scrollback-mode)
                     (>= (window-end window t) (point-max)))
                (if tmux-control--scrollback-left-bottom
                    (tmux-control-live)
                  ;; At the bottom but never left it: do not leave; let the
                  ;; wheel scroll (a no-op on a buffer this short).
                  (tmux-control--dispatch-wheel event))
              ;; Above the bottom -- viewing history.  Remember it, so a
              ;; later wheel-down that reaches the bottom leaves.
              (when (derived-mode-p 'tmux-control-scrollback-mode)
                (setq tmux-control--scrollback-left-bottom t))
              (tmux-control--dispatch-wheel event))))
      (tmux-control--dispatch-wheel event))))

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

(defun tmux-control--tiled-mode-p ()
  "Return non-nil when the current buffer is part of a tiled multi-pane view.
True for the tiled controller and for each of its pane buffers.  The
continuous live-history wheel behavior is scoped OUT of tiled mode: a tiled
pane is anchored to the top of its own screen by the tiling layer
\(`tmux-control--anchor-windows-to-screen-top'), which the in-place scroll and
the cursor-visibility follow set would fight, so tiled panes keep the plain
pager-on-wheel-up behavior regardless of
`tmux-control-wheel-scrolls-live-history'."
  (or tmux-control--tiled
      (and tmux-control--controller
           (buffer-live-p tmux-control--controller)
           (buffer-local-value 'tmux-control--tiled tmux-control--controller))))

(defun tmux-control-wheel-scroll (event)
  "Handle a mouse wheel EVENT in a live tmux-control buffer.

When scrolling up over a pane that shows its normal screen and whose
application has not requested mouse tracking, enter the Emacs scrollback
buffer (when `tmux-control-wheel-enters-scrollback').  This is the
Emacs-side analog of tmux's default wheel-up binding, which opens
copy-mode scrollback for normal-screen panes.

With `tmux-control-wheel-scrolls-live-history', wheel-up scrolls the live
buffer's own retained history (the output Eat has kept since you connected)
in place, stopping at the top -- it never flings back to the live tail.  It
opens the pager only when that whole retained history already fits on screen
(a fresh or quiet pane, where you are still at the live screen, so the pager
opens at the same tail); the deeper pre-session history is otherwise an
explicit `tmux-control-scrollback' (\\[tmux-control-scrollback]) away.  With
the option off, wheel-up opens the pager immediately.

In every other case -- a genuine full-screen (alternate-screen)
application or a mouse-aware application -- the event is forwarded to the
terminal unchanged so the application keeps its own handling.  Wheel-down
is handled by `tmux-control-wheel-down'.

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
            (if (and tmux-control-wheel-scrolls-live-history
                     (not (tmux-control--tiled-mode-p))
                     (not (tmux-control--live-history-exhausted-p window)))
                ;; There is retained history to scroll into (or you have
                ;; already scrolled up into it): scroll the live view in
                ;; place.  Do NOT fling to the pager here -- being scrolled up
                ;; and wheeling further must not jump you back to the live
                ;; tail; it simply stops at the top.
                (tmux-control--scroll-live-history event window)
              ;; The whole retained history is already on screen (a fresh or
              ;; quiet pane, so you are still at the live screen) -- or the
              ;; feature is off.  Open the pager for the full history; from
              ;; the live screen this is seamless (it opens at the same tail).
              (select-window window)
              (tmux-control-scrollback)))
           (t
            (with-selected-window window
              (eat-self-input 1 event)))))
      (eat-self-input 1 event))))

(defun tmux-control--live-history-exhausted-p (window)
  "Return non-nil when WINDOW already shows all of the live view's history.
True when both the top of the buffer and the live cursor are visible -- the
whole of what Eat still holds fits on screen, so wheel-up cannot scroll it
any further and the deeper pre-session history (which lives in tmux, not
Eat) needs the `tmux-control-scrollback' pager.  False once there is
retained history above the view to scroll into, or once you have scrolled up
off the live screen -- in which case wheel-up keeps scrolling in place.

The PARTIALLY arg to `pos-visible-in-window-p' is essential under
`pixel-scroll-precision-mode', which routinely parks a line a few pixels
clipped: without it a barely-clipped top or cursor line reads as not visible
and the routing misfires."
  (and (pos-visible-in-window-p (point-min) window t)
       (or (not (and tmux-control--terminal
                     (eat-term-live-p tmux-control--terminal)))
           (pos-visible-in-window-p
            (eat-term-display-cursor tmux-control--terminal) window t))))

(defun tmux-control--scroll-live-history (event window)
  "Scroll WINDOW up through the live view's retained history for EVENT.
Defers to the user's ordinary wheel scrolling (`tmux-control--dispatch-wheel'
honors `pixel-scroll-precision-mode'), so momentum and feel match every
other buffer.  At the very top it simply stops -- the deeper pre-session
history is an explicit `tmux-control-scrollback' (\\[tmux-control-scrollback])
away, so wheeling past the top never flings the view back to the live tail."
  (with-selected-window window
    (condition-case nil
        (tmux-control--dispatch-wheel event)
      ((beginning-of-buffer end-of-buffer args-out-of-range) nil))))

(defun tmux-control-wheel-down (event)
  "Handle a wheel-down EVENT in a live tmux-control buffer.
A full-screen (alternate-screen) or mouse-tracking application owns the
wheel, so forward the event to it -- the symmetric partner of
`tmux-control-wheel-scroll', which forwards wheel-up to such an app.
Without this, wheel-UP reached a mouse application (e.g. a TUI scrolled
with the mouse) but wheel-DOWN did not: nothing bound it, so it fell
through to the user's ordinary scrolling, and under
`pixel-scroll-precision-mode' that visibly scrolled the Emacs buffer
instead of the application.  On a normal-screen pane the wheel keeps the
user's ordinary downward scrolling."
  (interactive "e")
  (let ((window (posn-window (event-start event))))
    (if (and (window-live-p window)
             (with-current-buffer (window-buffer window)
               (and (derived-mode-p 'tmux-control-mode)
                    (or (tmux-control--alt-screen-p)
                        (tmux-control--pane-grabs-mouse-p)))))
        (with-selected-window window
          (eat-self-input 1 event))
      (tmux-control--dispatch-wheel event))))

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
  "Make `eat-semi-char-mode' return tmux-control scrollback buffers live.
In a live tmux-control buffer, also restore the full override keymap
that char mode swapped out (see `tmux-control--char-mode-keys')."
  (if (derived-mode-p 'tmux-control-scrollback-mode)
      (progn
        (tmux-control-live)
        (unless (bound-and-true-p eat--semi-char-mode)
          (eat-semi-char-mode)))
    (apply orig-fn args)
    (when (derived-mode-p 'tmux-control-mode)
      (setq tmux-control--char-mode-keys nil)
      (setq tmux-control--keys-active t))))

(advice-remove #'eat-semi-char-mode
               #'tmux-control--eat-semi-char-mode-advice)
(advice-add #'eat-semi-char-mode
            :around #'tmux-control--eat-semi-char-mode-advice)

(defun tmux-control--eat-char-mode-advice (orig-fn &rest args)
  "Adapt `eat-char-mode' to tmux-control buffers.
Eat's char mode exists to send EVERY key to the terminal -- C-c, C-x,
C-u, C-h and all -- leaving only `C-M-m' (M-RET) to come back to
semi-char mode.  That almost worked here out of the box, except the
tmux-control override keymap is an EMULATION map, which outranks char
mode's own keymap: C-c stayed a prefix, breaking precisely the key
char mode is most reached for (the interrupt).  Swap the override map
for the wheel-only `tmux-control--char-mode-map' while char mode is on;
`eat-semi-char-mode' restores it.  In a scrollback pager, char mode
means \"get me back to the live terminal, raw\": return live first,
then enter char mode there."
  (if (derived-mode-p 'tmux-control-scrollback-mode)
      (progn
        (tmux-control-live)
        (unless (bound-and-true-p eat--char-mode)
          (eat-char-mode)))
    (apply orig-fn args)
    (when (derived-mode-p 'tmux-control-mode)
      (setq tmux-control--keys-active nil)
      (setq tmux-control--char-mode-keys t))))

(advice-remove #'eat-char-mode
               #'tmux-control--eat-char-mode-advice)
(advice-add #'eat-char-mode
            :around #'tmux-control--eat-char-mode-advice)

(defun tmux-control-char-mode ()
  "Switch the live buffer to char mode: every key goes to the pane.
C-c interrupts, C-u kills the shell line, C-x and M-x reach the
application -- raw terminal feel, exactly like a standalone terminal
emulator.  `C-M-m' (M-RET) returns to semi-char mode, where C-c is the
tmux-control/Emacs prefix again.  This is Eat's own char mode, adapted
so the tmux-control keys get out of the way; the mode line shows
[char] / [semi-char]."
  (interactive)
  (eat-char-mode))

(defun tmux-control--reset-buffer ()
  "Reset the current buffer for a fresh tmux-control session."
  ;; A reconnect into a buffer that was tiled would `kill-all-local-variables'
  ;; (via `tmux-control-mode') and orphan its pane render buffers; tear the
  ;; tiling down first so they are killed and the state is clean.
  (when tmux-control--tiled
    (tmux-control--teardown-tiling (current-buffer) t))
  (let ((inhibit-read-only t))
    (when (process-live-p tmux-control--process)
      ;; Detach the sentinel before killing: it runs from the command loop
      ;; some time AFTER `delete-process', by which point a reconnect has
      ;; already installed the fresh process -- the stale sentinel would
      ;; then announce a lost connection and nil out the NEW process
      ;; variable.  This kill is deliberate; nothing to announce.
      (set-process-sentinel tmux-control--process #'ignore)
      (delete-process tmux-control--process))
    (remove-hook 'kill-buffer-hook #'tmux-control--kill-process t)
    (erase-buffer)
    (tmux-control-mode)
    (setq-local emulation-mode-map-alists
                (cons tmux-control--emulation-mode-map-alist
                      (delq tmux-control--emulation-mode-map-alist
                            emulation-mode-map-alists)))
    (setq tmux-control--keys-active t)
    (setq tmux-control--char-mode-keys nil)
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
    (when tmux-control--command-watchdog-timer
      (cancel-timer tmux-control--command-watchdog-timer))
    (setq tmux-control--command-watchdog-timer nil)
    (setq tmux-control--command-watchdog-warned nil)
    ;; A (re)connect starts the per-window buffer registry fresh; stale
    ;; sibling render buffers from the previous connection must go.
    (tmux-control--kill-render-buffers (current-buffer))
    (setq tmux-control--window-buffers nil)
    (setq tmux-control--window-id nil)
    (setq tmux-control--homeless nil)
    (setq tmux-control--session-display nil)
    (setq tmux-control--seed-cursor nil)
    (setq tmux-control--seed-cursor-visible :unknown)
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
    ;; Deliberate shutdown: keep the deferred sentinel from announcing it.
    (set-process-sentinel tmux-control--process #'ignore)
    (delete-process tmux-control--process))
  (setq tmux-control--process nil)
  (setq tmux-control--terminal nil)
  (setq eat-terminal nil)
  (setq tmux-control--keys-active nil)
  (setq tmux-control--char-mode-keys nil)
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

(defvar tmux-control--auto-frame-start nil
  "Auto-detected redraw frame-top marker (a trimmed line string), or nil.
Bound dynamically during compaction when no
`tmux-control-scrollback-frame-start-regexp' is configured, so
`tmux-control--scrollback-frame-start-line-p' can split frames generically.")

(defconst tmux-control--auto-frame-scan-lines 4000
  "Auto frame-top detection scans only the last this-many captured lines.
A repainting TUI's frames are recent and recur every frame-height, so a bounded
tail is enough to find the marker -- and it caps the cost of deciding \"no
repeating frame\" on a long (up to `tmux-control-scrollback-lines') history.")

(defvar tmux-control--scrollback-key-cache nil
  "Hash table memoizing scrollback match keys during one compaction pass.
Bound by `tmux-control--prepare-scrollback-text'; nil outside compaction,
in which case keys are computed without caching.  Defined before its
first `let'-binding so the byte-compiler knows the symbol is special and
keeps that binding dynamic.")

(defun tmux-control--scrollback-match-key (line)
  "Return a width-insensitive comparison key for scrollback LINE.
A repainting TUI re-emits the same logical line dressed for the current
pane width: a gutter glyph at the last column, status text right-aligned
to the edge, rules stretched to fill it.  Comparing raw text therefore
treats a frame repainted after a resize as all-new content, and
resize-driven repeats never collapse.  The key drops that dressing --
a trailing padded gutter glyph, repeated-character runs capped, padding
runs collapsed -- so equality follows content rather than geometry.
Keys are only ever compared; display always uses the original line."
  (or (and tmux-control--scrollback-key-cache
           (gethash line tmux-control--scrollback-key-cache))
      (let* ((key (string-trim-right line))
             ;; A lone box-drawing or block glyph after padding at the end
             ;; of the line is a right-edge gutter, not content.
             (key (replace-regexp-in-string "[ \t][─-▟]\\'" "" key))
             ;; Rules and dividers stretch with the pane width; cap any
             ;; repeated symbol run so length differences vanish.
             (key (replace-regexp-in-string
                   "\\([^[:alnum:][:blank:]]\\)\\1\\{3,\\}" "\\1\\1\\1\\1" key))
             ;; Alignment padding scales with width too.
             (key (replace-regexp-in-string "[ \t]\\{2,\\}" " " key))
             (key (string-trim key)))
        (when tmux-control--scrollback-key-cache
          (puthash line key tmux-control--scrollback-key-cache))
        key)))

(defun tmux-control--prepare-scrollback-text (text)
  "Prepare captured pane TEXT for the scrollback buffer.
Compaction runs when enabled and a frame marker is available -- either a
configured `tmux-control-scrollback-frame-start-regexp' or, failing that, one
auto-detected from repeated content (`tmux-control--auto-frame-start-line').
When no marker is found -- ordinary, non-repainting scrollback -- the text is
shown verbatim, colors and trailing backgrounds intact."
  (let* ((tmux-control--scrollback-key-cache (make-hash-table :test 'equal))
         (text (tmux-control--colorize-scrollback text))
         (auto (and tmux-control-compact-scrollback
                    (not tmux-control-scrollback-frame-start-regexp)
                    (tmux-control--auto-frame-start-line
                     (mapcar #'string-trim-right
                             (last (split-string text "\n")
                                   tmux-control--auto-frame-scan-lines))))))
    (tmux-control--trim-trailing-blank-lines
     (if (and tmux-control-compact-scrollback
              (or tmux-control-scrollback-frame-start-regexp auto))
         (let ((tmux-control--auto-frame-start auto))
           (tmux-control--compact-repeated-redraw-lines text))
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
  (tmux-control--scrollback-chunks-from-lines (split-string text "\n")))

(defun tmux-control--scrollback-chunks-from-lines (lines)
  "Split already-split LINES into likely TUI redraw chunks.
Lets a caller that already holds the line list -- auto-detection trying each
candidate marker in turn -- skip a join-then-resplit round trip over the
whole (up to several-thousand-line) scrollback each time."
  (let (chunks current)
    (dolist (line (mapcar #'string-trim-right lines))
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
Matches `tmux-control-scrollback-frame-start-regexp' when configured, else the
auto-detected `tmux-control--auto-frame-start' marker bound during compaction.
Nil when neither is available, so compaction does nothing without a frame
marker."
  (cond
   (tmux-control-scrollback-frame-start-regexp
    (string-match-p tmux-control-scrollback-frame-start-regexp line))
   (tmux-control--auto-frame-start
    (string= (tmux-control--scrollback-match-key line)
             tmux-control--auto-frame-start))))

(defconst tmux-control--auto-frame-min-occurrences 3
  "A line must recur at least this many times to anchor auto-detected frames.")

(defconst tmux-control--auto-frame-min-gap 4
  "Auto-detected frame-top occurrences must be at least this many lines apart,
so a run of identical filler lines is not taken for frame boundaries.")

(defun tmux-control--auto-frame-evenly-spread-p (indices)
  "Return non-nil when sorted INDICES are each at least the min frame gap apart."
  (let ((ok t) (prev nil))
    (dolist (i indices ok)
      (when (and prev (< (- i prev) tmux-control--auto-frame-min-gap))
        (setq ok nil))
      (setq prev i))))

(defun tmux-control--frames-share-redraw-body-p (lines marker)
  "Return non-nil when splitting LINES at MARKER yields adjacent frames that
share a distinctive redraw run -- evidence of a genuine repainting TUI rather
than a coincidentally repeated line.  Mirrors what the merge step actually
collapses: a shared run anywhere in the later frame, not only one starting at
its top.  That matters when the capture begins mid-frame, leaving the marker
just above a volatile line (a token counter, a clock) -- the shared body then
sits below that line, and an only-at-the-top check would miss it and veto an
otherwise perfect frame marker."
  (let* ((tmux-control--auto-frame-start marker)
         (tmux-control-scrollback-frame-start-regexp nil)
         ;; Chunk straight from LINES; auto-detection calls this once per
         ;; candidate marker, so joining to a string and re-splitting it each
         ;; time would be wasted O(n) work over the whole scrollback.
         (chunks (tmux-control--scrollback-chunks-from-lines lines))
         (shared nil))
    (while (and (cdr chunks) (not shared))
      (let ((a (tmux-control--trim-blank-line-list (car chunks)))
            (b (tmux-control--trim-blank-line-list (cadr chunks))))
        (when (and a b
                   (< (length (tmux-control--strip-seen-runs a b)) (length b)))
          (setq shared t)))
      (setq chunks (cdr chunks)))
    shared))

(defun tmux-control--auto-frame-start-line (lines)
  "Return the trimmed line that best marks repeated redraw frame tops in LINES.
Return nil when no convincing repeat is found, so compaction stays a no-op on
ordinary (non-repainting) scrollback.  A generic stand-in for a hand-written
`tmux-control-scrollback-frame-start-regexp': pick the distinctive line that
recurs like a screen top -- at least `tmux-control--auto-frame-min-occurrences'
times, spread out, the earliest among equally frequent lines -- then confirm
the frames it delimits actually share a redrawn body.  Lines are counted by
their width-insensitive `tmux-control--scrollback-match-key', so a TUI
repainted across pane resizes still accumulates occurrences of its recurring
lines, and the returned marker is that key."
  (let ((indices (make-hash-table :test 'equal))
        (i 0))
    (dolist (line lines)
      (let ((key (tmux-control--scrollback-match-key line)))
        (unless (string-empty-p key)
          (push i (gethash key indices))))
      (setq i (1+ i)))
    (let ((candidates nil))
      (maphash
       (lambda (key idxs)
         (let* ((idxs (nreverse idxs))
                (count (length idxs))
                (first (car idxs)))
           (when (and (>= count tmux-control--auto-frame-min-occurrences)
                      (>= (length key) 3)
                      (tmux-control--auto-frame-evenly-spread-p idxs))
             (push (list count first key) candidates))))
       indices)
      ;; Most frequent first, tie broken by earliest occurrence.  Accept the
      ;; first candidate whose delimited frames actually share a redrawn body,
      ;; rather than committing to the single most frequent line: when the
      ;; capture starts mid-frame both frame edges recur equally often, and the
      ;; tie-winner can be the edge sitting just above a volatile line whose
      ;; body is unrecognisable -- the real frame top is one place down the
      ;; list.  Also lets a mix of panels fall through to whichever genuinely
      ;; repaints.
      (setq candidates
            (sort candidates
                  (lambda (a b)
                    (if (= (nth 0 a) (nth 0 b))
                        (< (nth 1 a) (nth 1 b))
                      (> (nth 0 a) (nth 0 b))))))
      (cl-loop for cand in candidates
               for key = (nth 2 cand)
               when (tmux-control--frames-share-redraw-body-p lines key)
               return key))))

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
          ;; A clean suffix/prefix overlap: extend OUT with the new tail --
          ;; itself stripped of already-seen redraw runs, since a few lines
          ;; of coincidental overlap (chrome, a frame edge) can front a
          ;; remainder that still embeds a whole repeated frame body.
          (append out (tmux-control--strip-seen-runs out (nthcdr overlap chunk)))
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
  (tmux-control--redraw-run-distinctive-keys-p
   (mapcar #'tmux-control--scrollback-match-key lines)))

(defun tmux-control--redraw-run-distinctive-keys-p (keys)
  "`tmux-control--redraw-run-distinctive-p' over precomputed match KEYS.
Counts in one pass and stops as soon as both thresholds are met -- this
runs in the innermost compaction loop, so an O(n) early-exit count beats
building and de-duplicating intermediate lists."
  (let ((nonblank 0)
        (distinct 0)
        (seen (make-hash-table :test 'equal)))
    (catch 'enough
      (dolist (key keys)
        (unless (string-empty-p key)
          (setq nonblank (1+ nonblank))
          (unless (gethash key seen)
            (puthash key t seen)
            (setq distinct (1+ distinct)))
          (when (and (>= nonblank 4) (>= distinct 3))
            (throw 'enough t))))
      nil)))

(defun tmux-control--seen-run-length (hkeys ckeys start n)
  "Return the length of the longest already-seen redraw run of CKEYS at START.
HKEYS and CKEYS are precomputed match-key sequences for the haystack and
chunk (`tmux-control--scrollback-match-key'); the caller maps lines to keys
once, so the innermost search compares plain strings rather than re-deriving
keys per comparison.  Considers runs from START up to N, returning the
longest contiguous run that is distinctive
\(`tmux-control--redraw-run-distinctive-keys-p') and already present in
HKEYS, or nil when no qualifying run starts at START."
  (let ((len (min (- n start) tmux-control-compact-scrollback-window))
        (in-haystack nil))
    ;; Find the LONGEST run at START present in HKEYS.  Presence is
    ;; monotonic in LEN -- a longer run embeds its shorter prefix, so once a
    ;; length is absent every greater length is too -- hence the first hit
    ;; scanning down from the max is the longest, and we stop there.
    (while (and (>= len tmux-control--scrollback-min-redraw-run)
                (not in-haystack))
      (when (cl-search (cl-subseq ckeys start (+ start len)) hkeys
                       :test #'string=)
        (setq in-haystack len))
      (setq len (1- len)))
    ;; Distinctiveness is monotonic too (a longer run has at least as much
    ;; distinct content as its prefix), so if the longest seen run is not
    ;; distinctive no shorter one is either -- the old scan that tested both
    ;; conditions at every length would reach the same nil.  Testing it once
    ;; on the winner, rather than at every candidate length, is the speedup.
    (when (and in-haystack
               (tmux-control--redraw-run-distinctive-keys-p
                (cl-subseq ckeys start (+ start in-haystack))))
      in-haystack)))

(defun tmux-control--strip-seen-runs (out chunk)
  "Remove from CHUNK contiguous line runs already present in recent OUT.
Only long, distinctive runs are removed, so repeated full-screen TUI
redraw bodies collapse to a single copy while genuinely new lines (and
ordinary short repeats) are kept.  OUT is searched only within the recent
`tmux-control-compact-scrollback-window' lines.  Lines are compared by
their width-insensitive match keys, so a frame repainted at another pane
size still collapses."
  (let* ((haystack (last out tmux-control-compact-scrollback-window))
         (hkeys (mapcar #'tmux-control--scrollback-match-key haystack))
         (ckeys (mapcar #'tmux-control--scrollback-match-key chunk))
         (cvec (vconcat chunk))
         (n (length cvec))
         (i 0)
         (result '()))
    (while (< i n)
      (let ((run-len (tmux-control--seen-run-length hkeys ckeys i n)))
        (if run-len
            (setq i (+ i run-len))
          (push (aref cvec i) result)
          (setq i (1+ i)))))
    (nreverse result)))

(defun tmux-control--line-list-contains-p (haystack needle)
  "Return non-nil when HAYSTACK contains NEEDLE as contiguous lines.
Lines are compared by their width-insensitive match keys."
  (and (<= (length needle) (length haystack))
       (cl-search (mapcar #'tmux-control--scrollback-match-key needle)
                  (mapcar #'tmux-control--scrollback-match-key haystack)
                  :test #'string=)))

(defun tmux-control--line-list-overlap (left right)
  "Return largest safe suffix/prefix overlap between LEFT and RIGHT.
Lines are compared by their width-insensitive match keys."
  (let* ((lkeys (mapcar #'tmux-control--scrollback-match-key left))
         (rkeys (mapcar #'tmux-control--scrollback-match-key right))
         (max (min (length left)
                   (length right)
                   tmux-control-compact-scrollback-window))
         (overlap 0))
    (while (and (> max 0) (= overlap 0))
      (let ((candidate (cl-subseq rkeys 0 max)))
        (when (and (equal (last lkeys max) candidate)
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
          (tmux-control--flush-display sync-windows)
          ;; Per-window render buffers stream in the background; flush
          ;; whichever of them accumulated output this chunk.
          (when tmux-control-window-buffers
            (tmux-control--flush-window-buffers)))
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
    (tmux-control--note-pane-activity pane)
    (tmux-control--note-session-activity)
    ;; Per-window render buffers: route the pane's output to its window's
    ;; buffer when that window has been visited, so it keeps accumulating
    ;; in the background.  The controller is registered for its own window,
    ;; so its pane routes here too once the map is known.
    (let ((wbuf (and tmux-control-window-buffers
                     (hash-table-p tmux-control--pane-window)
                     (when-let* ((entry (gethash pane
                                                 tmux-control--pane-window))
                                 (id (cdr-safe entry)))
                       (tmux-control--window-buffer id)))))
      (cond
       ((and wbuf (not (eq wbuf (current-buffer))))
        (when (equal pane (buffer-local-value 'tmux-control--active-pane wbuf))
          (let ((decoded (tmux-control--decode-output payload)))
            (with-current-buffer wbuf
              (push decoded tmux-control--output-batch)))))
       (t
        ;; Bootstrapping the active pane from the first output exists for
        ;; connect time, before the :pane-id reply lands.  A HOMELESS
        ;; controller has a nil pane too, but for it this would adopt
        ;; whatever unbuffered pane speaks first -- re-aiming a buffer
        ;; that must stay out of rendering (Copilot review).
        (unless (or tmux-control--active-pane tmux-control--homeless)
          (setq tmux-control--active-pane pane))
        (when (and tmux-control--active-pane
                   (equal pane tmux-control--active-pane))
          (push (tmux-control--decode-output payload)
                tmux-control--output-batch)))))))

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
     ;; Reply blocks never nest, so a %begin while already collecting is
     ;; pane CONTENT (a capture of a control-mode transcript), not protocol.
     ((and (string-prefix-p "%begin " line)
           (not tmux-control--collecting-command))
      (let ((entry (pop tmux-control--command-queue)))
        (setq tmux-control--current-command-kind
              (or (car-safe entry) :ignore)))
      (when tmux-control--command-watchdog-warned
        (setq tmux-control--command-watchdog-warned nil)
        (tmux-control--message "tmux replied after the delay -- recovered"))
      (setq tmux-control--collecting-command t)
      ;; %begin <time> <number> <flags>: the number also appears on the
      ;; matching %end/%error (the time may differ between the two).
      (setq tmux-control--command-block-number
            (nth 2 (split-string line " ")))
      (setq tmux-control--command-output nil))
     ;; %end/%error close the block only when their command number matches
     ;; the %begin's; otherwise a captured line that merely LOOKS like one
     ;; falls through to be collected as content below.
     ((and (string-prefix-p "%end " line)
           (tmux-control--block-terminator-p line))
      (tmux-control--finish-command-output))
     ((and (string-prefix-p "%error " line)
           (tmux-control--block-terminator-p line))
      (let ((kind tmux-control--current-command-kind))
        (setq tmux-control--collecting-command nil)
        (setq tmux-control--command-output nil)
        (setq tmux-control--current-command-kind :ignore)
        ;; A closure query still gets called -- with nil -- so an async
        ;; consumer (a scrollback capture, say) can show the failure
        ;; instead of waiting forever.
        (if (functionp kind)
            (funcall kind nil)
          (tmux-control--message
           (format "tmux command failed (%s)" kind)))))
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
     ((string-match "\\`%window-pane-changed \\([^ ]+\\) \\(%[0-9]+\\)\\'" line)
      ;; The window's active pane changed (a split, a select-pane, a closed
      ;; pane).  In single-pane mode only the active pane is mirrored, so
      ;; follow it: repaint from its current screen.  In tiling mode every
      ;; pane is already shown, so just record the pointer (no reseed, no
      ;; flicker); the matching Emacs window can be focused on demand.
      (let* ((win-id (match-string 1 line))
             (pane (match-string 2 line))
             (wbuf (and tmux-control-window-buffers
                        (not tmux-control--tiled)
                        (tmux-control--window-buffer win-id))))
        (cond
         ((and wbuf (not (eq wbuf (current-buffer))))
          ;; A visited background window changed its active pane: retarget
          ;; and repaint THAT buffer; the controller's own view is untouched.
          (with-current-buffer wbuf
            (setq tmux-control--active-pane pane))
          (tmux-control--seed-window-buffer wbuf win-id))
         ((and tmux-control-window-buffers
               (not tmux-control--tiled)
               ;; A HOMELESS controller owns no window at all, so every
               ;; window's pane event is foreign to it -- without this it
               ;; fell through to the follow branch and re-aimed itself
               ;; (Copilot review).
               (or tmux-control--homeless
                   (and tmux-control--window-id
                        (not (equal win-id tmux-control--window-id)))))
          ;; Per-window buffers: the event names some OTHER window with no
          ;; render buffer (brand-new -- tmux-control-new-window emits
          ;; %window-pane-changed for the created window BEFORE the
          ;; %session-window-changed that builds its buffer -- or simply
          ;; never visited).  It is not this buffer's pane: adopting it
          ;; retargeted the controller onto a foreign pane, and when that
          ;; window later closed (an agent's task window, say) the
          ;; controller was left aimed at a DEAD pane -- empty screen,
          ;; keystrokes to "can't find pane", even window switches did not
          ;; heal it (chaos-soak find).  Just refresh the pane->window map
          ;; (a pane appeared or moved) for the activity machinery.
          (tmux-control--refresh-pane-window-map))
         (t
          ;; Our own window's pane changed (a split, select-pane, closed
          ;; pane) -- or the legacy single-buffer mode, whose view follows
          ;; the event unconditionally (pre-window-buffers semantics, a
          ;; load-bearing affordance).  Follow it.
          (setq tmux-control--active-pane pane)
          (unless tmux-control--tiled
            (tmux-control--seed-screen)
            (tmux-control--refresh-alt-screen-option)
            (tmux-control--refresh-pane-size))))))
     ((string-prefix-p "%layout-change " line)
      ;; The window's pane structure or sizes changed (a split, a resize, a
      ;; closed pane).  In tiling mode re-derive the tiling; in single-pane
      ;; mode reconcile the active pane's size and refresh the pane->window map
      ;; (panes came or went) for the tab bar's activity marker.
      (if tmux-control--tiled
          (progn
            ;; Register any just-appeared pane NOW, from the layout this line
            ;; carries, so its %output (which follows) streams in live from the
            ;; first byte; the debounced re-tile then places it without seeding
            ;; it (avoiding the split-into-a-screenful double-render).
            (tmux-control--eager-register-new-panes
             (current-buffer) (nth 2 (split-string line " ")))
            (setq tmux-control--retile-pending t))
        (tmux-control--refresh-pane-size)
        (tmux-control--refresh-pane-window-map)))
     ((string-prefix-p "%session-window-changed " line)
      ;; The session's active window changed (switched here or by another
      ;; client).  In tiling mode re-tile to the new window's panes.  In
      ;; single-pane mode always refresh the tab bar so its highlight and
      ;; unseen-output markers track the new current window -- and reseed the
      ;; live view onto the new window's active pane, UNLESS this client just
      ;; initiated the switch itself (in which case `--refresh-active-pane'
      ;; already reseeded; reseeding again would double-paint).  One pending
      ;; count is consumed per self-switch so rapid successive ones are each
      ;; absorbed; a passed deadline clears any stale count (a no-op select or
      ;; a background kill arms a count but yields no event).  Following an
      ;; *external* switch here keeps the live view -- and scrollback, which
      ;; captures `--active-pane' -- on the window the tab bar shows, rather
      ;; than stranding on the previous pane.
      (if tmux-control--tiled
          (setq tmux-control--retile-pending t)
        (tmux-control--refresh-windows)
        (if (and tmux-control-window-buffers
                 (string-match "\\`%session-window-changed [^ ]+ \\(@[0-9]+\\)\\'"
                               line))
            ;; Per-window buffers: a switch -- ours or another client's --
            ;; just swaps the displayed buffer.  The swap is idempotent, so
            ;; our own echoed switch needs no self-reseed accounting.
            (progn
              (tmux-control--quiet-activity)
              (tmux-control--display-window-buffer (match-string 1 line)))
          (if (and (> tmux-control--self-reseed-pending 0)
                   (<= (float-time) tmux-control--self-reseed-until))
              (setq tmux-control--self-reseed-pending
                    (1- tmux-control--self-reseed-pending))
            (setq tmux-control--self-reseed-pending 0)
            (tmux-control--refresh-active-pane)))))
     ((and (not tmux-control--tiled)
           (or (string-prefix-p "%window-add " line)
               (string-prefix-p "%window-close " line)
               (string-prefix-p "%unlinked-window-add " line)
               (string-prefix-p "%unlinked-window-close " line)
               (string-prefix-p "%window-renamed " line)
               (string-prefix-p "%unlinked-window-renamed " line)))
      ;; A closed window's render buffer goes with it.  A displayed one is
      ;; first swapped to the controller; the %session-window-changed that
      ;; follows a current-window close then swaps to the real new window.
      (when (and tmux-control-window-buffers
                 (string-match "\\`%\\(?:unlinked-\\)?window-close \\(@[0-9]+\\)\\'"
                               line))
        ;; The CONTROLLER's own window can close too (an agent's task
        ;; window the controller happened to be homed on).  The buffer
        ;; must survive -- it owns the process -- but its window id and
        ;; active pane are now dead: left as they were, it would render
        ;; a frozen screen and send keystrokes into "can't find pane" if
        ;; it ever reached a window again (C-x b always can).  Mark it
        ;; homeless instead: id and pane nil (typing then says "No
        ;; active tmux pane yet" -- honest, recoverable), registry entry
        ;; gone.  The session's view continues through the per-window
        ;; render buffers; the homeless controller keeps owning the
        ;; process and the session state, just no window of its own.
        (when (equal (match-string 1 line) tmux-control--window-id)
          (setq tmux-control--window-buffers
                (cl-remove-if (lambda (e) (eq (cdr e) (current-buffer)))
                              tmux-control--window-buffers))
          (setq tmux-control--window-id nil)
          (setq tmux-control--active-pane nil)
          (setq tmux-control--homeless t))
        (when-let* ((buf (tmux-control--window-buffer (match-string 1 line))))
          (unless (eq buf (current-buffer))
            (when (eq tmux-control--session-display buf)
              (setq tmux-control--session-display (current-buffer)))
            (dolist (win (get-buffer-window-list buf nil t))
              (set-window-buffer win (current-buffer)))
            (let ((kill-buffer-query-functions nil))
              (kill-buffer buf)))))
      ;; A window was created, closed, or renamed: refresh the tab bar and the
      ;; pane->window map for the activity marker.
      (tmux-control--refresh-windows)
      (tmux-control--refresh-pane-window-map))))))

(defun tmux-control--block-terminator-p (line)
  "Return non-nil when %end/%error LINE closes the current reply block.
True only while collecting a block AND when LINE's command number
matches the block's %begin (the timestamp differs between %begin and
its %end; the number does not).  Outside a block the answer is always
nil: a stray terminator-shaped line then matches no other clause of
the protocol dispatch and is simply ignored."
  (and tmux-control--collecting-command
       (equal (nth 2 (split-string line " "))
              tmux-control--command-block-number)))

(defun tmux-control--query (command callback)
  "Send control-mode COMMAND; call CALLBACK with its reply.
CALLBACK receives the reply's lines in order, or nil when tmux answers
with %error.  It runs from the process filter in the controller buffer,
so it should capture any other buffer it needs lexically.  The query
rides the regular command queue over the existing connection -- no
out-of-band tmux or ssh process -- so it works identically for local
and remote sessions."
  (tmux-control--send-command command callback))

(defun tmux-control--finish-command-output ()
  "Handle the end of a tmux command reply.
The reply state is snapshotted and RESET before the handler runs: a
handler -- a query callback in particular -- may directly or indirectly
pump the process (`accept-process-output', `sit-for'), re-entering the
filter; if the buffer still looked mid-block, the next %begin would be
swallowed as content and the reply queue would desynchronize."
  (let ((kind tmux-control--current-command-kind)
        (output tmux-control--command-output))
    (setq tmux-control--collecting-command nil)
    (setq tmux-control--current-command-kind :ignore)
    (setq tmux-control--command-output nil)
    (pcase kind
      ;; A function kind is a one-shot `tmux-control--query' callback; it
      ;; receives the reply lines in order.
      ((pred functionp)
       (funcall kind (reverse output)))
      (:pane-id
       (let ((pane (cl-find-if (lambda (line)
                                 (string-match-p "\\`%[0-9]+\\'" line))
                               output)))
         (when pane
           (setq tmux-control--active-pane pane)
           (tmux-control--seed-screen)
           (tmux-control--refresh-alt-screen-option)
           (tmux-control--refresh-pane-size))))
      (:pane-size
       ;; The reply carries "PANExSIZE\tWINDOWxSIZE": the PANE size drives
       ;; the renderer (in a split window the active pane is narrower than
       ;; the window, and the grid must match the pane); the WINDOW size is
       ;; what refresh-client actually negotiates, so the pin detection
       ;; compares THAT against what we asked for -- comparing the pane
       ;; would cry wolf on every split layout.
       (let* ((val (car (cl-remove-if #'string-empty-p
                                      (mapcar #'string-trim output))))
              (parts (and val (split-string val "\t")))
              (size (tmux-control--parse-pane-size
                     (list (or (car parts) ""))))
              (win-size (and (cadr parts)
                             (tmux-control--parse-pane-size
                              (list (cadr parts))))))
         (when (and size
                    (tmux-control--apply-eat-size (car size) (cdr size)))
           ;; The grid changed under already-rendered output, so repaint
           ;; the visible screen at the corrected width.
           (tmux-control--seed-screen))
         ;; A WINDOW that stays at another size than the one we just asked
         ;; tmux for means its size is PINNED (window-size manual -- e.g.
         ;; after any `resize-window', which tmux pins as a side effect) or
         ;; owned by another attached client.  That failure is otherwise
         ;; silent: the view keeps reconciling to a grid that never matches
         ;; the Emacs window.  Probe and say so, once per episode.
         (when win-size
           (tmux-control--maybe-warn-pinned-size win-size))))
      (:windows
       (tmux-control--update-windows output))
      (:pane-window
       (tmux-control--update-pane-window-map output))
      (:alt-screen-opt
       (let ((res (tmux-control--interpret-alt-screen-reply output nil)))
         (if (eq res :inherit)
             ;; Empty reply means the window inherits the option; resolve it
             ;; from the global-window default.
             (tmux-control--send-command "show-options -gwv alternate-screen"
                                         :alt-screen-opt-global)
           (setq tmux-control--alt-screen-honored (cdr res)))))
      (:alt-screen-opt-global
       (setq tmux-control--alt-screen-honored
             (cdr (tmux-control--interpret-alt-screen-reply output t))))
      (:version
       (setq tmux-control--capture-trailing-p
             (tmux-control--capture-n-supported-p
              (car (cl-remove-if #'string-empty-p
                                 (mapcar #'string-trim output))))))
      (:cursor-pos
       (setq tmux-control--seed-cursor
             (tmux-control--parse-cursor-pos output))
       (setq tmux-control--seed-cursor-visible
             (tmux-control--parse-cursor-visible output)))
      (:capture
       (tmux-control--write-terminal
        (tmux-control--screen-seed-sequence
         (mapconcat #'identity (nreverse output) "\n")
         tmux-control--seed-cursor
         tmux-control--seed-cursor-visible))))))

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
    (setq tmux-control--seed-cursor-visible :unknown)
    (tmux-control--send-command
     (format "display-message -p -t %s \"#{cursor_x},#{cursor_y},#{cursor_flag}\""
             tmux-control--active-pane)
     :cursor-pos)
    (tmux-control--send-command
     (format "capture-pane -p -e%s -t %s"
             ;; -N keeps trailing background cells so full-width fills survive.
             (if tmux-control--capture-trailing-p " -N" "")
             tmux-control--active-pane)
     :capture)
    (tmux-control--verify-seed (current-buffer)
                               #'tmux-control--seed-screen)))

(defconst tmux-control--seed-verify-max-retries 2
  "How many times a drift-detected seed is retried before giving up.
A pane that streams continuously can race every retry; the cap keeps
the worst case bounded, and the next seed (a resize, a window visit, a
pause) gets a fresh budget.")

(defvar-local tmux-control--seed-verify-retries 0
  "Consecutive seed retries triggered by cursor-drift detection.
Reset to zero whenever a verification passes.")

(defun tmux-control--eat-cursor-xy ()
  "Return the current buffer's terminal cursor as 0-indexed (X . Y).
Reads Eat's own cursor bookkeeping (the same coordinates tmux reports
as #{cursor_x},#{cursor_y}); nil when the terminal is gone or Eat's
internals are unavailable, in which case seed verification quietly
disables itself."
  (when (and tmux-control--terminal
             (eat-term-live-p tmux-control--terminal)
             (fboundp 'eat--t-term-display)
             (fboundp 'eat--t-disp-cursor)
             (fboundp 'eat--t-cur-x)
             (fboundp 'eat--t-cur-y))
    (let* ((disp (eat--t-term-display tmux-control--terminal))
           (cur (and disp (eat--t-disp-cursor disp))))
      (when cur
        ;; Eat's cursor is 1-indexed; tmux's is 0-indexed.
        (cons (1- (eat--t-cur-x cur)) (1- (eat--t-cur-y cur)))))))

(defun tmux-control--verify-seed (buffer reseed)
  "Verify BUFFER's freshly seeded screen against tmux; RESEED on drift.

The seed's cursor query and screen capture are two reply blocks, and
tmux may interleave %output between them -- a prompt redraw scrolling
the pane one row right there leaves the seeded baseline one row off,
after which every cursor-relative repaint applies one row off, FOREVER
\(deltas preserve relative consistency; nothing repaints).  The chaos
soak caught exactly this: a screen identical to the pane's but shifted
one row, stable for minutes.

So after each seed, ask tmux for the pane's cursor once more and
compare it with Eat's own cursor.  Stream ordering makes the comparison
exact: any output that moved tmux's cursor before this reply was
generated has already been fed to Eat by the time the reply dispatches
\(the filter flushes pending output before every control line), so on
an aligned screen the two agree even mid-stream.  Disagreement means
the baseline drifted: run RESEED (bounded by
`tmux-control--seed-verify-max-retries').  This also heals any
historical drift at the next natural seed, whatever its cause."
  (when (buffer-live-p buffer)
    (let ((pane (buffer-local-value 'tmux-control--active-pane buffer))
          (ctrl (with-current-buffer buffer (tmux-control--wb-controller))))
      (when (and pane (buffer-live-p ctrl))
        (with-current-buffer ctrl
          (tmux-control--query
           (format "display-message -p -t %s \"#{cursor_x},#{cursor_y}\""
                   pane)
           (lambda (lines)
             (when (and lines (buffer-live-p buffer))
               (with-current-buffer buffer
                 ;; Only judge the pane this verification was issued for:
                 ;; a pane switch between issue and reply would compare
                 ;; apples to oranges.
                 (when (equal pane tmux-control--active-pane)
                   (let ((fresh (tmux-control--parse-cursor-pos lines))
                         (mine (tmux-control--eat-cursor-xy)))
                     (cond
                      ((or (null fresh) (null mine))
                       (setq tmux-control--seed-verify-retries 0))
                      ((equal fresh mine)
                       (setq tmux-control--seed-verify-retries 0))
                      ((< tmux-control--seed-verify-retries
                          tmux-control--seed-verify-max-retries)
                       (cl-incf tmux-control--seed-verify-retries)
                       (funcall reseed))
                      (t
                       (setq tmux-control--seed-verify-retries 0))))))))))))))

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
   ;; A pane mirrored by a sibling window render buffer resyncs there.
   ((when-let* ((entry (and tmux-control-window-buffers
                            (hash-table-p tmux-control--pane-window)
                            (gethash pane tmux-control--pane-window)))
                (id (cdr-safe entry))
                (buf (tmux-control--window-buffer id)))
      (unless (eq buf (current-buffer))
        (tmux-control--seed-window-buffer buf id)
        t)))
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

(defun tmux-control--screen-seed-sequence (text &optional cursor cursor-visible)
  "Return terminal escapes to paint captured visible-screen TEXT.
CURSOR, when non-nil, is a (X . Y) cons of tmux's 0-indexed cursor column
and row on the visible screen; the cursor is placed there (clamped to the
grid).  When nil -- the position could not be queried -- the cursor falls
back to the bottom-left of the screen.  CURSOR-VISIBLE is `:visible',
`:hidden', or `:unknown'; unknown leaves the current cursor visibility
unchanged."
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
      (pcase cursor-visible
        (:visible (push "\e[?25h" out))
        (:hidden (push "\e[?25l" out)))
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
pass and replayed by `tmux-control--flush-display'.

With `tmux-control-wheel-scrolls-live-history' the follow set is keyed on
CURSOR VISIBILITY instead: every window of this buffer that currently shows
the live cursor follows, the rest do not.  So a window scrolled up off the
live screen holds (output accumulates below without yanking the reader back),
and one scrolled back down to it resumes following -- both regardless of where
point happens to sit, which a mouse-wheel scroll under
`pixel-scroll-precision-mode' leaves on the cursor rather than moving.  Eat's
own list keys on point==cursor, which the wheel does not maintain, so it can
neither hold reliably nor re-arm on the way back; this keys on what the user
actually sees.  Eat's `buffer' point decision is preserved."
  (and (fboundp 'eat--synchronize-scroll-windows)
       tmux-control--terminal
       (eat-term-live-p tmux-control--terminal)
       (let ((base (eat--synchronize-scroll-windows)))
         (if (or (not tmux-control-wheel-scrolls-live-history)
                 ;; Tiled panes are anchored by the tiling layer, not by this
                 ;; cursor-visibility follow set -- leave them on Eat's own
                 ;; list (see `tmux-control--tiled-mode-p').
                 (tmux-control--tiled-mode-p))
             base
           (let ((cursor (eat-term-display-cursor tmux-control--terminal)))
             (append
              (and (memq 'buffer base) '(buffer))
              (seq-filter
               ;; PARTIALLY: under `pixel-scroll-precision-mode' the cursor
               ;; line at the bottom is often a few pixels clipped; without
               ;; this it reads as not visible and following never resumes.
               (lambda (w) (pos-visible-in-window-p cursor w t))
               (get-buffer-window-list (current-buffer) nil t))))))))

(defun tmux-control--snap-to-live-screen (window)
  "Point WINDOW, newly showing this buffer, at the live terminal screen.

Emacs remembers a per-window point for every buffer a window has shown
and restores it on `set-window-buffer' -- but a live render buffer keeps
STREAMING while it is off screen, so the remembered point goes stale by
exactly as much output as arrived in the meantime.  Returning to a
window after an agent filled its buffer then landed the view thousands
of lines above the live screen, on ancient scrollback.  tmux's own rule
is the right one: arriving at a window always shows the live screen
(history stays one wheel-up away).  Re-anchoring point onto the cursor
also re-arms Eat's scroll-follow, which identifies a following window by
its point sitting on the cursor.

Runs from `window-buffer-change-functions' (buffer-local), so EVERY way
a live buffer reaches a window -- the window-switch swap, returning from
the scrollback pager, `switch-to-buffer', a window-configuration
restore -- self-heals, with no per-call-site bookkeeping.  Tiled pane
buffers are skipped: the tiling layer anchors its own windows
(`tmux-control--anchor-windows-to-screen-top')."
  (let ((buffer (window-buffer window)))
    (when (and (buffer-live-p buffer)
               ;; The buffer-local hook also fires for windows whose buffer
               ;; did NOT change when some other window on the frame did;
               ;; only a window actually ARRIVING at this buffer is snapped,
               ;; so a deliberately scrolled-up live view is not yanked to
               ;; the bottom by unrelated window traffic elsewhere.
               (not (eq (window-old-buffer window) buffer)))
      (with-current-buffer buffer
        (when (and (derived-mode-p 'tmux-control-mode)
                   tmux-control--terminal
                   (eat-term-live-p tmux-control--terminal)
                   (not (and tmux-control--controller
                             (buffer-live-p tmux-control--controller)
                             (buffer-local-value 'tmux-control--tiled
                                                 tmux-control--controller)))
                   (fboundp 'eat--synchronize-scroll))
          (let ((eat-terminal tmux-control--terminal))
            (eat--synchronize-scroll (list window))))))))

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
        ;; In a TILED pane only, anchor to the top of the current terminal
        ;; screen so a full-screen TUI (e.g. a Claude Code panel) shows from
        ;; its top instead of being scrolled with its top cut off when tall
        ;; box-drawing glyphs make the rows overflow the body in pixels.
        ;; Only there: the anchor counts buffer LINES back from point-max,
        ;; which lands above eat's display-beginning whenever a screen row
        ;; is a wrapped continuation.  A per-window render buffer sets
        ;; `tmux-control--controller' too, and inheriting the anchor made
        ;; every output flush fight eat's keystroke-time scroll sync -- the
        ;; view bounced between the two notions of "screen top" on each
        ;; typed character.
        (when (and tmux-control--controller
                   (buffer-live-p tmux-control--controller)
                   (buffer-local-value 'tmux-control--tiled
                                       tmux-control--controller))
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
chunks so a large paste is not dropped as one over-long `send-keys'.

Typing into a session whose connection has died offers to reconnect:
keystrokes are the natural thing to try against a dead-looking
terminal, so make them the recovery path instead of a silent no-op."
  (when (and (not (process-live-p tmux-control--process))
             (> (length string) 0)
             (not tmux-control--suppress-responses)
             tmux-control--session)
    (when (y-or-n-p "tmux-control: connection is down; reconnect? ")
      (tmux-control-reconnect)))
  (when (and (process-live-p tmux-control--process)
             (> (length string) 0)
             (not tmux-control--suppress-responses))
    ;; The session-target fallback exists for connect time, before the
    ;; active pane is known.  A HOMELESS controller (own window closed)
    ;; must NOT fall back: it would silently drive the session's current
    ;; pane -- which the user is watching through a DIFFERENT buffer --
    ;; from a frozen view (Copilot review).
    (let ((target (or tmux-control--active-pane
                      (and (not tmux-control--homeless)
                           tmux-control--fallback-target))))
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

(defun tmux-control-send-escape ()
  "Send a literal ESC to the pane, immediately.
In a graphical Emacs the escape key is otherwise translated into the
meta prefix and sits there waiting for a second key -- so a bare ESC
press sent NOTHING to the pane until the next keystroke.  ESC is the
most reflexive key a terminal has after C-c: it leaves vim's insert
mode, cancels a TUI's menu, interrupts an agent.  Send it the moment
it is pressed, like any terminal would.  (In a tty Emacs the escape
key never generates this `escape' event, so terminal Meta sequences
are unaffected.)

Bound only in `tmux-control-mode-map', the major mode map, so a modal
package that binds ESC to leave insert mode (xah-fly-keys, evil, viper)
keeps it: those bindings live in a minor-mode map, which outranks the
major mode map.  For such users the ESC key switches modes rather than
reaching the pane; to send ESC to the pane they bind this command to a
free key, or use char mode (where every key goes to the pane)."
  (interactive)
  (eat-self-input 1 ?\e))

(defconst tmux-control--paste-buffer-chunk-bytes 1024
  "Maximum UTF-8 bytes per `set-buffer' control command when pasting.
The escaped data is at most four characters per byte, keeping each
command line comfortably inside tmux's limits; longer pastes append
with `set-buffer -a'.")

(defun tmux-control--quote-tmux-data (bytes start end)
  "Return BYTES from START to END as a double-quoted tmux argument.
Alphanumerics and spaces are literal; every other byte is an octal
escape, which tmux's double-quote parser decodes -- including newlines,
which could never ride a one-line control command literally.  Escaping
everything else sidesteps the parser's specials ($ expansion, #{}
formats, quotes, backslashes) wholesale."
  ;; NB freshly consed list, never a quoted literal: the `nreverse' below
  ;; would destructively rewire a shared literal, corrupting every later
  ;; call (first paste fine, second reversed -- found live).
  (let ((parts (list "\""))
        (i start))
    (while (< i end)
      (let ((b (aref bytes i)))
        (push (if (or (<= ?a b ?z) (<= ?A b ?Z) (<= ?0 b ?9) (= b ?\s))
                  (string b)
                (format "\\%03o" b))
              parts))
      (setq i (1+ i)))
    (push "\"" parts)
    (apply #'concat (nreverse parts))))

(defun tmux-control--paste-to-pane (text)
  "Paste TEXT into the active pane through tmux's own paste buffer.
Loads TEXT into a named tmux buffer (chunked `set-buffer'/-a appends)
and delivers it with `paste-buffer -p -d': tmux then applies bracketed
paste exactly when the pane's application has requested it -- so a
multi-line paste into a modern shell arrives as one reviewable block
instead of executing line by line -- and translates linefeeds for the
pane like any terminal paste.  This is how iTerm2's tmux integration
pastes, and the reason is the same: the client cannot know the pane's
bracketed-paste state, but tmux does."
  (when (> (length text) 0)
    ;; Same homeless gating as `tmux-control--send-input': never drive
    ;; the session's current pane from a buffer that renders nothing.
    (let ((target (or tmux-control--active-pane
                      (and (not tmux-control--homeless)
                           tmux-control--fallback-target))))
      (if (not target)
          (tmux-control--message "No active tmux pane yet")
        (let* ((bytes (encode-coding-string text 'utf-8-unix))
               (n (length bytes))
               (size tmux-control--paste-buffer-chunk-bytes)
               (name (format "tmux-control-paste-%d" (emacs-pid)))
               (i 0))
          (while (< i n)
            (let ((end (min n (+ i size))))
              (tmux-control--send-command
               (format "set-buffer %s-b %s %s"
                       (if (zerop i) "" "-a ")
                       name
                       (tmux-control--quote-tmux-data bytes i end)))
              (setq i end)))
          (tmux-control--send-command
           (format "paste-buffer -p -d -b %s -t %s" name target)))))))

(defun tmux-control-yank (&optional _arg)
  "Paste the most recent kill into the pane via tmux's paste buffer.
Replaces `eat-yank' (and the remapped `yank'/`clipboard-yank' GUI
gestures) in tmux-control buffers so that bracketed paste is decided by
tmux, which knows the pane's state; see `tmux-control--paste-to-pane'."
  (interactive "P")
  (when-let* ((text (current-kill 0)))
    (tmux-control--paste-to-pane text)))

(defun tmux-control-yank-from-kill-ring (string &optional _arg)
  "Choose STRING from the kill ring and paste it into the pane.
The pane-side paste goes through tmux's paste buffer, exactly like
`tmux-control-yank'."
  (interactive (list (read-from-kill-ring "Yank to pane from kill-ring: ")
                     current-prefix-arg))
  (tmux-control--paste-to-pane string))

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
                        (list (cons (or kind :ignore) (float-time)))))
          (tmux-control--arm-command-watchdog)
          (process-send-string tmux-control--process
                               (concat command "\n")))))))

(defun tmux-control--arm-command-watchdog ()
  "Schedule a check that the oldest pending command gets its reply in time.
No-op when `tmux-control-command-timeout' is nil or a check is already
scheduled.  Must run in the controller buffer."
  (when (and tmux-control-command-timeout
             (null tmux-control--command-watchdog-timer))
    (setq tmux-control--command-watchdog-timer
          (run-at-time tmux-control-command-timeout nil
                       #'tmux-control--command-watchdog-check
                       (current-buffer)))))

(defun tmux-control--command-watchdog-check (buffer)
  "Warn when BUFFER's oldest pending command has gone unanswered too long.
Replies are matched to commands strictly in order, so the queue is never
popped here -- a late reply must still meet its own entry.  The check
re-arms itself while commands remain pending on a live connection: for
the remaining wait when the head entry is still fresh, or for a full
interval after warning so a recovery can be noticed and the episode
flag reset."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq tmux-control--command-watchdog-timer nil)
      (let ((head (car tmux-control--command-queue)))
        (cond
         ((null head)
          (setq tmux-control--command-watchdog-warned nil))
         ;; The watchdog can be disabled after this check was armed.
         ((not (numberp tmux-control-command-timeout))
          (setq tmux-control--command-watchdog-warned nil))
         ((not (process-live-p tmux-control--process))
          ;; The sentinel already reports a dead connection; a stuck-queue
          ;; warning on top would be noise.  Stop watching.
          (setq tmux-control--command-watchdog-warned nil))
         (t
          ;; `cdr-safe' tolerates a bare-symbol entry from a buffer that
          ;; predates timestamped entries (a live upgrade); with no send
          ;; time it counts as fresh and simply drains.
          (let ((age (- (float-time) (or (cdr-safe head) (float-time)))))
            (if (< age tmux-control-command-timeout)
                ;; The original head was answered and a younger command is
                ;; at the front now; wait out its remaining time.
                (setq tmux-control--command-watchdog-timer
                      (run-at-time (- tmux-control-command-timeout age) nil
                                   #'tmux-control--command-watchdog-check
                                   buffer))
              (unless tmux-control--command-watchdog-warned
                (setq tmux-control--command-watchdog-warned t)
                (let ((text (format "no reply from tmux for %ds (%d command%s pending) -- connection may be stuck; C-c C-r reconnects"
                                    (round age)
                                    (length tmux-control--command-queue)
                                    (if (cdr tmux-control--command-queue) "s" ""))))
                  (tmux-control--message text)
                  (message "tmux-control: %s" text)))
              ;; Keep watching so a drain after the warning resets the
              ;; episode (and a still-stuck queue stays detectable).
              (setq tmux-control--command-watchdog-timer
                    (run-at-time tmux-control-command-timeout nil
                                 #'tmux-control--command-watchdog-check
                                 buffer))))))))))

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
  (tmux-control--quiet-activity)
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
  ;; Remember what we asked for, so the :pane-size reconciliation can
  ;; notice tmux NOT following (a pinned window-size, a competing client)
  ;; and say so instead of silently snapping the grid back.
  (with-current-buffer (tmux-control--wb-controller)
    (setq tmux-control--requested-client-size (cons width height)))
  ;; refresh-client sizes the CLIENT, so tmux resizes every window to it;
  ;; keep the sibling window render buffers' grids in step so background
  ;; output renders at the size tmux is actually emitting for.
  (when tmux-control-window-buffers
    (let ((self (current-buffer)))
      (with-current-buffer (tmux-control--wb-controller)
        (dolist (entry tmux-control--window-buffers)
          (let ((buf (cdr entry)))
            (when (and (buffer-live-p buf)
                       (not (eq buf self)))
              (with-current-buffer buf
                (tmux-control--apply-eat-size width height))))))))
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
is found.  The reply may include a third cursor visibility field
(\"X,Y,FLAG\"), which is ignored here.  Pure: no side effects, for unit
testing the seed cursor query."
  (let ((val (car (cl-remove-if #'string-empty-p
                                (mapcar #'string-trim output)))))
    (when (and val (string-match "\\`\\([0-9]+\\),\\([0-9]+\\)\\(?:,[01]?\\)?\\'" val))
      (cons (string-to-number (match-string 1 val))
            (string-to-number (match-string 2 val))))))

(defun tmux-control--cursor-visible-from-flag (flag)
  "Return cursor visibility represented by tmux cursor FLAG.
Return `:visible' for \"1\", `:hidden' for \"0\", and `:unknown' for any
other value."
  (pcase flag
    ("1" :visible)
    ("0" :hidden)
    (_ :unknown)))

(defun tmux-control--parse-cursor-visible (output)
  "Parse cursor visibility from control-mode reply OUTPUT lines.
Return `:visible' when tmux's cursor flag is 1, `:hidden' when it is 0,
and `:unknown' when the flag is absent or the reply is malformed.  Pure:
no side effects, for unit testing the seed cursor query."
  (let ((val (car (cl-remove-if #'string-empty-p
                                (mapcar #'string-trim output)))))
    (if (and val (string-match "\\`[0-9]+,[0-9]+,\\([01]\\)\\'" val))
        (tmux-control--cursor-visible-from-flag (match-string 1 val))
      :unknown)))

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
     (format "display-message -p -t %s \"#{pane_width}x#{pane_height}\t#{window_width}x#{window_height}\""
             tmux-control--active-pane)
     :pane-size)))

(defun tmux-control--maybe-warn-pinned-size (actual)
  "Warn once when tmux keeps the WINDOW at ACTUAL despite our size requests.
ACTUAL is the window size from the :pane-size reconciliation reply (the
window, not the pane: a split window's active pane is legitimately
narrower than what refresh-client negotiates).  Compares widths only
\(heights legitimately differ by a status line), and probes the
displayed window's `window-size' option in-band before saying anything,
so the warning names the actual cause: a pinned window (\"manual\" --
the side effect of any `resize-window') or a competing attached client.
Resolving it is one command: `tmux-control-adopt-window-size'."
  (let ((requested tmux-control--requested-client-size))
    (cond
     ((null requested) nil)
     ((= (car requested) (car actual))
      ;; tmux followed us; any earlier episode is over.
      (setq tmux-control--size-pin-warned nil))
     ((not tmux-control--size-pin-warned)
      (setq tmux-control--size-pin-warned t)
      (let* ((buffer (current-buffer))
             ;; Probe the window actually on screen, by stable @id when
             ;; known -- the cached current-window INDEX can lag rapid
             ;; switches and would misattribute the diagnosis.
             (display-id (buffer-local-value
                          'tmux-control--window-id
                          (tmux-control--session-display-buffer buffer)))
             (target (or display-id
                         (format "%s:%s" tmux-control--session
                                 (or tmux-control--current-window "")))))
        (tmux-control--query
         (format "show-options -wqv -t %s window-size" target)
         (lambda (lines)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (let* ((value (and lines
                                  (car (cl-remove-if #'string-empty-p
                                                     (mapcar #'string-trim
                                                             lines)))))
                      (text (if (equal value "manual")
                                (format "tmux window size is pinned (window-size manual), so the view cannot follow this Emacs window (stuck at %dx%d); M-x tmux-control-adopt-window-size to unpin"
                                        (car actual) (cdr actual))
                              (format "tmux kept the window at %dx%d (asked %dx%d): window-size is %s -- another attached client may be sizing it; M-x tmux-control-adopt-window-size to take over"
                                      (car actual) (cdr actual)
                                      (car requested) (cdr requested)
                                      (or value "default")))))
                 (tmux-control--message text)
                 (message "tmux-control: %s" text)))))))))))

(defun tmux-control-adopt-window-size ()
  "Make the current tmux window's size follow this Emacs window.
Sets the window's `window-size' option to latest (undoing the manual pin
tmux applies as a side effect of any `resize-window', or wresting the
size from another attached client's stale claim) and immediately resizes
to this Emacs window.  See the guide on sharing a session with another
client (e.g. iTerm2) for the trade-offs."
  (interactive)
  (tmux-control--ensure-live)
  (let* ((ctrl (tmux-control--wb-controller))
         (idx (or (and tmux-control--window-id
                       (with-current-buffer ctrl
                         (cl-loop for w in tmux-control--windows
                                  when (equal (plist-get w :id)
                                              tmux-control--window-id)
                                  return (plist-get w :index))))
                  (buffer-local-value 'tmux-control--current-window ctrl))))
    (tmux-control--send-command
     (format "set-option -w -t %s%s window-size latest"
             tmux-control--session
             (if idx (concat ":" idx) ":")))
    (with-current-buffer ctrl
      (setq tmux-control--size-pin-warned nil))
    (tmux-control--resize-to-window)
    (message "tmux-control: window now follows this Emacs window")))

(defun tmux-control--sentinel (process message)
  "Handle PROCESS exit with MESSAGE."
  (when (buffer-live-p (process-buffer process))
    (with-current-buffer (process-buffer process)
      ;; The sentinel runs deferred from the command loop, so a quick
      ;; reconnect may already have installed a FRESH process in this
      ;; buffer by the time a dead process's sentinel fires.  Acting then
      ;; would nil out the new connection's process variable and print a
      ;; spurious loss announcement over a live session.  Only the
      ;; buffer's CURRENT process gets to report its own death.
      (when (eq process tmux-control--process)
        ;; If the session died while tiled, tear the tiling down so its
        ;; pane render buffers are not left orphaned without a process.
        (when tmux-control--tiled
          (tmux-control--teardown-tiling (current-buffer)))
        (let ((deliberate tmux-control--disconnecting))
          (setq tmux-control--disconnecting nil)
          (setq tmux-control--process nil)
          ;; A deliberate disconnect (C-c C-k) needs no announcement.
          ;; Anything else -- a dropped SSH connection, a killed tmux
          ;; server -- used to die silently here, leaving a dead-looking
          ;; buffer with no explanation and no way back short of
          ;; re-running `tmux-control-connect' with all its prompts.  Say
          ;; what happened and name the one-key recovery.  (Whether the
          ;; tmux session survived cannot be known from here -- a dropped
          ;; link leaves it running, a killed server does not -- so the
          ;; message is conditional.)
          (unless deliberate
            (tmux-control--message
             (format "connection lost (%s) -- if the tmux session is still running, C-c C-r reconnects"
                     (string-trim-right message)))
            (force-mode-line-update t)))))))

(defun tmux-control--kill-process ()
  "Delete the tmux control process and any dependent render buffers."
  ;; Cancel the command watchdog: its timer lives on the global `timer-list'
  ;; and holds this buffer as its argument, so without this the killed
  ;; controller is retained until the timer next fires.  Mirrors the
  ;; cancellation in `tmux-control--reset-buffer'.
  (when tmux-control--command-watchdog-timer
    (cancel-timer tmux-control--command-watchdog-timer)
    (setq tmux-control--command-watchdog-timer nil))
  (when tmux-control--panes
    (dolist (np tmux-control--panes)
      (when (buffer-live-p (cdr np))
        (let ((kill-buffer-query-functions nil))
          (kill-buffer (cdr np)))))
    (setq tmux-control--panes nil))
  (let ((self (current-buffer)))
    (dolist (entry tmux-control--window-buffers)
      (let ((buf (cdr entry)))
        (when (and (buffer-live-p buf) (not (eq buf self)))
          (let ((kill-buffer-query-functions nil))
            (kill-buffer buf))))))
  (setq tmux-control--window-buffers nil)
  (when (process-live-p tmux-control--process)
    ;; Deliberate teardown (the buffer is being killed); keep the deferred
    ;; sentinel from writing into whatever buffer reuses the name.
    (set-process-sentinel tmux-control--process #'ignore)
    (delete-process tmux-control--process)))

(defun tmux-control--message (message)
  "Append MESSAGE to the current tmux-control buffer."
  (let ((inhibit-read-only t))
    (goto-char (point-max))
    (insert (propertize (format "\n[tmux-control] %s\n" message)
                        'face 'font-lock-comment-face))))


;;;; Per-window render buffers (window scrollback persistence)
;;
;; With `tmux-control-window-buffers' on, each tmux window the user visits
;; gets its own render buffer -- an ordinary `tmux-control-mode' buffer
;; with its own Eat terminal, exactly like a tiled pane buffer but scoped
;; to a window's active pane.  The connect buffer keeps the process and
;; all session state (it is the controller) and doubles as the render
;; buffer for its own window.  A window switch swaps buffers in the
;; selected Emacs window instead of repainting one buffer in place, so
;; every visited window keeps its accumulated scrollback -- and keeps
;; STREAMING while in the background, because the control client receives
;; %output for every pane of every window anyway.

(defun tmux-control--wb-controller ()
  "Return the controller buffer for the current tmux-control buffer."
  (or tmux-control--controller (current-buffer)))

(defun tmux-control--window-id-for-index (index)
  "Return the @window-id for window INDEX from the cached window list.
Must run in the controller buffer; nil when not yet known."
  (let ((entry (cl-find-if (lambda (w) (equal (plist-get w :index) index))
                           tmux-control--windows)))
    (plist-get entry :id)))

(defun tmux-control--window-buffer (window-id)
  "Return the live render buffer for WINDOW-ID, or nil.
Must run in the controller buffer."
  (let ((buf (cdr (assoc window-id tmux-control--window-buffers))))
    (and (buffer-live-p buf) buf)))

(defun tmux-control--register-window-buffer (window-id buffer)
  "Record BUFFER as WINDOW-ID's render buffer on the controller."
  (setq tmux-control--window-buffers
        (cons (cons window-id buffer)
              (assoc-delete-all window-id tmux-control--window-buffers))))

(defun tmux-control--kill-render-buffers (controller)
  "Kill every per-window render buffer belonging to CONTROLLER.
A render buffer is named \"*<CONTROLLER-name>:@ID*\", so CONTROLLER's
own name with the closing star replaced by \":@\" is the exact prefix.

Sweeps by NAME rather than the `tmux-control--window-buffers' registry
on purpose: the registry can drift out of sync with the live buffers (a
visited window deregistered without its buffer killed), and a
registry-only sweep then leaves the orphan behind.  On a reconnect that
orphan keeps the now-dead process, so reaching it (`C-x b', a later
window event) hits \"process is not live\" with no recovery -- the
chaos-soak find this guards against.  CONTROLLER itself is never killed."
  (let ((prefix (concat (substring (buffer-name controller) 0 -1) ":@")))
    (dolist (buf (buffer-list))
      (when (and (buffer-live-p buf)
                 (not (eq buf controller))
                 (string-prefix-p prefix (buffer-name buf)))
        (let ((kill-buffer-query-functions nil))
          (kill-buffer buf))))))

(defun tmux-control--session-display-buffer (&optional ctrl)
  "Return the buffer currently representing CTRL's session on screen.
Prefers the controller's explicit display pointer (set by every swap, so
it is correct even mid-burst when the cached window index lags); falls
back to the current window's render buffer, then the controller itself."
  (let ((ctrl (or ctrl (tmux-control--wb-controller))))
    (with-current-buffer ctrl
      (or (and tmux-control-window-buffers
               (buffer-live-p tmux-control--session-display)
               tmux-control--session-display)
          (and tmux-control-window-buffers
               tmux-control--current-window
               (tmux-control--window-buffer
                (tmux-control--window-id-for-index
                 tmux-control--current-window)))
          ctrl))))

(defun tmux-control--make-window-buffer (window-id ctrl)
  "Create a render buffer for tmux window WINDOW-ID routed through CTRL.
Mirrors `tmux-control--make-pane-buffer': an ordinary `tmux-control-mode'
buffer with its own terminal, no process of its own, commands routed via
CTRL.  The buffer starts empty; `tmux-control--seed-window-buffer' fills
it asynchronously over the control connection."
  (with-current-buffer ctrl
    (let* ((host tmux-control--host)
           (name (format "*tmux-control:%s:%s:%s*"
                         (if (and host (not (string-empty-p host)))
                             host "local")
                         tmux-control--session window-id))
           (process tmux-control--process)
           (socket tmux-control--socket-name)
           (session tmux-control--session)
           (trailing tmux-control--capture-trailing-p)
           (fallback tmux-control--fallback-target)
           (size (and tmux-control--terminal
                      (eat-term-live-p tmux-control--terminal)
                      (eat-term-size tmux-control--terminal)))
           (buffer (get-buffer-create name)))
      (with-current-buffer buffer
        (let ((inhibit-read-only t)) (erase-buffer))
        (tmux-control-mode)
        (setq-local emulation-mode-map-alists
                    (cons tmux-control--emulation-mode-map-alist
                          (delq tmux-control--emulation-mode-map-alist
                                emulation-mode-map-alists)))
        (setq tmux-control--keys-active t
              tmux-control--controller ctrl
              tmux-control--process process
              tmux-control--host host
              tmux-control--socket-name socket
              tmux-control--session session
              tmux-control--capture-trailing-p trailing
              tmux-control--fallback-target fallback
              tmux-control--window-id window-id
              tmux-control--live-buffer buffer
              tmux-control--active-pane nil
              tmux-control--accumulator ""
              tmux-control--output-batch nil
              tmux-control--display-dirty nil
              tmux-control--utf8-carry ""
              tmux-control--alt-screen-honored t
              tmux-control--seed-cursor nil
              tmux-control--seed-cursor-visible :unknown)
        (setq tmux-control--terminal (eat-term-make buffer (point-min)))
        (setq eat-terminal tmux-control--terminal)
        (when size
          (eat-term-resize tmux-control--terminal (car size) (cdr size)))
        ;; A first visit takes two control-connection round trips to paint
        ;; (noticeable over SSH); show a notice instead of a silent blank.
        ;; The seed's screen-clear replaces it.
        (tmux-control--feed-terminal
         "\033[2m[tmux-control] loading window…\033[0m")
        (tmux-control--flush-display nil)
        (eat-semi-char-mode)
        (setf (eat-term-parameter tmux-control--terminal 'input-function)
              #'tmux-control--send-input)
        (setf (eat-term-parameter tmux-control--terminal 'set-cursor-function)
              (if (fboundp 'eat--set-cursor) #'eat--set-cursor #'ignore))
        (setf (eat-term-parameter tmux-control--terminal 'grab-mouse-function)
              (if (fboundp 'eat--grab-mouse) #'eat--grab-mouse #'ignore))
        (setf (eat-term-parameter tmux-control--terminal 'ring-bell-function)
              (if (fboundp 'eat--bell) #'eat--bell #'ignore))
        (setf (eat-term-parameter tmux-control--terminal
                                  'manipulate-selection-function)
              (if (fboundp 'eat--manipulate-kill-ring)
                  #'eat--manipulate-kill-ring #'ignore))
        (setf (eat-term-parameter tmux-control--terminal 'eat--process) process)
        (setf (eat-term-parameter tmux-control--terminal 'eat--input-process)
              process)
        (setf (eat-term-parameter tmux-control--terminal 'eat--output-process)
              process)
        ;; This buffer owns no process (the controller does), so Eat's
        ;; default ":%s" mode-line suffix would permanently read
        ;; "no process" -- alarming for a perfectly live view.  Keep the
        ;; rest (the [semi-char] mode indicator), drop the status.
        (setq mode-line-process (remove ":%s" mode-line-process))
        (when (or tmux-control-window-tab-bar tmux-control-session-activity)
          (setq-local header-line-format
                      '(:eval (tmux-control--header-line))))
        (add-hook 'kill-buffer-hook
                  #'tmux-control--window-buffer-killed nil t)
        (tmux-control--disable-line-numbers))
      (with-current-buffer ctrl
        (tmux-control--register-window-buffer window-id buffer))
      buffer)))

(defun tmux-control--window-buffer-killed ()
  "Deregister a killed window render buffer from its controller."
  (when (and tmux-control--window-id
             (buffer-live-p tmux-control--controller))
    (let ((buf (current-buffer)))
      (with-current-buffer tmux-control--controller
        (setq tmux-control--window-buffers
              (cl-remove-if (lambda (e) (eq (cdr e) buf))
                            tmux-control--window-buffers))))))

(defun tmux-control--seed-window-buffer (buffer window-id)
  "Resolve WINDOW-ID's active pane and seed BUFFER from it, asynchronously.
A closure-query chain over the control connection -- never blocking
Emacs, and ordered by tmux itself.  Two round trips, not three: the
active pane and its cursor come back in one list-panes reply (this is
the first-visit latency a remote user sees as a blank window, so every
round trip counts), then the capture paints the screen."
  (let ((ctrl (tmux-control--wb-controller)))
    (with-current-buffer ctrl
      (tmux-control--query
       (format "list-panes -t %s -F \"#{pane_active}\t#{pane_id}\t#{cursor_x},#{cursor_y},#{cursor_flag}\""
               window-id)
       (lambda (lines)
         (let (pane cur vis)
           (cl-loop for l in (or lines '())
                    when (string-match
                          "\\`1\t\\(%[0-9]+\\)\t\\(.*\\)\\'" l)
                    do (setq pane (match-string 1 l))
                       (let ((cline (list (match-string 2 l))))
                         (setq cur (tmux-control--parse-cursor-pos cline)
                               vis (tmux-control--parse-cursor-visible cline)))
                    and return nil)
           (when (and pane (buffer-live-p buffer))
             (with-current-buffer buffer
               (setq tmux-control--active-pane pane))
             (with-current-buffer ctrl
               (tmux-control--query
                (format "capture-pane -p -e%s -t %s"
                        (if (buffer-local-value
                             'tmux-control--capture-trailing-p buffer)
                            " -N" "")
                        pane)
                (lambda (cap-lines)
                  (when (and cap-lines (buffer-live-p buffer))
                    (with-current-buffer buffer
                      (tmux-control--write-terminal
                       (tmux-control--screen-seed-sequence
                        (string-join cap-lines "\n")
                        cur (or vis :unknown)))
                      (tmux-control--flush-display
                       (tmux-control--current-sync-windows)))
                    ;; Same drift detection as the controller seed: output
                    ;; interleaved between the cursor and capture replies
                    ;; leaves the baseline shifted; verify and re-seed.
                    (tmux-control--verify-seed
                     buffer
                     (lambda ()
                       (tmux-control--seed-window-buffer
                        buffer window-id))))))))))))))

(defun tmux-control--flush-window-buffers ()
  "Flush each sibling window render buffer's batched output and redisplay.
Runs in the controller buffer at the end of a filter chunk, mirroring
`tmux-control--flush-tiled-panes'; the controller's own batch was already
flushed by the regular single-pane path."
  (dolist (entry tmux-control--window-buffers)
    (let ((buf (cdr entry)))
      (when (and (buffer-live-p buf)
                 (not (eq buf (current-buffer))))
        (with-current-buffer buf
          (when tmux-control--output-batch
            (let ((sync (tmux-control--current-sync-windows)))
              (tmux-control--flush-output-batch)
              (tmux-control--flush-display sync))))))))

(defun tmux-control--display-window-buffer (window-id)
  "Show WINDOW-ID's render buffer in place of the session's current view.
Creates and seeds the buffer on first visit.  Runs in any buffer of the
session; swaps every Emacs window currently showing ANY of the session's
render buffers (or the controller) over to the new one.  The swap is
keyed off what is really on screen, never off the display pointer: the
two disagree once a render buffer is displayed by hand (a plain
`switch-to-buffer', `winner-undo', a window-configuration restore), and
a pointer-keyed swap then either hunted for an \"old\" buffer no window
was showing, or believed the target already on screen -- both silent
no-ops that strand the view until something happens to resync them."
  (let* ((ctrl (tmux-control--wb-controller))
         (prior (buffer-local-value 'tmux-control--session-display ctrl))
         (new (or (with-current-buffer ctrl
                    (tmux-control--window-buffer window-id))
                  ;; The controller renders its own window.
                  (and (equal window-id
                              (buffer-local-value 'tmux-control--window-id
                                                  ctrl))
                       ctrl)
                  (let ((b (tmux-control--make-window-buffer window-id ctrl)))
                    (tmux-control--seed-window-buffer b window-id)
                    b)))
         (swapped nil))
    (dolist (buf (cons ctrl (mapcar #'cdr (buffer-local-value
                                           'tmux-control--window-buffers
                                           ctrl))))
      (when (and (buffer-live-p buf) (not (eq buf new)))
        (dolist (win (get-buffer-window-list buf nil t))
          ;; `set-window-buffer' rejects strongly dedicated windows (side
          ;; windows, previews); they opted out of buffer reuse.
          (unless (eq (window-dedicated-p win) t)
            (set-window-buffer win new)
            (setq swapped t)))))
    (when (and (buffer-live-p new)
               (or swapped (not (eq prior new)))
               (get-buffer-window new t))
      (with-current-buffer new
        (tmux-control--resize-to-window)))
    ;; Record the swap unconditionally: `tmux-control--session-display-buffer'
    ;; readers (the flock switcher, connect-or-switch) find the session's
    ;; on-screen buffer through this pointer, and it must track the session's
    ;; current window even when no Emacs window was showing the live view.
    (with-current-buffer ctrl
      (setq tmux-control--session-display new))
    new))

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
with INFO a plist of :left :top :width :height :active :cmd :title :cursor
and :cursor-visible.
Folding the layout, every pane's geometry, and every pane's cursor into a
single `list-panes' call avoids a separate `display-message' for the layout
and one per pane for the cursor -- each a blocking (possibly SSH) round-trip
that previously ran for every re-tile."
  (let* ((fmt (concat "#{window_layout}\t#{pane_id}\t#{pane_left}\t#{pane_top}\t"
                      "#{pane_width}\t#{pane_height}\t#{pane_active}\t"
                      "#{cursor_x}\t#{cursor_y}\t#{cursor_flag}\t#{pane_current_command}\t"
                      "#{pane_title}"))
         (text (tmux-control--run-tmux
                (list "list-panes" "-t" tmux-control--session "-F" fmt)))
         (layout nil)
         (panes nil))
    (dolist (line (split-string (string-trim text) "\n" t))
      (let ((f (split-string line "\t")))
        (when (>= (length f) 12)
          (unless layout (setq layout (nth 0 f)))
          (push (cons (nth 1 f)
                      (list :left (string-to-number (nth 2 f))
                            :top (string-to-number (nth 3 f))
                            :width (string-to-number (nth 4 f))
                            :height (string-to-number (nth 5 f))
                            :active (string= (nth 6 f) "1")
                            :cursor (cons (string-to-number (nth 7 f))
                                          (string-to-number (nth 8 f)))
                            :cursor-visible
                            (tmux-control--cursor-visible-from-flag (nth 9 f))
                            :cmd (nth 10 f)
                            :title (nth 11 f)))
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

(defvar-local tmux-control--pane-fed-live nil
  "Non-nil in a tiled render buffer that was created the moment its pane
appeared (a split), so its `%output' has streamed in from the pane's very
first byte.  Set by `tmux-control--eager-register-new-panes' and honored by
`tmux-control--build-tiling' to skip seeding such a pane from `capture-pane'
on its INITIAL placement: the live stream already holds its whole content, so
a capture seed would paint a second copy of the screenful a freshly-split
pane often prints at once (a `cat', an agent's start-up banner).  The pane is
still resized (Eat reflows) on that first placement.  build-tiling then clears
this flag, so a LATER resize reseeds the pane normally -- by then it is
quiescent, so the seed cannot race output, and a reseed keeps it cell-exact
where Eat's own reflow could have drifted from tmux's grid.")

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
            tmux-control--seed-cursor nil
            tmux-control--seed-cursor-visible :unknown)
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

(defun tmux-control--eager-register-new-panes (controller layout)
  "Register render buffers for panes that are new in LAYOUT, fed live.
LAYOUT is the window-layout string from a `%layout-change' (a split, a pane
close).  A pane that just appeared has not been rendered yet; create its
buffer NOW -- synchronously, from the layout already in hand, no CLI -- and
add it to `tmux-control--panes' so its `%output' (which tmux sends strictly
after this notification) streams straight in from the pane's first byte
instead of being dropped for want of a buffer.  Mark it `fed-live' so the
debounced `tmux-control--build-tiling' that follows does NOT also seed it from
`capture-pane': the live stream is already the pane's whole content, and a
seed would paint a second copy of the screenful a freshly-split pane often
dumps at once.  A window SWITCH sends `%session-window-changed', not
`%layout-change', so its pre-existing panes are not registered here and are
still seeded normally."
  (when (buffer-live-p controller)
    (with-current-buffer controller
      (when tmux-control--tiled
        (let* ((tree (tmux-control--parse-layout layout))
               (leaves (and tree (tmux-control--layout-leaves tree)))
               (meta (list :host tmux-control--host
                           :socket tmux-control--socket-name
                           :session tmux-control--session
                           :trailing tmux-control--capture-trailing-p
                           :process tmux-control--process
                           :fallback tmux-control--fallback-target)))
          (dolist (leaf leaves)
            (let ((pane (concat "%" (plist-get leaf :id))))
              (unless (assoc pane tmux-control--panes)
                (let ((buf (tmux-control--make-pane-buffer
                            pane leaf controller meta)))
                  (with-current-buffer buf
                    (setq tmux-control--pane-fed-live t))
                  (setq tmux-control--panes
                        (cons (cons pane buf) tmux-control--panes)))))))))))

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
               (cursor-visible (or (plist-get tmux-control--pane-info
                                              :cursor-visible)
                                  :unknown))
               (text (ignore-errors (tmux-control--capture-pane-screen pane))))
          (when text
            (setq tmux-control--seed-cursor cursor)
            (setq tmux-control--seed-cursor-visible cursor-visible)
            ;; Clear the scrollback (\e[3J) before painting, not just the
            ;; screen, so a reseed (e.g. after a resize) does not leave the
            ;; previous, now-reflowed frame stacked above the fresh one -- an
            ;; app on a tmux with `alternate-screen off' repaints by appending.
            (tmux-control--write-terminal
             (concat "\e[3J"
                     (tmux-control--screen-seed-sequence
                      text cursor cursor-visible)))))))))

;;; Window arrangement from the parsed layout tree.

(defun tmux-control--our-tiling-window-p (window controller)
  "Return non-nil when WINDOW belongs to CONTROLLER's single-pane or tiled view.
True for the window showing CONTROLLER itself, for a tiled pane window (it
carries the `tmux-control-pane' parameter), and for any window showing a
render buffer whose controller is CONTROLLER.  Everything else on the frame
is a foreign window -- a user's non-tmux buffer the tiling must not consume."
  (let ((b (window-buffer window)))
    (or (eq b controller)
        (window-parameter window 'tmux-control-pane)
        (eq (buffer-local-value 'tmux-control--controller b) controller))))

(defun tmux-control--tiled-region-size (frame controller)
  "Return (COLS . ROWS): the size tmux should lay CONTROLLER's panes out in.
ROWS is how many terminal rows actually fit below the tiling: FRAME's inner
pixel height less the minibuffer and one mode line, divided by the line
height.  Measuring the mode line in PIXELS is the point -- it is commonly a
hair taller than a text row (a larger mode-line face), so any fixed
`frame-text-lines' row offset over-counts and the bottom pane's last row --
a full-screen TUI's bottom border -- clips.  The grids are sized to the tmux
pane heights this size produces, and `tmux-control--tile-arrange-node'
budgets each stacked pane's mode line, so making the total match the real
body keeps every pane's grid within its window.  This is the same height the
single-pane path derives from `window-screen-lines' (the real body), so the
two paths agree.  Reduced by any foreign window sharing the frame: a
full-height neighbor steals columns, a full-width one steals rows.  Computed
from frame-level measures (stable across the split, whether called before
tiling from the controller's window or while tiled from a pane window), so
the size never disagrees with itself and never forces a spurious re-tile."
  (let* ((char-h (max 1 (frame-char-height frame)))
         (windows (window-list frame 'no-mini))
         ;; The mode line's real pixel height, read from one of our own
         ;; windows (they share the face); a text row if none is up yet.
         (ours (cl-remove-if-not
                (lambda (w) (tmux-control--our-tiling-window-p w controller))
                windows))
         (ml-h (if ours (window-mode-line-height (car ours)) char-h))
         (mini-h (window-pixel-height (minibuffer-window frame)))
         ;; Full non-minibuffer height in rows: the threshold for "full-height
         ;; side column" (steals columns) vs "top/bottom band" (steals rows).
         ;; Classify against the FULL height, not the smaller body-row budget
         ;; below -- a tall band whose total height reached the body budget
         ;; would otherwise be misread as a full-height column.
         (usable-rows (- (frame-text-lines frame)
                         (window-total-height (minibuffer-window frame))))
         (cols (frame-text-cols frame))
         (rows (max 1 (floor (- (frame-inner-height frame) mini-h ml-h)
                             char-h))))
    (dolist (w windows)
      (unless (tmux-control--our-tiling-window-p w controller)
        (if (>= (window-total-height w) usable-rows)
            (setq cols (- cols (window-total-width w)))     ; a side column
          (setq rows (- rows (window-total-height w))))))    ; a top/bottom band
    (cons (max 1 cols) (max 1 rows))))

(defun tmux-control--collapse-tile-windows (keep)
  "Delete this tiling's own windows on KEEP's frame, except KEEP.
A tiling is always grown by splitting a single window, so every pane window
is a descendant of that one window and carries the `tmux-control-pane'
parameter `tmux-control--tile-arrange-node' stamps on it.  Deleting those
reclaims the tiling's rectangle back into KEEP without disturbing any
foreign (non-tmux) window sharing the frame -- the whole point, so switching
windows or untiling no longer wipes a user's other buffer.  When the tiling
owned the whole frame this deletes every other window, exactly as the old
`delete-other-windows' did.  KEEP loses its own pane marker so it reads as a
plain window afterwards."
  (when (window-live-p keep)
    (let ((frame (window-frame keep)))
      (dolist (w (window-list frame 'no-mini))
        (when (and (window-live-p w)
                   (not (eq w keep))
                   (window-parameter w 'tmux-control-pane)
                   (> (length (window-list frame 'no-mini)) 1))
          (ignore-errors (delete-window w)))))
    (set-window-parameter keep 'tmux-control-pane nil)))

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
  "Tile CONTROLLER's window region to match layout TREE, showing PANES buffers.
Subdivides the controller's own window (collapsing any prior tiling windows
back into it first), so a non-tmux window sharing the frame is preserved
rather than wiped; when the controller already fills the frame the tiling
fills the frame as before.  Returns an alist (PANE-ID . WINDOW), or nil when
the windows could not be built."
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
          ;; Reclaim only this tiling's own windows back into ROOT, leaving a
          ;; non-tmux window sharing the frame intact -- tiling devotes the
          ;; controller's region, not the whole frame.
          (tmux-control--collapse-tile-windows root)
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
            ;; Resolve each layout leaf to its real pane id.  A leaf's id in
            ;; the window-layout string IS the pane number (%N), so match on
            ;; that directly -- robust even when `pane_top'/`pane_left' are
            ;; offset from the layout coordinates (e.g. tmux `pane-border-status'
            ;; adds a title row, which some tools like pi-agents-tmux enable).
            ;; Fall back to a top-left coordinate match only if the id is unknown.
            (let ((unmatched nil))
              (dolist (leaf leaves)
                (let ((hit (or (assoc (concat "%" (plist-get leaf :id)) geometry)
                               (cl-find-if
                                (lambda (g)
                                  (and (= (plist-get (cdr g) :left)
                                          (plist-get leaf :x))
                                       (= (plist-get (cdr g) :top)
                                          (plist-get leaf :y))))
                                geometry))))
                  (if hit
                      (progn (plist-put leaf :pane (car hit))
                             (plist-put leaf :info (cdr hit)))
                    (setq unmatched t))))
              ;; A leaf with no pane match means the layout and pane list we
              ;; read disagree (a rare transient).  Rather than tile a partial
              ;; mapping that leaves a pane blank, try again shortly -- but only
              ;; a few times, so a persistent mismatch can't reschedule forever.
              (if unmatched
                  (when (< (cl-incf tmux-control--unmatched-retries) 5)
                    (tmux-control--schedule-retile controller))
                (setq tmux-control--unmatched-retries 0)
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
                              ;; A fed-live pane (registered the moment it
                              ;; appeared) is not seeded on this first placement
                              ;; -- its %output is streaming the whole content,
                              ;; so a capture seed would double-paint.  Still
                              ;; resize, so Eat reflows.
                              (unless tmux-control--pane-fed-live
                                (setq seed t))
                              (eat-term-resize tmux-control--terminal w h))))
                        ;; The fed-live skip is for the opening placement only.
                        ;; Clear it now so a LATER resize reseeds normally: by
                        ;; then the pane is quiescent (no seed/stream race), and
                        ;; Eat's own reflow can drift from tmux's grid on a
                        ;; shrink, so a capture seed keeps it cell-exact.
                        (setq tmux-control--pane-fed-live nil))
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
                  ;; Point every pane window at its terminal cursor, so a
                  ;; non-selected pane draws its hollow cursor where tmux has
                  ;; it (like iTerm) instead of at point-min.  A freshly
                  ;; arranged window starts at the buffer's point, and Eat's
                  ;; scroll-follow sync only catches a window whose point
                  ;; already sits on the cursor -- which a just-built or
                  ;; just-reseeded pane window does not -- so do it explicitly.
                  (dolist (pw pane-windows)
                    (let ((win (cdr pw))
                          (buf (cdr (assoc (car pw) new-panes))))
                      (when (and (window-live-p win) (buffer-live-p buf))
                        (let ((term (buffer-local-value
                                     'tmux-control--terminal buf)))
                          (when (and term (eat-term-live-p term))
                            (set-window-point
                             win (eat-term-display-cursor term)))))))
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
              ;; Collapse only the tiling's own windows back into WIN; a
              ;; non-tmux window sharing the frame survives untiling.  With no
              ;; foreign window this reclaims the whole frame as before.
              (tmux-control--collapse-tile-windows win)
              (set-window-buffer win controller))))
        (dolist (np panes)
          (when (buffer-live-p (cdr np))
            (let ((kill-buffer-query-functions nil)
                  (tmux-control--killing-pane t))
              (kill-buffer (cdr np)))))))))

;;; Interactive entry points.

(defun tmux-control-tile ()
  "Tile every pane of the current tmux window into Emacs windows.
Each pane is rendered live in its own buffer, arranged to match tmux's
own layout -- the iTerm \"show every pane\" view -- which is handy for a
split-pane window such as a Claude Code agent team.  Tiles within the
controller's own window region, so a non-tmux window sharing the frame is
left alone; when the controller fills the frame the tiling fills it.
`tmux-control-untile' (or \\`C-c C-t') returns to the single-pane view."
  (interactive)
  (tmux-control--ensure-live)
  (when tmux-control--controller
    (user-error "This is a tiled pane; use C-c C-t to untile"))
  (when tmux-control--tiled
    (user-error "Already tiling this session"))
  (let ((size (tmux-control--tiled-region-size (selected-frame) (current-buffer))))
    ;; Ask tmux to size the window to the Emacs area we tile into -- the frame
    ;; less any non-tmux window sharing it -- so the resulting %layout-change
    ;; re-tiles to the exact pane sizes.
    (setq tmux-control--tiled-client-size size)
    (tmux-control--send-command
     (format "refresh-client -C %dx%d" (car size) (cdr size)))
    (tmux-control--build-tiling (current-buffer))))

(defun tmux-control--reassert-tiling-size (controller frame)
  "Ask tmux to match CONTROLLER's tiling area on FRAME when it has resized.
Recomputes the tiling region (the frame less any foreign window sharing it,
the same measure tiling started from) and only acts when it actually
changed, so it ignores the internal window splits a re-tile makes -- those
keep the region size -- and so it never disagrees with the tile-time size."
  (when (and (buffer-live-p controller)
             (buffer-local-value 'tmux-control--tiled controller)
             (process-live-p
              (buffer-local-value 'tmux-control--process controller)))
    (with-current-buffer controller
      (let ((size (tmux-control--tiled-region-size frame controller)))
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
      (tmux-control--seed-pane-buffer-sync controller)
      ;; The tab bar's window/activity state was not tracked while tiled;
      ;; refresh it for the returning single-pane view.
      (when tmux-control-window-tab-bar
        (tmux-control--quiet-activity)
        (tmux-control--refresh-windows)
        (tmux-control--refresh-pane-window-map)))))

(defun tmux-control-toggle-tiling ()
  "Toggle between the tiled multi-pane view and the single-pane view.
Bound to \\`C-c C-t'."
  (interactive)
  (if (or tmux-control--controller tmux-control--tiled)
      (tmux-control-untile)
    (tmux-control-tile)))

(provide 'tmux-control)

;;; tmux-control.el ends here
