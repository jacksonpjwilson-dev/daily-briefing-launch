# Daily Briefing production-readiness audit

## P0 implementation update — November 13, 2026

Implemented in the existing native app on `codex/native-daily-briefing`, continuing **draft PR #1**. The November 12 inventory and gap analysis below are a historical baseline; this checklist supersedes their P0 defect statuses. The SwiftUI design, provider boundaries and website are preserved. No remote service, new provider or dependency was added. **Final Apple CI passed:** [run 43488600351](https://github.com/jacksonpjwilson-dev/daily-briefing-launch/actions/runs/43488600351) on `dd2a880`: 47 tests, all four targets, Watch scheme and iPhone simulator startup/survival/screenshot. The local portable suite passed 42 tests; the unchanged website passed all 27 smoke checks.

| Local hardening requirement | Implementation / remaining validation |
| --- | --- |
| [x] Correct target date | Explicit target work day, time zone, shift identity and scheduled preparation time are distinct from generation time. A next-day early shift selects tomorrow only after its prior-evening lead window opens; its schedule and daily weather use that date. |
| [x] Overnight manual shifts | Interval-overlap filtering retains ongoing shifts after midnight. Overrides use the original start day, including shortened overrides that have already ended. |
| [x] Meaningful revisions | Stable calendar/recurrence identity plus start/end, title/detail/location, link, source, all-day/shift and validity revisions; retrieval-only timestamp changes do not create false changes. |
| [x] Disabled-source privacy | Enabled policy gates provider jobs and summary inputs. Settings/consent/permission changes cancel work, rotate source revisions and immediately rewrite the shared privacy gate. History search/detail, share, speech, widgets and Watch reads filter cached data; derived summaries are invalidated with their inputs. Originals remain in the private recovery archive. |
| [x] Bounded refresh and persistence | Concurrent isolated provider jobs, per-provider deadlines, incremental same-row SwiftData checkpoints, interruption recovery, cancellation/late-result guards and background resubmission on completion/failure/cancellation. Summary runs after enabled fresh inputs within the remaining budget. Actual iOS execution time remains system-controlled. |
| [x] Stable read/pin state | Versioned annotation ledger carries stable item pins through regeneration/relaunch and reads through unchanged content on the same work date. Meaningful content changes become unread; temporarily absent pins are retained. Legacy calendar provenance is reconciled only against an authorized selected EventKit source. |
| [x] Versioned local recovery | Partial legacy preferences migrate with defaults and preserved originals; corrupt/future settings block autosave and expose explicit recovery. SwiftData V1→V2 migration and versioned snapshot payloads preserve old bytes; unreadable history remains visible, backups can be restored, and retention skips recovery/pinned rows. |
| [x] Permission, failure and freshness handling | Resume revalidation, EventKit tasks refresh, canceled reminder fetches, true denied versus unconfigured states, source-isolated failure/offline/timeout reporting, cached/as-of labels and source-report validity in text/speech/companions. METAR/TAF failures are independent. Locked/unreadable credentials prevent the authenticated upload stage; token replacement does not delete a working token first. |
| [x] Local notification hardening | Testable future/quiet-hour/deduplication planning; add replacements before removing obsolete app-owned requests; tapping a local reminder routes to Today. Signed notification-center behavior still needs device tests. |
| [x] Regression coverage | Scheduling/overnight/DST/time zones, meaningful changes, annotation continuity, disabled/consent/permission cache redaction, corrupt/future data, deadline/cancellation/late-result behavior, notification planning and actual macOS SwiftData migration/checkpoint recovery tests. Exact latest results are tracked in [VALIDATION.md](VALIDATION.md). |
| [ ] Signed physical-device acceptance | Follow [PHYSICAL_DEVICE_TESTING.md](PHYSICAL_DEVICE_TESTING.md). App Group/WeatherKit provisioning, real Keychain/notification/Watch behavior, Siri, accessibility and actual background expiration remain unverified here. P0 code completion is not device certification. |

