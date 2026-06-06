# tmux-control — guide

The full command/key reference, the tiled view, scrollback tuning, and the
test suites. See the [README](../README.md) for the overview, requirements,
and install. Connect with `M-x tmux-control-connect` (the session prompt
completes over existing sessions on the chosen host/socket; a new name creates
that session).

## Window and session management

These commands act on the connected session (`C-c C-n`/`C-c C-p`/`C-c C-s` are
bound in the live buffer; the rest are `M-x`, bind them to taste):

- `M-x tmux-control-select-window` switches the live view to another window.
  By default it opens a two-pane chooser with a live preview of the
  highlighted window (like tmux's `choose-tree`): move with the arrow keys,
  `n`/`p`, or the mouse, `RET` or click to select, `q`/`C-g` to cancel.  Its
  keys take precedence over modal packages (`xah-fly-keys`, `evil`).  Fall back
  to plain completion with `(setq tmux-control-window-preview nil)`.
- `C-c C-n` (`tmux-control-next-window`) and `C-c C-p`
  (`tmux-control-previous-window`) flip to the next or previous window in the
  session, wrapping around — like a terminal's next/previous-tab keys, with no
  menu and without rearranging your Emacs windows (a code buffer beside the
  live view stays put).  `M-x tmux-control-last-window` toggles back to the
  window you came from.  These delegate to tmux's own
  `next-window`/`previous-window`/`last-window`, so they follow the session's
  window order and any other attached client stays in sync.
- `M-x tmux-control-new-window` creates a window (optionally named) and
  switches to it.
- `M-x tmux-control-rename-window` renames a window, with completion over
  the session's windows.
- `M-x tmux-control-kill-window` removes a window after confirmation, with
  completion over the session's windows.

Switching, creating, or removing a window changes the session's active
window, so any other client attached to the same session follows along.

### Switching sessions

A host/socket usually runs **several tmux sessions** (one per project, say).
`tmux-control` gives each its own buffer and control connection — so each keeps
its own scrollback, tab bar, and activity state — and lets you flip between them
like tabs, **in place** in the current window:

- `C-c C-s` (`tmux-control-select-session`) prompts for a session on the same
  host and socket, completing over the ones that exist there, and switches the
  view to it.  Picking a session that is already connected reuses its live
  buffer (no respawn); picking one that exists in tmux but isn't shown yet
  connects it on the spot.  The prompt requires a match, so a typo can't
  accidentally spawn a session — to *create* one, use `M-x
  tmux-control-connect` (which attaches an existing session or creates a new
  one).
- `M-x tmux-control-next-session` and `M-x tmux-control-previous-session` step
  to the next/previous session in tmux's list order, wrapping around — a quick
  way to cycle a small set without the prompt.

Switching replaces the session in the **selected window** (it does not split the
frame or rearrange your other Emacs windows), so a code buffer beside the live
view stays put.  Because every session is its own buffer, you can also just keep
several open and switch with the ordinary `C-x b` / `switch-to-buffer`; the
session commands are the tmux-aware shortcut.

### The flock view: every session at once (experimental)

`C-c C-f` (`tmux-control-toggle-flock`) tiles **every connected session** into a
grid — one live cell each — for a dashboard of all your projects (or agents) at
a glance.  This is cheap precisely because of the design above: each session is
already its own buffer with its own always-live connection (it streams whether
or not it is on screen), so the flock view is just an Emacs window arrangement
over buffers that are already live — no extra connections.

- Each cell is an ordinary session buffer: its mode line and window tab bar
  label it, every cell updates independently and live, and you can read, switch
  windows in, or type into any session without leaving the overview.
- Each session is sized to its cell while flocked (like the tiled pane view);
  `C-c C-f` again — or `M-x tmux-control-unflock` — returns to the single
  session under point, resized to the full window.
- By default it tiles the sessions you have already connected
  (`tmux-control-connect` / `tmux-control-select-session`).  With a prefix
  argument — `C-u C-c C-f` — it first connects *every* session on the host and
  socket, so one keystroke gives you the whole host.

Like the tiled view it takes the **whole frame** and resizes each session to
its cell, so a session also attached elsewhere (another client) follows tmux's
`window-size` rule.  Experimental.

### The window tab bar

In the single-pane view, a **tab bar** in the header line lists the session's
windows like iTerm's tmux tabs — `index:name` for each, the current one
highlighted.  It is the at-a-glance map of the session: click a tab to switch
to it, and watch a **dot** appear on any *background* window whose pane
produces output while you are looking elsewhere — the "which window wants
me?" signal.  Visiting a window clears its dot; a window that rings its bell
shows a `!`.

The dot reflects genuine background output: the prompt/redraw burst that a
connect, window switch, or frame resize provokes in every pane is deliberately
*not* counted, so an idle session does not light up.  The bar costs one
terminal row (tmux is sized to match, so nothing clips) and is hidden in the
tiled view, where each pane already carries its own label.  Turn it off with:

```elisp
(setq tmux-control-window-tab-bar nil)
```

## Panes

A tmux window can hold several panes at once (a split layout).  By default
`tmux-control` mirrors **one pane at a time** — the window's active pane,
rendered cleanly (output from the other panes is not interleaved into the
view).  Move between panes with:

- `C-c C-o` (`tmux-control-other-pane`) — cycle to the next pane.
- `M-x tmux-control-select-pane` — jump to a pane by name, completing over
  the window's panes (each labelled by its index, command, and title).

Switching the pane sets the window's active pane, so other clients follow
along and the live view repaints on the chosen pane.

## Tiling

`C-c C-t` (`tmux-control-toggle-tiling`) flips between the single-pane view
and a **tiled** view that renders *every* pane of the current window at
once, each in its own buffer, with the Emacs windows split to match tmux's
own layout — the iTerm "show every pane" view.

![The same tmux session in iTerm2 and in Emacs via tmux-control](images/iterm-vs-tmux-control.png)

*The same live tmux session — a multi-pane window — rendered by iTerm2's
native tmux integration (left) and by the tiled view in Emacs (right):
cell-for-cell the same.*

In the tiled view:

- Every pane updates live and independently; output is routed per pane, so
  nothing is interleaved.
- Type into a pane to send input to it; selecting a pane's Emacs
  window makes it tmux's active pane too (other clients follow).
- Splitting, resizing, or closing a pane in tmux re-tiles automatically,
  and the mode line labels each pane by its id, command, and title.
- Resizing the Emacs frame re-divides the tmux window to match, so the
  panes re-fit instead of clipping.
- Each pane is a normal `tmux-control` buffer, so `C-c C-e` scrollback and
  the usual movement/search/copy work in any of them.

For a session with **several multi-pane windows**, tile one window, then
switch windows (`M-x tmux-control-select-window`) to bring another into the
tiled view; each window tiles its own panes, like iTerm's per-window tabs.
`C-c C-t` again (or `M-x tmux-control-untile`) returns to the single-pane
view on the currently active pane.

Tiling is **experimental** and devotes the whole frame to the session
(`delete-other-windows`).  Each pane's terminal is sized to tmux's grid, so the
rendering matches tmux cell-for-cell, and the Emacs windows split to match.
Re-tiles are debounced and their tmux queries batched, so a busy remote session
is not stalled by layout changes.

Known limitations of the tiled view (none of which affect the single-pane
view):

- It takes the **whole frame** (`delete-other-windows`); there is no
  tile-within-a-region mode.
- Switching windows while tiled rebuilds the new window's pane buffers, so a
  window's Emacs-side scrollback is not kept across a switch.
- A vertical stack spends one row on an Emacs mode line where tmux spends it on
  a pane border, so a stacked pane can sit one row short — but content is never
  clipped.

## Key bindings

- `C-c C-k` disconnects the Emacs control client.
- `C-c C-l` refreshes the live view from tmux's current visible screen without
  sending input to the pane.
- `C-c C-e` opens a normal Emacs scrollback view of the pane (movement/search/
  copy, `g` to refresh, `q`/`RET`/`C-c C-e` to return).  Typing an ordinary
  character also returns to the live pane and forwards that key, so you can
  just start your next command.  (For modal users this fires only on
  self-inserting keys, so command-mode navigation in the read-only buffer is
  preserved.)
- Scrolling up with the mouse wheel also enters the scrollback view (while the
  pane shows its normal screen); a full-screen app that genuinely owns the
  alternate screen keeps its own wheel scrolling instead.  Disable with
  `(setq tmux-control-wheel-enters-scrollback nil)`.

Line numbers are disabled locally in live and scrollback buffers.

## Files are local

A tmux-control buffer is a local Emacs buffer that *renders* a remote pane;
it is not a remote filesystem context.  Its `default-directory` stays local
and the package does no directory tracking, so `find-file`, `dired`,
`M-x compile`, and similar commands operate on the machine running Emacs —
not on the remote host.  To edit a file you see in a remote pane, open it
explicitly over TRAMP, e.g. `C-x C-f /ssh:dev:~/path/to/file`.

## Scrollback

Scrollback joins soft-wrapped tmux lines by default; disable that with:

```elisp
(setq tmux-control-scrollback-join-wrapped-lines nil)
```

### Compacting repeated TUI redraws

Some TUIs repaint by reprinting their whole screen instead of using the
alternate screen — common when tmux runs with `alternate-screen off`, which
keeps full-screen apps on the normal screen so their history is preserved.
Each repaint is then appended to the pane history, so scrolling back would
otherwise show the same screen many times over.

`tmux-control` collapses those repeats **automatically**: it detects the
repeated frame in the captured history and shows it once, followed by whatever
changed between repaints (a spinner, a token count, an evolving prompt), so you
see the progression instead of dozens of copies.  It is conservative — with no
repeating frame the text is left untouched (plain scrollback is verbatim);
collapsing a repeat trims trailing whitespace from the surrounding lines.  Turn
it off with:

```elisp
(setq tmux-control-compact-scrollback nil)
```

For a particular TUI you can fine-tune the result: pin the frame boundary with
`tmux-control-scrollback-frame-start-regexp` (when auto-detection picks a poor
line — say a busy app whose very top line changes every frame) and drop
volatile per-frame "chrome" (status bars, rules, an evolving prompt) with
`tmux-control-scrollback-chrome-regexps` for an even tighter collapse.  For
example, to pin the frame to a panel whose top is a box-drawing border and
drop a couple of volatile per-frame lines:

```elisp
(setq tmux-control-scrollback-frame-start-regexp "\\`\\s-*╭"  ; the panel's top border
      tmux-control-scrollback-chrome-regexps
      '("\\`[─━]\\{10,\\}\\'" "\\`❯\\'"))            ; a full-width rule, a bare prompt
```

## High-volume output (flow control)

Live `%output` is rendered in batches (one repaint per process-filter chunk),
so a flood — `cat` on a large file, a noisy build, `yes` — streams without
freezing Emacs.  The view still replays every line, so a very large burst
takes a while to drain.

For an upper bound on that, enable tmux's control-mode flow control:

```elisp
(setq tmux-control-pause-after 1)  ;; seconds behind before tmux pauses
```

When the output buffered for this client falls more than that many seconds
behind, tmux pauses the pane; the client reseeds from the current screen and
resumes, so the view jumps to the latest state instead of replaying the
backlog.  It engages only on a genuinely **low-bandwidth** link — Emacs reads
the socket eagerly, so a fast client (even a high-latency-but-fat-pipe SSH one)
keeps up and never triggers it.  Off by default; needs tmux 3.2+.

## Development

Run the pure-logic unit tests (no tmux server required):

```sh
make test
```

`eat` is a hard dependency, so the runner needs it on the load path.  It
defaults to the straight.el build path; override `EAT_DIR` if yours lives
elsewhere:

```sh
make test EAT_DIR=/path/to/eat
```

A **live integration suite** asserts render fidelity — that what tmux-control
paints into Eat matches tmux's own `capture-pane`, across plain text, colors,
UTF-8 box-drawing, wide/CJK/emoji glyphs, the live `%output` stream, window
switching, and the tab bar's activity flags.  It needs a real tmux on `PATH`
(a dedicated `tc-ert-test` socket; skipped where tmux is absent):

```sh
make test-integration
```

For the GUI multi-pane tiling — which needs a real frame and can't be
checked in batch — `test/tmux-control-live-oracle.el` exposes the same
render-vs-`capture-pane` comparison as commands to run against a live GUI
Emacs while exercising tiling by hand:

```elisp
(load-file "test/tmux-control-live-oracle.el")
(tmux-control-live-compare-all "main")  ;; MATCH/DIFF per tiled pane
```
