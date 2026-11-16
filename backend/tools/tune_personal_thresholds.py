"""Measure the personal-sign cut-offs on every recorded signer and suggest new ones.

Reads the clips saved by the app under ``training_samples/<user>/<sign>/*.mp4``
(the ``seed`` folder counts as one signer) and replays the same decision rule as
``predict_user`` with different cut-offs. Nothing is written outside the
project: features are cached next to each clip, and the report goes to
``personal_models/threshold_report.json``.

Three tests are run:

* ``same_signer``  - each clip is matched against the same person's other clips
  (what happens after a user trains their own signs).
* ``unknown_sign`` - the clip's whole sign is removed first, so the app has never
  been taught it. Any "match" here is a false match.
* ``cross_signer`` - each clip is matched against everyone else's clips (how well
  one person's examples work for a new person, e.g. the seed model).

Usage (from ``backend``):

    .venv\\Scripts\\python.exe tools\\tune_personal_thresholds.py
    .venv\\Scripts\\python.exe tools\\tune_personal_thresholds.py --max-false-match 0.01
    .venv\\Scripts\\python.exe tools\\tune_personal_thresholds.py --exact   # re-read 8-frame queries from video
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np

BACKEND_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND_ROOT))

from app.models import personal_sign_model as psm  # noqa: E402

# Live predictions use 8 frames per clip; the cached features have 16.
QUERY_FRAMES = 8
MIN_CLIPS_PER_SIGN = 3  # same rule as train_user()
REPORT_PATH = psm.MODEL_ROOT / "threshold_report.json"


@dataclass
class Trial:
    test: str
    signer: str
    actual: str          # the sign that was performed
    known: bool          # whether that sign is among the examples
    best_label: str
    best_distance: float
    gap: float
    single_label: bool
    hands_ok: bool


@dataclass
class Clip:
    signer: str
    label: str
    path: Path
    sequence: np.ndarray   # 16-frame features (examples)
    query: np.ndarray      # 8-frame features (what live prediction sees)


def load_clips(exact: bool) -> list[Clip]:
    clips: list[Clip] = []
    for user_dir in sorted(psm.SAMPLE_ROOT.iterdir()):
        if not user_dir.is_dir() or user_dir.name.startswith("."):
            continue
        for label_dir in sorted(user_dir.iterdir()):
            if not label_dir.is_dir() or label_dir.name.startswith("."):
                continue
            for path in sorted(label_dir.glob("*.mp4")):
                try:
                    sequence = np.asarray(psm._load_sequence(path), dtype=np.float32)
                    if exact:
                        query = np.asarray(
                            psm.extract_sequence(path.read_bytes(), frame_count=QUERY_FRAMES),
                            dtype=np.float32,
                        )
                    else:
                        picks = np.linspace(0, len(sequence) - 1, QUERY_FRAMES).astype(int)
                        query = sequence[picks]
                except ValueError as exc:
                    print(f"  skipped {path.relative_to(psm.USB_ROOT)}: {exc}")
                    continue
                clips.append(Clip(user_dir.name, label_dir.name, path, sequence, query))
    return clips


def trainable(clips: list[Clip]) -> list[Clip]:
    """Keep only signs with enough clips to be trained, as the app requires."""
    counts: dict[str, int] = {}
    for clip in clips:
        counts[clip.label] = counts.get(clip.label, 0) + 1
    return [clip for clip in clips if counts[clip.label] >= MIN_CLIPS_PER_SIGN]


def score(test: str, query_clip: Clip, examples: list[Clip]) -> Trial | None:
    if not examples:
        return None
    distances: dict[str, list[float]] = {}
    for example in examples:
        distances.setdefault(example.label, []).append(
            psm.sequence_distance(query_clip.query, example.sequence)
        )
    ranked = sorted((float(np.mean(values)), label) for label, values in distances.items())
    best_distance, best_label = ranked[0]
    signals = psm._signal_diagnostics(query_clip.query)
    hands_ok = signals["hands_frames"] >= psm.PREDICT_MIN_HANDS_RATIO * max(signals["frames_analyzed"], 1)
    return Trial(
        test=test,
        signer=query_clip.signer,
        actual=query_clip.label,
        known=query_clip.label in distances,
        best_label=best_label,
        best_distance=best_distance,
        gap=(ranked[1][0] - best_distance) if len(ranked) > 1 else 0.0,
        single_label=len(ranked) == 1,
        hands_ok=hands_ok,
    )


def run_trials(clips: list[Clip]) -> list[Trial]:
    trials: list[Trial] = []
    signers = sorted({clip.signer for clip in clips})
    for signer in signers:
        own = trainable([clip for clip in clips if clip.signer == signer])
        others = [clip for clip in clips if clip.signer != signer]
        for clip in own:
            rest = [other for other in own if other is not clip]
            trials.append(score("same_signer", clip, rest))
            trials.append(score("unknown_sign", clip, [other for other in own if other.label != clip.label]))
            trials.append(score("cross_signer", clip, trainable(others)))
    return [trial for trial in trials if trial is not None]


def decide(trial: Trial, accept: float, gap_min: float, confirm: float) -> str:
    """Same rule as predict_user()."""
    if trial.hands_ok and trial.best_distance < accept and (trial.single_label or trial.gap > gap_min):
        return "accepted"
    if trial.hands_ok and trial.best_distance < confirm:
        return "confirm"
    return "rejected"


def rates(trials: list[Trial], accept: float, gap_min: float, confirm: float) -> dict:
    known = [t for t in trials if t.known]
    unknown = [t for t in trials if not t.known]
    right_match = wrong_match = right_maybe = wrong_maybe = rejected = 0
    unknown_match = unknown_maybe = 0
    for trial in known:
        decision = decide(trial, accept, gap_min, confirm)
        correct = trial.best_label == trial.actual
        if decision == "accepted":
            right_match += correct
            wrong_match += not correct
        elif decision == "confirm":
            right_maybe += correct
            wrong_maybe += not correct
        else:
            rejected += 1
    for trial in unknown:
        decision = decide(trial, accept, gap_min, confirm)
        unknown_match += decision == "accepted"
        unknown_maybe += decision == "confirm"

    def share(value: int, total: int) -> float | None:
        return round(value / total, 4) if total else None

    return {
        "known_trials": len(known),
        "correct_match": share(right_match, len(known)),
        "wrong_match": share(wrong_match, len(known)),
        "correct_maybe": share(right_maybe, len(known)),
        "wrong_maybe": share(wrong_maybe, len(known)),
        "not_recognized": share(rejected, len(known)),
        "unknown_trials": len(unknown),
        "unknown_matched": share(unknown_match, len(unknown)),
        "unknown_maybe": share(unknown_maybe, len(unknown)),
    }


def false_match_rate(trials: list[Trial], accept: float, gap_min: float) -> float:
    """Share of all trials where the app would confidently say the wrong sign."""
    bad = sum(
        1
        for trial in trials
        if decide(trial, accept, gap_min, np.inf) == "accepted"
        and (not trial.known or trial.best_label != trial.actual)
    )
    return bad / len(trials) if trials else 0.0


def suggest(trials: list[Trial], max_false_match: float) -> dict:
    personal = [t for t in trials if t.test in {"same_signer", "unknown_sign"}]
    gap_min = psm.ACCEPT_GAP
    candidates = np.round(np.arange(0.02, 0.301, 0.005), 3)
    accept = float(candidates[0])
    for value in candidates:
        if false_match_rate(personal, float(value), gap_min) <= max_false_match:
            accept = float(value)
    # "Maybe" should still catch most real signs that miss the strict cut-off.
    correct_distances = sorted(
        t.best_distance for t in personal if t.known and t.best_label == t.actual and t.hands_ok
    )
    confirm = (
        float(np.round(np.percentile(correct_distances, 95), 3)) if correct_distances else psm.CONFIRM_DISTANCE
    )
    return {
        "ACCEPT_DISTANCE": accept,
        "ACCEPT_GAP": gap_min,
        "CONFIRM_DISTANCE": max(confirm, accept),
        "rule": (
            f"Largest ACCEPT_DISTANCE whose false-match rate on same_signer + unknown_sign is "
            f"<= {max_false_match:.0%}; CONFIRM_DISTANCE = 95th percentile of correct-match distances."
        ),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--max-false-match", type=float, default=0.02,
                        help="highest acceptable share of confident wrong answers (default 0.02)")
    parser.add_argument("--exact", action="store_true",
                        help="re-read 8-frame queries from each video instead of sub-sampling cached features")
    args = parser.parse_args()

    print(f"Reading clips under {psm.SAMPLE_ROOT} ...")
    clips = load_clips(args.exact)
    signers = sorted({clip.signer for clip in clips})
    per_signer = {
        signer: {
            label: sum(1 for c in clips if c.signer == signer and c.label == label)
            for label in sorted({c.label for c in clips if c.signer == signer})
        }
        for signer in signers
    }
    trials = run_trials(clips)
    current = (psm.ACCEPT_DISTANCE, psm.ACCEPT_GAP, psm.CONFIRM_DISTANCE)
    suggestion = suggest(trials, args.max_false_match)
    proposed = (suggestion["ACCEPT_DISTANCE"], suggestion["ACCEPT_GAP"], suggestion["CONFIRM_DISTANCE"])

    warnings = []
    if len(signers) < 3:
        warnings.append(f"Only {len(signers)} signer(s). Record at least 3-5 different people before changing the cut-offs.")
    if any(len(labels) < 3 for labels in per_signer.values()):
        warnings.append("Some signers have fewer than 3 signs; the unknown-sign test is weak for them.")

    report = {
        "signers": per_signer,
        "clips": len(clips),
        "query_frames": "exact" if args.exact else "sub-sampled from cached 16-frame features",
        "current": {"ACCEPT_DISTANCE": current[0], "ACCEPT_GAP": current[1], "CONFIRM_DISTANCE": current[2]},
        "suggested": suggestion,
        "results": {
            test: {
                "current": rates([t for t in trials if t.test == test], *current),
                "suggested": rates([t for t in trials if t.test == test], *proposed),
            }
            for test in ("same_signer", "unknown_sign", "cross_signer")
        },
        "warnings": warnings,
    }
    psm.MODEL_ROOT.mkdir(parents=True, exist_ok=True)
    REPORT_PATH.write_text(json.dumps(report, indent=2), encoding="utf-8")

    print(f"\nSigners: {len(signers)}  clips: {len(clips)}")
    for signer, labels in per_signer.items():
        print(f"  {signer}: " + ", ".join(f"{label}={count}" for label, count in labels.items()))
    print(f"\nCurrent   accept<{current[0]}  gap>{current[1]}  maybe<{current[2]}")
    print(f"Suggested accept<{proposed[0]}  gap>{proposed[1]}  maybe<{proposed[2]}")
    for test, result in report["results"].items():
        for name in ("current", "suggested"):
            r = result[name]
            if r["known_trials"]:
                print(f"  {test:13s} {name:9s} correct match {r['correct_match']:.0%}  wrong match {r['wrong_match']:.0%}"
                      f"  maybe {((r['correct_maybe'] or 0) + (r['wrong_maybe'] or 0)):.0%}  not recognized {r['not_recognized']:.0%}")
            if r["unknown_trials"]:
                print(f"  {test:13s} {name:9s} untaught sign called a match {r['unknown_matched']:.0%}"
                      f"  maybe {r['unknown_maybe']:.0%}")
    for warning in warnings:
        print(f"\nWARNING: {warning}")
    print(f"\nFull report: {REPORT_PATH}")


if __name__ == "__main__":
    main()
