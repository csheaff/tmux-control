# tmux-control 0.7.1

`tmux-control-kill-pane` moves from `C-c x` to `C-c C-x`. Emacs reserves `C-c`
followed by a letter for users' own bindings, and MELPA's checks reject
packages that bind those keys. To keep the old key, add it to your
configuration:

```elisp
(with-eval-after-load 'tmux-control
  (keymap-set tmux-control-mode-map "C-c x" #'tmux-control-kill-pane))
```
