import XCTest
@testable import BriefingCore

final class LocalHardeningTests: XCTestCase {
    func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    func calendar(_ zone: String = "America/Toronto") -> Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: zone)!; return c
    }
    func event(id: String = "event-1", start: Date, end: Date? = nil, title: String = "Test shift") -> BriefingItem {
        BriefingItem(id: id, title: title, detail: "Test location", date: start, end: end ?? start.addingTimeInterval(3600), source: "Test calendar", isShift: true, origin: .calendar, calendarIdentifier: "work")
    }
    func testEveningBeforeEarlyShiftSelectsWorkDayAndContent() {
        let shift = event(start: date("2026-11-12T05:15:00Z")) // 00:15 Toronto
        let target = BriefingScheduler.target(at: date("2026-11-12T04:30:00Z"), events: [shift], preferences: .init(), calendar: calendar())
        XCTAssertEqual(target.dayStart, date("2026-11-12T05:00:00Z"))
        XCTAssertEqual(target.scheduledFor, date("2026-11-12T04:30:00Z"))
        XCTAssertTrue(target.contains(shift))
        XCTAssertFalse(target.contains(event(start: date("2026-11-11T14:00:00Z"))))
    }
    func testTargetDoesNotAdvanceBeforePreparationWindowOrMoveBackForOngoingShift() {
        let shift = event(start: date("2026-11-12T05:15:00Z"))
        let early = BriefingScheduler.target(at: date("2026-11-12T04:00:00Z"), events: [shift], preferences: .init(), calendar: calendar())
        XCTAssertEqual(early.dayStart, date("2026-11-11T05:00:00Z"))
        let ongoing = event(start: date("2026-11-12T03:00:00Z"), end: date("2026-11-12T11:00:00Z"))
        let afterMidnight = BriefingScheduler.target(at: date("2026-11-12T06:00:00Z"), events: [ongoing], preferences: .init(), calendar: calendar())
        XCTAssertEqual(afterMidnight.dayStart, date("2026-11-12T05:00:00Z"))
        XCTAssertTrue(afterMidnight.contains(ongoing))
    }
    func testTargetDayBoundsRespectDSTAndTimeZone() {
        let spring = BriefingScheduler.target(at: date("2026-03-08T12:00:00Z"), events: [], preferences: .init(), calendar: calendar())
        let fall = BriefingScheduler.target(at: date("2026-11-01T12:00:00Z"), events: [], preferences: .init(), calendar: calendar())
        XCTAssertEqual(spring.dayEnd.timeIntervalSince(spring.dayStart), 23 * 3600)
        XCTAssertEqual(fall.dayEnd.timeIntervalSince(fall.dayStart), 25 * 3600)
        let london = BriefingScheduler.target(at: date("2026-11-12T04:45:00Z"), events: [], preferences: .init(), calendar: calendar("Europe/London"))
        XCTAssertEqual(london.timeZoneID, "Europe/London")
        XCTAssertEqual(london.dayStart, date("2026-11-12T00:00:00Z"))
    }
    func testOngoingManualShiftSurvivesMidnightAndEndsAtBoundary() {
        var shift = ManualShift(); shift.start = date("2026-11-12T03:00:00Z"); shift.end = date("2026-11-12T11:00:00Z")
        let items = ManualSchedule.resolve(calendarItems: [], shifts: [shift], from: date("2026-11-12T05:00:00Z"), to: date("2026-11-13T05:00:00Z"), calendar: calendar())
        XCTAssertEqual(items.map(\.id), [shift.id.uuidString]); XCTAssertEqual(items.first?.origin, .manual)
        XCTAssertTrue(ManualSchedule.resolve(calendarItems: [], shifts: [shift], from: shift.end, to: shift.end.addingTimeInterval(3600), calendar: calendar()).isEmpty)
    }
    func testShortenedManualOverrideDoesNotResurrectCalendarNightShift() {
        let original = event(start: date("2026-11-12T03:00:00Z"), end: date("2026-11-12T11:00:00Z"))
        var manual = ManualShift(); manual.start = date("2026-11-12T01:00:00Z"); manual.end = date("2026-11-12T02:00:00Z")
        let items = ManualSchedule.resolve(calendarItems: [original], shifts: [manual], from: date("2026-11-12T05:00:00Z"), to: date("2026-11-13T05:00:00Z"), calendar: calendar())
        XCTAssertTrue(items.isEmpty)
    }
    func testStableCalendarIdentityAndRecurringOccurrences() {
        let a = CalendarIdentity.id(calendar: "work", item: "persistent-id", occurrence: nil)
        XCTAssertEqual(a, CalendarIdentity.id(calendar: "work", item: "persistent-id", occurrence: nil))
        XCTAssertNotEqual(a, CalendarIdentity.id(calendar: "other-calendar", item: "persistent-id", occurrence: nil))
        XCTAssertNotEqual(CalendarIdentity.id(calendar: "work", item: "series", occurrence: date("2026-11-12T13:00:00Z")), CalendarIdentity.id(calendar: "work", item: "series", occurrence: date("2026-11-13T13:00:00Z")))
    }
    func testMeaningfulChangesIncludeTimeDurationLocationLinksAndSource() {
        let item = event(start: date("2026-11-12T13:00:00Z"))
        let old = BriefingSnapshot(generatedAt: Date(), sections: [.init(kind: .schedule, state: .ready, items: [item])])
        let changes: [(inout BriefingItem) -> Void] = [
            { $0.date = $0.date!.addingTimeInterval(3600) }, { $0.end = $0.end!.addingTimeInterval(1800) },
            { $0.detail = "Changed location" }, { $0.url = URL(string: "https://example.com/updated") }, { $0.source = "Changed calendar" }
        ]
        for edit in changes {
            var changed = item; edit(&changed)
            let new = BriefingSnapshot(generatedAt: Date(), sections: [.init(kind: .schedule, state: .ready, items: [changed])])
            XCTAssertEqual(BriefingChanges.compare(old, new), ["Schedule has updated information."])
        }
        var same = old; same.sections[0].fetchedAt = Date(); same.sections[0].expiresAt = Date().addingTimeInterval(600)
        XCTAssertTrue(BriefingChanges.compare(old, same).isEmpty)
    }
    func testPinsAndReadsSurviveIdenticalRegenerationButChangesBecomeUnread() {
        let item = event(start: date("2026-11-12T13:00:00Z"))
        var old = BriefingSnapshot(generatedAt: Date(), sections: [.init(kind: .schedule, state: .ready, items: [item])])
        old.target = BriefingScheduler.target(at: item.date!, events: [item], preferences: .init(), calendar: calendar())
        old.pinnedItems = [item.id]; old.readSections = [.schedule]
        var ledger = AnnotationLedger(); ledger.record(old)
        var next = old; next.id = UUID(); next.generatedAt = Date().addingTimeInterval(10); next.readSections = []; next.pinnedItems = []
        XCTAssertEqual(ledger.applying(to: next).readSections, [.schedule])
        XCTAssertEqual(ledger.applying(to: next).pinnedItems, [item.id])
        next.sections[0].items[0].date = item.date!.addingTimeInterval(1800)
        XCTAssertTrue(ledger.applying(to: next).readSections.isEmpty)
        XCTAssertEqual(ledger.applying(to: next).pinnedItems, [item.id])
        var partial = next; partial.sections[0].items = []
        XCTAssertTrue(ledger.applying(to: partial).pinnedItems.isEmpty)
        XCTAssertEqual(ledger.applying(to: next).pinnedItems, [item.id], "An interrupted source must not erase the saved annotation")
    }
    func testDisabledSourcesAreRemovedFromHistorySearchSharingAndSummary() {
        let secret = BriefingItem(id: "private-id", title: "Private calendar value", source: "Test calendar", origin: .calendar, calendarIdentifier: "work")
        let summary = BriefingSection(kind: .summary, state: .ready, items: [.init(title: "Private calendar value", source: "AI")], isGenerated: true, dependencies: [.schedule])
        var original = BriefingSnapshot(generatedAt: Date(), sections: [.init(kind: .schedule, state: .ready, items: [secret]), summary])
        original.pinnedItems = [secret.id]; original.readSections = [.schedule]
        let policy = SnapshotAccessPolicy(enabled: [.summary], aiAllowed: true)
        let filtered = policy.applying(to: original, historical: true)
        XCTAssertFalse(filtered.summaryText.contains("Private calendar value"))
        XCTAssertTrue(filtered.sections.allSatisfy { $0.items.isEmpty }); XCTAssertTrue(filtered.pinnedItems.isEmpty)
        XCTAssertTrue(filtered.readSections.isEmpty)
        XCTAssertEqual(original.sections[0].items.count, 1, "Filtering must not destroy the private archive")
    }
    func testRevokedPermissionsRemovePrivateCacheButKeepManualEntries() {
        let calendarItem = event(start: Date())
        let manual = BriefingItem(id: "manual", title: "Manual entry", source: "Manual schedule", isShift: true, origin: .manual)
        let original = BriefingSnapshot(generatedAt: Date(), sections: [
            .init(kind: .schedule, state: .ready, items: [calendarItem, manual]),
            .init(kind: .tasks, state: .ready, items: [.init(title: "Private reminder", source: "Reminders")]),
            .init(kind: .weather, state: .ready, items: [.init(title: "Private location forecast", source: "Weather")])])
        let policy = SnapshotAccessPolicy(enabled: [.schedule, .tasks, .weather], calendarAllowed: false, remindersAllowed: false, locationAllowed: false, manualIDs: ["manual"])
        let visible = policy.applying(to: original)
        XCTAssertEqual(visible.sections[0].items.map(\.id), ["manual"])
        XCTAssertEqual(visible.sections[0].state, .partial)
        XCTAssertTrue(visible.sections[1].items.isEmpty); XCTAssertTrue(visible.sections[2].items.isEmpty)
        XCTAssertFalse(visible.summaryText.contains("Private reminder"))
    }
    func testChangedCalendarSelectionCannotExposeOtherCalendarOrLegacyUnknownProvenance() {
        let approved = event(start: Date())
        var other = approved; other.id = "other"; other.calendarIdentifier = "personal"
        let legacy = BriefingItem(id: "legacy", title: "Unknown calendar", source: "Work")
        let original = BriefingSnapshot(generatedAt: Date(), sections: [.init(kind: .schedule, state: .ready, items: [approved, other, legacy])])
        let policy = SnapshotAccessPolicy(enabled: [.schedule], calendarIDs: ["work"])
        XCTAssertEqual(policy.applying(to: original, historical: true).sections[0].items.map(\.id), [approved.id])
    }
    func testSharedCacheRechecksGateAndFailsClosedIfCorrupt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedCacheStore(directory: directory)
        let snapshot = BriefingSnapshot(generatedAt: Date(), sections: [.init(kind: .news, state: .ready, items: [.init(id: "secret", title: "Cached private feed", source: "Test feed")])])
        let permitted = SnapshotAccessPolicy(enabled: [.news])
        try store.save(snapshot, policy: permitted)
        XCTAssertTrue(try store.read().snapshot.summaryText.contains("Cached private feed"))
        try store.replacePolicy(.init(enabled: []))
        XCTAssertFalse(try store.read().snapshot.summaryText.contains("Cached private feed"), "Even an unchanged old payload must obey the new gate")
        try Data("broken".utf8).write(to: directory.appendingPathComponent("briefing-access-v2.json"))
        XCTAssertThrowsError(try store.read())
        try Data(#"{"schemaVersion":999,"policy":{}}"#.utf8).write(to: directory.appendingPathComponent("briefing-access-v2.json"))
        XCTAssertThrowsError(try store.read())
    }
    func testChangedSourceConfigurationInvalidatesLiveCacheButKeepsDatedArchive() {
        let snapshot = BriefingSnapshot(generatedAt: Date(), sections: [.init(kind: .news, state: .ready, items: [.init(title: "Old feed", source: "Test")])])
        let policy = SnapshotAccessPolicy(enabled: [.news], sourceVersions: ["news": UUID()])
        XCTAssertTrue(policy.applying(to: snapshot).sections[0].items.isEmpty)
        XCTAssertEqual(policy.applying(to: snapshot, historical: true).sections[0].items.count, 1)
    }
    func testPartialAviationKeepsMETARWhenTAFFailsAndMarksExpiredProducts() throws {
        let now = date("2026-11-12T12:00:00Z")
        let data = Data(#"[{"icaoId":"CYKF","rawOb":"FICTIONAL TEST METAR","reportTime":"2026-11-12T11:30:00.000Z"}]"#.utf8)
        let reports = try JSONDecoder().decode([AviationReport].self, from: data)
        let section = AviationReports.section([.init(product: "metar", records: reports), .init(product: "taf", error: "Fixture timeout")], now: now)
        XCTAssertEqual(section.state, .partial); XCTAssertEqual(section.items.count, 1); XCTAssertTrue(section.isFresh(at: now))
        XCTAssertTrue(section.message.contains("TAF unavailable"))
        let expired = AviationReports.section([.init(product: "metar", records: reports)], now: now.addingTimeInterval(3 * 3600))
        XCTAssertEqual(expired.state, .stale); XCTAssertFalse(expired.isFresh(at: now.addingTimeInterval(3 * 3600)))
        XCTAssertTrue(expired.items.first!.detail.contains("expired or unknown"))
    }
    func testPartialFreshnessAndSpokenExpiryAreTransparent() {
        let now = Date()
        let s = BriefingSection(kind: .aviation, state: .partial, message: "TAF unavailable", fetchedAt: now, expiresAt: now.addingTimeInterval(60), items: [.init(title: "Test report", source: "Fixture", sourceExpiresAt: now.addingTimeInterval(-1))])
        XCTAssertTrue(s.isFresh(at: now)); XCTAssertFalse(s.isFresh(at: now.addingTimeInterval(61)))
        XCTAssertTrue(s.spokenText(at: now).contains("Expired or unverified"))
        XCTAssertTrue(s.assessed(at: now.addingTimeInterval(61)).message.contains("TAF unavailable"))
    }
    func testAllDayItemsDoNotCreateTimedConflictWarnings() {
        let start = Date()
        var allDay = event(id: "all-day", start: start, end: start.addingTimeInterval(24 * 3600)); allDay.isAllDay = true
        XCTAssertTrue(BriefingScheduler.conflicts([allDay, event(start: start.addingTimeInterval(3600))]).isEmpty)
    }
}
