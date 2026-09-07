"""Known-answer tests for measurements, independent of the GUI recorder."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("analysis", Path(__file__).with_name("analyze-scroll-trace.py"))
analysis = importlib.util.module_from_spec(spec)
spec.loader.exec_module(analysis)


def event(id, scheduled, enqueued, start, finish, before, after):
    return dict(id=id, scheduled_ms=scheduled, enqueue_ms=enqueued, start_ms=start,
                finish_ms=finish, before_px=before, after_px=after, delta_px=16)


def observation(time, position, completed, kind="pre-redisplay"):
    return dict(time_ms=time, position_px=position, started=completed,
                completed=completed, kind=kind)


def fixture():
    return dict(label="known", hz=60, metadata={}, gc_count=0, gc_ms=0,
                events=[event(1, 10, 20, 23, 27, 1000, 984),
                        event(2, 30, 30, 31, 33, 984, 968)],
                observations=[observation(0, 1000, 0, "initial"),
                              observation(30, 984, 1), observation(35, 968, 2),
                              observation(50, 968, 2, "heartbeat")])


class AnalysisTests(unittest.TestCase):
    def test_delayed_input_is_latency_not_a_position_jump(self):
        summary, _ = analysis.analyze(fixture())
        self.assertEqual(summary["timer_lateness_ms"]["max"], 10)
        self.assertEqual(summary["queue_delay_ms"]["max"], 3)
        self.assertEqual(summary["handler_ms"]["max"], 4)
        self.assertEqual(summary["scheduled_to_redisplay_ms"]["max"], 20)
        self.assertEqual(summary["max_position_error_px"], 0)
        self.assertEqual(summary["max_unrequested_jump_px"], 0)

    def test_content_moves_during_hold_without_input(self):
        trace = fixture()
        trace["observations"][-1]["position_px"] += 60
        summary, _ = analysis.analyze(trace)
        self.assertEqual(summary["max_position_error_px"], 60)
        self.assertEqual(summary["max_unrequested_jump_px"], 60)
        self.assertEqual(summary["unrequested_jumps_over_1px"], 1)
        self.assertEqual(summary["tail_motion_ms"], 20)

    def test_missing_events_and_anchors_are_reported(self):
        trace = fixture()
        trace["events"].append(event(3, 60, None, None, None, None, None))
        trace["observations"].append(observation(70, None, 2))
        summary, _ = analysis.analyze(trace)
        self.assertEqual(summary["missing"], 1)
        self.assertEqual(summary["handled"], 2)
        self.assertEqual(summary["unknown_anchor_samples"], 1)

    def test_percentiles_and_empty_samples(self):
        self.assertEqual(analysis.distribution(list(range(1, 101))),
                         {"p50": 50, "p95": 95, "p99": 99, "max": 100})
        self.assertIsNone(analysis.distribution([])["p95"])

    def test_hold_drift_is_not_counted_as_a_scrolling_frame_gap(self):
        trace = fixture()
        trace["hz"] = 1  # Small synthetic plan: three up inputs, then one down.
        trace["events"] = [event(1, 10, 10, 11, 12, 1000, 984),
                           event(2, 20, 20, 21, 22, 984, 968),
                           event(3, 30, 30, 31, 32, 968, 952),
                           event(4, 1000, 1000, 1001, 1002, 968, 952)]
        trace["observations"] = [observation(0, 1000, 0, "initial"),
                                 observation(15, 984, 1), observation(25, 968, 2),
                                 observation(35, 952, 3), observation(500, 968, 3),
                                 observation(1005, 952, 4)]
        summary, _ = analysis.analyze(trace)
        self.assertEqual(summary["movement_interval_ms"]["max"], 10)
        self.assertEqual(summary["max_unrequested_jump_px"], 16)


if __name__ == "__main__":
    unittest.main()
