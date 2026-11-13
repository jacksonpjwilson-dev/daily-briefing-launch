#if canImport(SwiftData)
import SwiftData
import Foundation
#if SWIFT_PACKAGE
import BriefingCore
#endif

enum HistorySchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [SavedBriefing.self] }
    @Model final class SavedBriefing {
        var id: UUID = UUID()
        var generatedAt: Date = Date()
        var text: String = ""
        var payload: Data = Data()
        init() {}
    }
}
enum HistorySchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] { [SavedBriefing.self] }
    @Model final class SavedBriefing {
        var id: UUID = UUID()
        var generatedAt: Date = Date()
        var text: String = ""
        var payload: Data = Data()
        var payloadVersion: Int = 1
        var recoveryPayload: Data? = nil
        var recoveryReason: String? = nil
        init(_ snapshot: BriefingSnapshot) throws {
            id = snapshot.id; generatedAt = snapshot.generatedAt; text = snapshot.summaryText
            payload = try SnapshotCodec.encode(snapshot); payloadVersion = SnapshotCodec.currentVersion
        }
        var snapshot: BriefingSnapshot? { try? SnapshotCodec.decode(payload).value }
        var canRestoreBackup: Bool { recoveryPayload.flatMap { try? SnapshotCodec.decode($0) } != nil }
    }
}
typealias SavedBriefing = HistorySchemaV2.SavedBriefing
struct HistoryMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [HistorySchemaV1.self, HistorySchemaV2.self] }
    static var stages: [MigrationStage] { [.lightweight(fromVersion: HistorySchemaV1.self, toVersion: HistorySchemaV2.self)] }
}
enum Persistence {
    static func container(cloud: Bool = false, url: URL? = nil, inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(versionedSchema: HistorySchemaV2.self)
        let database: ModelConfiguration.CloudKitDatabase = cloud ? .private("iCloud.com.example.DailyBriefing") : .none
        let configuration: ModelConfiguration
        if let url { configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: database) }
        else { configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory, cloudKitDatabase: database) }
        return try ModelContainer(for: schema, migrationPlan: HistoryMigrationPlan.self, configurations: [configuration])
    }
}
@MainActor final class HistoryStore {
    private let context: ModelContext
    private var rows: [UUID: SavedBriefing] = [:]
    private(set) var recoveryMessages: [String] = []
    init(context: ModelContext) { self.context = context }
    func load(recoverInterrupted: Bool = true) throws -> [BriefingSnapshot] {
        // Sorting in memory avoids the old toolchain's non-Sendable generated key-path diagnostics.
        let records = try context.fetch(FetchDescriptor<SavedBriefing>()).sorted { $0.generatedAt < $1.generatedAt }
        var snapshots: [BriefingSnapshot] = []
        recoveryMessages = []
        for row in records {
            rows[row.id] = row
            do {
                let decoded = try SnapshotCodec.decode(row.payload)
                var snapshot = decoded.value
                guard snapshot.id == row.id else { throw StoredDataError.invalidDocument("The history record identifier does not match its payload.") }
                if recoverInterrupted && snapshot.status == .refreshing { snapshot.status = .interrupted }
                if decoded.version < SnapshotCodec.currentVersion || snapshot.status != decoded.value.status {
                    if row.recoveryPayload == nil { row.recoveryPayload = row.payload }
                    row.payload = try SnapshotCodec.encode(snapshot); row.payloadVersion = SnapshotCodec.currentVersion
                    row.text = snapshot.summaryText
                }
                row.recoveryReason = nil; snapshots.append(snapshot)
            } catch {
                row.recoveryReason = error.localizedDescription
                recoveryMessages.append("A briefing saved on \(row.generatedAt.formatted(date: .abbreviated, time: .shortened)) needs recovery. Its original data is preserved in History.")
            }
        }
        try context.save()
        return snapshots
    }
    func save(_ snapshot: BriefingSnapshot) throws {
        let data = try SnapshotCodec.encode(snapshot)
        if let row = rows[snapshot.id] {
            row.payload = data; row.text = snapshot.summaryText; row.payloadVersion = SnapshotCodec.currentVersion
        } else {
            let row = try SavedBriefing(snapshot); context.insert(row); rows[snapshot.id] = row
        }
        do { try context.save() }
        catch { context.rollback(); throw error }
    }
    func restore(_ row: SavedBriefing) throws {
        guard let backup = row.recoveryPayload else { throw StoredDataError.invalidDocument("No readable backup is available.") }
        let recovered = try SnapshotCodec.decode(backup).value
        guard recovered.id == row.id else { throw StoredDataError.invalidDocument("The recovery copy belongs to a different briefing.") }
        let unreadable = row.payload
        row.payload = try SnapshotCodec.encode(recovered); row.recoveryPayload = unreadable
        row.payloadVersion = SnapshotCodec.currentVersion; row.recoveryReason = nil; row.text = recovered.summaryText
        try context.save()
    }
    func prune(before cutoff: Date) throws {
        for (id, row) in Array(rows) where row.generatedAt < cutoff {
            // Never discard unreadable records, migration recovery copies or pinned briefings automatically.
            guard row.recoveryReason == nil, row.recoveryPayload == nil, row.snapshot?.pinnedItems.isEmpty == true else { continue }
            context.delete(row); rows.removeValue(forKey: id)
        }
        try context.save()
    }
}
#endif
