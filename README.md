# tmux-control

`tmux-control` turns Emacs into a **control-mode client for a tmux pane** —
the [iTerm2 tmux-integration](https://iterm2.com/documentation-tmux-integration.html)
idea, but in Emacs.

Unlike running tmux inside a terminal buffer (`vterm`, `eat`, `ansi-term`),
where the session dies with the Emacs frame, `tmux-control` speaks tmux
control mode (`tmux -C`) to a **persistent, possibly remote** tmux server
over SSH and renders the live pane through [Eat](https://codeberg.org/akib/emacs-eat).
The tmux session outlives Emacs: detach, restart, or reconnect from another
machine and the pane is still there. Eat handles rendering, input,
scrollback, search, and copy.

It is experimental — a first MVP (see [Status](#status)).

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
- `M-x tmux-control-new-window` creates a window (optionally named) and
  switches to it.
- `M-x tmux-control-rename-window` renames a window, with completion over
  the session's windows.
- `M-x tmux-control-kill-window` removes a window after confirmation, with
  completion over the session's windows.

Switching, creating, or removing a window changes the session's active
window, so any other client attached to the same session follows along.

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

Tiling is experimental and devotes the whole frame to the session
(`delete-other-windows`).  Each pane's terminal is sized to tmux's grid
(so the rendering matches tmux exactly) and the Emacs windows split to
match; a vertical stack can leave a one-row gap where Emacs spends a mode
line that tmux spends on a pane border, but content is never clipped.
Re-tiles are debounced and their tmux queries batched, so a busy remote
session is not stalled by layout changes.

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

#### Compacting repeated TUI redraws (opt-in)

Some TUIs repaint by reprinting their whole screen instead of using the
alternate screen — common when tmux runs with `alternate-screen off`, which
keeps full-screen apps on the normal screen so their history is preserved.
Each repaint is then appended to the pane history, so scrolling back shows
the same screen many times over.

`tmux-control` can collapse those repeats, but the line that marks the top of
one repaint is necessarily application-specific, so compaction is **off by
default** (scrollback is shown verbatim).  To enable it, point
`tmux-control-scrollback-frame-start-regexp` at your TUI's repaint marker and
list its per-frame "chrome" (status bars, rules, an evolving prompt) in
`tmux-control-scrollback-chrome-regexps` so changing lines don't defeat
de-duplication.  For the [Claude Code](https://www.anthropic.com/claude-code)
TUI, for example:

```elisp
(setq tmux-control-compact-scrollback t
      tmux-control-scrollback-frame-start-regexp "\\`\\s-*\\[Session\\]"
      tmux-control-scrollback-chrome-regexps
      '("\\`\\[Session\\]" "AI Credits:" "\\`/ commands"
        "\\`[─━]\\{10,\\}\\'" "\\`❯\\'"))
```

With no frame regexp set, `tmux-control-compact-scrollback` has nothing to act
on and scrollback is left untouched.

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
instead of replaying the whole backlog.  It engages only when the client is
genuinely behind, which is most likely over a higher-latency (e.g. remote SSH)
connection; a fast local client often keeps up and never triggers it.  Off by
default; requires tmux 3.2 or newer.

## Status

This is a first MVP.  It can attach to tmux, seed the live terminal from
`capture-pane` (cursor included), open a same-buffer Emacs scrollback view that
can optionally compact repeated TUI redraws, render live `%output` through Eat
in batches, send keyboard input back with `send-keys -H` (chunking large
pastes), resize the tmux client, and optionally use tmux flow control (pause
mode) for very high-volume output.  Mouse handling and broader edge-case
hardening still need work.

There is also an **experimental multi-pane tiling** view (`C-c C-t`, see
[Tiling every pane at once](#tiling-every-pane-at-once-experimental)) that
renders all of a window's panes at once, split to match tmux's layout.  It
is rougher than the single-pane view — whole-frame only, approximate
sizing — but already handles live per-pane output, per-pane input,
focus-follow, and automatic re-tiling on split/resize/close.

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

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).

