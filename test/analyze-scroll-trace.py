"""Analyze tmux-control-scroll-trace JSON; optionally plot with matplotlib.

All times are software measurements. A pre-redisplay hook is NOT proof that
the compositor presented a frame. No FPS or physical input latency is inferred.
"""
import argparse
import bisect
import json
import math
from pathlib import Path


def distribution(values):
    values = sorted(values)
    if not values:
        return {key: None for key in ("p50", "p95", "p99", "max")}
    return {**{f"p{p}": values[math.ceil(len(values) * p / 100) - 1]
               for p in (50, 95, 99)}, "max": values[-1]}


def analyze(trace):
    events = trace["events"]
    handled = [event for event in events if event["finish_ms"] is not None]
    observations = trace["observations"]
    base = observations[0]["position_px"]
    expected = [base]
    for event in events:
        expected.append(expected[-1] - event["delta_px"])
    stable = [obs for obs in observations
              if obs["started"] == obs["completed"] and obs["position_px"] is not None]
    redraws = [obs for obs in stable if obs["kind"] == "pre-redisplay"]
    redraw_ids = [obs["completed"] for obs in redraws]
    response = []
    for event in handled:
        index = bisect.bisect_left(redraw_ids, event["id"])
        if index < len(redraws):
            response.append({"id": event["id"], "scheduled_ms": event["scheduled_ms"],
                             "ms": redraws[index]["time_ms"] - event["scheduled_ms"]})
    drift = [obs["position_px"] - expected[obs["completed"]] for obs in stable]
    residuals = [(b["position_px"] - a["position_px"])
                 - (expected[b["completed"]] - expected[a["completed"]])
                 for a, b in zip(stable, stable[1:])]
    # Drop intentional half-second holds when computing movement intervals.
    intervals = []
    for group in ([e for e in handled if e["id"] <= 3 * trace["hz"]],
                  [e for e in handled if e["id"] > 3 * trace["hz"]]):
        if not group:
            continue
        end_index = bisect.bisect_left(redraw_ids, group[-1]["id"])
        end_time = (redraws[end_index]["time_ms"] if end_index < len(redraws)
                    else group[-1]["finish_ms"])
        frames = [obs for obs in redraws
                  if group[0]["id"] <= obs["completed"] <= group[-1]["id"]
                  and group[0]["enqueue_ms"] <= obs["time_ms"] <= end_time]
        changed = []
        for obs in frames:
            if not changed or obs["position_px"] != changed[-1]["position_px"]:
                changed.append(obs)
        intervals.extend(b["time_ms"] - a["time_ms"]
                         for a, b in zip(changed, changed[1:]))
    changed_at = [b["time_ms"] for a, b in zip(stable, stable[1:])
                  if b["position_px"] != a["position_px"]]
    enqueued = [event for event in events if event["enqueue_ms"] is not None]
    result = {
        "label": trace["label"], "hz": trace["hz"],
        "scheduled": len(events), "handled": len(handled),
        "missing": len(events) - len(handled),
        "timer_lateness_ms": distribution([e["enqueue_ms"] - e["scheduled_ms"] for e in enqueued]),
        "queue_delay_ms": distribution([e["start_ms"] - e["enqueue_ms"] for e in handled]),
        "handler_ms": distribution([e["finish_ms"] - e["start_ms"] for e in handled]),
        "scheduled_to_redisplay_ms": distribution([row["ms"] for row in response]),
        "redisplay_samples": len(response),
        "movement_interval_ms": distribution(intervals),
        "movement_gaps_over_2_input_periods": sum(gap > 2000 / trace["hz"] for gap in intervals),
        "max_position_error_px": max(map(abs, drift), default=0),
        "max_unrequested_jump_px": max(map(abs, residuals), default=0),
        "unrequested_jumps_over_1px": sum(abs(x) > 1 for x in residuals),
        "unknown_anchor_samples": sum(obs["position_px"] is None for obs in observations),
        "inferred_anchor_samples": sum(obs.get("anchor_kind") == "inferred-next-row" for obs in observations),
        "tail_motion_ms": max(0, max(changed_at, default=0) - enqueued[-1]["enqueue_ms"]) if enqueued else None,
        "gc_count": trace["gc_count"], "gc_ms": trace["gc_ms"],
        "gc_events": trace.get("gc_events", []),
        "allocation_counts": trace.get("allocation_counts"),
        "observer_elapsed_ms": trace.get("observer_elapsed_ms"),
        "initial_depth": trace["metadata"].get("initial_depth"),
        "final_depth": trace.get("final_depth"),
        "metadata": trace["metadata"],
    }
    return result, {"stable": stable, "base": base, "response": response,
                    "drawable": [obs for obs in observations if obs["started"] == obs["completed"]]}


