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
- `C-c C-l` sends form-feed to the pane, which asks many TUIs to repaint.

## Status

This is a first MVP.  It can attach to tmux, render `%output` through Eat, send
keyboard input back with `send-keys -H`, and resize the tmux client.  Mouse
handling, robust command correlation, paste chunking, and initial scrollback
seeding still need work.
