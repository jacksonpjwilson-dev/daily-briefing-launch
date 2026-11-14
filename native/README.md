# Daily Briefing — native Apple app

This is an additive native implementation in `jacksonpjwilson-dev/daily-briefing-launch`. The existing launch site, screenshots, assets, JavaScript, and website CI are preserved. The repository contained no Swift or Xcode foundation. The separate `briefing` repository was inspected as a reference, but its live public data is not imported into private native briefings.

## Open and run

1. On a Mac with Xcode 16 or later, open `native/DailyBriefing.xcodeproj`.
2. Select the **DailyBriefing** scheme and an iPhone simulator running iOS 17 or later. Build and run. The watch app targets watchOS 10 or later.
3. In Settings → Calendars & permissions, explicitly authorize calendars and select contributing calendars. Choose a work calendar, or add a manual shift. Calendar access is read only. Google calendars appear after being synchronized with Apple Calendar in iOS Settings.
4. Select **Apply settings & refresh**. Today and History now use SwiftData; subsequent launches can read the saved briefing offline.
5. For physical devices and working widgets, set your development team on all four targets and replace the example bundle identifiers and App Group. See signing below. Install the companion watch app on a paired Watch; refresh on iPhone after pairing.

No credentials are needed for manual scheduling, local persistence, calendar/reminders integration, speech, RSS news, or public NOAA aviation reports. Network availability and source terms still apply.

## Implemented

P0 local hardening is implemented in place; see the current checklist in [PRODUCTION_READINESS.md](PRODUCTION_READINESS.md), exact checks in [VALIDATION.md](VALIDATION.md), and [signed physical-device setup/test steps](PHYSICAL_DEVICE_TESTING.md). This does not configure remote delivery or disconnected providers.

- SwiftUI dashboard with light/dark/system appearance, source timestamps, freshness states, next commitment and work countdown, overlapping-event indicators, expandable and reorderable cards, hidden sections, section refresh, pull-to-refresh, pin/read state, source links, and sharing.
- Versioned UserDefaults settings and SwiftData saved briefings, searchable privacy-filtered history, offline reading, configurable 7–365 day retention. Same-row checkpoints preserve partial refresh progress; interrupted runs recover after relaunch. Migration originals, corrupt records and pinned briefings are protected from automatic retention cleanup. Recovery controls avoid silent settings resets. Read/pin annotations survive stable-content regeneration.
- EventKit calendar selection, work calendar, calendar change refresh, read-only native event viewer, manual overrides, and incomplete reminders. Manual shifts replace calendar shifts on the same start date without editing source events.
- Scheduling: earliest shift start minus 45 minutes by default; configurable lead; 04:00 fallback; separate weekend default; days-off switch; device time zone; explicit next-day briefing targets when early shifts enter their prior-evening preparation window. Overnight manual shifts remain visible after midnight. System time-zone changes regenerate scheduling. No precise background-execution claim.
- Local reminders, stable deduplication identifiers, quiet-hour suppression, BGAppRefresh scheduling and app-open refresh. Notification content asks the user to open and refresh. A scheduled reminder never falsely says a new briefing is ready.
- WeatherKit current conditions, next six hourly forecasts, daily high/low, precipitation, wind, alerts where supplied, Celsius/Fahrenheit, and source/legal links. Permission and WeatherKit configuration are required.
- RSS news with source attribution, publication timestamps, title deduplication, topic matching, and HTTPS article links. Default BBC RSS; change the URL or clear topics in Settings.
- NOAA Aviation Weather Center METAR/TAF for configured ICAO airports, initially CYKF. Original raw reports and issue timestamps are preserved. Fetch freshness is distinct from report validity. Not an operational flight briefing.
- Optional AI HTTPS adapter (including future G.I.L.E.S.) with Keychain token, selected length and explicit consent. Only enabled, fresh sections are sent. AI output is labeled as generated interpretation. Without AI, the app provides a deterministic source roll-up. Refreshing a source invalidates the older summary.
- AVSpeechSynthesizer playback, pause/resume, next-section and stop, rate and voice selection, supported spoken-audio session.
- WidgetKit small/medium/large Home Screen widgets and circular/rectangular/inline Lock Screen widgets. App Group cached snapshots; timeline entries at expiry; deep links; highlighted section selectable in app Settings.
- ActivityKit shift countdown, Lock Screen and Dynamic Island compact/expanded views. Start explicitly from a shift's context menu within four hours of its start. Old activities end when the app refreshes or becomes active. The system marks the countdown stale at shift start.
- Siri/App Intents for opening Today and schedule/weather/tasks/sports, reading the next cached appointment, and opening the app to refresh.
- Watch companion with local cached summary, schedule, shift countdown, weather and tasks, transferred through WatchConnectivity. Separate watch WidgetKit extension for Smart Stack and complications.
- Head Quarter HTTPS monitoring boundary: explicitly send timestamp, provider state, failure count and build metadata with a Keychain credential. Briefing content is excluded. No Head Quarter connection is claimed before configuration.

## Signing and optional capabilities

The checked-in project is generated reproducibly by `python3 native/generate_project.py` without XcodeGen or external dependencies. Commit generated output together with generator changes. `python3 native/validate_project.py` verifies project references, source target membership, plists, schemes, and reproducibility.