The privacy gate protects subsequent controllable reads and transfers. An already-rendered OS widget image or an offline Watch cannot be instantly recalled; signed-device/reconnection tests are a release gate. Legacy source data that cannot be verified is retained privately and hidden from exports, rather than guessed or deleted. Recovery copies deliberately override normal retention and may require user-directed cleanup later.

**Next priorities:** configure signed Apple identities and run the device matrix; then P1 remote enrollment/scheduling/APNs/native ingestion, real email/sports and compatible AI/monitoring services, companion/runtime completion and TestFlight/release validation. CloudKit stays off until signed migration and two-device tests pass. Email/sports placeholders, exact-time remote preparation, section-aware speech, Watch delivery acknowledgement and production icons remain outside this local hardening phase.

## Historical baseline — November 12, 2026

Audit date: November 12, 2026. Repository: `jacksonpjwilson-dev/daily-briefing-launch`. Application code reviewed: `e8344e784f7434eb1b8962134fbbc5883f7b7c21`; later changes before this audit were documentation only. [Draft PR #1](https://github.com/jacksonpjwilson-dev/daily-briefing-launch/pull/1).

**Assessment:** Daily Briefing has a real, compiling native foundation with implemented local features. Production readiness still requires reliability fixes, signed Apple configuration, real provider connections, a remote delivery service, and device testing. Green CI establishes compilation and startup; it does not establish end-to-end operation of every integration.

The original audit changed documentation only. Its inventory below records the pre-P0 implementation; use the dated checklist above for the current local hardening status. The current SwiftUI screens, modular provider interfaces, SwiftData history, website and assets remain preserved.

## 1. Latest Apple CI, including credential security

[Run 43198797955](https://github.com/jacksonpjwilson-dev/daily-briefing-launch/actions/runs/43198797955) completed successfully for `e8344e7`, the credential-origin security patch, on Xcode 16.4:

- Ten core tests passed on macOS, with zero failures. Project-reference, target-membership, plist and reproducibility validation passed.
- iPhone app, iPhone WidgetKit/Live Activity extension, watch app, and watch widget extension built successfully. The separate Watch scheme also passed.
- The app installed and launched on an iPhone 16 Pro simulator running iOS 18.5, survived the process check, and produced a screenshot.
- No calendar/reminder/location permissions were granted by that smoke check. It did not exercise real accounts, signed device entitlements, Siri, widgets on a device, or a physical Watch.

The security patch is in the tested SHA. It scopes Keychain accounts by service and HTTPS host/port, rejects HTTP endpoints and URL-embedded credentials, and separates AI from monitoring credentials. Tests cover those account-selection properties. Actual Keychain I/O, HTTP authorization/redirect behavior, revocation and background locked-device behavior still need integration tests.

Two diagnostics remain important despite the successful result:

1. SwiftData-generated predicates/key paths produce Sendable warnings that would become errors under Swift 6 language mode. The project currently uses Swift 5 language mode. Investigate and document the toolchain/framework boundary before changing language mode; the warnings are not evidence of a proven runtime race.
2. App Intents natural-language training logs `Unable to parse extract.actionsdata`, then continues and finishes the build. Intent metadata is generated, but Siri discovery and invocation are unverified. Treat this as an investigation and device-test item, not a proven working Siri experience.

No signed Release archive, provisioning validation, TestFlight install, real-device provider test or iCloud migration test has passed yet.

## 2. Feature-by-feature inventory

“Implemented” means executable code is present and wired into the app. “Verified” is reserved for the specific checks above and the tested pure logic. Implemented features without interaction/device tests are not claimed as fully validated.

| Feature | Current status | Actual scope and remaining qualification |
| --- | --- | --- |
| Native project and architecture | Verified builds/startup | Four native targets; SwiftUI app, shared Foundation models, service modules and reproducible project generator. No web wrapper. |
| Greeting, date, next commitment, shift countdown, freshness and appearance | Implemented | Real dashboard values come from the current snapshot/calendar query; light/dark/system settings exist. Interactive accessibility and rollover testing remain. |
| Persistent preferences | Implemented | UserDefaults saves settings. Schema migration and recovery are missing; decode failure silently restores defaults. Preferences/manual shifts do not currently sync through CloudKit. |
| Local persistence and offline history | Implemented | SwiftData saves generated snapshots, search text and read/pin state; history search and configurable retention exist. Migration, corruption recovery and retention edge cases need tests. |
| Scheduling calculations | Verified core logic | Earliest shift minus lead time; 45-minute default; 04:00 fallback; weekend time; days-off switch; DST/time-zone/midnight tests. This calculates a target time, not proof of delivery. |
| Manual work overrides | Implemented, incomplete | Add/delete entries and replace same-start-day calendar shifts. No existing-entry edit/day-off override UI; ongoing overnight manual shifts have an interval-filtering defect. |
| Calendar integration | Implemented; permission-dependent | EventKit authorization, calendar/work-calendar selection, dates, locations, conflict indicators, change observation and read-only event viewer. Google calendars must first be synchronized with Apple Calendar. No direct Google Calendar OAuth connection. |
| Tasks/reminders | Implemented; permission-dependent | Reads up to 50 incomplete reminders and shows due/priority information. No task-completion workflow or deadline notifications. Calendar-store changes currently refresh schedule, not the tasks section. |
| Briefing generation and manual refresh | Implemented, incomplete reliability | Full/section refresh, loading states, partial reports, failure labels and old-source fallback exist. Requests are sequential and saving occurs after generation, which is vulnerable to background cancellation. |
| Card order, visibility, expansion and source links | Implemented | Settings and dashboard actions are wired. Enabled/hidden summary semantics need correction; widget configuration is global rather than per widget instance. |
| Read, pin, share and history search | Implemented, scoped | State persists within a saved briefing. A new briefing resets read/pin sets; pins are indicators, not a cross-history saved collection. Shared text includes timestamps, source and stale labels. |
| Changes since previous briefing | Partial | Compares provider states and item titles/details. Misses time-only, end-time and link changes; it is not a comprehensive important-change detector. |
| Weather | Real adapter; configuration required | WeatherKit current conditions, six hourly entries, daily high/low, precipitation, wind, alerts and attribution; Celsius/Fahrenheit. Disabled by `WeatherKitConfigured=false`; entitlement and real location permission required. No scheduled-location/travel forecasts or weather push alerts. |
| News | Real network implementation | Configurable single RSS feed, topic filtering, publication dates, HTTPS links, attribution and title deduplication. No multi-feed aggregation or robust cross-source story matching. |
| Aviation | Real network implementation, limited | NOAA METAR/TAF for up to five ICAO airports, default CYKF; raw reports, timestamps, attribution and operational disclaimer. No flight tracking, movements, disruption feed or airport operations integration. METAR and TAF should fail independently and report validity must be checked explicitly. |
| Email | Placeholder/boundary only | Always returns a disconnected section. `EmailProvider` has no concrete implementation; no OAuth, inbox retrieval, priority/deadline/reply classification or refresh/revocation logic exists. |
| Sports | Placeholder/boundary only | Team preferences exist, but the section always returns disconnected. `SportsProvider` has no concrete implementation. Scores, fixtures, standings, headlines and game notifications are absent. A public NBA probe returned HTTP 403 in this environment; that does not establish that all usable sources require payment. |
| Summary without AI | Functional deterministic roll-up | Copies selected fresh source items and flags overlapping commitments. It is labeled AI-off and is not an AI-generated narrative. |
| AI/G.I.L.E.S. | Real HTTP adapter; service required | Optional HTTPS JSON request, scoped Keychain token, consent, generated-output label and length preference. No compatible service has been verified. Length/action-prioritization quality is not enforced; actual G.I.L.E.S. compatibility is not established by the interface name. |
| Local notifications | Implemented, limited | Schedules up to seven briefing reminders, quiet-hour suppression, stable identifiers and replacement of pending requests. Messages honestly ask the user to open/refresh. No ready-content guarantee, per-feature alert categories or tested cross-channel deduplication. |
| Background refresh | Implemented, opportunistic | BGAppRefresh requests and app-open refresh exist. No exact execution guarantee; cancellation/failure can prevent scheduling the next request. |
| Remote briefing delivery/APNs | Missing implementation | Documentation describes a future service. No backend, user/device enrollment, APNs token registration/entitlement, remote snapshot download, remote notification routing or delivery mode exists. |
| Home/Lock Screen widgets | Implemented; App Group/signing required | Small/medium/large and accessory layouts, cached snapshots, expiry entries and deep links. Compilation passed; a signed shared-container/locked-device workflow has not been tested. |
| Live Activities/Dynamic Island | Implemented, limited | Explicit shift countdown within four hours of start; compact/expanded layouts. No commute/live-game activity. Stale date is set at shift start, but exact automatic termination while suspended is not implemented; expired activities end when app work resumes. |
| Apple Watch and Smart Stack | Implemented; pairing/signing required | WatchConnectivity snapshot transfer, cached summary/schedule/weather/tasks and watch widgets. No independent source fetch, delivery acknowledgement/retry workflow or physical pairing test. |
| Siri/Shortcuts | Implemented; runtime unverified | Open Today/schedule/weather/tasks/sports, read a fresh cached next appointment, open app to refresh. Opening weather/tasks is different from speaking those sections. Cached next-appointment lookup covers today's saved schedule. Training diagnostic and device invocation need testing. |
| Spoken briefing | Implemented, partly complete | System speech, play/pause/resume/stop, voices and rate. “Next section” steps an index while full playback is one utterance; it does not track the currently spoken section. Timing/freshness should be included consistently in speech. |
| CloudKit/iCloud | Configuration template and store option | Optional private CloudKit database is coded, but example identifiers and default App Group-only entitlements remain. Only SavedBriefing is a SwiftData model. Safe store transition, multi-device merges, account changes and settings sync are unverified/incomplete. |
| Head Quarter monitoring | Real manual HTTP adapter; service required | Sends a manually requested health report with a scoped token. No real Head Quarter contract/connection is verified, automatic heartbeat or durable failure journal exists. Counters reset at launch and count failed sections rather than complete refresh attempts. |
| Privacy/security | Implemented controls; release work remains | Consent gate, origin-scoped Keychain credentials, HTTPS checks, protected shared snapshot and privacy manifest exist. Account/token lifecycle, export/delete, source-disable propagation, lockscreens/Watch privacy and provider-specific retention require completion/review. |
| Preview/mock data | Preview/test-only | Fictional schedule is in DEBUG `#Preview`; test fixtures are isolated. Live providers do not return mock emails, scores, weather or appointments. Unavailable sources are shown as unavailable. |

## 3. Concrete reliability gaps to fix first

These are code-level findings, not requests for a redesign:

1. **Briefing target day is missing.** `BriefingController.refresh` uses the generation day's midnight and only includes that day's schedule. A 00:15 shift whose briefing is due at 23:30 the previous evening can therefore produce the wrong day's report. Store the intended work date/shift/window separately from `generatedAt`, and test both content and delivery alignment. Source: `App/BriefingController.swift`, lines 38 and 51–52.
2. **Ongoing manual night shifts can disappear.** Manual entries are filtered by start date rather than interval overlap. A 22:00–06:00 manual shift is omitted after midnight. Source: `Services/CalendarService.swift`, line 33.
3. **Time-only changes are missed.** Change detection compares title/detail only. Include meaningful date/end/location/source revisions and stable identities. Source: `App/BriefingController.swift`, lines 105–106.
4. **Disabling the summary does not prevent its generation.** Full refresh takes the summary branch whenever `kind == nil`, including when summary is hidden. Clarify hide versus disable and enforce the enabled-provider policy before AI requests. Source: `App/BriefingController.swift`, line 76.
5. **Background work can lose partial progress and its next refresh.** Provider calls run sequentially, saving and BG rescheduling happen at the end, and cancellation returns early. Add deadlines, incremental persistence, bounded parallel fetches and reliable resubmission without claiming precise iOS execution.
6. **Read/pin state and disabled-source caches need lifecycle rules.** New snapshots reset interaction sets. Hiding a section does not immediately remove it from an existing shared widget/Watch snapshot until a successful refresh. Persist stable user annotations and immediately propagate privacy/disable changes to exports and companion caches.
7. **Durable data recovery is missing.** Settings decode falls back silently; history payload decode can silently hide a row. Add versioned settings/snapshot migration, visible recovery/export and tested local/CloudKit transitions without deleting useful data.
8. **Freshness and integration reliability need end-to-end coverage.** Revalidate permissions and fresh location on resume, refresh tasks after EventKit changes, distinguish actual report validity from retrieval time, retain a successful METAR when TAF fails, and verify source timestamps across widgets, speech and Watch.

Notification deduplication currently has an identifier-determinism assertion, not an integration test proving that pending notification replacement, permission changes and remote/local coexistence work. Ten passing tests are useful coverage, not complete production coverage.

## 4. Website preservation and operation

Compared with baseline `1a8a6ab`, all original website HTML, CSS, JavaScript, image assets and smoke-test code are unchanged. Of 28 original tracked files, only `README.md` changed: four documentation lines link to the native project. New native source/workflows do not replace the website.

- All 25 original public site files returned HTTP 200 from the live [launch site](https://jacksonpjwilson-dev.github.io/daily-briefing-launch/) and matched the baseline byte for byte, including its 10,646-byte index.html.
- The existing site smoke test passed all 27 checks.
- Chromium tested the current local website at desktop and 390px mobile sizes: anchor navigation scrolled to Schedule, the sticky-navigation state updated, all 19 images loaded, no JavaScript page errors occurred, and mobile content width equaled the viewport (390px).
- Desktop/mobile screenshots were captured and mobile rendering inspected. The browser interaction checks used the local unchanged files; the live-site check established HTTP availability and exact HTML equality. External preview services are separate systems and are not certified by this check.

## 5. Prioritized implementation plan and exit criteria

### P0 — Harden the existing local app

Keep the current UI and service boundaries. Fix the target-day/night-shift/change-detection/summary-disable findings, preserve user annotations, persist partial results, handle cancellation and provider deadlines, version settings/history, and make permission/disable changes immediately affect caches and uploads. Add meaningful orchestration, notification replacement, provider parsing and persistence tests, plus interactive UI coverage.

**Exit:** authorized calendar/reminder data and manual shifts survive refresh/relaunch/offline operation; midnight and time-zone scenarios select the correct briefing day; rescheduled commitments generate a change; disabled sections do not initiate unwanted work or remain exposed in companion caches; user data migrates without silent reset.

### P0 — Configure Apple identities and signed development builds

Replace example bundle/App Group/CloudKit/background identifiers consistently. Configure a real team and provisioning for app and extensions; enable App Groups, WeatherKit and optional CloudKit/required background modes. Add production icons. Keep credentials outside source. Start physical iPhone testing at this stage. Investigate Siri metadata diagnostics and review SwiftData concurrency warnings without unnecessarily changing architecture or language mode.

**Exit:** a signed development build on a physical iPhone reads selected calendars/reminders, retrieves real weather, shares a widget snapshot correctly and preserves privacy when locked. CloudKit stays off until migration and two-device behavior pass.

### P1 — Build the remote delivery backend and native connection

Add an optional backend alongside the local architecture:

- Authenticated user/device enrollment, APNs token/environment registration and rotation, minimal preferences, IANA time zone, shift occurrences and schedule revisions.
- An authoritative work-schedule source. A server cannot read phone-only EventKit data automatically: use explicitly consented uploads with freshness bounds or a separately authorized server calendar integration/webhook. Handle manual overrides, revocation and stale inputs explicitly.
- Persistent scheduling/jobs: earliest shift minus lead, fallback/weekend/day-off/quiet-hour rules, DST and prior-evening delivery, cancellation/recalculation after changes, retries and idempotency by user/occurrence/revision.
- Generate and save a versioned briefing before sending a ready alert. Add native remote snapshot ingestion into SwiftData, authenticated fetch, notification/deep-link routing and offline fallback.
- Define local/server delivery modes to avoid duplicate reminders; do not rely on a silent push to cancel a local notification while suspended. Persist delivery failures, invalid-token handling and operational metrics. APNs is best effort; a backend improves scheduling control but cannot guarantee exact user receipt.

**Exit:** staging generates an actual saved briefing, sends an APNs alert to a signed phone, opens that briefing, handles a changed shift and duplicate job safely, respects quiet/day-off settings, and reports failures accurately.

### P1 — Connect and complete data providers

- Gmail: choose the supported OAuth flow and minimum scopes, register clients, add PKCE/system authentication, secure token refresh/revocation and a real EmailProvider. Implement unread/important/reply/deadline criteria. Complete Google verification/security requirements applicable to chosen scopes and distribution.
- Sports: select a legitimate accessible source under acceptable terms, implement the existing interface, then scores, fixtures/time zones, standings, attribution, headlines and configured notifications. Do not treat the single failed NBA probe as proof that a paid service is mandatory.
- Weather/news/aviation: exercise real configurations, source schemas, freshness and partial failures; add required forecast/location and flight/airport data integrations for the original scope. Keep operational flight products explicitly separate.
- AI/G.I.L.E.S.: verify the real contract and consent behavior, enforce summary lengths/source references/action quality, and keep deterministic use available with AI off.
- Head Quarter: verify the actual endpoint contract and add durable, correctly defined health events and optional reporting cadence without uploading briefing contents by default.

**Exit:** each enabled module shows actual attributed, timestamped data from a tested provider; disconnect, expired permission, offline, empty data and service failure remain distinguishable. No disconnected placeholder is counted as an operational integration.

### P1 — Finish companion and system behavior

Test and harden WidgetKit cache invalidation/deep links/expiry and source privacy; Siri discovery/invocation; true section-aware speech and interruptions; Watch transfer, reconnect and acknowledged freshness. For suspended Live Activity completion/live-game updates, add configured ActivityKit push-token handling and server updates/end events; otherwise keep the limitation visible. Commute/game activities require reliable sources before activation.

**Exit:** signed widgets, Siri, speech and a paired physical Watch work with the same real briefing, with clear stale/offline states and no unintended sensitive content exposure.

### P0 release gate — Physical devices, TestFlight and distribution

Run throughout signed development, then gate release on:

- Minimum iOS 17 and a current iOS version; fresh install, permission denial/revocation, calendar removal/recurrences, manual night shifts, DST/time-zone changes and days off.
- Airplane mode, stale caches, provider 401/403/429/5xx/timeouts, token expiry, background refresh disabled, low-power mode, locked phone, terminated app, reconnect and multi-day notification scheduling.
- APNs sandbox/production, duplicate suppression, changed/canceled shifts, notification taps, and honest distinction between target time, generated content and observed delivery.
- Two-device CloudKit sync/migration/account changes without data loss; Widget/App Group lock-screen privacy; real Watch pairing and Live Activity expiry; audio interruptions, VoiceOver, Dynamic Type, contrast and reduced motion.
- Signed Release archive, TestFlight install/update, app icons, verified privacy disclosures/retention and deletion controls, WeatherKit/source branding and provider terms, operational monitoring and rollback.

**Exit:** the intended full daily workflow is demonstrated on physical devices and documented, outstanding critical defects are closed, and the release artifact—not only a Debug simulator build—is validated.

This sequence brings the current implementation forward in place. A production local-only release could precede optional cloud features, but the original automatic personalized-delivery goal requires the remote pipeline and its real source connections.
