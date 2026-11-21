#!/usr/bin/env python3
"""Stage Microsoft ONNX Runtime 1.31.1 in the disposable debug APK source only.

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

    sha = official_hash()
    aar_dir = (Path.home() / ".gradle/caches/modules-2/files-2.1"
               / "com.microsoft.onnxruntime/onnxruntime-android"
               / EXPECTED_VERSION)
    aars = list(aar_dir.rglob("*.aar"))
    if len(aars) != 1:
        raise RuntimeError("Official Microsoft ONNX AAR unavailable")
    with ZipFile(aars[0]) as archive:
        pinned_binary = archive.read(LIB)
    if hashlib.sha256(pinned_binary).hexdigest() != sha:
        raise RuntimeError("Microsoft ONNX library changed during preparation")

    # The previous CI only *removed* one Sherpa source; Gradle pickFirsts
    # could still bundle the legacy binary from another intermediate.
    # Stage the exact Microsoft AAR library in the Android app's DEBUG source
    # set, which has priority over dependency-provided native libraries.
    # This source set is written ONLY on the disposable GitHub runner.
    target = Path("android/app/src/debug/jniLibs/arm64-v8a/libonnxruntime.so")
    if target.is_symlink() or (target.exists() and not target.is_file()):
        raise RuntimeError(f"Unsafe debug native target: {target}")
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(pinned_binary)
    if hashlib.sha256(target.read_bytes()).hexdigest() != sha:
        raise RuntimeError("Staged debug library does not match Microsoft AAR")
    print(f"Staged official ARM64 ORT in disposable debug app source: sha256={sha}")

    # Make any native Sherpa source selected through pickFirsts identical
    # rather than relying on deleting one source after Gradle compilation.
    # Sherpa's JNI companion is preserved; this does not prove runtime ABI
    # compatibility until the APK is tested on a device.
    hosted = Path.home() / ".pub-cache/hosted/pub.dev"
    paths = sorted(hosted.glob(
        "sherpa_onnx_android_arm64-*/android/src/main/jniLibs/"
        "arm64-v8a/libonnxruntime.so"
    ))
    for source in paths:
        if not source.is_file() or source.is_symlink():
            raise RuntimeError(f"Unexpected Sherpa native source: {source}")
        previous_sha = hashlib.sha256(source.read_bytes()).hexdigest()
        if previous_sha != sha:
            source.write_bytes(pinned_binary)
            print(f"Replaced temporary Sherpa ARM64 ORT source: "
                  f"previous={previous_sha}, pinned={sha}")
        if hashlib.sha256(source.read_bytes()).hexdigest() != sha:
            raise RuntimeError("Sherpa temporary library did not match pin")

    print("Pocket diagnostic selection staged; APK must still pass its exact"
          " packaged-Microsoft-AAR hash, package-ID and no-weights gates")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
