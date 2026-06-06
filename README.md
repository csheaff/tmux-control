# tmux-control

`tmux-control` turns Emacs into a **control-mode client for a tmux pane** —
the [iTerm2 tmux-integration](https://iterm2.com/documentation-tmux-integration.html)
idea, but in Emacs.

![The same tmux session in iTerm2 and in Emacs via tmux-control](docs/images/iterm-vs-tmux-control.png)

*The same live tmux session — a [`pi-agents-tmux`](https://www.npmjs.com/package/@vanillagreen/pi-agents-tmux)
agent team in split panes — rendered by iTerm2's native tmux integration
(left) and by tmux-control in Emacs (right). Multi-pane **tiling** is
[experimental](#tiling-every-pane-at-once-experimental); the shipped client
mirrors one pane at a time.*

Unlike running tmux inside a terminal buffer (`vterm`, `eat`, `ansi-term`),
where the session dies with the Emacs frame, `tmux-control` speaks tmux
control mode (`tmux -C`) to a **persistent, possibly remote** tmux server
over SSH and renders the live pane through [Eat](https://codeberg.org/akib/emacs-eat).
The tmux session outlives Emacs: detach, restart, or reconnect from another
machine and the pane is still there. Eat handles rendering, input,
scrollback, search, and copy.

The single-pane client is stable and in daily use; the multi-pane **tiling**
view (rendering every pane at once) is still
[experimental](#tiling-every-pane-at-once-experimental).  See
[Status](#status) for details.

## Usage

```elisp
(use-package tmux-control
  :straight (:local-repo "~/code/tmux-control" :type git)
  :custom
  (tmux-control-default-host "dev")
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

These commands act on the connected session (no key bindings by default):

- `M-x tmux-control-select-window` switches the live view to another window
  in the session.  By default it opens a two-pane chooser with a live
  preview of the highlighted window's screen (like tmux's `choose-tree`
  menu): move with the arrow keys, `n`/`p`, or the mouse; press `RET` (or
  click) to select; and `q` or `C-g` to cancel.  The chooser opens on the
  session's currently active window, so the preview immediately shows where
  you are.  The preview is captured on
  demand with a short idle debounce and cached per window for the chooser's
  lifetime.  The chooser's own keys take precedence over modal-editing
  packages such as `xah-fly-keys` or `evil`.  Disable the chooser to fall
  back to plain completion with:

  ```elisp
  (setq tmux-control-window-preview nil)
  ```

  Tune the preview debounce (seconds of idle before capturing) with:

  ```elisp
  (setq tmux-control-window-preview-delay 0.15)
  ```
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
watch a whole agent team work side by side.  In the tiled view:

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
- Splitting an already-tiled pane into a command that **immediately prints a
  screenful** (a `cat`, an agent's start-up banner) can render that one pane's
  first screen twice: the pane is both seeded from `capture-pane` and sent the
  same content as live `%output`.  Other panes are unaffected.
- A vertical stack spends one row on an Emacs mode line where tmux spends it on
  a pane border, so a stacked pane can sit one row short — but content is never
  clipped.

Useful bindings:

- `C-c C-k` disconnects the Emacs control client.
- `C-c C-l` refreshes the live view from tmux's current visible screen without
  sending input to the pane.
- `C-c C-e` switches the current buffer into a normal Emacs scrollback view
  captured from tmux.  In that view, use normal Emacs movement/search/copy,
  `g` to refresh, and `q`, `RET`, `C-c C-e`, or
  `M-x eat-semi-char-mode` to return to the live pane.
- In the scrollback view, simply typing an ordinary character also returns to
  the live pane and forwards that keystroke to it, so you can start your next
  command without an explicit exit step.  (Modal-editing users, e.g.
  `xah-fly-keys`: this only fires for self-inserting keys, so command-mode
  navigation in the read-only scrollback buffer is preserved.)
- Scrolling up with the mouse wheel also enters the scrollback view, but only
  while the pane shows its normal screen.  When a full-screen application
  genuinely owns the alternate screen (e.g. `vim` or `less` under a tmux that
  honors `alternate-screen`), the wheel is forwarded to that application so it
  keeps its own mouse scrolling.  Note that with `alternate-screen off` (a
  common setting that preserves scrollback for TUIs), tmux keeps even
  full-screen apps on the normal screen, so the wheel correctly opens the
  scrollback view for them too -- matching tmux's own wheel-up behavior.
  Disable this with:

  ```elisp
  (setq tmux-control-wheel-enters-scrollback nil)
  ```

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
see the progression instead of dozens of copies.  It is conservative — it acts
only when it actually finds a repeating frame, so ordinary command output is
left verbatim.  Turn it off with:

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
behind, tmux pauses the pane and notifies the client, which reseeds from the
pane's current screen and resumes — so the view jumps to the latest state
instead of replaying the whole backlog.  It engages only when the client
genuinely can't keep up with the stream, which in practice means a
**low-bandwidth** link — Emacs reads the control socket eagerly, so a client
with enough throughput keeps up and never triggers it.  That includes a fast
local client and, in testing, even a high-latency remote SSH connection with
ample bandwidth: latency alone does not trigger pause mode, only a starved
pipe does.  Off by default; requires tmux 3.2 or newer.

## Status

The single-pane client is stable.  It can attach to tmux, seed the live
terminal from `capture-pane` (cursor included), open a same-buffer Emacs
scrollback view that automatically compacts repeated TUI redraws, render live
`%output` through Eat in batches, send keyboard input back with `send-keys -H`
(chunking large pastes), resize the tmux client, and optionally use tmux flow
control (pause mode) for very high-volume output.  Windows are navigated like
tabs — next/previous/last switching and a clickable header-line **tab bar**
that flags background windows with unseen output.  Mouse handling and broader
edge-case hardening still need work.

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

There is also a **live integration suite** that asserts render fidelity —
that the text tmux-control paints into an Eat buffer matches tmux's own
`capture-pane` for the same screen, for the connect-time seed and the live
`%output` stream, across plain text, colors, UTF-8 box-drawing, wide lines,
and double-width CJK/emoji glyphs; it also covers window navigation
(next/previous/last switching with reseed) and the tab bar's activity
flagging.  It needs a real tmux on `PATH` (it uses a dedicated `tc-ert-test`
socket and never touches other servers; tests skip where tmux is absent):

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

