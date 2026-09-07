"""Known-answer tests for grouping delayed inputs into episodes."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("soak", Path(__file__).with_name("analyze-scroll-soak.py"))
soak = importlib.util.module_from_spec(spec)
spec.loader.exec_module(soak)


class SoakTests(unittest.TestCase):
    def test_many_delayed_inputs_from_one_pause_are_one_episode(self):
        responses = [dict(scheduled_ms=0, ms=200), dict(scheduled_ms=20, ms=190),
                     dict(scheduled_ms=40, ms=175)]
        episodes = soak.slow_episodes(responses)
        self.assertEqual(len(episodes), 1)
        self.assertEqual(episodes[0]["inputs"], 3)
        self.assertEqual(episodes[0]["start_ms"], 0)
        self.assertEqual(episodes[0]["end_ms"], 215)

    def test_separated_pauses_stay_separate(self):
        responses = [dict(scheduled_ms=0, ms=70), dict(scheduled_ms=100, ms=50),
                     dict(scheduled_ms=200, ms=80)]
        episodes = soak.slow_episodes(responses)
        self.assertEqual(len(episodes), 2)
        self.assertEqual([e["inputs"] for e in episodes], [1, 1])

    def test_same_relative_times_in_separate_segments_are_separate(self):
        trace = dict(label="a", hz=60, metadata={}, gc_count=1, gc_ms=70,
                     gc_events=[dict(completion_ms=90, gc_ms=70)],
                     events=[dict(id=1, scheduled_ms=10, enqueue_ms=90, start_ms=91,
                                  finish_ms=92, delta_px=16)],
                     observations=[dict(time_ms=0, position_px=100, started=0, completed=0, kind="initial"),
                                   dict(time_ms=95, position_px=84, started=1, completed=1, kind="pre-redisplay")])
        result = soak.aggregate([trace, trace], dict(gc_count=3, gc_ms=200, wall_seconds=14))
        self.assertEqual(result["episode_count"], 2)
        self.assertEqual(result["episodes_overlapping_gc"], 2)
        self.assertEqual(result["between_segments_gc_count"], 1)
        self.assertEqual(result["between_segments_gc_ms"], 60)


if __name__ == "__main__":
    unittest.main()
