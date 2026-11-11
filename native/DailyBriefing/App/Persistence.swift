import SwiftData
import Foundation

@Model final class SavedBriefing {
    var id: UUID = UUID()
    var generatedAt: Date = Date()
    var text: String = ""
    var payload: Data = Data()
    init(_ snapshot: BriefingSnapshot) throws {
        id = snapshot.id; generatedAt = snapshot.generatedAt
        text = snapshot.summaryText; payload = try JSONEncoder().encode(snapshot)
    }
    var snapshot: BriefingSnapshot? { try? JSONDecoder().decode(BriefingSnapshot.self, from: payload) }
}
enum Persistence {
    static func container(cloud: Bool) throws -> ModelContainer {
        let schema = Schema([SavedBriefing.self])
        let configuration = ModelConfiguration(schema: schema,
            cloudKitDatabase: cloud ? .private("iCloud.com.example.DailyBriefing") : .none)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
