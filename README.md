# tmux-control

`tmux-control` turns Emacs into a **control-mode client for a tmux pane** —
the [iTerm2 tmux-integration](https://iterm2.com/documentation-tmux-integration.html)
idea, but in Emacs.

Unlike running tmux inside a terminal buffer (`vterm`, `eat`, `ansi-term`),
where the session dies with the Emacs frame, `tmux-control` speaks tmux
control mode (`tmux -C`) to a **persistent, possibly remote** tmux server
over SSH and renders the live pane through [Eat](https://codeberg.org/akib/emacs-eat).
The tmux session outlives Emacs: detach, restart, or reconnect from another
machine and the pane is still there. Eat handles rendering, input,
scrollback, search, and copy.

It is experimental — a first MVP (see [Status](#status)).

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

The session prompt completes over the sessions that already exist on the
chosen host and socket.  Selecting one attaches to it; typing a new name
creates that session (tmux attaches if it exists, otherwise creates it).

### Window and session management

These commands act on the connected session (no key bindings by default):

- `M-x tmux-control-select-window` switches the live view to another window
  in the session, with completion over the session's windows.
- `M-x tmux-control-new-window` creates a window (optionally named) and
  switches to it.
- `M-x tmux-control-rename-window` renames a window, with completion over
  the session's windows.
- `M-x tmux-control-kill-window` removes a window after confirmation, with
  completion over the session's windows.

Switching, creating, or removing a window changes the session's active
window, so any other client attached to the same session follows along.

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

## Development

Run the test suite (pure-logic unit tests, no tmux server required) with:

```sh
make test
```

`eat` is a hard dependency, so the runner needs it on the load path.  It
defaults to the straight.el build path; override `EAT_DIR` if yours lives
elsewhere:

```sh
make test EAT_DIR=/path/to/eat
```

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).

