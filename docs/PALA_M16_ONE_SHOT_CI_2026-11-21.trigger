PALA M16 — SOURCE-ONLY CI RUN REQUEST
Branch: pala/m16-release-gate-034-2026-11-21
Date: 2026-11-21
Purpose: one integrated validation pass after correcting Git history checkout and exact reviewed additive-change pins.
Release APK build: FORBIDDEN
Installation: FORBIDDEN
Model/data/security changes: NONE
Subsequent documentation commits will NOT trigger the source-validation workflow.

Single diagnostic retry after baseline-order correction and frozen-lock enforcement.
Source workflow commit 710f73071013acb3ab13dee46a1cfb9667c120db.
No APK. No installation. No new signing key. No data access. Do not automatically retry.

Fourth source-only CI request: collect all failures and optional 64-file format patch in ONE pass; no APK or installation. Workflow cd3dc994. 

AFTER_GREEN_FORMATTER_221EFE2 — Single final source-only integrated run for the combined M1-M19 release candidate.
Baseline formatting saved in GitHub commit 221efe252941c2a857f0d6fc016b2f63430b4f94.
Run Flutter analyze, M9-M19 and legacy chat tests, offline upgrade protections, Android host check.
Never build or sign an APK, change the Qwen model, access HA, or modify owner device.
If CI fails, capture named failing test(s), do not issue another trigger until the cause is investigated.
