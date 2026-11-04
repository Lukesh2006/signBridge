"""Offline regressions for the personal-sign reliability gate.

MediaPipe is never run: extract_sequence is replaced with synthetic landmark
sequences, and the sample/model folders point at a temporary directory.

Run from backend/: python -m unittest discover -s tests/regression -v
"""

import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import numpy as np

from app.models import personal_sign_model as psm

FRAMES = 16


def _sequence(offset: float = 0.0, motion: float = 0.15, seed: int = 0, hands: bool = True) -> list:
    """Pose + two hands moving sideways; `offset` shifts every point along x.

    DTW averages over rows + columns, so an x offset d gives a distance of
    roughly d / 2 between two equal-length sequences.
    """
    rng = np.random.default_rng(seed)
    base = np.random.default_rng(42).uniform(0.2, 0.8, size=(75, 3)).astype(np.float32)
    frames = []
    for index in range(FRAMES):
        points = base.copy()
        points[:, 0] += offset + motion * np.sin(index / 2.0)
        points += rng.normal(0.0, 0.001, size=points.shape).astype(np.float32)
        if not hands:
            points[33:] = 0.0
        values = np.zeros(psm.FEATURE_COUNT, dtype=np.float32)
        values[: psm.LANDMARK_VALUE_COUNT] = points.reshape(-1)
        frames.append(values.tolist())
    return frames


class _GateTestCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        root = Path(self._tmp.name)
        self.clips: dict[bytes, list] = {}
        self._counter = 0
        patches = [
            patch.object(psm, "SAMPLE_ROOT", root / "training_samples"),
            patch.object(psm, "MODEL_ROOT", root / "personal_models"),
            patch.object(psm, "SEED_MODEL_PATH", root / "personal_models" / "continuous_seed.json"),
            patch.object(psm, "extract_sequence", side_effect=self._extract),
        ]
        for patcher in patches:
            patcher.start()
            self.addCleanup(patcher.stop)
        self.addCleanup(self._tmp.cleanup)

    def _extract(self, video_bytes, frame_count=FRAMES):
        return self.clips[video_bytes]

    def clip(self, **kwargs) -> bytes:
        self._counter += 1
        data = f"clip-{self._counter}".encode()
        self.clips[data] = _sequence(seed=self._counter, **kwargs)
        return data

    def save(self, label, user="user-1", kind=None, confirm=False, **kwargs):
        return psm.save_sample(user, label, self.clip(**kwargs), kind=kind, confirm=confirm)

    def model_path(self, user="user-1") -> Path:
        return psm.MODEL_ROOT / f"{user}.json"


