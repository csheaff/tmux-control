# tmux-control 0.8.1

- After `C-c C-r` reconnects a view in place, tmux is sized to the window
  with its header line, so the view's top row stays in sight. tmux kept one
  row more than the window showed until the window next changed.
- A connect's quiet period for background activity is no longer cut short by
  the resize it makes, so a slow first repaint doesn't flag windows.
