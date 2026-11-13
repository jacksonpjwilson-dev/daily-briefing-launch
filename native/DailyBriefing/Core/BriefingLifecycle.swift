import Foundation

public struct BriefingTarget: Codable, Equatable, Sendable {
    public var dayStart: Date
    public var dayEnd: Date
    public var timeZoneID: String
    public var shiftID: String?
    public var scheduledFor: Date?
    public var dayKey: String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID) ?? TimeZone(secondsFromGMT: 0)!
        let c = calendar.dateComponents([.year, .month, .day], from: dayStart)
        return "\(timeZoneID)|\(c.year!)-\(c.month!)-\(c.day!)"
    }
    public func contains(_ item: BriefingItem) -> Bool {
        guard let start = item.date else { return false }
        return start < dayEnd && (item.end ?? start.addingTimeInterval(1)) > dayStart
    }
}
public extension BriefingScheduler {
    static func target(at now: Date, events: [BriefingItem], preferences: SchedulingPreferences, calendar: Calendar) -> BriefingTarget {
        let shifts = events.filter { $0.isShift && $0.date != nil }
        var day = calendar.startOfDay(for: now)
        // Only advance into tomorrow once the earliest shift's preparation window has opened.
        // An ongoing night shift does not move today's report back into yesterday.
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: day),
           let shift = shifts.filter({ calendar.isDate($0.date!, inSameDayAs: tomorrow) }).min(by: { $0.date! < $1.date! }),
           shift.date! > now,
           shift.date!.addingTimeInterval(-Double(max(0, preferences.leadMinutes)) * 60) <= now {
            day = tomorrow
        }
        let first = shifts.filter { calendar.isDate($0.date!, inSameDayAs: day) }.min { $0.date! < $1.date! }
        return BriefingTarget(dayStart: day, dayEnd: calendar.date(byAdding: .day, value: 1, to: day)!,
            timeZoneID: calendar.timeZone.identifier, shiftID: first?.id,
            scheduledFor: delivery(on: day, shifts: shifts.compactMap(\.date), preferences: preferences, calendar: calendar))
    }
}
public enum ManualSchedule {
    public static func resolve(calendarItems: [BriefingItem], shifts: [ManualShift], from start: Date, to end: Date, calendar: Calendar) -> [BriefingItem] {
        let valid = shifts.filter { $0.end > $0.start }
        // Use all override dates, even when a shortened override already ended before this query.
        let overriddenDays = Set(valid.map { calendar.startOfDay(for: $0.start) })
        let original = calendarItems.filter { item in
            guard item.isShift, let date = item.date else { return true }
            return !overriddenDays.contains(calendar.startOfDay(for: date))
        }
        let manual = valid.filter { $0.start < end && $0.end > start }.map {
            BriefingItem(id: $0.id.uuidString, title: $0.title, detail: "Manual override", date: $0.start,
                end: $0.end, source: "Manual schedule", isShift: true, origin: .manual)
        }
        return (original + manual).sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
    }
}
public enum CalendarIdentity {
    public static func id(calendar: String, item: String, occurrence: Date?) -> String {
        let parts = [calendar, item, occurrence.map { String($0.timeIntervalSince1970) } ?? "single"]
        let key = parts.map { "\($0.utf8.count):\($0)" }.joined()
        return "calendar:" + Data(key.utf8).base64EncodedString()
    }
}
public extension BriefingItem {
    /// Ignores retrieval timestamps; includes the actual appointment/report revisions.
    var meaningfulRevision: String {
        [id, title, detail, date.map { String($0.timeIntervalSince1970) } ?? "", end.map { String($0.timeIntervalSince1970) } ?? "",
         url?.absoluteString ?? "", source, sourceExpiresAt.map { String($0.timeIntervalSince1970) } ?? "", String(isShift), String(isAllDay), calendarIdentifier ?? ""].joined(separator: "\u{1F}")
    }
}
public extension BriefingSection {
    var contentRevision: String {
        let content = ([kind.rawValue, state.rawValue, message] + items.map(\.meaningfulRevision).sorted()).joined(separator: "\u{1E}")
        // A non-security digest for read-state comparison, never authentication or access control.
        var value: UInt64 = 14695981039346656037
        for byte in content.utf8 { value = (value ^ UInt64(byte)) &* 1099511628211 }
        return String(value, radix: 16)
    }
}
public enum BriefingChanges {
    public static func compare(_ old: BriefingSnapshot?, _ new: BriefingSnapshot) -> [String] {
        guard let old else { return [] }
        return new.sections.filter { $0.kind != .summary }.compactMap { section in
            guard let prior = old.sections.first(where: { $0.kind == section.kind }) else { return "Added \(section.kind.title)." }
            if prior.state != section.state { return "\(section.kind.title): \(prior.state.rawValue) → \(section.state.rawValue)." }
            return prior.items.map(\.meaningfulRevision).sorted() == section.items.map(\.meaningfulRevision).sorted()
                ? nil : "\(section.kind.title) has updated information."
        }
    }
}
public struct AnnotationLedger: Codable, Equatable, Sendable {
    public var pinnedIDs: Set<String> = []
    public var readRevisions: [String: String] = [:]
    public init() {}
    private func key(_ snapshot: BriefingSnapshot, _ kind: SectionKind) -> String {
        let c = Calendar.autoupdatingCurrent
        let start = c.startOfDay(for: snapshot.generatedAt)
        let legacyTarget = BriefingTarget(dayStart: start, dayEnd: c.date(byAdding: .day, value: 1, to: start)!, timeZoneID: c.timeZone.identifier)
        let day = snapshot.target?.dayKey ?? legacyTarget.dayKey
        return day + "|" + kind.rawValue
    }
    public mutating func record(_ snapshot: BriefingSnapshot) {
        let visibleIDs = Set(snapshot.sections.flatMap(\.items).map(\.id))
        pinnedIDs.subtract(visibleIDs); pinnedIDs.formUnion(snapshot.pinnedItems.intersection(visibleIDs))
        for section in snapshot.sections {
            let k = key(snapshot, section.kind)
            if snapshot.readSections.contains(section.kind) { readRevisions[k] = section.contentRevision }
            else { readRevisions.removeValue(forKey: k) }
        }
    }
    public func applying(to snapshot: BriefingSnapshot) -> BriefingSnapshot {
        var value = snapshot
        value.pinnedItems = pinnedIDs.intersection(Set(value.sections.flatMap(\.items).map(\.id)))
        value.readSections = Set(value.sections.filter { readRevisions[key(value, $0.kind)] == $0.contentRevision }.map(\.kind))
        return value
    }
}

public extension BriefingSection {
    func spokenText(at now: Date) -> String {
        let status = assessed(at: now)
        let sourceDate = fetchedAt.map { " Source refreshed \($0.formatted(date: .abbreviated, time: .shortened))." } ?? ""
        return "\(kind.title). \(status.state.rawValue). \(status.message)." + sourceDate + items.map { item in
            let expired = item.sourceExpiresAt.map { $0 <= now } == true ? " Expired or unverified source report." : ""
            let date = item.date.map { " \($0.formatted(date: .abbreviated, time: .shortened))." } ?? ""
            return " \(item.title)." + date + " \(item.detail)." + expired
        }.joined()
    }
}