class SampleGateTests(_GateTestCase):
    def test_first_clip_is_accepted_and_cached(self):
        result = self.save("Hello")
        self.assertTrue(result["saved"])
        self.assertEqual(result["decision"], "accepted")
        self.assertEqual(result["kind"], "isl_variant")
        cache = psm.SAMPLE_ROOT / "user-1" / "hello" / f"{result['sample_id']}.json"
        record = json.loads(cache.read_text(encoding="utf-8"))
        self.assertEqual(len(record["sequence"]), FRAMES)
        self.assertEqual(record["gate"]["decision"], "accepted")

    def test_missing_hands_is_rejected_and_not_saved(self):
        result = self.save("Hello", hands=False)
        self.assertFalse(result["saved"])
        self.assertEqual(result["decision"], "rejected")
        self.assertIn("Hands", result["reasons"][0])
        self.assertEqual(psm.list_samples("user-1"), {})

    def test_static_clip_is_rejected(self):
        result = self.save("Hello", motion=0.0)
        self.assertEqual(result["decision"], "rejected")
        self.assertFalse(result["saved"])

    def test_consistent_clip_is_accepted(self):
        self.save("Hello")
        self.save("Hello")
        result = self.save("Hello")
        self.assertEqual(result["decision"], "accepted")
        self.assertEqual(result["samples_for_sign"], 3)
        self.assertLess(result["checks"]["own_median_distance"], psm.CONSISTENCY_MAX)

    def test_inconsistent_clip_needs_confirmation_then_saves_on_confirm(self):
        self.save("Hello")
        self.save("Hello")
        warned = self.save("Hello", offset=0.24)
        self.assertEqual(warned["decision"], "needs_confirmation")
        self.assertFalse(warned["saved"])
        self.assertIn("different", warned["reasons"][0])
        self.assertEqual(psm.list_samples("user-1"), {"hello": 2})

        confirmed = self.save("Hello", offset=0.24, confirm=True)
        self.assertTrue(confirmed["saved"])
        self.assertEqual(confirmed["decision"], "needs_confirmation")
        self.assertEqual(psm.list_samples("user-1"), {"hello": 3})
        details = psm.list_sample_details("user-1")["hello"]["samples"]
        self.assertTrue(details[-1]["gate"]["confirmed_by_user"])

    def test_clip_closer_to_another_sign_warns(self):
        for _ in range(2):
            self.save("Hello")
            self.save("Thanks", offset=0.3)
        # Halfway-plus towards THANKS: further from HELLO than from THANKS.
        result = self.save("Hello", offset=0.2)
        self.assertEqual(result["decision"], "needs_confirmation")
        self.assertEqual(result["checks"]["nearest_other_label"], "thanks")
        self.assertTrue(any("THANKS" in reason for reason in result["reasons"]))

    def test_first_clip_of_new_sign_near_existing_sign_warns(self):
        self.save("Hello")
        result = self.save("Wave", offset=0.04)
        self.assertEqual(result["decision"], "needs_confirmation")
        self.assertIn("HELLO", result["reasons"][0])

    def test_other_users_clips_are_not_compared(self):
        self.save("Hello", user="user-2")
        result = self.save("Wave", offset=0.04)
        self.assertEqual(result["decision"], "accepted")
        self.assertNotIn("nearest_other_label", result["checks"])

    def test_kind_is_kept_per_sign_and_conflicts_are_rejected(self):
        self.save("Zap", kind="custom_gesture")
        follow_up = self.save("Zap")
        self.assertEqual(follow_up["kind"], "custom_gesture")
        with self.assertRaises(ValueError):
            self.save("Zap", kind="isl_variant")
        with self.assertRaises(ValueError):
            self.save("Other", kind="made_up")
        self.assertEqual(psm.list_sample_details("user-1")["zap"]["kind"], "custom_gesture")

    def test_invalid_label_is_rejected(self):
        with self.assertRaises(ValueError):
            self.save("../escape")


class DeleteSampleTests(_GateTestCase):
    def _train_two_signs(self, hello_clips=3):
        ids = [self.save("Hello")["sample_id"] for _ in range(hello_clips)]
        for _ in range(3):
            self.save("Thanks", offset=0.6)
        psm.train_user("user-1")
        return ids

    def test_delete_without_model_leaves_no_model(self):
        sample_id = self.save("Hello")["sample_id"]
        result = psm.delete_sample("user-1", "hello", sample_id)
        self.assertEqual(result["model"], "not_trained")
        self.assertEqual(result["samples_for_sign"], 0)
        self.assertFalse((psm.SAMPLE_ROOT / "user-1" / "hello").exists())
        self.assertFalse(self.model_path().exists())

    def test_delete_rebuilds_model_without_the_clip(self):
        ids = self._train_two_signs(hello_clips=4)
        result = psm.delete_sample("user-1", "hello", ids[0])
        self.assertEqual(result["model"], "rebuilt")
        model = json.loads(self.model_path().read_text(encoding="utf-8"))
        self.assertEqual(len(model["prototypes"]), 6)
        self.assertEqual(model["labels"], {"hello": "isl_variant", "thanks": "isl_variant"})

    def test_delete_below_minimum_removes_model(self):
        ids = self._train_two_signs(hello_clips=3)
        result = psm.delete_sample("user-1", "hello", ids[0])
        self.assertEqual(result["model"], "removed")
        self.assertFalse(self.model_path().exists())

    def test_bad_or_missing_sample_id(self):
        with self.assertRaises(ValueError):
            psm.delete_sample("user-1", "hello", "../../secret")
        with self.assertRaises(LookupError):
            psm.delete_sample("user-1", "hello", "123")


