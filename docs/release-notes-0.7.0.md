# tmux-control 0.7.0

This release adds a public API for packages built on tmux-control, so they no
longer need its internal functions and variables.

## Public API

- `tmux-control-connect-or-switch`, `tmux-control-send-command` and
  `tmux-control-query` connect to a session and talk to tmux over its
  connection.
- `tmux-control-tiled-p`, `tmux-control-buffer-host`,
  `tmux-control-buffer-socket-name`, `tmux-control-buffer-session`,
  `tmux-control-active-pane` and `tmux-control-window-id` describe the current
  buffer.
- `tmux-control-send-command` and `tmux-control-query` accept exactly one tmux
  command. They refuse blank and comment-only lines, more than one line, and
  an unquoted `;`, `{` or `}`, any of which would detach the client or
  misalign later replies.
- In a tiled pane buffer, `tmux-control-window-id` returns the window holding
  the pane.
- The internal names these functions wrap still work.

See "For package authors" in the README for the full list.