Replace `com.example.DailyBriefing`, `group.com.example.DailyBriefing`, and `iCloud.com.example.DailyBriefing` consistently in the generator and Swift sources. Regenerate the project. Configure your team and provisioning in Xcode. The default entitlements include only the shared App Group; enable it on app and extension identifiers. The iPhone and Watch each have their own local group container; WatchConnectivity transfers the snapshot between devices.

**WeatherKit:** enable WeatherKit on the iOS App ID, add its entitlement, and set `WeatherKitConfigured` to `True` in the generator before regenerating the project. `Resources/OptionalCloudWeather.entitlements` is an example containing both WeatherKit and CloudKit. Use only the capabilities you actually configure. Use the WeatherKit-provided attribution/legal link in the weather section. The weather card loads the WeatherKit-provided Apple Weather attribution mark and links to its legal page; verify placement against Apple's current branding requirements before release.

**CloudKit:** create your private container, configure iCloud/CloudKit entitlements, set `CODE_SIGN_ENTITLEMENTS` to your configured entitlement file, and then enable iCloud in the app and restart. SwiftData models have defaults and no unique constraints to support CloudKit. Existing local data migration into a newly enabled cloud store must be validated with the real signed container before release. If container initialization fails, the app offers switching to local mode on the next launch without deleting data.

**Widgets/Watch/Live Activities:** configure App Groups and install signed targets. Live Activities require the system setting and the existing `NSSupportsLiveActivities` flag. Watch delivery requires a paired, activated WatchConnectivity session and installed companion app.

**Distribution:** supply a production 1024×1024 app icon and watch icons, set your bundle IDs/team, verify privacy labels against your actual provider/analytics behavior, verify WeatherKit branding, test accessibility and permission revocation on devices, and validate archive signing before App Store submission. Existing website image assets remain available and unchanged; no production app icon is claimed in this implementation.

## Provider contracts

AI: enter an HTTPS endpoint in Settings. A POST includes `{ "sections": [BriefingSection], "length": "Quick" | "Standard" | "Detailed" }`. Return HTTP 200 and `{ "summary": "..." }`. The optional bearer token is kept in Keychain under its HTTPS origin and service. Switching hosts or ports cannot reuse the previous server's token. The user explicitly opts in to sending private source content. Disabling consent stops future uploads but cannot delete provider-held copies. Consent is reset if the endpoint changes.

Monitoring: set an HTTPS endpoint and bearer token. Tap **Send health report**. The JSON contains `lastSuccessfulGeneration`, `nextScheduledBriefing`, provider `section/state/lastRefresh`, integration and delivery error strings, failed attempt count, version and build. Dates use Foundation's default Codable date encoding (seconds since 2001-01-01 UTC); the same applies to the AI contract and cached snapshot format. An accepted request confirms HTTP delivery, not full ecosystem compatibility. Failed provider fetches are distinct from disconnected, denied, missing-data, stale and offline states.

Email: `EmailProvider` is the connection boundary. A shipping Gmail integration needs a registered OAuth client, ASWebAuthenticationSession/PKCE or a supported server exchange, provider scopes, encrypted token storage and refresh/revocation handling. No email access or inbox messages are simulated.

Sports: `SportsProvider` is the replaceable boundary. Defaults are Philadelphia 76ers and San Antonio Spurs. Connect a licensed provider and translate results to attributed timestamped `BriefingSection` values before enabling scores, standings or game notifications. No live scores or unsupported scraped feed is bundled.

Remote briefing/push: this repository contains the local app, not a deployed scheduling server. A server implementation must register APNs device tokens and user time zone, receive only explicitly consented source data, recalculate schedule changes, generate content, deliver signed authenticated payloads and track delivery failures. Add the APNs capability/entitlement and token registration only when such a server is configured. Never put an APNs signing key in the app. No endpoint or delivery guarantee is fabricated here.

## Limits to finish before a production release

- Unsigned Apple-framework builds and an iPhone simulator startup smoke check passed on GitHub macOS CI. Interactive UI testing with authorized data, CloudKit sync, WeatherKit entitlement verification and physical-device integration still require configured signing and devices. See `VALIDATION.md` for the exact results.
- iOS background refresh and widget updates are opportunistic. Exact preparation/delivery needs an authenticated server. The current local notifications are reminders only. Quiet hours skip reminders rather than shifting them.
- A Live Activity cannot be guaranteed to end at the exact instant of a shift while the app is suspended without a configured ActivityKit push server. Stale date limits freshness, foreground/background refresh ends expired activities, and the system imposes its own maximum duration. Commute and live-game activities are not implemented without reliable source data.
- Email OAuth, licensed sports retrieval/standings/game alerts, remote push, severe-weather push alerts, and remote generation remain integration work. Weather is for current location; scheduled-location geocoding/travel forecasts are not implemented. News is a single configurable RSS feed rather than a feed aggregator. AI summary lengths are passed as preferences to the configured provider, not guaranteed reading durations.
- Watch uses the latest received privacy-filtered snapshot; it does not independently fetch sources. OS notification mirroring is controlled by Watch settings. A shared privacy gate filters subsequent widget/Watch reads and malformed gates fail closed. Already-rendered OS images and an offline Watch cannot be recalled immediately; device/reconnection validation remains required.
- No user data is uploaded to AI until consent is enabled; RSS/NOAA receive normal network requests, WeatherKit receives the weather location, and manual monitoring uploads status only on user action. No paid AI provider is hardcoded.
