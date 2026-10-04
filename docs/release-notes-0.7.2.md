# tmux-control 0.7.2

- `unload-feature` now leaves Emacs as it was: `tmux-control-unload-function`
  removes the advice on Eat and on the pager command, the global resize hooks,
  the Evil initial state, and `tmux-control-idle-gc-mode`'s hooks and timer.
  Close tmux-control buffers before unloading.
- The two `window-size-change-functions` hooks that follow resizes of
  scrollback pagers and tiled views are added by the first tmux-control buffer
  rather than when the package loads.
