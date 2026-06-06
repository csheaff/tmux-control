# tmux-control

`tmux-control` turns Emacs into a **control-mode client for a tmux pane** —
the [iTerm2 tmux-integration](https://iterm2.com/documentation-tmux-integration.html)
idea, but in Emacs.

![A live tmux session in Emacs via tmux-control: the session's windows as a header-line tab bar, switched with one key, with a dot flagging a background window that produced output](docs/images/demo.gif)

*A live tmux session in Emacs. Each window is a **tab** in the header line,
flipped with one key (`C-c C-n`); a **dot** marks a background window that
produced output — the "which window wants me?" signal — and clears when you
visit it. Every pane is just an Emacs buffer you can search and copy from.*

Other ways to pair Emacs with tmux either **send it commands**
([`emamux`](https://github.com/emacsorphanage/emamux)), **navigate** between
Emacs windows and tmux panes when Emacs itself runs *inside* tmux
([`tmux-pane`](https://github.com/laishulu/emacs-tmux-pane)), or run tmux
*inside* an Emacs terminal buffer (`vterm`, `eat`, `ansi-term`) — a terminal in
a terminal, with tmux's own status bar and prefix keys.  None of them render
tmux's own panes as Emacs buffers.  `tmux-control` does: it speaks tmux's
**control-mode protocol** (`tmux -C`, the same one iTerm2's native integration
uses), so each live pane becomes an Emacs buffer rendered through
[Eat](https://codeberg.org/akib/emacs-eat) — no nested terminal, no tmux
chrome, just a buffer you navigate, search, and copy from.  The session lives
on a **persistent, possibly remote** server and outlives Emacs: detach,
restart, or reconnect from another machine and the pane is still there.

The single-pane client is stable and in daily use; multi-pane **tiling** is
still [experimental](#tiling-every-pane-at-once-experimental) (see
[Status](#status)).

## Requirements

- **Emacs 29.1+**
- **[Eat](https://codeberg.org/akib/emacs-eat) 0.9.4+** — the terminal renderer
  and a hard dependency (`straight`/`package.el` pulls it in automatically).
- **tmux 3.x** on the target host, local or remote over SSH (flow control needs
  3.2+).
- macOS or Linux.

## Usage

```elisp
(use-package tmux-control
  :straight (tmux-control :type git :host github :repo "csheaff/tmux-control")
  :custom
  ;; Connection defaults for `M-x tmux-control-connect' — these are examples;
  ;; set them to your own host / socket / session.
  (tmux-control-default-host "dev")          ; an SSH host alias, or nil for local
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

These commands act on the connected session (`C-c C-n`/`C-c C-p` are bound in
the live buffer; the rest are `M-x`, bind them to taste):

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

#### The window tab bar

In the single-pane view, a **tab bar** in the header line lists the session's
windows like iTerm's tmux tabs — `index:name` for each, the current one
highlighted.  It is the at-a-glance map of the session: click a tab to switch
to it, and watch a **dot** appear on any *background* window whose pane
produces output while you are looking elsewhere — the "which window (or agent)
wants me" signal for a window-per-agent workflow.  Visiting a window clears its
dot; a window that rings its bell shows a `!`.

The dot reflects genuine background output: the prompt/redraw burst that a
connect, window switch, or frame resize provokes in every pane is deliberately
*not* counted, so an idle session does not light up.  The bar costs one
terminal row (tmux is sized to match, so nothing clips) and is hidden in the
tiled view, where each pane already carries its own label.  Turn it off with:

```elisp
(setq tmux-control-window-tab-bar nil)
```

### Panes (and agent teams)

A tmux window can hold several panes at once.  A common case is a
[Claude Code](https://www.anthropic.com/claude-code) **agent team** in tmux
mode (`teammateMode: tmux`), which runs each teammate in its own pane so you
can watch them work.

By default `tmux-control` mirrors **one pane at a time** — the window's
active pane, rendered cleanly (output from the other panes is not
interleaved into the view).  Move between panes (teammates) with:

- `C-c C-o` (`tmux-control-other-pane`) — cycle to the next pane.
- `M-x tmux-control-select-pane` — jump to a pane by name, completing over
  the window's panes (each labelled by its index, command, and title).

Switching the pane sets the window's active pane, so other clients follow
along and the live view repaints on the chosen pane.

#### Tiling every pane at once (experimental)

`C-c C-t` (`tmux-control-toggle-tiling`) flips between the single-pane view
and a **tiled** view that renders *every* pane of the current window at
once, each in its own buffer, with the Emacs windows split to match tmux's
own layout — the iTerm "show every pane" view.  This is the natural way to
watch a whole agent team work side by side.

![The same tmux session in iTerm2 and in Emacs via tmux-control](docs/images/iterm-vs-tmux-control.png)

*The same live tmux session — a [`pi-agents-tmux`](https://www.npmjs.com/package/@vanillagreen/pi-agents-tmux)
agent team in split panes — rendered by iTerm2's native tmux integration
(left) and by the tiled view in Emacs (right): cell-for-cell the same.*

In the tiled view:

- Every pane updates live and independently; output is routed per pane, so
  nothing is interleaved.
- Type into a pane to send to that teammate; selecting a pane's Emacs
  window makes it tmux's active pane too (other clients follow).
- Splitting, resizing, or closing a pane in tmux re-tiles automatically,
  and the mode line labels each pane by its id, command, and title.
- Resizing the Emacs frame re-divides the tmux window to match, so the
  panes re-fit instead of clipping.
- Each pane is a normal `tmux-control` buffer, so `C-c C-e` scrollback and
  the usual movement/search/copy work in any of them.

For a session with **several windows — say two, each running its own agent
team** — tile one window, then switch windows (`M-x
tmux-control-select-window`) to bring the other team into the tiled view;
each window tiles its own panes, like iTerm's per-window tabs.  `C-c C-t`
again (or `M-x tmux-control-untile`) returns to the single-pane view on the
currently active pane.

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

Useful bindings:

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

### Files are local

A tmux-control buffer is a local Emacs buffer that *renders* a remote pane;
it is not a remote filesystem context.  Its `default-directory` stays local
and the package does no directory tracking, so `find-file`, `dired`,
`M-x compile`, and similar commands operate on the machine running Emacs —
not on the remote host.  To edit a file you see in a remote pane, open it
explicitly over TRAMP, e.g. `C-x C-f /ssh:dev:~/path/to/file`.

Scrollback joins soft-wrapped tmux lines by default; disable that with:

```elisp
(setq tmux-control-scrollback-join-wrapped-lines nil)
```

#### Compacting repeated TUI redraws

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
`tmux-control-scrollback-chrome-regexps` for an even tighter collapse.  For the
[Claude Code](https://www.anthropic.com/claude-code) TUI, for example:

```elisp
(setq tmux-control-scrollback-frame-start-regexp "\\`\\s-*\\[Session\\]"
      tmux-control-scrollback-chrome-regexps
      '("\\`\\[Session\\]" "AI Credits:" "\\`/ commands"
        "\\`[─━]\\{10,\\}\\'" "\\`❯\\'"))
```

### High-volume output (flow control)

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

## Status

The single-pane client is stable: it attaches to a tmux session (local or
remote over SSH), seeds the live screen from `capture-pane`, streams `%output`
through Eat, sends input with `send-keys -H`, resizes the client, navigates
windows like tabs (with the activity-flagging tab bar), opens an Emacs
scrollback view that auto-compacts repeated TUI redraws, and can use tmux flow
control for very high-volume output.  Mouse handling and broader edge-case
hardening still need work.

The **multi-pane tiling** view (`C-c C-t`, see
[Tiling every pane at once](#tiling-every-pane-at-once-experimental)) renders
all of a window's panes at once, split to match tmux's layout, each pane
cell-for-cell faithful.  It is still **experimental** — whole-frame only, with
the known limitations listed in that section — but already handles live
per-pane output, per-pane input, focus-follow, and automatic re-tiling on
split/resize/close.

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

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).