def plot(traces, results, output):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    plt.rcParams.update({"font.size": 10, "axes.spines.top": False, "axes.spines.right": False})
    by_label = {trace["label"]: (trace, detail) for trace, (_, detail) in zip(traces, results)}
    if {"stream-60", "stream-old-budget-60", "stream-60-repeat"} <= by_label.keys():
        overview, (position_ax, delay_ax) = plt.subplots(1, 2, figsize=(13, 4.8))
        reference = by_label["stream-60"][0]
        times, positions, position = [0], [0], 0
        for event in reference["events"]:
            position -= event["delta_px"]
            times.append(event["scheduled_ms"] / 1000)
            positions.append(position)
        times.append(6)
        positions.append(position)
        position_ax.step(times, positions, where="post", color="#a2afbd", linewidth=3,
                         label="Scheduled movement")
        for label, name, color in [("stream-60", "Larger history budget", "#137a72"),
                                    ("stream-old-budget-60", "Old history budget", "#c45b29")]:
            detail = by_label[label][1]
            position_ax.plot([o["time_ms"] / 1000 for o in detail["drawable"]],
                             [o["position_px"] - detail["base"] if o["position_px"] is not None else math.nan
                              for o in detail["drawable"]], label=name, color=color, linewidth=1.6)
        position_ax.set(title="Does the content follow the requested movement?",
                        xlabel="Elapsed seconds", ylabel="Content displacement (Emacs pixels)")
        position_ax.legend(fontsize=9)
        position_ax.grid(alpha=.2)
        for label, name, color in [("stream-60", "Streaming run with GC", "#c45b29"),
                                    ("stream-60-repeat", "Streaming repeat", "#137a72")]:
            detail = by_label[label][1]
            delay_ax.plot([r["scheduled_ms"] / 1000 for r in detail["response"]],
                          [r["ms"] for r in detail["response"]], label=name, color=color)
        gc_ms = reference["gc_ms"]
        delay_ax.text(.03, .75, f"GC total in the outlier run: {gc_ms:.0f} ms",
                      transform=delay_ax.transAxes, color="#8a411e")
        delay_ax.set(title="Do short handler times conceal a stall?",
                     xlabel="Scheduled input time (seconds)", ylabel="Input to redisplay opportunity (ms)")
        delay_ax.legend(fontsize=9, loc="upper left")
        delay_ax.grid(alpha=.2)
        overview.suptitle("Quantifying scroll stability and responsiveness", fontsize=16)
        overview.text(.5, .01, "Software state and redisplay opportunities; not physical screen presentation.",
                      ha="center", fontsize=9, color="#52606b")
        overview.tight_layout(rect=(0, .04, 1, .94))
        overview.savefig(output / "overview.png", dpi=160)
        plt.close(overview)
    fig, axes = plt.subplots(len(traces), 2, figsize=(13, 2.6 * len(traces)), squeeze=False)
    for (trace, (summary, detail)), (left, right) in zip(zip(traces, results), axes):
        times, positions, position = [0], [0], 0
        for event in trace["events"]:
            position -= event["delta_px"]
            times.append(event["scheduled_ms"] / 1000)
            positions.append(position)
        times.append(6)
        positions.append(position)
        left.step(times, positions, where="post", color="#94a3b8", label="Scheduled movement", linewidth=2)
        left.plot([obs["time_ms"] / 1000 for obs in detail["drawable"]],
                  [obs["position_px"] - detail["base"] if obs["position_px"] is not None else math.nan
                   for obs in detail["drawable"]],
                  color="#137a72", label="Observed content position", linewidth=1.4)
        left.set(title=trace["label"], ylabel="Movement (Emacs pixels)", xlabel="Seconds")
        left.grid(alpha=.2)
        left.legend(fontsize=8, loc="best")
        right.plot([row["scheduled_ms"] / 1000 for row in detail["response"]],
                   [row["ms"] for row in detail["response"]], color="#b74b28", linewidth=1)
        right.axhline(1000 / trace["hz"], color="#94a3b8", linestyle="--",
                      label=f"Input period: {1000 / trace['hz']:.1f} ms")
        right.set(title="Scheduled input to next redisplay opportunity",
                  ylabel="Software response (ms)", xlabel="Seconds", ylim=(0, None))
        right.grid(alpha=.2)
        right.legend(fontsize=8)
    fig.suptitle("Scroll trajectories and software response\nRedisplay opportunities are not presented frames", fontsize=15)
    fig.tight_layout(rect=(0, 0, 1, .975))
    fig.savefig(output / "scroll-trajectories.png", dpi=160)
    plt.close(fig)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("traces", type=Path, nargs="+")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--plot", action="store_true")
    args = parser.parse_args()
    traces = [json.loads(path.read_text()) for path in args.traces]
    results = [analyze(trace) for trace in traces]
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "summary.json").write_text(json.dumps([summary for summary, _ in results], indent=2))
    lines = ["# Scroll trajectory measurements", "",
             "Synthetic pixel inputs entered Emacs's command queue at 60 or 120 Hz. "
             "Each run moves up 2,880 pixels, holds, moves down 480 pixels, then holds. "
             "Numbered, fixed-height rows identify content independently of buffer insertions and deletions.", "",
             "These are software timings, including timer wakeup and command-queue delays. "
             "A pre-redisplay hook is a redisplay opportunity, not a presented screen frame. "
             "Physical device latency, compositor latency, remote latency, and display FPS were not measured.", "",
             "| Run | Handled | Queue p95 | Handler p95 | Response p95 / max | Largest unrequested jump | Position error max | Unknown anchors |",
             "|---|---:|---:|---:|---:|---:|---:|---:|"]
    def fmt(number):
        return "n/a" if number is None else f"{number:.2f}"
    for summary, _ in results:
        lines.append(f"| {summary['label']} | {summary['handled']}/{summary['scheduled']} "
                     f"| {fmt(summary['queue_delay_ms']['p95'])} ms | {fmt(summary['handler_ms']['p95'])} ms "
                     f"| {fmt(summary['scheduled_to_redisplay_ms']['p95'])} / {fmt(summary['scheduled_to_redisplay_ms']['max'])} ms "
                     f"| {fmt(summary['max_unrequested_jump_px'])} px | {fmt(summary['max_position_error_px'])} px "
                     f"| {summary['unknown_anchor_samples']} |")
    lines += ["", "Response = scheduled input to the first pre-redisplay observation after its handler completed. "
              "Position error compares observed content with the sum of completed inputs; scheduling delay alone does not count as a jump. "
              "The gray curves use the intended schedule, exposing scheduling delay separately. "
              "Unknown anchors are unmeasurable positions, shown as gaps in the plots; they do not establish zero error. "
              "If Eat trims the beginning of a fixture row, its number is inferred from the next complete numbered row; "
              "those samples are labeled in the raw trace and counted separately in the summary.", "",
              "GC totals, timer lateness, p50/p95/p99 values, movement gaps, missing events, unknown anchors, "
              "and configuration metadata are in [summary.json](summary.json). "
              "Movement gaps exclude intentional holds. This short trace is diagnostic, not a statistically robust frame-rate benchmark."]
    if args.plot:
        plot(traces, results, args.output)
        if (args.output / "overview.png").exists():
            lines += ["", "![Stability and latency overview](overview.png)"]
        lines += ["", "![Scroll trajectories](scroll-trajectories.png)"]
    (args.output / "report.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines[:11]))


if __name__ == "__main__":
    main()
