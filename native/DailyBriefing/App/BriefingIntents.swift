import AppIntents
import Foundation

enum BriefingDestination: String, AppEnum {
    case today, schedule, weather, tasks, sports
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Briefing section")
    static let caseDisplayRepresentations: [BriefingDestination: DisplayRepresentation] = [
        .today: "Today's briefing", .schedule: "Work schedule", .weather: "Weather", .tasks: "Important tasks", .sports: "Sports updates"]
}
struct OpenBriefingIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Daily Briefing"
    static let description = IntentDescription("Open today's briefing or a section.")
    static let openAppWhenRun = true
    @Parameter(title: "Section", default: .today) var section: BriefingDestination
    @MainActor func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "dailybriefing://\(section.rawValue)")!))
    }
}
struct NextAppointmentIntent: AppIntent {
    static let title: LocalizedStringResource = "Read my next appointment"
    static let description = IntentDescription("Read the next commitment from the latest cached briefing. Open the app to refresh calendar data.")
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let snapshot = SharedSnapshot.read(), let schedule = snapshot.sections.first(where: { $0.kind == .schedule }),
              schedule.isFresh(at: Date()) else { return .result(dialog: "Open Daily Briefing to refresh your appointments.") }
        guard let next = schedule.items.first(where: { ($0.date ?? .distantPast) > Date() }), let date = next.date else { return .result(dialog: "No upcoming appointment is saved in today's briefing.") }
        return .result(dialog: "\(next.title), \(date.formatted(date: .abbreviated, time: .shortened)).")
    }
}
struct RefreshBriefingIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh daily briefing"
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "dailybriefing://refresh")!))
    }
}
struct BriefingShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenBriefingIntent(), phrases: ["Open \(.applicationName)", "Show \(\.$section) in \(.applicationName)"], shortTitle: "Open briefing", systemImageName: "sun.max")
        AppShortcut(intent: NextAppointmentIntent(), phrases: ["Read my next appointment in \(.applicationName)"], shortTitle: "Next appointment", systemImageName: "calendar")
        AppShortcut(intent: RefreshBriefingIntent(), phrases: ["Refresh \(.applicationName)"], shortTitle: "Refresh briefing", systemImageName: "arrow.clockwise")
    }
}
