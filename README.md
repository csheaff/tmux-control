# tmux-control

`tmux-control` is an experimental Emacs client for a tmux pane.  It uses tmux
control mode for the persistent process/session and Eat for terminal rendering,
input, scrollback, search, and copy behavior inside Emacs.

## Usage

```elisp
(use-package tmux-control
  :straight (:local-repo "~/code/tmux-control" :type git)
  :custom
  (tmux-control-default-host "dev")
  (tmux-control-default-socket-name "main")
  (tmux-control-default-session "emacs"))
```

Then run:

```elisp
M-x tmux-control-connect
```

Useful bindings:

- `C-c C-k` disconnects the Emacs control client.
- `C-c C-l` refreshes the live view from tmux's current visible screen without
  sending input to the pane.
- `C-c C-e` switches the current buffer into a normal Emacs scrollback view
  captured from tmux.  In that view, use normal Emacs movement/search/copy,
  `g` to refresh, and `q`, `l`, `RET`, `C-c C-e`, or
  `M-x eat-semi-char-mode` to return to the live pane.

Line numbers are disabled locally in live and scrollback buffers.

Scrollback defaults to joining soft-wrapped tmux lines and compacting repeated
TUI redraw chunks.  These are heuristics for panes that were run with tmux
`alternate-screen` disabled.  Disable compaction with:

```elisp
(setq tmux-control-compact-scrollback nil)
```

Disable wrapped-line joining with:

```elisp
(setq tmux-control-scrollback-join-wrapped-lines nil)
```

## Status

This is a first MVP.  It can attach to tmux, seed the live terminal from
`capture-pane`, open a compacted same-buffer Emacs scrollback view, render live
`%output` through Eat, send keyboard input back with `send-keys -H`, and resize
the tmux client.  Mouse handling, robust paste chunking, and broader edge-case
hardening still need work.
