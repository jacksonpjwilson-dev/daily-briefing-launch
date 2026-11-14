#if canImport(SwiftData)
import XCTest
import SwiftData
@testable import BriefingCore
@testable import HistoryPersistence

final class HistoryPersistenceTests: XCTestCase {
    func snapshot() -> BriefingSnapshot {
        BriefingSnapshot(generatedAt: Date(), sections: [.init(kind: .news, state: .ready, fetchedAt: Date(), expiresAt: Date().addingTimeInterval(600), items: [.init(id: "article", title: "History test fixture", source: "Test")])])
    }
    @MainActor func testOriginalUnversionedStoreAndPayloadMigrateWithoutDataLoss() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("legacy.store"), saved = snapshot()
        let original = try JSONEncoder().encode(saved)
        try autoreleasepool {
            let schema = Schema([HistorySchemaV1.SavedBriefing.self]) // Same unversioned schema as the original app.
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
            let row = HistorySchemaV1.SavedBriefing(); row.id = saved.id; row.generatedAt = saved.generatedAt; row.payload = original; row.text = saved.summaryText
            container.mainContext.insert(row); try container.mainContext.save()
        }
        let container = try Persistence.container(url: url)
        let store = HistoryStore(context: container.mainContext)
        let loaded = try store.load()
        XCTAssertEqual(loaded.map(\.id), [saved.id]); XCTAssertEqual(loaded[0].sections[0].items[0].title, "History test fixture")
        let row = try container.mainContext.fetch(FetchDescriptor<SavedBriefing>()).first!
        XCTAssertEqual(row.recoveryPayload, original); XCTAssertEqual(row.payloadVersion, 2)
        XCTAssertEqual(try SnapshotCodec.decode(row.payload).version, 2)
    }
    @MainActor func testCheckpointIsUpdatedInPlaceAndInterruptedRunIsRecovered() async throws {
        let container = try Persistence.container(inMemory: true)
        let store = HistoryStore(context: container.mainContext)
        var value = snapshot(); value.status = .refreshing
        try store.save(value)
        value.sections.append(.init(kind: .schedule, state: .ready)); try store.save(value)
        let reopened = HistoryStore(context: container.mainContext)
        let records = try reopened.load()
        XCTAssertEqual(records.count, 1); XCTAssertEqual(records[0].sections.count, 2)
        XCTAssertEqual(records[0].status, .interrupted)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<SavedBriefing>()), 1)
    }
    @MainActor func testCorruptRowsRemainVisibleAndReadableBackupCanBeRestored() async throws {
        let container = try Persistence.container(inMemory: true)
        let value = snapshot()
        let original = try SnapshotCodec.encode(value)
        let row = try SavedBriefing(value); let damaged = Data("unreadable history".utf8)
        row.payload = damaged; row.recoveryPayload = original
        container.mainContext.insert(row); try container.mainContext.save()
        let store = HistoryStore(context: container.mainContext)
        XCTAssertTrue(try store.load().isEmpty)
        XCTAssertEqual(row.payload, damaged); XCTAssertNotNil(row.recoveryReason); XCTAssertEqual(store.recoveryMessages.count, 1)
        XCTAssertTrue(row.canRestoreBackup)
        try store.restore(row)
        XCTAssertEqual(row.recoveryPayload, damaged)
        XCTAssertEqual(row.snapshot?.sections.first?.items.first?.title, "History test fixture")
    }
    @MainActor func testPruningKeepsUnreadableRecoveryAndPinnedHistory() async throws {
        let container = try Persistence.container(inMemory: true)
        let store = HistoryStore(context: container.mainContext)
        var ordinary = snapshot(); ordinary.generatedAt = .distantPast
        var pinned = ordinary; pinned.id = UUID(); pinned.pinnedItems = ["article"]
        try store.save(ordinary); try store.save(pinned)
        try store.prune(before: Date())
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<SavedBriefing>()), 1)
        XCTAssertEqual(try store.load().first?.id, pinned.id)
    }
    @MainActor func testInterruptedCoordinatorPersistsFastSourceBeforeCancellation() async throws {
        let container = try Persistence.container(inMemory: true)
        let store = HistoryStore(context: container.mainContext)
        var value = snapshot(); value.sections = []; value.status = .refreshing
        try store.save(value)
        let first = expectation(description: "Persisted first section")
        let task = Task { @MainActor in
            await RefreshCoordinator.run(jobs: [
                .init(kind: .schedule) { .init(kind: .schedule, state: .ready) },
                .init(kind: .news) { try await Task.sleep(nanoseconds: 1_000_000_000); return .init(kind: .news, state: .ready) }
            ], enabled: [.schedule, .news], budget: 2) { section in
                value.sections.append(section); try store.save(value); first.fulfill()
            }
        }
        await fulfillment(of: [first], timeout: 1); task.cancel()
        let outcome = await task.value; XCTAssertEqual(outcome, .interrupted)
        let recovered = try HistoryStore(context: container.mainContext).load()
        XCTAssertEqual(recovered.first?.sections.map(\.kind), [.schedule])
        XCTAssertEqual(recovered.first?.status, .interrupted)
    }
}
#endif
