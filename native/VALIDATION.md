# Validation — updated 2026-11-12

- Existing GitHub repository inspected through the authorized connection; selected `daily-briefing-launch` with user confirmation. Existing website application files are unchanged.
- Branch: `codex/native-daily-briefing`.
- `swift test --package-path native` using official Swift 6.0.3 Linux toolchain: **9 tests passed, 0 failures**. These exercise the same Foundation scheduling/freshness/conflict/policy models compiled into all native targets.
- `swiftc -frontend -parse` on all **20 Swift files**: passed. Syntax parsing is not Apple framework type checking.
- `python3 native/validate_project.py`: passed; **102 PBX objects**, four targets, references/membership, Info/entitlement/privacy plists, shared schemes, deterministic generation.
- Existing `node ci/smoke.mjs`: **27 checks passed, 0 failed** before adding native build products.
- `git diff --check`: passed.
- Public BBC RSS and NOAA CYKF METAR/TAF endpoints responded HTTP 200 during source checks; a later TAF probe returned HTTP 502, confirming the need for partial/offline handling.
- Initial macOS CI: core tests and project validation passed. The Apple build found a widget background ShapeStyle/View mismatch; the code was corrected and pushed for revalidation.

The environment is Linux with no Xcode or Apple SDKs. A Docker Swift test attempt failed because the image exhausted disk space; that image was removed, the workspace recovered, and tests subsequently passed using a directly installed official Swift toolchain with writable caches.

GitHub Actions run [43066174548](https://github.com/jacksonpjwilson-dev/daily-briefing-launch/actions/runs/43066174548), commit `4e9053c`, confirmed successful unsigned builds of the iPhone app, iPhone WidgetKit/Live Activity extension, watch app, and watch widget extension. The separate Watch scheme also built successfully. The real iPhone app was installed and launched in a simulator, remained running throughout the smoke check, and produced a screenshot. Visual inspection confirmed the dashboard renders its greeting, next planned briefing time, cards, source connection states, and navigation without fabricated connected data.

The first workflow attempt was marked failed because the separate core job could not acquire a hosted macOS runner after multiple attempts; the successful Apple build and simulator check were unaffected. The core job was rerun on November 12 and exposed a Swift Package manifest issue: it defaulted to a macOS deployment target older than the date-formatting API used by shared text. The package now explicitly targets macOS 12, iOS 17 and watchOS 10. Nine core tests had already passed locally with Swift 6.0.3; macOS revalidation follows the manifest fix.

No signed archive, WeatherKit entitlement, CloudKit sync, APNs delivery, OAuth connection, or physical Watch integration has been verified. The simulator smoke check confirms startup/process survival and visual rendering; it does not replace interactive tests of authorized calendar data or device capabilities.

On macOS, run:

```sh
swift test --package-path native
python3 native/validate_project.py
xcodebuild -project native/DailyBriefing.xcodeproj -scheme DailyBriefing \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath native/DerivedData CODE_SIGNING_ALLOWED=NO build
xcodebuild -project native/DailyBriefing.xcodeproj -scheme DailyBriefingWatch \
  -configuration Debug -destination 'generic/platform=watchOS Simulator' \
  -derivedDataPath native/DerivedData CODE_SIGNING_ALLOWED=NO build
```

Before release, test first-run/denied/revoked permissions, all-disconnected/partial/offline generation, force quit and relaunch, manual overnight shifts, settings changes and pending notification replacement, midnight/time-zone changes, read/pin/history retention, widget cache expiry/deep links, Dynamic Type/VoiceOver, AI consent revocation/endpoint changes, CloudKit migration, Watch pairing and Live Activity expiry.
