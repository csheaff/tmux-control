# tmux-control 0.8.4

This is the last release. tmux-control is no longer developed, and its
repository is archived. It still works with Eat 0.9.4 and tmux 3.x. The
README names an alternative for Ghostel users.

## Tall rows

- A terminal keeps its last rows in view when rows drawn in a taller
  fallback font make its screen taller than its window. Claude Code keeps
  its cursor on an input row above its status lines, and those lines were
  cut off at the window's bottom. Now old output at the top gives way
  instead. Tiled panes and alternate screens still show from their first
  row, so there what does not fit still runs off the bottom.
