# Terminal refinements validation

Validated on 2026-09-30 with Emacs 30.2, Eat 0.9.4, and tmux 3.6a on macOS.
Tests use dedicated local tmux sockets, with raw input recorded by
[`test/terminal-probe.py`](../test/terminal-probe.py).
The unit suites were rerun on 2026-10-01 after adding review regressions.

## Automated results

- Source unit suite: 290/290 passed.
- Byte compilation: passed with warnings treated as errors.
- Compiled unit suite: 290/290 passed.
- Live integration suite: 32/32 passed against both source and the compiled package.
- Scroll trace checks: 8 Elisp and 8 Python tests passed.
- Python TUI helper compilation and `git diff --check`: passed.

Use `EAT_DIR=/path/to/eat` with the Makefile targets documented in the
[user guide](guide.md#development).

## New live scenarios

| Scenario | Verification |
| --- | --- |
| Same session on different sockets | Distinct processes/controllers, reuse after rename, reconnect of a one-character buffer name |
| Tiled history | Retained text after switching windows, output while away, resize/repaint, untile/retile; closed pane cache pruned |
| Stalled connection | Stop the isolated tmux server, reject overdue keystrokes/paste, resume it and recover |
| Reconnect with code beside tiling | Restore pane layout without removing the code window or changing its focus |
| Unacknowledged input | Record delivery uncertainty and verify reconnect sends no replayed input |
| Automatic retry | Kill the local control transport, wait for real retry timer, restore tiling and reset retry budget |
| Diagnostics | Immediate cached report plus successful asynchronous pane/sizing/client queries |
| Pager diagnostics | Resolve the linked live pane/grid, bindings/options, and controller for asynchronous server queries |
| Disconnect after untile | Kill retained pane caches on deliberate and unexpected disconnects; reconnect stays untiled |
| Existing TUI | Attach after alternate screen/mouse/cursor-key/paste modes enabled; compare Unicode screen with tmux and verify every byte of cursor-key, Unicode input, mouse press/release, and a 5,000-character bracketed paste |

Unit regressions also cover incomplete reply blocks, superseded repaint replies,
resuming a paused pane when another repaint supersedes its seed, accents split
across chunks/color escapes, bookmark file persistence, stale report replies,
killed cached-buffer cleanup, old watchdog timer cancellation on reset, and
immediate input recovery when the command timeout is disabled after a warning.

Batch Emacs does not run the normal user-idle event loop, so integration tests
explicitly execute their own pending retile timer callback to settle layouts.
Mouse events are synthetic Emacs events passed through real Eat encoding, the
control transport, tmux, and the running TUI; this does not establish physical
mouse hit-testing or native event delivery.

## Native Emacs GUI pass

The Mac was unlocked for a subsequent native pass on 2026-09-30. The pass used
a separate `-Q` GUI Emacs process and disposable `tc-native-qa` tmux socket,
the installed xah-fly-keys package with its qwerty layout and ESC binding,
and the user's precision-scroll and wheel settings. Native keyboard, paste,
mouse-click, and scrolling events were delivered through the macOS UI.

| Scenario | Result |
| --- | --- |
| Native terminal input | Typing, application cursor keys, and bare ESC reached the raw recorder |
| Native multiline paste and Ctrl-Y | Exact UTF-8 alpha/beta payloads and newline-to-CR conversion, each enclosed once in bracketed-paste delimiters |
| Mouse-aware alternate-screen TUI | Wheel-up reached the program as SGR button 64; left and middle mouse presses/releases reached their hit-tested cells |
| Installed modal package | Semi-char ESC entered xah command state without reaching the pane; raw ESC, Ctrl-C, Ctrl-U, and typing reached the recorder; native Option-Return restored semi-char mode |
| Pre-connection history | Native wheel-up opened the pager, further scrolling moved backward through numbered history, and returning live restored the pane |
| Retained live history | Native wheel-up stayed in the live buffer; additional output grew it from 7,697 to 8,435 positions while window start stayed at 5,487; scrolling down resumed live input |
| Precision scrolling | Repeated native up/down scrolling passed with `pixel-scroll-precision-mode` and the user's wheel options enabled |
| Tiling beside code | Switch, untile/retile, and native frame resize preserved the code window; the final code focus and point 50 survived resize, and both tiled buffers matched tmux captures |
| Terminal edges and glyphs | CJK, accents, and emoji rendered; `terminal-probe.py --edge-markers` showed both the first and last columns after tiling and resize |

This pass found and fixed three issues: Eat's GUI scroll synchronization could
clip the first alternate-screen row; raw mode could lose keys to modal maps
and did not recognize native Option-Return; fringe-free internal tile windows
could replace their last cell with a truncation marker or retain horizontal
scrolling from an earlier arrangement. Regressions cover alternate-screen
anchoring without changing normal-history scrolling, modal key precedence,
symbolic GUI keys, and resetting a reused tile's horizontal origin. The GUI
oracle now treats canonically equivalent accents as equal.

Additional ERT review coverage exercises xah's enabled/disabled transition
with a terminal-wide overriding map and arranges three real Emacs windows
from a parsed tmux layout. The arrangement test checks each separator budget,
available body width, and unchanged Eat grid width. Both regressions were
also verified to fail with their corresponding old behavior restored in memory.

## Remaining validation

No remote machine was available. Real SSH disconnects, sleep/wake, remote
latency, and SSH authentication/configuration behavior remain unverified.
Local server stalls and killed control transports exercise the shared recovery
paths but cannot establish SSH-specific behavior.

Native UI automation establishes macOS event delivery and mouse hit-testing;
physical trackpad inertia, hand-driven interaction, and input-to-display latency
were not measured. The pass used an isolated configuration, not every extension
in the user's full init file. Complex graphemes without a single-cell canonical
composition remain an Eat limitation.
