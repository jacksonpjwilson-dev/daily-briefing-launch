import XCTest
@testable import BriefingCore

final class RecoveryTests: XCTestCase {
    func defaults() -> UserDefaults { UserDefaults(suiteName: "DailyBriefingTests." + UUID().uuidString)! }
    func testLegacyPartialSettingsGainDefaultsWithoutLosingValuesOrSourceFile() throws {
        let defaults = defaults()
        let original = Data(#"{"name":"Fixture User","scheduling":{"leadMinutes":75},"hiddenSections":["email"]}"#.utf8)
        defaults.set(original, forKey: PreferencesPersistence.legacyKey)
        let store = PreferencesPersistence(defaults: defaults)
        XCTAssertFalse(store.recoveryRequired)
        XCTAssertEqual(store.document.preferences.name, "Fixture User")
        XCTAssertEqual(store.document.preferences.scheduling.leadMinutes, 75)
        XCTAssertEqual(store.document.preferences.scheduling.weekdayMinute, 240)
        XCTAssertEqual(store.document.preferences.hiddenSections, [.email])
        XCTAssertEqual(defaults.data(forKey: PreferencesPersistence.legacyKey), original)
        XCTAssertEqual(defaults.data(forKey: PreferencesPersistence.backupKey), original)
        XCTAssertNotNil(defaults.data(forKey: PreferencesPersistence.currentKey))
        XCTAssertEqual(PreferencesPersistence(defaults: defaults).document.sourceVersions, store.document.sourceVersions)
    }
    func testFutureOrCorruptPreferencesArePreservedAndAutosaveBlocked() throws {
        for data in [Data("not-json".utf8), Data(#"{"schemaVersion":"future","preferences":{}}"#.utf8),
                     Data(#"{"schemaVersion":2,"preferences":"damaged"}"#.utf8), Data(#"{"schemaVersion":999,"preferences":{"name":"Future data"}}"#.utf8)] {
            let defaults = defaults(); defaults.set(data, forKey: PreferencesPersistence.currentKey)
            let store = PreferencesPersistence(defaults: defaults)
            XCTAssertTrue(store.recoveryRequired); XCTAssertNotNil(store.notice)
            var edited = store.document.preferences; edited.name = "Attempted edit"; store.save(edited)
            XCTAssertEqual(defaults.data(forKey: PreferencesPersistence.currentKey), data)
            XCTAssertEqual(defaults.data(forKey: PreferencesPersistence.recoveryKey), data)
            store.keepCurrent()
            XCTAssertFalse(store.recoveryRequired)
            XCTAssertEqual(defaults.data(forKey: PreferencesPersistence.recoveryKey), data)
            XCTAssertEqual(try PreferencesCodec.decode(defaults.data(forKey: PreferencesPersistence.currentKey)!).preferences.name, "Attempted edit")
        }
    }
    func testPartialVersionedSettingsPersistNewRevisionIDsAcrossLaunches() {
        let defaults = defaults()
        defaults.set(Data(#"{"schemaVersion":2,"preferences":{"name":"Existing"}}"#.utf8), forKey: PreferencesPersistence.currentKey)
        let first = PreferencesPersistence(defaults: defaults)
        XCTAssertFalse(first.recoveryRequired)
        let second = PreferencesPersistence(defaults: defaults)
        XCTAssertEqual(first.document.sourceVersions, second.document.sourceVersions)
        XCTAssertEqual(second.document.preferences.name, "Existing")
    }
    func testLastGoodRecoveryAndAnnotationsSurviveSettingsSave() throws {
        let defaults = defaults(); let store = PreferencesPersistence(defaults: defaults)
        var p = store.document.preferences; p.name = "Last good"; store.save(p)
        p.name = "Another readable value"; store.save(p)
        let damaged = Data("corrupt-current".utf8); defaults.set(damaged, forKey: PreferencesPersistence.currentKey)
        let recovery = PreferencesPersistence(defaults: defaults)
        XCTAssertTrue(recovery.restoreLastGood())
        XCTAssertEqual(recovery.document.preferences.name, "Last good")
        XCTAssertEqual(defaults.data(forKey: PreferencesPersistence.recoveryKey), damaged)
        var snapshot = BriefingSnapshot(generatedAt: Date(), sections: [.init(kind: .news, state: .ready, items: [.init(id: "article", title: "Fixture", source: "Test")])])
        snapshot.pinnedItems = ["article"]; snapshot.readSections = [.news]
        recovery.recordAnnotations(snapshot)
        var value = recovery.document.preferences; value.appearance = "dark"; recovery.save(value)
        let again = PreferencesPersistence(defaults: defaults)
        XCTAssertEqual(again.document.annotations.pinnedIDs, ["article"])
        XCTAssertEqual(again.document.annotations.applying(to: snapshot).readSections, [.news])
    }
    func testSourceVersionsOnlyChangeForRelevantSettingsAndEndpointChangeRevokesAIConsent() {
        let store = PreferencesPersistence(defaults: defaults())
        let original = store.document.sourceVersions
        var p = store.document.preferences; p.name = "Different name"; store.save(p)
        XCTAssertEqual(store.document.sourceVersions, original)
        p.newsTopics = "Changed topic"; store.save(p)
        XCTAssertNotEqual(store.document.sourceVersions["news"], original["news"])
        XCTAssertNotEqual(store.document.sourceVersions["summary"], original["summary"])
        XCTAssertEqual(store.document.sourceVersions["weather"], original["weather"])
        p.aiEndpoint = "https://one.example/summary"; store.save(p)
        p.aiConsent = true; store.save(p); XCTAssertTrue(store.document.preferences.aiConsent)
        p.aiEndpoint = "https://two.example/summary"; store.save(p)
        XCTAssertFalse(store.document.preferences.aiConsent)
    }
    func testLegacyHistoryPayloadMigratesMissingFieldsAndFutureSchemaFails() throws {
        let id = UUID()
        let data = try JSONSerialization.data(withJSONObject: ["id": id.uuidString, "generatedAt": 800000000.0,
            "sections": [["kind":"news","state":"ready","items":[["id":"legacy","title":"Legacy fixture","source":"Test"]]]]])
        let legacy = try SnapshotCodec.decode(data)
        XCTAssertEqual(legacy.version, 1); XCTAssertEqual(legacy.value.id, id)
        XCTAssertEqual(legacy.value.sections[0].items[0].detail, "")
        XCTAssertEqual(legacy.value.status, .complete)
        let upgraded = try SnapshotCodec.decode(SnapshotCodec.encode(legacy.value))
        XCTAssertEqual(upgraded.version, 2); XCTAssertEqual(upgraded.value.sections[0].items[0].id, "legacy")
        XCTAssertThrowsError(try SnapshotCodec.decode(Data(#"{"schemaVersion":999,"payload":{}}"#.utf8)))
        XCTAssertThrowsError(try SnapshotCodec.decode(Data("broken".utf8)))
    }
}

final class NotificationPlanningTests: XCTestCase {
    func testReplacementDeduplicatesAndDoesNotRemoveUnrelatedNotifications() {
        let now = Date(), first = now.addingTimeInterval(600), second = now.addingTimeInterval(1200)
        let pending = [NotificationPolicy.identifier(for: first), "briefing.obsolete", "other-feature"]
        let plan = NotificationPlan.make(dates: [second, first, first, now.addingTimeInterval(-1)], enabled: true, quiet: .init(), now: now, calendar: .current, pendingIDs: pending)
        XCTAssertEqual(plan.dates, [first, second]); XCTAssertEqual(plan.obsoleteIDs, ["briefing.obsolete"])
        let disabled = NotificationPlan.make(dates: [first], enabled: false, quiet: .init(), now: now, calendar: .current, pendingIDs: pending)
        XCTAssertTrue(disabled.dates.isEmpty)
        XCTAssertEqual(Set(disabled.obsoleteIDs), Set(pending.filter { $0.hasPrefix("briefing.") }))
    }
    func testQuietHoursAndSevenNotificationLimitAreAppliedToActualPlan() {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = ISO8601DateFormatter().date(from: "2026-11-12T12:00:00Z")!
        var quiet = NotificationPolicy(); quiet.quietEnabled = true
        let dates = (0..<30).map { now.addingTimeInterval(Double($0 + 1) * 3600) }
        let plan = NotificationPlan.make(dates: dates, enabled: true, quiet: quiet, now: now, calendar: c, pendingIDs: [])
        XCTAssertEqual(plan.dates.count, 7)
        XCTAssertTrue(plan.dates.allSatisfy { quiet.allows($0, calendar: c) })
    }
}
