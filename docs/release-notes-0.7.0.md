# tmux-control 0.7.0

This release adds a public API for packages built on tmux-control, so they no
longer need its internal functions and variables. It also collects the
terminal, recovery and modal-editing fixes made since 0.6.0.

## Public API

- `tmux-control-connect-or-switch`, `tmux-control-send-command` and
  `tmux-control-query` connect to a session and talk to tmux over its
  connection.
- `tmux-control-tiled-p`, `tmux-control-buffer-host`,
  `tmux-control-buffer-socket-name`, `tmux-control-buffer-session`,
  `tmux-control-active-pane` and `tmux-control-window-id` describe the current
  buffer.
- `tmux-control-send-command` and `tmux-control-query` accept exactly one tmux
  command, starting with the bare command name. They refuse blank and
  comment-only lines, variable assignments, NUL bytes, more than one line, and
  an unquoted `;`, `{` or `}`, any of which would detach the client or
  misalign later replies.
- `tmux-control-window-id` also works in tiled pane buffers and in session
  buffers without `tmux-control-window-buffers`.
- The internal names these functions wrap still work.

See "For package authors" in the README for the full list.

## Connections and terminal fidelity

- Add named connection bookmarks using native Emacs bookmarks and a copyable
  `tmux-control-diagnostics` report with asynchronous live server details.
- Separate connection identity by host, socket, and session; controller renames
  no longer break reuse or render-buffer cleanup.
- Retain visited tiled pane history through window switches, resizing,
  repaints, and untile/retile; cached panes keep streaming while hidden.
- Restore tiling on reconnect while preserving neighboring code windows/focus.
- Detect incomplete command replies, refuse additional input on an overdue
  connection, and report unacknowledged input without replaying it on recovery.
- Refresh pane cursor and terminal modes during in-band repaint/flow-control
  recovery; ignore stale seeds from older connections or superseded requests.
- Preserve canonically composable combining accents that Eat 0.9.4 omits.
  Complex graphemes without a single-cell composition remain an Eat limitation.

## Scrollback and the live buffer

- Scrolling back shows a clickable `↑ 120 lines` indicator; clicking it
  returns that window to live output.
- `tmux-control-clear-scrollback` (`C-c M-o`) clears both the Emacs copy of a
  pane's history and tmux's, for example after a full-screen program repaints
  at a new size and leaves its old frame in scrollback.
- The live terminal buffer is read-only, so an editing command can no longer
  change the text Eat uses as its model of the pane. Typing still reaches the
  pane, and input methods keep working.
- `tmux-control-adopt-window-size` clears stale sizing warnings and takes
  sizing back from another attached client.
- Every header line redraws when the window list changes.

## Modal editing and GUI frames

- Full-screen programs no longer lose rows or columns in GUI frames:
  alternate-screen scrolling, tmux's separator column in horizontal tiles, and
  stale horizontal scrolling are handled.
- In raw mode, keys go to the pane before modal-editing maps; entering raw mode
  clears xah-fly-keys' command map, and Option-Return returns to semi-char
  mode.
- Evil users: buffers start in `tmux-control-evil-state`, `insert` by
  default, so keys reach the pane instead of acting as Evil commands.
- The README shows how to send ESC to the pane under a modal package.

## Installation

- The README shows `use-package :vc` (Emacs 30) and `package-vc-install`
  (Emacs 29) alongside straight.el.
- `.elpaignore` keeps the test helpers out of package installs, which had
  printed load errors during `package-vc` installation.
