# Quantifying GUI scroll trajectories

`test/tmux-control-scroll-trace.el` records a controlled five-second movement
through Emacs's command queue: three seconds toward older content at 960
pixels/second, a half-second hold, one second back at 480 pixels/second, and
a final half-second hold. The same distance is replayed at either 60 Hz
(240 inputs) or 120 Hz (480 inputs). Recording stops at six seconds to
observe delayed movement.

The recorder does not change scrolling preferences, force redisplay, start
Emacs's profiler, or change garbage-collection settings. It adds temporary
command and pre-redisplay hooks, a rolling absolute-deadline input timer,
a post-GC hook, and a 20 ms heartbeat. Only the next input timer is pending;
after a main-loop pause, all overdue inputs are enqueued individually.
This avoids the allocation cost of inserting hundreds of pending timers.
`M-x tmux-control-scroll-trace-stop` stops early, removes those
hooks/timers, drops only this recorder's remaining queued inputs, and saves
the partial trace. Do not interact with the test window during a replay.

## What each measurement means

| Measurement | Definition |
|---|---|
| Timer lateness | Actual enqueue time minus intended input time |
| Queue delay | Handler entry minus actual enqueue time |
| Handler cost | Time between pre-command and post-command hooks |
| Software response | Intended input time to the first pre-redisplay observation after its handler completes |
| Position error | Observed content coordinate minus the displacement requested by completed inputs |
| Unrequested jump | Change in position error between observations |
| Movement interval | Time between changing pre-redisplay positions, excluding intentional holds |
| Tail movement | Last observed movement after the final input was enqueued |
| GC events | Completion time, elapsed collection time since the previous GC, and function names on the post-GC stack |
| Allocation counts | New conses, floats, vector cells, symbols, string characters, intervals, and strings during recording |

There is no OS input queue or physical device in this replay. A
pre-redisplay observation is an opportunity to draw, **not proof of a
presented frame**. The measurements cannot establish display FPS, physical
trackpad latency, compositor latency, or network performance. Input periods
of 16.7/8.3 ms provide a pacing reference, not a claim about monitor refresh.

The ASCII fixture has numbered, uniform-height rows that fit the window.
Coordinates use row identity plus `window-vscroll`, so prepending older
history does not look like a jump. When Eat trims part of the first row,
the recorder infers that row's number from the following complete row and
labels the observation `inferred-next-row`. Unknown positions are reported
as missing anchors, not zero error. Do not apply this coordinate system to
arbitrary text, wrapped rows, or mixed-height glyphs.

`gc_events` records completion from `post-gc-hook`, not an independently
measured start timestamp. Stack arguments are excluded. An explicit
`garbage-collect` call is visible in the stack; automatic collections may
have a different stack. `allocation_counts` uses `memory-use-counts` in the
order above: these are allocations across the entire Emacs process,
including the recorder and unrelated activity, not retained heap size or
bytes. Counts exclude trace-file serialization. The metadata records the
GC threshold, percentage, and input scheduler; compare runs with the same
recorder and the same compiled/source build.

## Run a fixture

From the repository root, create a dedicated local tmux server:

```sh
trace_socket="tc-scroll-trace-$$"
trace_config=$(mktemp)
printf 'set -g history-limit 50000\nset -g status off\n' > "$trace_config"
trace_command=$(python3 -c 'import shlex,sys; print(shlex.join(["python3", "-u", sys.argv[1]]))' "$PWD/test/scroll-trace-workload.py")
tmux -L "$trace_socket" -f "$trace_config" new-session -d -s trace -x 160 -y 50 "$trace_command"
rm "$trace_config"
printf 'Test socket: %s\n' "$trace_socket"
```

In GUI Emacs, load the current package and `test/tmux-control-scroll-trace.el`
with `M-x load-file`. Connect using the printed socket name:

```elisp
(tmux-control-connect nil "THE-PRINTED-SOCKET" "trace")
```

Enable `pixel-scroll-precision-mode` if it is not already enabled. Make the
fixture window wider than 70 columns. Send the fixture its `history` command
to generate 6,000 colored rows, then wait for the burst to finish:

```elisp
(tmux-control--send-input nil (concat "history" (string 13)))
```

For a live trace, position the view 300 lines above the tail. The short timer
allows ordinary redisplay to settle before measuring the line height:

```elisp
(progn
  (goto-char (point-max))
  (forward-line -300)
  (set-window-start nil (point))
  (set-window-point nil (point))
  (set-window-vscroll nil 0 t)
  (run-at-time 0.3 nil #'tmux-control-scroll-trace-start
               "quiet-60" "/tmp/scroll-results" 60))
```

