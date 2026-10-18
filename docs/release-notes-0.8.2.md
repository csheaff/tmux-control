# tmux-control 0.8.2

- Clicks keep working after a terminal misses a mouse release. A press in a
  program that takes the mouse made Eat send every later click in Emacs to
  the terminal if the release never reached it: while tmux wasn't replying,
  when the window showed another buffer by the release, or when a question
  read it. Now the press is let go of once its release is handled, and a
  press outside any terminal goes to its own binding.
- A split view's pane starts at its screen's top when a window
  configuration brings it back, as perspective.el's `persp-switch` does. It
  showed a line or more of scrollback until the pane's next output.
- Two docstrings start with a whole sentence, as checkdoc asks.
