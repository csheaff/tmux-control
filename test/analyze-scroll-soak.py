"""Aggregate repeated scroll traces, keeping delayed inputs and pause episodes separate.

A slow-response episode is a union of overlapping scheduled-input-to-redisplay
intervals whose response exceeds 50 ms. Its span is not measured screen freeze
time. Use arm-level GC totals to include collections between recorded segments.
"""
import argparse
import importlib.util
import json
from pathlib import Path

spec = importlib.util.spec_from_file_location("scroll_trace_analysis", Path(__file__).with_name("analyze-scroll-trace.py"))
trace_analysis = importlib.util.module_from_spec(spec)
spec.loader.exec_module(trace_analysis)


def slow_episodes(responses, threshold_ms=50):
    episodes = []
    for response in sorted(responses, key=lambda item: item["scheduled_ms"]):
        if response["ms"] <= threshold_ms:
            continue
        start = response["scheduled_ms"]
        end = start + response["ms"]
        if not episodes or start > episodes[-1]["end_ms"]:
            episodes.append(dict(start_ms=start, end_ms=end, inputs=1,
                                 max_response_ms=response["ms"]))
        else:
            episode = episodes[-1]
            episode["end_ms"] = max(episode["end_ms"], end)
            episode["inputs"] += 1
            episode["max_response_ms"] = max(episode["max_response_ms"], response["ms"])
    return episodes


def aggregate(traces, arm=None):
    summaries, responses, episodes, per_cycle = [], [], [], []
    for trace in traces:
        summary, detail = trace_analysis.analyze(trace)
        summaries.append(summary)
        responses.extend(detail["response"])
        cycle_episodes = slow_episodes(detail["response"])
        for episode in cycle_episodes:
            episode["label"] = trace["label"]
            # GC completion and elapsed duration give an approximate interval.
            # Overlap is diagnostic evidence, not an independently timed GC start.
            episode["overlaps_gc"] = any(
                gc["completion_ms"] >= episode["start_ms"]
                and gc["completion_ms"] - gc["gc_ms"] <= episode["end_ms"]
                for gc in trace.get("gc_events", []))
        episodes.extend(cycle_episodes)
        per_cycle.append(dict(label=trace["label"],
                              response_ms=summary["scheduled_to_redisplay_ms"],
                              delayed_inputs=sum(r["ms"] > 50 for r in detail["response"]),
                              episodes=len(cycle_episodes), gc_count=summary["gc_count"],
                              gc_ms=summary["gc_ms"],
                              max_position_error_px=summary["max_position_error_px"]))
    slow = sum(r["ms"] > 50 for r in responses)
    recorded_gcs = sum(s["gc_count"] for s in summaries)
    recorded_gc_ms = sum(s["gc_ms"] for s in summaries)
    return dict(cycles=len(traces), scheduled=sum(s["scheduled"] for s in summaries),
                handled=sum(s["handled"] for s in summaries), measured_responses=len(responses),
                missing=sum(s["missing"] for s in summaries),
                unmeasured_responses=sum(s["handled"] for s in summaries) - len(responses),
                response_ms=trace_analysis.distribution([r["ms"] for r in responses]),
                delayed_inputs=slow, delayed_input_percent=100 * slow / len(responses) if responses else None,
                episodes=episodes, episode_count=len(episodes),
                episodes_overlapping_gc=sum(e["overlaps_gc"] for e in episodes),
                recorded_gc_count=recorded_gcs, recorded_gc_ms=recorded_gc_ms,
                arm_gc_count=arm["gc_count"] if arm else None,
                arm_gc_ms=arm["gc_ms"] if arm else None,
                between_segments_gc_count=arm["gc_count"] - recorded_gcs if arm else None,
                between_segments_gc_ms=arm["gc_ms"] - recorded_gc_ms if arm else None,
                arm_wall_seconds=arm["wall_seconds"] if arm else None,
                max_position_error_px=max((s["max_position_error_px"] for s in summaries), default=None),
                unknown_anchor_samples=sum(s["unknown_anchor_samples"] for s in summaries),
                per_cycle=per_cycle)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path, help="Directory with raw/before-NN.json and after-NN.json")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    results = {}
    for version in ("before", "after"):
        files = sorted((args.directory / "raw").glob(f"{version}-[0-9][0-9].json"))
        traces = [json.loads(file.read_text()) for file in files]
        arm_file = args.directory / f"{version}-arm.json"
        arm = json.loads(arm_file.read_text()) if arm_file.exists() else None
        results[version] = aggregate(traces, arm)
        results[version]["complete"] = bool(arm and len(traces) == arm["cycles"])
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "summary.json").write_text(json.dumps(results, indent=2) + "\n")
    lines = ["# Longer scroll comparison", "",
             "Software response from scheduled input to a redisplay opportunity; not physical display FPS.", "",
             "| Version | Segments | Inputs >50 ms | Slow-response episodes | p95 / p99 / max response | Recorded GC count / time | Whole-arm GC count / time |",
             "|---|---:|---:|---:|---:|---:|---:|"]
    for version, result in results.items():
        def ms(value):
            return "n/a" if value is None else f"{value:.2f}"
        p = result["response_ms"]
        lines.append(f"| {version} | {result['cycles']} | {result['delayed_inputs']} "
                     f"| {result['episode_count']} | {ms(p['p95'])} / {ms(p['p99'])} / {ms(p['max'])} ms "
                     f"| {result['recorded_gc_count']} / {ms(result['recorded_gc_ms'])} ms "
                     f"| {result['arm_gc_count']} / {ms(result['arm_gc_ms'])} ms |")
    lines += ["", "Episodes combine overlapping slow input-response intervals within each segment. "
              "Ten inputs delayed by one pause can therefore count as one episode. Episode spans are not "
              "measured screen freeze durations. Whole-arm GC totals include between-segment setup and file writing; "
              "recorded totals cover the six-second traces only. Explicit collections before each arm are excluded.", "",
              "[Full summary and individual episodes](summary.json)"]
    (args.output / "report.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