class TrainUserTests(_GateTestCase):
    def test_validation_reports_leave_one_out_and_seed_baseline(self):
        for _ in range(3):
            self.save("Hello")
            self.save("Thanks", offset=0.6)
        # A seed signer whose HELLO looks like this user's THANKS.
        seed = {
            "prototypes": [
                {"label": "hello", "sequence": _sequence(offset=0.6, seed=90)},
                {"label": "thanks", "sequence": _sequence(offset=1.2, seed=91)},
            ]
        }
        psm.MODEL_ROOT.mkdir(parents=True, exist_ok=True)
        psm.SEED_MODEL_PATH.write_text(json.dumps(seed), encoding="utf-8")

        result = psm.train_user("user-1")
        validation = result["validation"]
        self.assertEqual(validation["accuracy"], 1.0)
        self.assertEqual(validation["total"], 6)
        baseline = validation["seed_baseline"]
        self.assertEqual(baseline["clips"], 6)
        self.assertEqual(baseline["personal_model_accuracy"], 1.0)
        self.assertLess(baseline["seed_model_accuracy"], 1.0)

    def test_training_needs_three_clips_for_two_signs(self):
        self.save("Hello")
        with self.assertRaises(ValueError):
            psm.train_user("user-1")


class PredictBandTests(_GateTestCase):
    def setUp(self):
        super().setUp()
        model = {
            "labels": {"hello": "isl_variant", "zap": "custom_gesture"},
            "prototypes": [
                {"label": "hello", "sequence": _sequence(seed=1)},
                {"label": "hello", "sequence": _sequence(seed=2)},
                {"label": "zap", "sequence": _sequence(offset=1.0, seed=3)},
            ],
        }
        psm.MODEL_ROOT.mkdir(parents=True, exist_ok=True)
        self.model_path().write_text(json.dumps(model), encoding="utf-8")

    def predict(self, **kwargs):
        return psm.predict_user("user-1", self.clip(**kwargs))

    def test_close_match_is_accepted(self):
        result = self.predict()
        self.assertEqual(result["decision"], "accepted")
        self.assertTrue(result["accepted"])
        self.assertEqual(result["label"], "hello")
        self.assertEqual(result["model"], "personal")

    def test_middle_distance_asks_for_confirmation(self):
        result = self.predict(offset=0.24)
        self.assertEqual(result["decision"], "confirm")
        self.assertFalse(result["accepted"])
        self.assertEqual(result["label"], "")
        self.assertEqual(result["suggestion"], "hello")

    def test_far_clip_is_rejected(self):
        result = self.predict(offset=0.5)
        self.assertEqual(result["decision"], "rejected")

    def test_missing_hands_is_rejected_even_when_close(self):
        result = self.predict(hands=False)
        self.assertEqual(result["decision"], "rejected")
        self.assertIn("Hands", result["reason"])

    def test_custom_gesture_kind_is_reported(self):
        result = self.predict(offset=1.0)
        self.assertEqual(result["suggestion"], "zap")
        self.assertEqual(result["kind"], "custom_gesture")

    def test_seed_fallback_reports_isl_kind(self):
        self.model_path().unlink()
        seed = {"prototypes": [{"label": "hello", "sequence": _sequence(seed=5)}]}
        psm.SEED_MODEL_PATH.write_text(json.dumps(seed), encoding="utf-8")
        result = self.predict()
        self.assertEqual(result["model"], "seed")
        self.assertEqual(result["kind"], "isl")


if __name__ == "__main__":
    unittest.main()
