#!/usr/bin/env python3
"""Build a *local, non-commercial* Pocket Farsi v2 Android test ZIP.

Input files are downloaded independently by the owner from the authors'
official pages. This script never downloads, installs, deletes, or enables
a speech engine. The output ZIP is for the explicit Advanced/experimental
import panel; it is NOT placed in Git or in a signed production APK.

Official sources:
- Nimaone/pocket-tts-farsi-v2-onnx (graphs, data, NPZ, manifest)
- mehdi-hf/pocket-tts-farsi-v2 (tokenizer_ph.model)
- Authorized 24 kHz PCM16 mono voice prompt, 0.5..5 seconds
License reminder: CC BY-NC 4.0. Do not distribute model/voice bundles.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import wave
import zipfile

CORE = (
    "manifest.json",
    "flow_lm_step.onnx", "flow_lm_step.onnx.data",
    "mimi_encoder.onnx", "mimi_encoder.onnx.data",
    "mimi_decoder_step_kv.onnx", "mimi_decoder_step_kv.onnx.data",
    "g2p_encoder.onnx", "g2p_decoder.onnx", "g2p_decoder.onnx.data",
    "weights.npz", "decode_state_init.npz",
)
EXTRAS = ("tokenizer_ph.model", "voice_reference.wav")
MAX_TOTAL = 700 * 1024 * 1024
MAX_FILE = 500 * 1024 * 1024


def validate(onnx_dir: Path, tokenizer: Path, voice: Path) -> dict[str, Path]:
    source: dict[str, Path] = {}
    for name in CORE:
        source[name] = onnx_dir / name
    source[EXTRAS[0]] = tokenizer
    source[EXTRAS[1]] = voice

    total = 0
    for name, file in source.items():
        if file.is_symlink() or not file.is_file():
            raise ValueError("Missing, unreadable or linked package asset: " + name)
        length = file.stat().st_size
        if length <= 0 or length > MAX_FILE:
            raise ValueError("Unsafe model asset size: " + name)
        total += length
    if total > MAX_TOTAL:
        raise ValueError("Unpacked model is larger than the configured limit")

    with source["manifest.json"].open(encoding="utf-8") as handle:
        metadata = json.load(handle)
    if not isinstance(metadata, dict) or not isinstance(metadata.get("constants"), dict):
        raise ValueError("Invalid ONNX model manifest")
    constants = metadata["constants"]
    expected = {"sample_rate": 24000, "ldim": 32, "dim": 1024}
    if any(constants.get(k) != value for k, value in expected.items()):
        raise ValueError("Model constants are incompatible with PALA")
    if not isinstance(constants.get("layers"), int) or not isinstance(
        constants.get("cache_capacity"), int
    ):
        raise ValueError("Missing model runtime dimensions")

    with wave.open(str(voice), "rb") as wavefile:
        if (wavefile.getnchannels() != 1 or wavefile.getsampwidth() != 2
                or wavefile.getframerate() != 24000):
            raise ValueError("Reference must be mono, PCM16, 24000 Hz WAV")
        if not 12000 <= wavefile.getnframes() <= 120000:
            raise ValueError("Reference voice must be between 0.5 and 5 seconds")

    if tokenizer.stat().st_size < 128:
        raise ValueError("The official SentencePiece tokenizer is missing or truncated")
    return source


def build(onnx_dir: Path, tokenizer: Path, voice: Path, output: Path) -> Path:
    source = validate(onnx_dir, tokenizer, voice)
    if output.exists():
        raise FileExistsError("Existing output preserved; choose a new ZIP filename")
    output.parent.mkdir(parents=True, exist_ok=True)
    size = sum(file.stat().st_size for file in source.values())
    free = shutil.disk_usage(output.parent).free
    if free < size + 64 * 1024 * 1024:
        raise OSError("Insufficient space to create the model ZIP")

    handle, stage_path = tempfile.mkstemp(
        dir=output.parent, prefix=".pala-pocket-bundle-", suffix=".tmp"
    )
    os.close(handle)
    stage = Path(stage_path)
    try:
        with zipfile.ZipFile(stage, "w", compression=zipfile.ZIP_STORED,
                             allowZip64=True) as archive:
            for name, file in source.items():
                archive.write(file, arcname=name)
        with zipfile.ZipFile(stage) as archive:
            if set(archive.namelist()) != set(source):
                raise ValueError("ZIP file list mismatch")
            if archive.testzip() is not None:
                raise ValueError("Model archive CRC error")
        if output.exists():
            raise FileExistsError("Existing output was not overwritten")
        stage.replace(output)
        return output
    finally:
        if stage.exists():
            stage.unlink()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--onnx-dir", type=Path, required=True)
    parser.add_argument("--tokenizer", type=Path, required=True)
    parser.add_argument("--voice-wav", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = build(args.onnx_dir, args.tokenizer, args.voice_wav, args.out)
    except (OSError, ValueError, EOFError, wave.Error, json.JSONDecodeError,
            zipfile.BadZipFile) as exc:
        print("Pocket package was NOT produced: " + str(exc), file=sys.stderr)
        return 1
    print("Verified local Pocket test ZIP created: " + str(result))
    print("Import only through PALA's Advanced test panel; Gyro remains default.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
