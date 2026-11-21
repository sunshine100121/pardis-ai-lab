#!/usr/bin/env python3
"""Prepare one private, non-commercial Pocket Farsi v2 test ZIP on Surface.

Downloads only the official author's ONNX model, tokenizer, and (unless an
authorized --voice WAV is provided) official voice prompt. Never installs an
APK, modifies PALA, sends a voice to an API, or uploads weights to GitHub.
Model weights license: CC BY-NC 4.0. Python 3.12 is required.
Install once if missing: python -m pip install huggingface_hub
"""
from __future__ import annotations

import argparse
import shutil
import sys
import tempfile
import wave
from pathlib import Path

from prepare_pocket_farsi_v2_bundle import CORE, build

ONNX_REPO = "Nimaone/pocket-tts-farsi-v2-onnx"
VOICE_REPO = "mehdi-hf/pocket-tts-farsi-v2"
VOICE_SAMPLE = "samples/prompt_hello.wav"


def normalize_voice(source: Path, out: Path) -> Path:
    """Produce 0.5–5s mono 24kHz PCM16 owner-authorized WAV for local Pocket."""
    with wave.open(str(source), "rb") as source_wav:
        channels = source_wav.getnchannels()
        width = source_wav.getsampwidth()
        rate = source_wav.getframerate()
        compression = source_wav.getcomptype()
        frames = source_wav.readframes(source_wav.getnframes())
    if compression != "NONE" or channels not in (1, 2) or width not in (1, 2, 3, 4):
        raise ValueError("Reference prompt must be standard mono/stereo PCM WAV")
    if rate < 8000 or rate > 96000:
        raise ValueError("Unexpected reference sample rate")
    import audioop  # Python 3.12, matching the owner's Surface
    if channels == 2:
        frames = audioop.tomono(frames, width, 0.5, 0.5)
    if width != 2:
        frames = audioop.lin2lin(frames, width, 2)
    if rate != 24000:
        frames, _ = audioop.ratecv(frames, 2, 1, rate, 24000, None)
    count = len(frames) // 2
    if count < 12000:
        raise ValueError("Reference shorter than 0.5s")
    if count > 120000:
        frames = frames[:3 * 24000 * 2]
    with wave.open(str(out), "wb") as output_wav:
        output_wav.setnchannels(1)
        output_wav.setsampwidth(2)
        output_wav.setframerate(24000)
        output_wav.writeframes(frames)
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--voice", type=Path, help="Optional authorized WAV from previous Surface Pocket tests")
    parser.add_argument("--out", type=Path, default=Path.home() / "Downloads/PALA-Pocket-Farsi-v2-personal-test.zip")
    args = parser.parse_args()
    if sys.version_info[:2] != (3, 12):
        print("Use the existing Python 3.12 on Surface", file=sys.stderr)
        return 1
    if args.out.exists():
        print("Existing ZIP preserved; choose another --out filename", file=sys.stderr)
        return 1
    try:
        from huggingface_hub import hf_hub_download, snapshot_download
    except ImportError:
        print("Install once: python -m pip install huggingface_hub", file=sys.stderr)
        return 1

    cache = Path.home() / "Downloads" / "PALA-Pocket-v2-source-cache"
    cache.mkdir(parents=True, exist_ok=True)
    if shutil.disk_usage(cache).free < 1_300_000_000:
        print("At least 1.3 GB free disk space is needed for this test", file=sys.stderr)
        return 1
    print("Obtaining official ONNX models; no tablet installation or voice changes")
    onnx = Path(snapshot_download(
        repo_id=ONNX_REPO, local_dir=cache / "onnx",
        allow_patterns=list(CORE), max_workers=2))
    tokenizer = Path(hf_hub_download(
        repo_id=VOICE_REPO, filename="tokenizer_ph.model", local_dir=cache / "voice"))
    if args.voice:
        if not args.voice.is_file():
            raise FileNotFoundError("The owner's approved WAV is missing")
        reference = args.voice
    else:
        reference = Path(hf_hub_download(
            repo_id=VOICE_REPO, filename=VOICE_SAMPLE, local_dir=cache / "voice"))
    with tempfile.TemporaryDirectory(prefix="pala-pocket-voice-") as tmp:
        voice = normalize_voice(reference, Path(tmp) / "voice_reference.wav")
        artifact = build(onnx, tokenizer, voice, args.out)
    print("Locally validated personal Pocket pack:", artifact)
    print("Import only into the separately verified Pocket diagnostic application.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError) as exc:
        print("Safe stop: " + str(exc), file=sys.stderr)
        raise SystemExit(1)
