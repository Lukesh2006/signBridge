"""Local, per-user sign prototypes built from the user's own short clips.

This deliberately starts as a small personalized nearest-prototype model. It
does not claim to understand continuous ISL or replace a reviewed ISL dataset.
All source clips and model files stay under the USB repository.
"""

from __future__ import annotations

import json
import logging
import os
import re
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import cv2
import numpy as np

from app.websocket.websocket_processing import (
    build_landmarkers,
    mp,
    mp_python,
    mp_vision,
)

logger = logging.getLogger(__name__)

BACKEND_ROOT = Path(__file__).resolve().parents[2]
USB_ROOT = BACKEND_ROOT.parent
SAMPLE_ROOT = USB_ROOT / "training_samples"
MODEL_ROOT = USB_ROOT / "personal_models"
SEED_ROOT = SAMPLE_ROOT / "seed"
SEED_MODEL_PATH = MODEL_ROOT / "continuous_seed.json"
FACE_MODEL_PATH = BACKEND_ROOT / "models" / "face_landmarker.task"
FRAME_COUNT = 16
LANDMARK_VALUE_COUNT = 225
FACE_BLENDSHAPE_COUNT = 52
FACE_PRESENT_INDEX = LANDMARK_VALUE_COUNT + FACE_BLENDSHAPE_COUNT
FEATURE_COUNT = FACE_PRESENT_INDEX + 1
MAX_UPLOAD_BYTES = 25 * 1024 * 1024
SAFE_LABEL = re.compile(r"^[\w -]{1,40}$", re.UNICODE)
SAMPLE_ID = re.compile(r"^\d{1,25}$")
LABEL_META = "_label.json"

# A personal variation of a standard ISL sign is kept apart from a gesture the
# user invented, so a custom gesture is never presented as standard ISL.
KIND_NAMES = {
    "isl_variant": "your way of an ISL sign",
    "custom_gesture": "your own custom gesture",
}
KINDS = set(KIND_NAMES)
DEFAULT_KIND = "isl_variant"
SEED_KIND = "isl"

# Reliability gate for new personal examples. Starting values come from the 16
# seed clips of one signer (same-sign DTW distance p50 0.058 / max 0.075,
# different-sign p50 0.072, motion 0.031-0.076); tune them on real users.
MIN_HANDS_RATIO = 0.6
MIN_BODY_RATIO = 0.6
MIN_MOTION = 0.012
CONSISTENCY_MAX = 0.09
CONFUSION_MARGIN = 0.01
FIRST_CLIP_CONFUSION_MAX = 0.05

# Prediction bands: show the sign, ask the user to confirm it, or reject it.
ACCEPT_DISTANCE = 0.10
ACCEPT_GAP = 0.004
CONFIRM_DISTANCE = 0.14
PREDICT_MIN_HANDS_RATIO = 0.5

