import Foundation

enum SharedSnapshot {
    static let groupID = "group.com.example.DailyBriefing"
    private static var store: SharedCacheStore? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID).map { SharedCacheStore(directory: $0) }
    }
    static func readDocument() -> SharedCacheDocument? { try? store?.read() }
    static func read() -> BriefingSnapshot? { readDocument()?.snapshot }
    static func write(_ snapshot: BriefingSnapshot, policy: SnapshotAccessPolicy) throws {
        guard let store else { throw CocoaError(.fileNoSuchFile) }
        try store.save(snapshot, policy: policy)
    }
    static func replacePolicy(_ policy: SnapshotAccessPolicy) throws {
        guard let store else { throw CocoaError(.fileNoSuchFile) }
        try store.replacePolicy(policy)
    }
    static var selectedSection: SectionKind {
        get { SectionKind(rawValue: UserDefaults(suiteName: groupID)?.string(forKey: "widgetSection") ?? "schedule") ?? .schedule }
        set { UserDefaults(suiteName: groupID)?.set(newValue.rawValue, forKey: "widgetSection") }
    }
}
