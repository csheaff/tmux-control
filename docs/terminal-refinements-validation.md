# Terminal refinements validation

Validated on 2026-09-30 with Emacs 30.2, Eat 0.9.4, and tmux 3.6a on macOS.
Tests use dedicated local tmux sockets, with raw input recorded by
[`test/terminal-probe.py`](../test/terminal-probe.py).

## Automated results

- Source unit suite: 285/285 passed.
- Byte compilation: passed with warnings treated as errors.
- Compiled unit suite: 285/285 passed.
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

## Remaining validation

No remote machine was available. Real SSH disconnects, sleep/wake, remote
latency, and SSH authentication/configuration behavior remain unverified.
Local server stalls and killed control transports exercise the shared recovery
paths but cannot establish SSH-specific behavior.

The Mac was locked, preventing native Emacs UI QA. Physical mouse/trackpad
interaction, native paste shortcuts, font rendering, and interaction with
installed modal packages still need an unlocked GUI session. Complex graphemes
without a single-cell canonical composition remain an Eat limitation.
