# Validation — 2026-11-11

- Existing GitHub repository inspected through the authorized connection; selected `daily-briefing-launch` with user confirmation. Existing website application files are unchanged.
- Branch: `codex/native-daily-briefing`.
- `swift test --package-path native` using official Swift 6.0.3 Linux toolchain: **8 tests passed, 0 failures**. These exercise the same Foundation scheduling/freshness/conflict/policy models compiled into all native targets.
- `swiftc -frontend -parse` on all **20 Swift files**: passed. Syntax parsing is not Apple framework type checking.
- `python3 native/validate_project.py`: passed; **102 PBX objects**, four targets, references/membership, Info/entitlement/privacy plists, shared schemes, deterministic generation.
- Existing `node ci/smoke.mjs`: **27 checks passed, 0 failed** before adding native build products.
- `git diff --check`: passed.
- Public BBC RSS and NOAA CYKF METAR/TAF endpoints responded HTTP 200 during source checks; a later TAF probe returned HTTP 502, confirming the need for partial/offline handling.
- Initial macOS CI: core tests and project validation passed. The Apple build found a widget background ShapeStyle/View mismatch; the code was corrected and pushed for revalidation.

The environment is Linux with no Xcode or Apple SDKs. A Docker Swift test attempt failed because the image exhausted disk space; that image was removed, the workspace recovered, and tests subsequently passed using a directly installed official Swift toolchain with writable caches.

The checked-in `.github/workflows/native.yml` adds macOS core tests and unsigned simulator builds for iPhone and Watch. CI results will be recorded here when available. No simulator/device run, signed archive, WeatherKit entitlement, CloudKit sync, APNs delivery, OAuth connection, or physical Watch integration has been verified in this Linux session.

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
