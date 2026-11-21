#!/usr/bin/env python3
"""Select Microsoft ONNX Runtime 1.31.1 for a disposable Pocket diagnostic APK only.

This runs solely on the ephemeral GitHub Actions runner and never changes the
user's installed PALA app, model files, or production signing. We refuse to
ship any APK whose packaged ORT differs from the exact Microsoft AAR.
"""
from __future__ import annotations

import hashlib
import os
from pathlib import Path
from zipfile import ZipFile

EXPECTED_VERSION = "1.31.1"
LIB = "jni/arm64-v8a/libonnxruntime.so"


def official_hash() -> str:
    base = Path.home() / ".gradle/caches/modules-2/files-2.1/com.microsoft.onnxruntime/onnxruntime-android" / EXPECTED_VERSION
    aars = list(base.rglob("*.aar"))
    if len(aars) != 1:
        raise RuntimeError(f"Expected exactly one pinned Microsoft ONNX AAR; got {len(aars)}")
    with ZipFile(aars[0]) as archive:
        data = archive.read(LIB)
    if len(data) < 1000000:
        raise RuntimeError("Official Microsoft ARM64 library unexpectedly small")
    sha = hashlib.sha256(data).hexdigest()
    print(f"Microsoft ONNX {EXPECTED_VERSION}, arm64 SHA256: {sha}")
    return sha


def main() -> int:
    if os.environ.get("PALA_POCKET_TEST_APK") != "true":
        raise RuntimeError("Refusing to run outside the isolated Pocket APK job")
    official_hash()
    hosted = Path.home() / ".pub-cache/hosted/pub.dev"
    # Sherpa's separately distributed ARM64 Flutter plugin provides an older
    # native ORT copy. Keep all Sherpa source and its JNI; remove ONLY this
    # conflicting .so in the disposable job, so Gradle can package the pinned
    # Microsoft runtime for the separate Pocket diagnostic APK.
    paths = sorted(hosted.glob("sherpa_onnx_android_arm64-*/android/src/main/jniLibs/arm64-v8a/libonnxruntime.so"))
    if not paths:
        print("No Sherpa ARM64 ORT source duplicates found; retain normal build and verify output after packaging")
    for path in paths:
        if not path.is_file() or path.is_symlink():
            raise RuntimeError("Unexpected Sherpa ORT path: " + str(path))
        print("Omitting old Sherpa ORT from disposable diagnostic runner: " + path.parent.parent.parent.name)
        path.unlink()
    print("Pocket diagnostic native selection staged; final APK must pass exact AAR hash match")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
