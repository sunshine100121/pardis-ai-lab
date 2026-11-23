2026-11-23 | Native Android compile-only retry
Prior source gate: GitHub Actions 45232697245; Flutter analyze and targeted M01-M06 tests SUCCESS.
Blocker: Maven Central HTTP 429 on Gradle Kotlin artifacts, not application code.
One native compile only, with one conditional backoff on HTTP 429. No APK, no install.
