# tmux-control 0.8.0

## Names

- The mode line names the host and tmux window, such as "dev › build", in
  place of the buffer name, and the terminal's mode reads "tmux".
  `tmux-control-mode-line-window-name` keeps the buffer name instead.
- Buffers are named "\*tmux HOST:SESSION\*", "local" for the local server.
  Update anything in your configuration that matches the old names.

## Keys and links

- Shift+Return and Option+Return reach the program as tmux's own S-Enter and
  M-Enter on tmux 3.5 and later, so they start a new line in Claude Code's
  prompt rather than sending it. Older servers get the bytes as before.
- A lone ESC stays whole: the M-RET override binding is gone.
- `C-c C-u` opens a URL shown on the screen. Links that programs mark with
  OSC 8 open with a click or `C-c C-u`, in the live view and in scrollback.
- `C-c C-o` moves to the next pane's window in a tiled view.

## Split windows

- A split window keeps its tabs: the header line sits over the top-left pane,
  and tmux lays the panes out one row shorter to make room. Each pane keeps
  the mode line other windows have, naming its host, window and pane.
- When a split closes, the view goes back to one pane, with its tabs.
- A new tiled view keeps you on the pane you were looking at, tmux's active
  one, so `C-c |` focuses the new pane, as tmux does.
- Switching sessions replaces all of a split session's panes, and returning
  to it splits it again.

## What you see

- Panes render as tmux does where Eat's emulation departs from it, checked
  against tmux by a differential test (`make test-vt-oracle`).
  `tmux-control-correct-emulation` turns the corrections off.
- The view repaints from tmux after any change in size, so it stays on tmux's
  screen as a pane gets shorter, taller, narrower or wider, and long lines
  wrap where tmux wraps them.
- A repainted screen starts on a line of its own, which fixes a garbled first
  row after returning to a split session.
- No-break spaces show as spaces.

## Speed

- Keystrokes are answered sooner, panes that keep scrolling stay fast, and a
  settled window is left alone when output arrives.
- Idle collection (`tmux-control-idle-gc-mode`) checks from idle timers
  rather than 20 times a second, and terminal buffers keep no undo.
- A window showing a window buffer resizes tmux when it changes size.

## Diagnostics

- `tmux-control-pause-log-mode` notes each time Emacs stops responding, with
  what it was doing: a command, tmux output, a timer, or redisplay. It also
  notes the time spent collecting garbage. `tmux-control-diagnostics` lists
  the latest notes.

## For packages

- `tmux-control-switch-session-functions` lets a package show a session its
  own way when you switch to it from a view, as Roost does to open the task.
  tmux ending a connection is said once.
