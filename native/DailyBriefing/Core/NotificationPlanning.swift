import Foundation

public struct NotificationPlan: Sendable {
    public var dates: [Date]
    public var obsoleteIDs: [String]
    public static func make(dates: [Date], enabled: Bool, quiet: NotificationPolicy, now: Date,
                            calendar: Calendar, pendingIDs: [String]) -> Self {
        let selected = enabled ? Array(Set(dates.filter { $0 > now && quiet.allows($0, calendar: calendar) }).sorted().prefix(7)) : []
        let desired = Set(selected.map(NotificationPolicy.identifier(for:)))
        return Self(dates: selected, obsoleteIDs: pendingIDs.filter { $0.hasPrefix("briefing.") && !desired.contains($0) })
    }
}