Repeat with `120` and a different filename label. For a streaming trace,
send `stream` immediately before scheduling the start; it emits 300 rows
per second for seven seconds. `stop` ends it early. Keep the input trajectory
identical between cases.

To measure history loading, open `C-c C-e`, wait for the initial capture,
then start at line 220 from `point-min` instead of 300 lines from the tail.
That position crosses the prefetch threshold under both the old and new
defaults. Compare buffer-local settings of 2,000 rows/one screen and 500
rows/three screens. Check `initial_depth` and `final_depth` in the output to
confirm that an extension actually occurred during each recording.

An old-retention control uses buffer-local `eat-term-scrollback-size` of
131072, compared with 1048576. A static reference can copy the colored text
to a `tmux-control-scrollback-mode` buffer without a live process or the
lazy-loading hook. These settings and buffers belong only to the fixture.

## Analyze and retain the results

```sh
python3 test/analyze-scroll-trace.py /tmp/scroll-results/*.json --output /tmp/scroll-report
# Optional figures, using matplotlib in an isolated uv environment:
uv run --with matplotlib python test/analyze-scroll-trace.py /tmp/scroll-results/*.json --output /tmp/scroll-report --plot
make test-scroll-trace EAT_DIR=/path/to/eat
```

The analyzer writes `report.md` and `summary.json`, plus figures with
`--plot`. Preserve the raw traces alongside them. Summaries include
p50/p95/p99/max, missing inputs, unknown/inferred anchors, GC totals,
observer elapsed time, and relevant configuration. In the initial local
suite, observation itself took roughly 15–20 ms total over each six-second
run; timer and hook overhead are additional. These are short diagnostic
traces, so retain outliers and repeat suspicious cases before attributing
them to a particular function.

Use Emacs's memory profiler in a separate diagnostic run to identify
allocation stacks. Its sampling changes overhead, so do not treat those
timings as the latency benchmark. The package's `make benchmark` also
reports created strings and string characters per call. Allocation
reductions can reduce GC pressure without shortening a collection of the
existing Emacs heap; an occasional pause does not by itself justify a
global GC threshold change.

### Longer comparisons

For a sustained comparison, repeat the six-second trace without forcing a
collection between segments. Return the fixture viewport to 300 rows above
the current tail between segments, allowing redisplay to settle before the
next recording. This keeps a long run inside the retained history. Each
segment includes four seconds of wheel input and two seconds of settling
and holds; 50 segments provide 300 recorded seconds and 200 seconds of
active input. Recreate and seed the fixture identically for each version,
and collect once before each version starts to equalize allocation headroom.
Keep GC thresholds and profiling settings unchanged across versions.

Save traces as `raw/before-01.json` through `before-50.json`, and equivalent
`after-*.json` files. Track whole-version `gc_count`, `gc_ms`, `wall_seconds`,
and `cycles` in `before-arm.json` and `after-arm.json`, so collections during
between-segment setup and serialization remain visible. These totals exclude
the explicit collection before the version starts.

```sh
python3 test/analyze-scroll-soak.py /tmp/long-scroll-test --output /tmp/long-scroll-report
```

The aggregate report counts responses over 50 ms and groups overlapping
slow response intervals into episodes. One GC pause can delay many inputs;
those should not be counted as many independent freezes. Episode spans are
not measured screen freeze durations. Report missing inputs and unknown
anchors alongside the timing results. A sequential before/after run remains
exploratory: if a difference appears, repeat in reverse order before claiming
an improvement in rare-pause frequency.

### Idle collection experiment

`test/tmux-control-idle-gc-experiment.el` is an optional developer probe,
not part of package initialization. It requests a collection only when its
fixture buffer is selected, no input is pending, no command has completed
for at least one second, and ten million cons cells have been allocated
since the previous collection. A short periodic timer checks these
conditions. Existing automatic GC limits remain in force.

Load the experiment and call
`(tmux-control-idle-gc-experiment-start (current-buffer))` in the fixture.
Always finish with `M-x tmux-control-idle-gc-experiment-stop`, which removes
its timer and hooks. Collection itself affects the entire Emacs process;
the selected-buffer check only limits when this experiment requests it.

Compare the same decoder and fixture with the policy off and on. Include
total GC time as well as delayed inputs: collecting more often may shorten
each pause while increasing total collection work. Also test input arriving
just after the quiet threshold. The policy does not inspect future trace
events and cannot guarantee that input will not arrive during collection.
If allocation eligibility is artificially primed for a short boundary
test, report that intervention separately from the natural long run.

On completion, disconnect the fixture with `tmux-control-disconnect` and
stop only its dedicated server:

```sh
tmux -L "$trace_socket" kill-server
```