# Building the three MediaPipe detectors takes seconds, so each worker thread
# builds its own set once and keeps it. Detectors are not thread-safe, which is
# why they are per thread; frames of one clip are spread across the workers.
EXTRACT_WORKERS = max(1, min(4, (os.cpu_count() or 1) // 3))
_extract_pool: ThreadPoolExecutor | None = None
_extract_pool_lock = threading.Lock()
_thread_state = threading.local()
_all_detectors: list[tuple] = []


def _build_face_landmarker():
    if mp is None or mp_vision is None or mp_python is None or not FACE_MODEL_PATH.exists():
        return None
    return mp_vision.FaceLandmarker.create_from_options(
        mp_vision.FaceLandmarkerOptions(
            base_options=mp_python.BaseOptions(model_asset_path=str(FACE_MODEL_PATH)),
            num_faces=1,
            output_face_blendshapes=True,
            output_facial_transformation_matrixes=True,
        )
    )


def _frame_feature(
    frame: np.ndarray,
    pose_detector,
    hand_detector,
    face_detector,
) -> np.ndarray:
    """Build pose, hand and facial-expression features for one frame."""
    rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
    image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
    values = np.zeros(FEATURE_COUNT, dtype=np.float32)
    pose_landmarks = None

    if pose_detector is not None:
        pose = pose_detector.detect(image)
        if pose.pose_landmarks:
            pose_landmarks = pose.pose_landmarks[0]
            for index, landmark in enumerate(pose_landmarks[:33]):
                values[index * 3:index * 3 + 3] = (landmark.x, landmark.y, landmark.z)

    if hand_detector is not None:
        hands = hand_detector.detect(image)
        if hands.hand_landmarks:
            for hand_index, landmarks in enumerate(hands.hand_landmarks[:2]):
                # Sort into left/right slots when handedness is supplied.
                target = hand_index
                if hands.handedness and hand_index < len(hands.handedness):
                    category = hands.handedness[hand_index][0].category_name.lower()
                    target = 0 if category == "left" else 1
                offset = 99 + target * 63
                for index, landmark in enumerate(landmarks[:21]):
                    start = offset + index * 3
                    values[start:start + 3] = (landmark.x, landmark.y, landmark.z)

    if face_detector is not None:
        face = face_detector.detect(image)
        if not face.face_blendshapes:
            # Full-body recordings often leave the face too small for the
            # detector. Crop around Pose's head anchors, enlarge the ROI, and
            # retry; expression scores are independent of the crop position.
            height, width = rgb.shape[:2]
            if pose_landmarks and len(pose_landmarks) > 8:
                head = [pose_landmarks[index] for index in (0, 2, 5, 7, 8)]
                xs = [point.x * width for point in head]
                ys = [point.y * height for point in head]
                nose = pose_landmarks[0]
                center_x = nose.x * width
                center_y = nose.y * height + 0.04 * height
                span_x = max(xs) - min(xs)
                span_y = max(ys) - min(ys)
                box_width = max(0.30 * width, 2.5 * span_x, 1.7 * span_y, 96)
                box_height = max(1.50 * box_width, 2.5 * span_y, 160)
                x1 = max(0, int(center_x - box_width / 2))
                x2 = min(width, int(center_x + box_width / 2))
                y1 = max(0, int(center_y - box_height / 2))
                y2 = min(height, int(center_y + box_height / 2))
                crop = rgb[y1:y2, x1:x2]
            else:
                crop = rgb[: max(1, int(height * 0.45)), :, :]
            if crop.size:
                enlarged = cv2.resize(crop, (256, 256), interpolation=cv2.INTER_CUBIC)
                cropped_image = mp.Image(image_format=mp.ImageFormat.SRGB, data=enlarged)
                face = face_detector.detect(cropped_image)
        if face.face_blendshapes:
            blendshapes = face.face_blendshapes[0]
            for index, category in enumerate(blendshapes[:FACE_BLENDSHAPE_COUNT]):
                values[LANDMARK_VALUE_COUNT + index] = category.score
            values[FACE_PRESENT_INDEX] = 1.0
    return values


def _thread_detectors() -> tuple:
    """This worker thread's (pose, hand, face) detectors, built on first use."""
    detectors = getattr(_thread_state, "detectors", None)
    if detectors is None:
        pose_detector, hand_detector = build_landmarkers()
        detectors = (pose_detector, hand_detector, _build_face_landmarker())
        _thread_state.detectors = detectors
        with _extract_pool_lock:
            _all_detectors.append(detectors)
    return detectors


def _extract_executor() -> ThreadPoolExecutor:
    global _extract_pool
    with _extract_pool_lock:
        if _extract_pool is None:
            _extract_pool = ThreadPoolExecutor(
                max_workers=EXTRACT_WORKERS, thread_name_prefix="sign-extract"
            )
        return _extract_pool


def _features_for_frame(frame: np.ndarray) -> list[float]:
    pose_detector, hand_detector, face_detector = _thread_detectors()
    if pose_detector is None and hand_detector is None and face_detector is None:
        raise RuntimeError("MediaPipe pose, hand and face models are unavailable on the USB drive.")
    return _frame_feature(frame, pose_detector, hand_detector, face_detector).tolist()


def warm_up_extractors() -> None:
    """Build every worker's detectors in the background so the first clip is not slow."""
    pool = _extract_executor()
    for _ in range(EXTRACT_WORKERS):
        pool.submit(_thread_detectors)


def shutdown_extractors() -> None:
    """Stop the workers and close their detectors while MediaPipe can still do so.

    Left to garbage collection at interpreter exit, MediaPipe's own close fails
    and prints a traceback for every detector.
    """
    global _extract_pool
    with _extract_pool_lock:
        pool, _extract_pool = _extract_pool, None
    if pool is not None:
        # Wait first so detectors still being built are registered and closed.
        pool.shutdown(wait=True, cancel_futures=True)
    with _extract_pool_lock:
        detectors, _all_detectors[:] = list(_all_detectors), []
    for detector in (item for group in detectors for item in group):
        if detector is not None:
            try:
                detector.close()
            except Exception:
                logger.exception("Could not close a MediaPipe detector")


def _read_frames(cap, indices: np.ndarray) -> dict[int, np.ndarray]:
    """Decode the clip once from the start and keep only the sampled frames.

    Seeking with CAP_PROP_POS_FRAMES re-decodes from a keyframe on every call,
    which is much slower than one pass over a short clip.
    """
    wanted = set(int(index) for index in indices)
    last = max(wanted)
    frames: dict[int, np.ndarray] = {}
    for position in range(last + 1):
        if position in wanted:
            ok, frame = cap.read()
            if ok:
                frames[position] = frame
        else:
            ok = cap.grab()
        if not ok:
            break
    return frames


def extract_sequence(video_bytes: bytes, frame_count: int = FRAME_COUNT) -> list[list[float]]:
    """Sample a local MP4/WebM in memory; never copies it to laptop temp storage."""
    # OpenCV's video decoder needs a path. Use the USB repo itself for its
    # short-lived input, then remove the file in the finally block.
    temp_dir = SAMPLE_ROOT / ".processing"
    temp_dir.mkdir(parents=True, exist_ok=True)
    extension = ".webm" if video_bytes.startswith(b"\x1a\x45\xdf\xa3") else ".mp4"
    temp_path = temp_dir / f"clip_{time.time_ns()}{extension}"
    cap = None
    try:
        temp_path.write_bytes(video_bytes)
        cap = cv2.VideoCapture(str(temp_path))
        if not cap.isOpened():
            raise ValueError("Could not read this video. Please use a short MP4 clip.")
        frame_total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
        if frame_total < 2:
            raise ValueError("The video is too short or contains no readable frames.")
        sample_indices = np.linspace(0, max(frame_total - 1, 0), frame_count).astype(int)
        frames = _read_frames(cap, sample_indices)
    finally:
        if cap is not None:
            cap.release()
        try:
            temp_path.unlink(missing_ok=True)
        except OSError:
            logger.warning("Could not remove temporary clip %s", temp_path)

    # Short clips repeat sample indices; analyze each distinct frame once.
    positions = sorted(frames)
    features = dict(zip(positions, _extract_executor().map(_features_for_frame, [frames[p] for p in positions])))
    sequence = [features[int(index)] for index in sample_indices if int(index) in features]
    if len(sequence) < 4:
        raise ValueError("Could not extract enough frames. Keep your hands visible and retry.")
    return sequence


def _safe_uid(user_id: str) -> str:
    # Firebase UIDs are expected to be URL/filesystem safe; also sanitize to
    # ensure the path cannot escape the USB project directory.
    return re.sub(r"[^A-Za-z0-9_-]", "_", user_id)[:128]


def _user_dir(user_id: str) -> Path:
    return SAMPLE_ROOT / _safe_uid(user_id)


def _user_model_path(user_id: str) -> Path:
    return MODEL_ROOT / f"{_safe_uid(user_id)}.json"


def _validate_label(label: str) -> str:
    label = label.strip()
    if not SAFE_LABEL.fullmatch(label) or label in {".", ".."}:
        raise ValueError("Use a sign name with letters, numbers, spaces, _ or - (max 40 characters).")
    return label


def _label_dir(user_id: str, label: str) -> Path:
    return _user_dir(user_id) / label.lower().replace(" ", "_")


def _read_json(path: Path) -> dict | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def _write_json(path: Path, data: dict) -> None:
    path.write_text(json.dumps(data, separators=(",", ":")), encoding="utf-8")


def _stored_kind(folder: Path) -> str | None:
    meta = _read_json(folder / LABEL_META) or {}
    kind = meta.get("kind")
    return kind if kind in KINDS else None


def _label_kind(folder: Path) -> str:
    return _stored_kind(folder) or DEFAULT_KIND


def _load_sequence(clip_path: Path) -> list[list[float]]:
    """Return a clip's 16-frame features, extracting and caching legacy clips."""
    cache_path = clip_path.with_suffix(".json")
    record = _read_json(cache_path) or {}
    if record.get("sequence"):
        return record["sequence"]
    record["sequence"] = extract_sequence(clip_path.read_bytes())
    record.setdefault("created_at", clip_path.stat().st_mtime)
    _write_json(cache_path, record)
    return record["sequence"]


def _user_clips(user_id: str) -> dict[str, list[Path]]:
    """Map each of the user's sign folders to its saved clips."""
    user_dir = _user_dir(user_id)
    if not user_dir.exists():
        return {}
    clips = {}
    for folder in sorted(user_dir.iterdir()):
        if not folder.is_dir() or folder.name == ".processing":
            continue
        paths = sorted(folder.glob("*.mp4"))
        if paths:
            clips[folder.name] = paths
    return clips


def _frame_distance(first: np.ndarray, second: np.ndarray) -> float:
    first_points = first[:LANDMARK_VALUE_COUNT].reshape(75, 3)
    second_points = second[:LANDMARK_VALUE_COUNT].reshape(75, 3)
    first_seen = np.linalg.norm(first_points, axis=1) > 1e-5
    second_seen = np.linalg.norm(second_points, axis=1) > 1e-5
    common = first_seen & second_seen
    union = first_seen | second_seen
    if common.sum() < 5:
        landmark_distance = 0.35
    else:
        landmark_distance = float(
            np.linalg.norm(first_points[common] - second_points[common], axis=1).mean()
        )
        if union.any():
            landmark_distance += 0.025 * float((first_seen ^ second_seen).sum() / union.sum())

    first_face = first[FACE_PRESENT_INDEX] > 0.5
    second_face = second[FACE_PRESENT_INDEX] > 0.5
    if first_face and second_face:
        face_distance = float(
            np.abs(
                first[LANDMARK_VALUE_COUNT:FACE_PRESENT_INDEX]
                - second[LANDMARK_VALUE_COUNT:FACE_PRESENT_INDEX]
            ).mean()
        )
        return 0.70 * landmark_distance + 0.30 * face_distance
    if first_face != second_face:
        landmark_distance += 0.03
    return landmark_distance


def _pairwise_frame_distances(first: np.ndarray, second: np.ndarray) -> np.ndarray:
    """_frame_distance for every (first frame, second frame) pair at once."""
    first_points = first[:, :LANDMARK_VALUE_COUNT].reshape(len(first), 75, 3)
    second_points = second[:, :LANDMARK_VALUE_COUNT].reshape(len(second), 75, 3)
    first_seen = np.linalg.norm(first_points, axis=2) > 1e-5
    second_seen = np.linalg.norm(second_points, axis=2) > 1e-5
    common = first_seen[:, None, :] & second_seen[None, :, :]
    common_count = common.sum(axis=2)
    union_count = (first_seen[:, None, :] | second_seen[None, :, :]).sum(axis=2)
    mismatch_count = (first_seen[:, None, :] ^ second_seen[None, :, :]).sum(axis=2)
    point_gaps = np.linalg.norm(first_points[:, None] - second_points[None, :], axis=3)
    enough = common_count >= 5
    landmark = np.where(
        enough,
        (point_gaps * common).sum(axis=2) / np.maximum(common_count, 1)
        + 0.025 * mismatch_count / np.maximum(union_count, 1),
        0.35,
    )

    first_face = first[:, FACE_PRESENT_INDEX] > 0.5
    second_face = second[:, FACE_PRESENT_INDEX] > 0.5
    both_faces = first_face[:, None] & second_face[None, :]
    one_face = first_face[:, None] ^ second_face[None, :]
    face = np.abs(
        first[:, None, LANDMARK_VALUE_COUNT:FACE_PRESENT_INDEX]
        - second[None, :, LANDMARK_VALUE_COUNT:FACE_PRESENT_INDEX]
    ).mean(axis=2)
    return np.where(both_faces, 0.70 * landmark + 0.30 * face, landmark + 0.03 * one_face)


def sequence_distance(first: np.ndarray, second: np.ndarray) -> float:
    """Dynamic time warping over landmark and face-expression feature frames."""
    rows, columns = len(first), len(second)
    local = _pairwise_frame_distances(
        np.asarray(first, dtype=np.float32), np.asarray(second, dtype=np.float32)
    ).tolist()
    # The frame distances above are the expensive part; the 16x16 warping
    # path itself is cheap in plain Python.
    previous = [0.0] + [float("inf")] * columns
    for row in range(rows):
        current = [float("inf")] * (columns + 1)
        local_row = local[row]
        for column in range(1, columns + 1):
            current[column] = local_row[column - 1] + min(
                previous[column], current[column - 1], previous[column - 1]
            )
        previous = current
    return previous[columns] / max(rows + columns, 1)


def _signal_diagnostics(sequence: np.ndarray) -> dict[str, int | float]:
    """Summarize which visual signals MediaPipe found in an analyzed clip."""
    frames = np.asarray(sequence, dtype=np.float32)
    pose = frames[:, :99].reshape(len(frames), 33, 3)
    left_hand = frames[:, 99:162].reshape(len(frames), 21, 3)
    right_hand = frames[:, 162:225].reshape(len(frames), 21, 3)
    pose_points = (np.linalg.norm(pose, axis=2) > 1e-5).sum(axis=1)
    left_points = (np.linalg.norm(left_hand, axis=2) > 1e-5).sum(axis=1)
    right_points = (np.linalg.norm(right_hand, axis=2) > 1e-5).sum(axis=1)
    face_frames = int((frames[:, FACE_PRESENT_INDEX] > 0.5).sum())
    return {
        "frames_analyzed": int(len(frames)),
        "body_frames": int((pose_points >= 15).sum()),
        "left_hand_frames": int((left_points >= 12).sum()),
        "right_hand_frames": int((right_points >= 12).sum()),
        "hands_frames": int(((left_points >= 12) | (right_points >= 12)).sum()),
        "face_frames": face_frames,
        "motion_score": round(float(np.abs(np.diff(frames[:, :LANDMARK_VALUE_COUNT], axis=0)).mean()), 4)
        if len(frames) > 1
        else 0.0,
    }


def assess_sample(
    sequence: list[list[float]],
    same_label: list[np.ndarray],
    other_labels: dict[str, list[np.ndarray]],
) -> dict:
    """Decide whether a new clip is reliable enough to become a personal example.

    Tracking quality failures are hard rejections. Inconsistency with the
    user's other clips of the same sign, or closeness to a different sign, is
    only a warning: legitimate signing varies, so the user decides.
    """
    query = np.asarray(sequence, dtype=np.float32)
    signals = _signal_diagnostics(query)
    frames = max(int(signals["frames_analyzed"]), 1)
    hands_ratio = signals["hands_frames"] / frames
    body_ratio = signals["body_frames"] / frames
    checks: dict[str, int | float | str] = {
        "hands_ratio": round(hands_ratio, 3),
        "body_ratio": round(body_ratio, 3),
        "motion_score": signals["motion_score"],
        "same_sign_clips": len(same_label),
    }

    rejections = []
    if hands_ratio < MIN_HANDS_RATIO:
        rejections.append(
            f"Hands were tracked in only {round(hands_ratio * 100)}% of the clip. Keep both hands in frame."
        )
    if body_ratio < MIN_BODY_RATIO:
        rejections.append(
            f"Your body was tracked in only {round(body_ratio * 100)}% of the clip. Step back so shoulders and elbows are visible."
        )
    if signals["motion_score"] < MIN_MOTION:
        rejections.append("Almost no movement was detected. Make the sign once while recording.")
    if rejections:
        return {"decision": "rejected", "reasons": rejections, "checks": checks}

    warnings = []
    own_distance = None
    if same_label:
        own_distance = float(np.median([sequence_distance(query, example) for example in same_label]))
        checks["own_median_distance"] = round(own_distance, 4)
        if own_distance > CONSISTENCY_MAX:
            warnings.append("This clip is quite different from your other examples of this sign.")
    if other_labels:
        nearest_distance, nearest_label = min(
            (float(np.mean([sequence_distance(query, example) for example in examples])), label)
            for label, examples in other_labels.items()
        )
        checks["nearest_other_label"] = nearest_label
        checks["nearest_other_distance"] = round(nearest_distance, 4)
        readable = nearest_label.replace("_", " ").upper()
        if own_distance is not None:
            if nearest_distance + CONFUSION_MARGIN < own_distance:
                warnings.append(f"This clip looks more like your {readable} examples than this sign.")
        elif nearest_distance < FIRST_CLIP_CONFUSION_MAX:
            warnings.append(f"This clip looks very similar to your {readable} examples.")

    return {
        "decision": "needs_confirmation" if warnings else "accepted",
        "reasons": warnings,
        "checks": checks,
    }


def save_sample(
    user_id: str,
    label: str,
    video_bytes: bytes,
    kind: str | None = None,
    confirm: bool = False,
) -> dict:
    """Save a clip only when it passes the reliability gate (or the user confirms a warning)."""
    label = _validate_label(label)
    if kind is not None and kind not in KINDS:
        raise ValueError("kind must be isl_variant or custom_gesture.")
    if not video_bytes or len(video_bytes) > MAX_UPLOAD_BYTES:
        raise ValueError("Clip must be smaller than 25 MB.")
    folder = _label_dir(user_id, label)
    stored_kind = _stored_kind(folder)
    if stored_kind and kind and kind != stored_kind:
        raise ValueError(
            f"'{label}' is already saved as {KIND_NAMES[stored_kind]}. Use a different name for {KIND_NAMES[kind]}."
        )
    resolved_kind = stored_kind or kind or DEFAULT_KIND

    sequence = extract_sequence(video_bytes)
    clips = _user_clips(user_id)
    same = [np.asarray(_load_sequence(path), dtype=np.float32) for path in clips.get(folder.name, [])]
    others = {
        name: [np.asarray(_load_sequence(path), dtype=np.float32) for path in paths]
        for name, paths in clips.items()
        if name != folder.name
    }
    gate = assess_sample(sequence, same, others)
    result = {
        "label": label,
        "kind": resolved_kind,
        "decision": gate["decision"],
        "reasons": gate["reasons"],
        "checks": gate["checks"],
        "saved": False,
        "sample_id": None,
        "samples_for_sign": len(same),
    }
    if gate["decision"] == "rejected" or (gate["decision"] == "needs_confirmation" and not confirm):
        return result

    folder.mkdir(parents=True, exist_ok=True)
    if stored_kind is None:
        _write_json(folder / LABEL_META, {"label": label, "kind": resolved_kind})
    sample_id = str(time.time_ns())
    (folder / f"{sample_id}.mp4").write_bytes(video_bytes)
    _write_json(
        folder / f"{sample_id}.json",
        {
            "sequence": sequence,
            "created_at": time.time(),
            "gate": {
                "decision": gate["decision"],
                "reasons": gate["reasons"],
                "checks": gate["checks"],
                "confirmed_by_user": gate["decision"] == "needs_confirmation",
            },
        },
    )
    result.update(saved=True, sample_id=sample_id, samples_for_sign=len(same) + 1)
    return result


def list_samples(user_id: str) -> dict[str, int]:
    user_dir = _user_dir(user_id)
    if not user_dir.exists():
        return {}
    return {
        folder.name: len(list(folder.glob("*.mp4")))
        for folder in sorted(user_dir.iterdir())
        if folder.is_dir() and folder.name != ".processing"
    }


def list_sample_details(user_id: str) -> dict[str, dict]:
    """Per-sign kind and per-clip gate results, so the user can review and undo."""
    details = {}
    for label, paths in _user_clips(user_id).items():
        samples = []
        for path in paths:
            record = _read_json(path.with_suffix(".json")) or {}
            samples.append({"id": path.stem, "created_at": record.get("created_at"), "gate": record.get("gate")})
        details[label] = {"kind": _label_kind(_user_dir(user_id) / label), "samples": samples}
    return details


def delete_sample(user_id: str, label: str, sample_id: str) -> dict:
    """Remove one saved example and keep any trained personal model in sync."""
    if not SAMPLE_ID.fullmatch(sample_id or ""):
        raise ValueError("Unknown sample id.")
    folder = _label_dir(user_id, _validate_label(label))
    clip_path = folder / f"{sample_id}.mp4"
    if not clip_path.is_file():
        raise LookupError("That example no longer exists.")
    clip_path.unlink()
    clip_path.with_suffix(".json").unlink(missing_ok=True)
    remaining = len(list(folder.glob("*.mp4")))
    if remaining == 0:
        (folder / LABEL_META).unlink(missing_ok=True)
        try:
            folder.rmdir()
        except OSError:
            logger.warning("Could not remove empty sign folder %s", folder)
    return {
        "deleted": True,
        "label": folder.name,
        "sample_id": sample_id,
        "samples_for_sign": remaining,
        "model": _rebuild_user_model(user_id),
    }


def _rebuild_user_model(user_id: str) -> str:
    """Refresh an existing personal model after its clips change."""
    model_path = _user_model_path(user_id)
    if not model_path.exists():
        return "not_trained"
    try:
        train_user(user_id, validate=False)
        return "rebuilt"
    except ValueError:
        # Too few clips left: fall back to the seed model rather than keep
        # prototypes from a clip the user removed.
        model_path.unlink(missing_ok=True)
        return "removed"


def _leave_one_out_predictions(prototypes: list[dict]) -> list[str]:
    """Nearest-neighbour label for each clip, excluding the clip itself."""
    arrays = [np.asarray(item["sequence"], dtype=np.float32) for item in prototypes]
    count = len(arrays)
    distances = np.full((count, count), np.inf, dtype=np.float32)
    for row in range(count):
        for column in range(row + 1, count):
            distances[row, column] = distances[column, row] = sequence_distance(arrays[row], arrays[column])
    return [prototypes[int(np.argmin(distances[index]))]["label"] for index in range(count)]


def _accuracy_report(labels: list[str], predicted: list[str], method: str) -> dict:
    per_label: dict[str, list[int]] = {label: [0, 0] for label in sorted(set(labels))}
    for actual, guess in zip(labels, predicted):
        per_label[actual][1] += 1
        per_label[actual][0] += int(actual == guess)
    correct = sum(values[0] for values in per_label.values())
    return {
        "method": method,
        "correct": correct,
        "total": len(labels),
        "accuracy": round(correct / len(labels), 4) if labels else 0.0,
        "per_label": {
            label: {"correct": values[0], "total": values[1]}
            for label, values in per_label.items()
        },
    }


def _seed_baseline(prototypes: list[dict], personal_predictions: list[str]) -> dict | None:
    """Compare the seed model with the personal model on the same user clips."""
    seed = _read_json(SEED_MODEL_PATH)
    if not seed or not seed.get("prototypes"):
        return None
    seed_items = [
        (item["label"], np.asarray(item["sequence"], dtype=np.float32)) for item in seed["prototypes"]
    ]
    seed_labels = {label for label, _ in seed_items}
    shared = [index for index, item in enumerate(prototypes) if item["label"] in seed_labels]
    if not shared:
        return None
    seed_correct = personal_correct = 0
    for index in shared:
        query = np.asarray(prototypes[index]["sequence"], dtype=np.float32)
        _, seed_guess = min((sequence_distance(query, example), label) for label, example in seed_items)
        seed_correct += int(seed_guess == prototypes[index]["label"])
        personal_correct += int(personal_predictions[index] == prototypes[index]["label"])
    return {
        "method": "1nn_on_same_user_clips",
        "labels": sorted({prototypes[index]["label"] for index in shared}),
        "clips": len(shared),
        "seed_model_accuracy": round(seed_correct / len(shared), 4),
        "personal_model_accuracy": round(personal_correct / len(shared), 4),
    }


def train_seed_model() -> dict:
    """Train the USB-resident baseline from labeled isolated seed clips."""
    prototypes = []
    for label_dir in sorted(path for path in SEED_ROOT.iterdir() if path.is_dir()):
        for clip_path in sorted(label_dir.glob("*.mp4")):
            sequence = extract_sequence(clip_path.read_bytes())
            prototypes.append({"label": label_dir.name, "sequence": sequence})
    labels = sorted({item["label"] for item in prototypes})
    if len(labels) < 2 or len(prototypes) < len(labels) * 2:
        raise ValueError("Seed training needs at least two labeled clips per sign.")

    report = _accuracy_report(
        [item["label"] for item in prototypes],
        _leave_one_out_predictions(prototypes),
        "leave_one_clip_out_1nn",
    )
    MODEL_ROOT.mkdir(parents=True, exist_ok=True)
    model = {
        "version": 2,
        "type": "pose_hands_face_dtw_prototypes",
        "frames": FRAME_COUNT,
        "feature_count": FEATURE_COUNT,
        "labels": {label: SEED_KIND for label in labels},
        "prototypes": prototypes,
        "validation": report,
    }
    _write_json(SEED_MODEL_PATH, model)
    return {
        "trained": True,
        "sign_count": len(labels),
        "clip_count": len(prototypes),
        "validation": report,
    }


def train_user(user_id: str, validate: bool = True) -> dict:
    eligible = {label: paths for label, paths in _user_clips(user_id).items() if len(paths) >= 3}
    if len(eligible) < 2:
        raise ValueError("Record at least 3 clips for each of at least 2 signs before training.")

    prototypes = [
        {"label": label, "sequence": _load_sequence(path)}
        for label, paths in eligible.items()
        for path in paths
    ]
    model = {
        "version": 2,
        "type": "pose_hands_face_dtw_prototypes",
        "frames": FRAME_COUNT,
        "feature_count": FEATURE_COUNT,
        "labels": {label: _label_kind(_user_dir(user_id) / label) for label in eligible},
        "prototypes": prototypes,
    }
    result = {"trained": True, "sign_count": len(eligible), "clip_count": len(prototypes)}
    if validate:
        predictions = _leave_one_out_predictions(prototypes)
        report = _accuracy_report(
            [item["label"] for item in prototypes], predictions, "leave_one_clip_out_1nn"
        )
        baseline = _seed_baseline(prototypes, predictions)
        if baseline:
            report["seed_baseline"] = baseline
        model["validation"] = report
        result["validation"] = report
    MODEL_ROOT.mkdir(parents=True, exist_ok=True)
    _write_json(_user_model_path(user_id), model)
    return result


def predict_user(user_id: str, video_bytes: bytes) -> dict:
    model_path = _user_model_path(user_id)
    personal = model_path.exists()
    if not personal:
        model_path = SEED_MODEL_PATH
    if not model_path.exists():
        raise ValueError("No sign model yet. Add labeled clips and train first.")
    # Fewer samples keep the rolling webcam prediction responsive. DTW
    # aligns this shorter query with the 16-frame training examples.
    sequence = np.asarray(extract_sequence(video_bytes, frame_count=8), dtype=np.float32)
    model = json.loads(model_path.read_text(encoding="utf-8"))
    kinds = model.get("labels") or {}
    distances: dict[str, list[float]] = {}
    for item in model["prototypes"]:
        exemplar = np.asarray(item["sequence"], dtype=np.float32)
        distances.setdefault(item["label"], []).append(sequence_distance(sequence, exemplar))
    ranked = sorted((float(np.mean(values)), label) for label, values in distances.items())
    signals = _signal_diagnostics(sequence)
    if not ranked:
        return {
            "label": "",
            "suggestion": "",
            "confidence": 0.0,
            "accepted": False,
            "decision": "rejected",
            "reason": "No usable hand/pose landmarks found.",
            "signals": signals,
        }
    best_distance, best_label = ranked[0]
    gap = (ranked[1][0] - best_distance) if len(ranked) > 1 else 0.0
    hands_ok = signals["hands_frames"] >= PREDICT_MIN_HANDS_RATIO * max(int(signals["frames_analyzed"]), 1)
    # Initial conservative bands; real user feedback is needed to tune them.
    # "confidence" is only a rescaled distance (an accepted sign can score
    # under 50%), so clients should show `decision`, not this number.
    confidence = max(0.0, min(1.0, 1.0 - best_distance / CONFIRM_DISTANCE))
    if hands_ok and best_distance < ACCEPT_DISTANCE and (len(ranked) == 1 or gap > ACCEPT_GAP):
        decision, reason = "accepted", "Matched sign examples."
    elif hands_ok and best_distance < CONFIRM_DISTANCE:
        decision, reason = "confirm", "Close match. Please confirm whether this was the sign."
    elif not hands_ok:
        decision, reason = "rejected", "Hands were not visible enough. Please repeat with both hands in frame."
    else:
        decision, reason = "rejected", "Uncertain; please repeat or add more examples."
    accepted = decision == "accepted"
    return {
        "label": best_label if accepted else "",
        "suggestion": best_label,
        "confidence": round(confidence, 3),
        "accepted": accepted,
        "decision": decision,
        "kind": kinds.get(best_label, DEFAULT_KIND if personal else SEED_KIND),
        "model": "personal" if personal else "seed",
        "reason": reason,
        "signals": signals,
    }
