PALA M16: ONE-TIME DART FORMATTING REQUEST
Date: 2026-11-21
Commit source: f31df608f7323018457f0913644128b0d316f848
Format only reviewed changed Dart sources; preserve privacy, model, app identity, data and installer.
Commit to same M16 branch after source+pin validation only.
No APK, no signing, no device connection.
Retry of same formatting-only operation with fast-forward/rebase protection; previous attempt may conflict with newer checkpoint. No APK, no data changes, no force-push.

Corrected single format-only run request 2026-11-21: exclude Flutter-generated translations from staged files and verify unchanged generation diff. Workflow a7e123250dd37d807ec5250f298ce19afae8833d. No build, install, model or HA changes.

YAML_FIXED_F50DEF36_FORMAT_TRIGGER: start exactly one format-only run after removing stray line 214 and duplicated git commands; source-only, no APK, no install, no model/HA changes.
