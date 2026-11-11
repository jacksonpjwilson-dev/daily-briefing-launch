import Observation
import Foundation
import SwiftUI

struct AppPreferences: Codable {
    var name = "Jackson"
    var scheduling = SchedulingPreferences()
    var notificationPolicy = NotificationPolicy()
    var notificationsEnabled = false
    var calendarIDs: Set<String> = []
    var workCalendarID = ""
    var scheduleSource = "calendar"
    var manualShifts: [ManualShift] = []
    var sectionOrder = SectionKind.allCases
    var hiddenSections: Set<SectionKind> = []
    var newsTopics = "World, Technology, Aviation"
    var newsFeed = "https://feeds.bbci.co.uk/news/rss.xml"
    var airports = "CYKF"
    var teams = "Philadelphia 76ers, San Antonio Spurs"
    var fahrenheit = false
    var appearance = "system"
    var cloudSync = false
    var summaryLength = "Quick"
    var aiEndpoint = ""
    var aiConsent = false
    var monitoringEndpoint = ""
    var speechRate: Float = 0.45
    var voiceID = ""
    var widgetSection = SectionKind.schedule
    var retentionDays = 30
}
@MainActor @Observable final class SettingsStore {
    var value: AppPreferences { didSet { save() } }
    init() {
        value = UserDefaults.standard.data(forKey: "preferences.v1")
            .flatMap { try? JSONDecoder().decode(AppPreferences.self, from: $0) } ?? AppPreferences()
    }
    private func save() {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: "preferences.v1") }
    }
}
