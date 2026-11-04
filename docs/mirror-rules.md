# What Emacs must agree with tmux on

tmux-control keeps a copy of part of tmux's state: the session's windows, which
one is current, the panes they show, and the server's sessions. Tabs, buffers
and keystrokes all act on that copy, so when it is wrong, typing goes to the
wrong place. These rules say what must be true once tmux has answered everything
it has been asked. `test/tmux-control-mirror.el` checks each one by asking tmux
over a connection of its own, at the quiet points of a random run.

Each rule compares Emacs with tmux, never with what Emacs expected. The rules
hold for each session this Emacs is connected to.

| Rule | What must be true |
|---|---|
| `windows` | The cached window list names the session's windows in tmux's order, with tmux's ids, indexes and names. |
| `current` | One window is marked current, and it is tmux's current window. |
| `view` | Every Emacs window showing the session shows the buffer of tmux's current window. |
| `buffers` | No live buffer is left for a window that has left the session, and no window has two. With `tmux-control-window-buffers` set to `all`, every window has a buffer. |
| `typing` | A window's buffer sends keys to tmux's active pane in that window. |
| `names` | With `tmux-control-window-buffer-names` set to `tab`, a window's buffer is named as its tab reads. |
| `sessions` | The cached session list is tmux's, in tmux's order. |
| `last` | When the client predicts where `last-window` goes, tmux's last window is the same one. Not knowing is fine. |
| `size` | A window's buffer is the size of tmux's active pane in that window. |
| `screen` | The shown buffer's screen matches tmux's `capture-pane`. |
| `settled` | Nothing is left waiting: no command unanswered, no switch unconfirmed, no re-tile on its way. |
| `tabs` | The tab drawn as current is the window on screen. |
| `fit` | A shown window with one pane is the size of its Emacs window. |
| `prompt` | A prompt closes when answered or cancelled, and its window shows the prompt. |
| `connection` | A session that still exists keeps its connection. |
| `errors` | No Lisp error reached a process filter, sentinel or timer. |

A disagreement counts only if it lasts. The check first waits for a round trip
through the control connection, then retries for a few seconds, because timers
and refreshes may still be in flight at any instant.

## Known exceptions

- Two Emacs windows showing different windows of a session, side by side, are
  left as you arranged them, so `view` doesn't hold for them.
- `move-window -r` renumbers windows and `swap-window` exchanges them, and tmux
  3.6a says nothing to control clients about either. Tabs and `tab` buffer names
  keep the old numbers until the session's windows next change. The first is
  documented in `tmux-control-window-buffer-names`.

## Reading a failure

Label every failure with one of these before fixing it:

- **Wrong belief**: the code assumes tmux does something it doesn't.
- **Wrong code**: the code knows what tmux does, and handles it wrongly.
- **View only**: the copy is right, and what is shown from it is wrong.
