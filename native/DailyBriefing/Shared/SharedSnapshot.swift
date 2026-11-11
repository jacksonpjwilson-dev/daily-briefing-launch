import Foundation

// Replace all example identifiers together before configuring signing.
enum SharedSnapshot {
    static let groupID = "group.com.example.DailyBriefing"
    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent("briefing-v1.json")
    }
    static func read() -> BriefingSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BriefingSnapshot.self, from: data)
    }
    static func write(_ snapshot: BriefingSnapshot) throws {
        guard let url = fileURL else { throw CocoaError(.fileNoSuchFile) }
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    static var selectedSection: SectionKind {
        get { SectionKind(rawValue: UserDefaults(suiteName: groupID)?.string(forKey: "widgetSection") ?? "schedule") ?? .schedule }
        set { UserDefaults(suiteName: groupID)?.set(newValue.rawValue, forKey: "widgetSection") }
    }
}
