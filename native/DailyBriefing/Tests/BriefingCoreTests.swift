import XCTest
@testable import BriefingCore

final class BriefingCoreTests: XCTestCase {
    func calendar(_ zone: String = "America/Toronto") -> Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: zone)!; return c
    }
    func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    func testShiftExamplesAndEarliestShift() {
        let c = calendar(), p = SchedulingPreferences()
        for hour in [4, 8, 15] {
            let shift = c.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: hour))!
            let delivery = BriefingScheduler.delivery(on: shift, shifts: [shift.addingTimeInterval(3600), shift], preferences: p, calendar: c)!
            XCTAssertEqual(shift.timeIntervalSince(delivery), 2700)
        }
    }
    func testDefaultWeekendAndDayOff() {
        let c = calendar(); var p = SchedulingPreferences(); p.weekendMinute = 360
        let weekday = date("2026-11-11T12:00:00Z"), weekend = date("2026-11-14T12:00:00Z")
        XCTAssertEqual(c.component(.hour, from: BriefingScheduler.delivery(on: weekday, shifts: [], preferences: p, calendar: c)!), 4)
        XCTAssertEqual(c.component(.hour, from: BriefingScheduler.delivery(on: weekend, shifts: [], preferences: p, calendar: c)!), 6)
        p.deliverOnDaysOff = false
        XCTAssertNil(BriefingScheduler.delivery(on: weekday, shifts: [], preferences: p, calendar: c))
    }
    func testTimeZoneChange() {
        let day = date("2026-11-11T12:00:00Z")
        let toronto = BriefingScheduler.delivery(on: day, shifts: [], preferences: .init(), calendar: calendar())!
        let london = BriefingScheduler.delivery(on: day, shifts: [], preferences: .init(), calendar: calendar("Europe/London"))!
        XCTAssertEqual(toronto.timeIntervalSince(london), 5 * 3600)
    }
    func testSpringGapAndFallRepeat() {
        let c = calendar(); var p = SchedulingPreferences(); p.weekendMinute = 150
        let spring = BriefingScheduler.delivery(on: date("2026-03-08T12:00:00Z"), shifts: [], preferences: p, calendar: c)!
        XCTAssertEqual(c.component(.hour, from: spring), 3)
        p.weekendMinute = 90
        let fall = BriefingScheduler.delivery(on: date("2026-11-01T12:00:00Z"), shifts: [], preferences: p, calendar: c)!
        XCTAssertEqual(fall, date("2026-11-01T05:30:00Z"))
        let shift = date("2026-03-08T07:15:00Z")
        XCTAssertEqual(BriefingScheduler.delivery(on: shift, shifts: [shift], preferences: p, calendar: c), shift.addingTimeInterval(-2700))
    }
    func testCrossMidnightAndPastDeliveries() {
        let c = calendar(), shift = date("2026-11-12T05:15:00Z"), now = date("2026-11-12T04:00:00Z")
        let dates = BriefingScheduler.upcoming(after: now, shifts: [shift], preferences: .init(), calendar: c)
        XCTAssertEqual(dates.first, date("2026-11-12T04:30:00Z"))
        XCTAssertTrue(dates.allSatisfy { $0 > now })
    }
    func testCacheMissingDataAndGeneration() {
        let now = Date()
        let missing = BriefingSection(kind: .email, state: .disconnected)
        XCTAssertFalse(missing.isFresh(at: now))
        let ready = BriefingSection(kind: .schedule, state: .ready, fetchedAt: now, expiresAt: now.addingTimeInterval(60))
        XCTAssertTrue(ready.isFresh(at: now))
        XCTAssertEqual(ready.assessed(at: now.addingTimeInterval(61)).state, .stale)
        XCTAssertEqual(GenerationPhase.result(for: []), .failed)
        XCTAssertEqual(GenerationPhase.result(for: [ready]), .complete)
        XCTAssertEqual(GenerationPhase.result(for: [ready, missing]), .partial)
    }
    func testCredentialsStayWithTheirOrigin() {
        let account = CredentialScope.account(service: "ai", endpoint: URL(string: "https://one.example/summary")!)
        XCTAssertNotNil(account)
        XCTAssertEqual(account, CredentialScope.account(service: "ai", endpoint: URL(string: "https://one.example:443/other-path")!))
        XCTAssertNotEqual(account, CredentialScope.account(service: "ai", endpoint: URL(string: "https://two.example/summary")!))
        XCTAssertNotEqual(account, CredentialScope.account(service: "ai", endpoint: URL(string: "https://one.example:8443/summary")!))
        XCTAssertNotEqual(account, CredentialScope.account(service: "monitoring", endpoint: URL(string: "https://one.example/health")!))
        XCTAssertNil(CredentialScope.account(service: "ai", endpoint: URL(string: "http://one.example/summary")!))
        XCTAssertNil(CredentialScope.account(service: "ai", endpoint: URL(string: "https://user:secret@one.example/summary")!))
    }
    func testSharedTextLabelsExpiredSources() {
        let old = Date().addingTimeInterval(-7200)
        let section = BriefingSection(kind: .weather, state: .ready, fetchedAt: old, expiresAt: old.addingTimeInterval(1800),
            items: [.init(title: "Weather report", source: "Verified source")])
        let snapshot = BriefingSnapshot(generatedAt: old, sections: [section])
        XCTAssertTrue(snapshot.summaryText.contains("[stale]"))
        XCTAssertTrue(snapshot.summaryText.contains("source refreshed"))
        XCTAssertTrue(snapshot.summaryText.contains("Verified source"))
        XCTAssertTrue(snapshot.summaryText.contains("saved"))
    }
    func testGenerationStateTransitions() {
        var state = GenerationStateMachine()
        XCTAssertEqual(state.phase, .idle)
        XCTAssertTrue(state.start()); XCTAssertEqual(state.phase, .loading)
        XCTAssertFalse(state.start(), "Concurrent generation must be rejected")
        state.finish(sections: []); XCTAssertEqual(state.phase, .failed)
        XCTAssertTrue(state.start())
        state.finish(sections: [.init(kind: .schedule, state: .ready), .init(kind: .email, state: .disconnected)])
        XCTAssertEqual(state.phase, .partial)
        XCTAssertTrue(state.start()); state.cancel(); XCTAssertEqual(state.phase, .idle)
        XCTAssertTrue(state.start()); state.fail(); XCTAssertEqual(state.phase, .failed)
        XCTAssertTrue(state.start()); state.finish(sections: [.init(kind: .schedule, state: .ready)])
        XCTAssertEqual(state.phase, .complete)
    }
    func testConflictsAndNotificationDeduplication() {
        let now = Date()
        let a = BriefingItem(id: "a", title: "A", date: now, end: now.addingTimeInterval(600), source: "Calendar")
        let b = BriefingItem(id: "b", title: "B", date: now.addingTimeInterval(300), end: now.addingTimeInterval(900), source: "Calendar")
        XCTAssertEqual(BriefingScheduler.conflicts([a, b]), ["a", "b"])
        XCTAssertEqual(NotificationPolicy.identifier(for: now), NotificationPolicy.identifier(for: now))
        var p = NotificationPolicy(); p.quietEnabled = true
        XCTAssertFalse(p.allows(date("2026-11-11T04:30:00Z"), calendar: calendar()))
        XCTAssertTrue(p.allows(date("2026-11-11T09:00:00Z"), calendar: calendar()))
    }
}
