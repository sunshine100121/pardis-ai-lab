PALA 0.3.4+7 — SINGLE SIGNED TEST APK, NO INSTALL
2026-11-21
Source: pala/m16-release-gate-034-2026-11-21, tested baseline 66806b220052505fb7f8e767f790dcdae22b8837.
Previous submitted and validated APK: 0.3.3+6, sha256 32868b073977dfa07683600e70ef6be614439b30e86d74a99a3aa4796c48ad5f.
Reuse owner release signer and stable applicationId; build only once after source and data contract checks.
Publish APK and public verification reports only when package versionCode 7, name 0.3.4, arm64 and owner certificate match.
NO INSTALL, NO UNINSTALL, NO CLEAR DATA, NO DOWNLOAD OF VOICE MODELS, NO HA WRITE.
M16_RETRY_LOCKFILE_ONLY_AFTER_RUN16: The only retry of the original v0.3.4+7 signed artifact; first build run 44903525823 compiled APK but blocked output because bootstrap rewrote only pubspec.lock SDK metadata. Reviewed release-only enforce-lockfile fix in 1ee606e; same source/runtime/owner key, no new candidate, no install. If this run fails, stop and diagnose before another action.
