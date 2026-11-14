#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Compile the Android integration before authorizing an APK. Flutter's wrapper
# comes from a throwaway template; application source is never patched in CI.
wrapper_dir="$(mktemp -d)/pala_wrapper"
flutter create --platforms=android --no-pub "$wrapper_dir"
cp "$wrapper_dir/android/gradlew" android/gradlew
cp "$wrapper_dir/android/gradle/wrapper/gradle-wrapper.jar" android/gradle/wrapper/gradle-wrapper.jar
python3 - <<'PY'
import os
from pathlib import Path
Path('android/local.properties').write_text(
    'sdk.dir=' + os.environ['ANDROID_HOME'] + '\nflutter.sdk=' + os.environ['FLUTTER_ROOT'] + '\n',
    encoding='utf-8')
PY
bash scripts/bootstrap.sh
cd android
bash gradlew :app:compileReleaseKotlin -x compileFlutterBuildRelease --console=plain
