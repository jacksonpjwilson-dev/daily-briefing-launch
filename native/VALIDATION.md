# Validation — updated 2026-11-12

Repository: `jacksonpjwilson-dev/daily-briefing-launch`. Branch: `codex/native-daily-briefing`. The existing promotional website and assets are preserved. Native implementation and configuration are reviewed in [draft PR #1](https://github.com/jacksonpjwilson-dev/daily-briefing-launch/pull/1).

## Confirmed results

| Check | Result |
| --- | --- |
| Current core suite, official Swift 6.0.3 on Linux | **10 tests passed, 0 failures** |
| Current macOS core suite | **10 tests passed**, including the credential-origin regression; [job](https://github.com/jacksonpjwilson-dev/daily-briefing-launch/actions/runs/43198797955/job/131116508749) |
| iPhone app, WidgetKit/Live Activity extension, watch app, watch widget extension | **All four targets built successfully** on Xcode 16.4 macOS CI; the separate Watch scheme also passed; [build job](https://github.com/jacksonpjwilson-dev/daily-briefing-launch/actions/runs/43198797955/job/131116507996) |
| iPhone simulator install, launch and process survival | **Passed** in [run 43198797955](https://github.com/jacksonpjwilson-dev/daily-briefing-launch/actions/runs/43198797955); screenshot captured and visually inspected |
| Generated Xcode project validation | **Passed**: 102 PBX objects, four targets, source membership, plist/entitlement/privacy syntax, shared schemes and reproducibility |
| Existing website smoke test | **27 checks passed, 0 failed** |
| Whitespace/diff validation | **Passed** |

The ten tests cover shift/fallback/weekend/day-off scheduling, time zones, DST gaps/repeats, midnight crossings, source freshness and missing data, generation transitions and concurrency rejection, overlapping commitments, notification identifiers/quiet hours, stale-source labels in shared text, and credential-origin isolation.

## Latest revalidation

[Run 43198797955](https://github.com/jacksonpjwilson-dev/daily-briefing-launch/actions/runs/43198797955) completed **successfully** for application-code commit `e8344e7`, including the credential-origin security patch. Ten tests passed on macOS; project validation, all four Apple targets, the separate Watch build, and the iPhone simulator install/launch/process-survival check passed on Xcode 16.4. Subsequent changes were documentation only.

The previous queued status is superseded by this result. Signed capabilities and physical-device integration remain unverified. Build logs still contain SwiftData Sendable warnings and an App Intents training diagnostic; see `PRODUCTION_READINESS.md` for their scope, the complete feature audit and release plan.

The BBC RSS feed and NOAA CYKF METAR/TAF endpoints responded HTTP 200 in source probes; a later NOAA request returned HTTP 502. The public NBA scoreboard endpoint returned HTTP 403 in this environment. Sports therefore retains a disconnected provider boundary instead of invented scores or a claim that access is configured.

## Scope of verification

The simulator screenshot confirmed the real dashboard renders its greeting, planned briefing time, cards, source connection states and navigation. The smoke check tests startup/process survival; it does not replace interactive tests with authorized calendar data. Later dashboard text clarifies that a planned briefing time is not proof a notification was scheduled and keeps developer configuration details out of the weather card.

No signed archive, WeatherKit entitlement, CloudKit sync, APNs delivery, OAuth connection or physical Watch integration has been verified. These require configured Apple capabilities, providers and devices. Production icons and release privacy/branding review also remain setup work; see `README.md`.

## Run on macOS

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
```

Before release, test denied/revoked permissions, authorized live data, offline/partial generation, relaunch and retention, notification replacement, midnight/time-zone changes, widgets/deep links, Dynamic Type/VoiceOver, AI consent changes, CloudKit migration, Watch pairing and Live Activity expiry.
