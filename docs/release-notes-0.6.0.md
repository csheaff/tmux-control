# tmux-control 0.6.0

This release improves scrollback loading and live-history retention, reduces
temporary output-decoding allocations, and adds optional idle-time garbage
collection for tmux-control views.

## Scrollback

- History loads in smaller, 500-row extensions and begins loading three
  screens before the loaded top. Both settings are configurable.
- Overlap matching normalizes only the bounded seam between history chunks.
- Live buffers retain up to 1,048,576 characters by default, reducing the
  chance that incoming output discards text being read. Customize
  `tmux-control-live-scrollback-size`, or set it to `nil` to inherit Eat's
  setting. The limit applies to new or reconnected buffers; more retained
  text uses more memory per pane.
- Output decoding copies literal runs together and reuses octal replacement
  strings to reduce temporary allocation.

## Optional idle collection

Enable `M-x tmux-control-idle-gc-mode` to request garbage collection during
quiet periods in live views and scrollback pagers. Run it again to disable.
The mode is off by default and leaves Emacs's automatic GC settings intact.
Use `M-x tmux-control-idle-gc-status` to see its requested collections.

The defaults require one second without a completed command, ten million
new cons allocations since the last collection, a selected tmux-control
view, and no pending input or active minibuffer.

In a controlled five-minute comparison, maximum software response fell
from 242 ms to 12 ms, while total GC time increased from 230 ms to 452 ms.
Input deliberately resumed during collection still saw 62–71 ms responses.
These exploratory measurements do not establish display FPS or physical
trackpad latency. Try the mode with your normal workload before enabling
it permanently. Lower decoder allocation alone did not demonstrate fewer
long scrolling pauses.

## Other fixes since 0.5.0

- Handle normalized control-mode delimiters.
- Preserve carriage returns when decoding UTF-8 output streams.
- Anchor tiled pane windows to Eat's live display start.

## Developer tools

New allocation benchmarks, controlled GUI scroll traces, and aggregate
analysis tools make input delays and reading-position drift measurable.
See [the measurement guide](scroll-tracing.md) for reproduction steps and
limitations, and [the user guide](guide.md) for configuration.
