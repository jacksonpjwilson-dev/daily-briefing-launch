# Validation — updated 2026-11-13

Repository: `jacksonpjwilson-dev/daily-briefing-launch`; branch: `codex/native-daily-briefing`; [draft PR #1](https://github.com/jacksonpjwilson-dev/daily-briefing-launch/pull/1). P0 changes extend the existing native implementation; website files and architecture are preserved.

## Current local checks

| Check | Result |
| --- | --- |
| Complete portable suite, official Swift 6.0.3 on Linux | **42 tests passed, zero failures** on `ba02e60` |
| Generated project validation | **Passed**: 141 PBX objects, four targets, source membership, plists/entitlements/privacy, schemes and deterministic regeneration |
| Swift syntax parsing | All 31 Swift files passed the available Swift frontend; this does not type-check Apple APIs on Linux |
| Existing website smoke suite | **27 checks passed, zero failures** |
| Website preservation | All 25 public files match baseline `1a8a6ab` locally and returned HTTP 200 with byte-identical contents from the live GitHub Pages site on November 13 |
| Diff validation | `git diff --check` passed; no P0 changes outside `native/` |

Portable tests cover the original scheduling/freshness/credential-origin cases plus target-day contents, ongoing night shifts, shortened overrides, DST/time zones, stable recurring IDs, meaningful revisions, read/pin continuity, disabled/permission/consent privacy, shared-cache gates, METAR/TAF independent failures and validity, speech timestamps, legacy/partial/corrupt/future settings and snapshot recovery, notification planning, provider deadlines/late results, cancellation/checkpoints/resubmission, isolated failures and locked-credential short-circuit behavior. Fixtures are not live integration tests.

## Apple CI

Final validation: [run 43488600351](https://github.com/jacksonpjwilson-dev/daily-briefing-launch/actions/runs/43488600351), commit `dd2a880`. **Passed on Xcode 16.4:** all 47 tests (zero failures), project validation, all four native targets, the separate Watch scheme, and iPhone simulator installation/launch/exact-PID survival/screenshot capture. Application code is unchanged from `ba02e60`; this revision hardens only the bounded simulator smoke check. The simulator smoke check granted no provider permissions. The subsequent documentation-only commit does not change this validated source.

[Run 43486353137](https://github.com/jacksonpjwilson-dev/daily-briefing-launch/actions/runs/43486353137) passed all **47 macOS tests**, project validation, all four native builds and the separate Watch scheme. Its simulator installation exceeded the former 90-second limit before launching the app. The smoke helper now allows a bounded 180-second installation and checks the exact launched host PID rather than repeatedly querying a busy simulator's launchd registry. Nonzero command exits, lost app process, zombie state and failed screenshot still fail validation; command stdout/stderr is retained for diagnosis.

Earlier P0 [run 43481237221](https://github.com/jacksonpjwilson-dev/daily-briefing-launch/actions/runs/43481237221) passed 42 macOS tests, including five actual SwiftData tests, project validation, all four Apple target builds and the separate Watch build. The simulator installed/launched the app but its subsequent `simctl spawn launchctl list` command exceeded its 30-second timeout, so that run's simulator check **failed**; it is not counted as a successful startup-survival test. Intermediate runs were superseded/canceled after later source fixes.

The five macOS-only SwiftData tests exercise migration from the original unversioned schema, same-row checkpoint/reopen recovery, corrupt rows/backup restoration, pinned retention and cancellation with a real persisted checkpoint. These are additional to the portable suite. CloudKit is not enabled in these local-store tests.

The previous credential-security baseline [run 43198797955](https://github.com/jacksonpjwilson-dev/daily-briefing-launch/actions/runs/43198797955) passed all ten then-existing tests, all builds and simulator startup on `e8344e7`. P0 retains HTTPS-origin/service token scoping and strengthens update/read failure handling. Actual SecItem I/O and a locked signed phone remain device tests; the core short-circuit fixture does not prove Security.framework behavior.

## Scope and unresolved validation

No signed archive, physical iPhone/Watch run, real WeatherKit capability, CloudKit transition/sync, APNs, email OAuth, configured AI/monitoring service or production sports integration is certified by these checks. The simulator smoke check grants no calendar/reminder/location permission and does not perform the signed-device matrix.

The macOS checkpoint/reopen test logs a CoreData “model is still editable” checksum diagnostic, then passes its persistence/recovery assertions. No migration assertion failed; verify a backed-up real installation upgrade on devices before release rather than treating this framework diagnostic as resolved. App Intents metadata/training diagnostics require Siri invocation testing. The older SwiftData sort/predicate warning sites were removed by sorting fetched rows in memory; the project remains in its existing Swift 5 language mode. Full Swift 6 adoption is separate work. OS background opportunities and widget rendering are not precise delivery guarantees. An offline Watch/already-rendered widget image cannot be recalled instantly.

See [PRODUCTION_READINESS.md](PRODUCTION_READINESS.md) for the updated checklist and [PHYSICAL_DEVICE_TESTING.md](PHYSICAL_DEVICE_TESTING.md) for exact signing/configuration and acceptance steps.

## Reproduce on macOS

```sh
swift test --package-path native
python3 native/validate_project.py
xcodebuild -project native/DailyBriefing.xcodeproj -scheme DailyBriefing \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath native/DerivedData CODE_SIGNING_ALLOWED=NO build
xcodebuild -project native/DailyBriefing.xcodeproj -scheme DailyBriefingWatch \
  -configuration Debug -destination 'generic/platform=watchOS Simulator' \
  -derivedDataPath native/DerivedData CODE_SIGNING_ALLOWED=NO build
python3 native/ci_simulator_smoke.py
node ci/smoke.mjs
```
