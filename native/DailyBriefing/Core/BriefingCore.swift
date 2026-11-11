import Foundation

public enum SectionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case schedule, weather, tasks, email, news, sports, aviation, summary
    public var id: String { rawValue }
    public var title: String { rawValue == "summary" ? "Daily perspective" : rawValue.capitalized }
    public var symbol: String {
        switch self {
        case .schedule: "calendar"
        case .weather: "cloud.sun.fill"
        case .tasks: "checklist"
        case .email: "envelope.badge"
        case .news: "newspaper"
        case .sports: "basketball.fill"
        case .aviation: "airplane"
        case .summary: "sparkles"
        }
    }
}
public enum ProviderState: String, Codable, Sendable {
    case ready, disconnected, permissionDenied, offline, failed, stale, missingData
}
public struct BriefingItem: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public var date: Date?
    public var end: Date?
    public var url: URL?
    public var source: String
    public var attributionImageURL: URL?
    public var isShift: Bool
    public init(id: String = UUID().uuidString, title: String, detail: String = "", date: Date? = nil,
                end: Date? = nil, url: URL? = nil, source: String, isShift: Bool = false, attributionImageURL: URL? = nil) {
        self.id = id; self.title = title; self.detail = detail; self.date = date
        self.end = end; self.url = url; self.source = source; self.isShift = isShift; self.attributionImageURL = attributionImageURL
    }
}
public struct BriefingSection: Codable, Identifiable, Sendable {
    public var kind: SectionKind
    public var state: ProviderState
    public var message: String
    public var fetchedAt: Date?
    public var expiresAt: Date?
    public var items: [BriefingItem]
    public var isGenerated: Bool
    public var id: SectionKind { kind }
    public init(kind: SectionKind, state: ProviderState, message: String = "", fetchedAt: Date? = nil,
                expiresAt: Date? = nil, items: [BriefingItem] = [], isGenerated: Bool = false) {
        self.kind = kind; self.state = state; self.message = message; self.fetchedAt = fetchedAt
        self.expiresAt = expiresAt; self.items = items; self.isGenerated = isGenerated
    }
    public func isFresh(at now: Date) -> Bool {
        state == .ready && fetchedAt != nil && expiresAt.map { $0 > now } == true
    }
    public func assessed(at now: Date) -> BriefingSection {
        var copy = self
        if state == .ready && !isFresh(at: now) { copy.state = .stale; copy.message = "Cached information — refresh before relying on it." }
        return copy
    }
}
public struct BriefingSnapshot: Codable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var generatedAt: Date
    public var sections: [BriefingSection]
    public var nextDelivery: Date?
    public var changes: [String] = []
    public var readSections: Set<SectionKind> = []
    public var pinnedItems: Set<String> = []
    public var summaryText: String {
        sections.map { section in
            "\(section.kind.title): " + (section.items.isEmpty ? section.message : section.items.map { "\($0.title). \($0.detail)" }.joined(separator: " "))
        }.joined(separator: "\n\n")
    }
}
public struct ManualShift: Codable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var title: String = "Work shift"
    public var start: Date = Date()
    public var end: Date = Date().addingTimeInterval(8 * 3600)
}
public struct SchedulingPreferences: Codable, Sendable {
    public var leadMinutes: Int = 45
    public var weekdayMinute: Int = 240
    public var weekendMinute: Int = 240
    public var deliverOnDaysOff: Bool = true
    public init() {}
}
public enum BriefingScheduler {
    /// Shifts belong to their start date. Subtract elapsed minutes, including across midnight/DST.
    public static func delivery(on day: Date, shifts: [Date], preferences: SchedulingPreferences,
                                calendar: Calendar) -> Date? {
        if let shift = shifts.filter({ calendar.isDate($0, inSameDayAs: day) }).min() {
            return shift.addingTimeInterval(-Double(max(0, preferences.leadMinutes)) * 60)
        }
        guard preferences.deliverOnDaysOff else { return nil }
        let minute = calendar.isDateInWeekend(day) ? preferences.weekendMinute : preferences.weekdayMinute
        let clamped = min(1439, max(0, minute))
        return calendar.date(bySettingHour: clamped / 60, minute: clamped % 60, second: 0, of: day,
                             matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
    }
    public static func upcoming(after now: Date, shifts: [Date], preferences: SchedulingPreferences,
                                calendar: Calendar, days: Int = 7) -> [Date] {
        // Include tomorrow's early shift whose delivery falls tonight.
        (0...days).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: now).flatMap {
                delivery(on: $0, shifts: shifts, preferences: preferences, calendar: calendar)
            }
        }.filter { $0 > now }.sorted()
    }
    public static func conflicts(_ items: [BriefingItem]) -> Set<String> {
        var result: Set<String> = []
        let timed = items.filter { $0.date != nil && $0.end != nil }.sorted { $0.date! < $1.date! }
        for (index, item) in timed.enumerated() {
            for other in timed.dropFirst(index + 1) {
                guard other.date! < item.end! else { break }
                if other.end! > item.date! { result.insert(item.id); result.insert(other.id) }
            }
        }
        return result
    }
}
public enum GenerationPhase: Equatable, Sendable {
    case idle, loading, complete, partial, failed
    public static func result(for sections: [BriefingSection]) -> Self {
        guard !sections.isEmpty else { return .failed }
        let available = sections.filter { $0.state == .ready }.count
        return available == sections.count ? .complete : .partial
    }
}
public struct NotificationPolicy: Codable, Sendable {
    public var quietStart: Int = 1320
    public var quietEnd: Int = 180
    public var quietEnabled: Bool = false
    public init() {}
    public func allows(_ date: Date, calendar: Calendar) -> Bool {
        guard quietEnabled else { return true }
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        if quietStart == quietEnd { return false }
        let quiet = quietStart < quietEnd ? (minute >= quietStart && minute < quietEnd) : (minute >= quietStart || minute < quietEnd)
        return !quiet
    }
    public static func identifier(for date: Date) -> String { "briefing.\(Int(date.timeIntervalSince1970))" }
}
