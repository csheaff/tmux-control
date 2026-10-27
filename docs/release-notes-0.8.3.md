# tmux-control 0.8.3

## Speed

- A terminal that keeps receiving output is redrawn at most 30 times a
  second, and all such terminals are redrawn together. Emacs pays for each
  redraw of a frame, so drawing every chunk of a fast stream kept it busy:
  four terminals each printing 200 lines a second held Emacs at 75–100% of
  a core on a Mac, and now take 35–43%. The first output after a quiet
  spell is drawn at once, and so is everything for half a second after you
  type into the terminal, so typing feels the same. Set
  `tmux-control-redisplay-interval` to change the pace, or to nil to draw
  every chunk as it comes.
- A pane whose program stopped at its last column no longer repaints from
  tmux three times over after a resize or a visit. Over SSH each repaint
  cost a round trip.

## Window buffers

- `tmux-control-window-buffers` takes `all`: every window of the session
  gets its buffer as soon as tmux-control learns of it, and the buffer keeps
  up with its window whether or not it is shown.
- `tmux-control-window-buffer-names` set to `tab` names window buffers as
  their tabs read, such as "\*tmux dev:work 1:bash\*", and renames them when
  tmux renames or moves a window. The default, `id`, keeps
  "\*tmux dev:work @5\*".
- A window's buffer takes the size of the pane that becomes active. Closing
  a split's other pane left the buffer at the split's height, blank above
  its last few rows.

## Sizes and tiled views

- A new connection asks tmux for its size once its window has settled. A
  package that changes the window right after connecting, as Roost does when
  it docks its task panel, had tmux rewrap the pane at two widths, and the
  pane showed a long line from its second row.
- Tiled panes keep their screens in view through a resize. They showed a
  row or more of history above the screen until the next repaint.
- A tiled view beside a full-height window, with a band such as a menu
  across the frame's bottom, is sized by its columns. tmux was asked for
  one row.
- Panes stacked in a tiled view fit their rows when the mode line is taller
  than a line of text, as modus themes and doom-modeline make it. They came
  out a few pixels short and scrolled their screen part way out of view.
- The rightmost pane of a tiled view shows its last column rather than a
  `$`.

## Dropped connections

- When a connection drops, its screen stays in view with the note on the
  line under it. The window used to scroll down to the note, past blank
  rows. Notes no longer move point.
- A click on a dead terminal says in the echo area that `C-c C-r`
  reconnects. It asked whether to reconnect for each press and each
  release. Typing still asks.

## For packages

- `tmux-control-window-buffer-functions` is called with each new window
  buffer once it knows its connection and window. Making a buffer doesn't
  display it, so this is where a package can, for example, add it to a
  perspective.

## Tests and docs

- The VT oracle (`make test-vt-oracle`) measures tab stops and grapheme
  cells as tmux does, no longer echoes query replies onto the screen it
  compares, and has 35 new cases, among them grapheme clusters and tmux's
  own quirks.
- The README and guide show the current look, and the README says to
  require 0.8.0 for `tmux-control-switch-session-functions`.
