#if DEBUG
import SwiftUI

// Preview-only fictional fixtures. Never used by live providers or persistence.
enum PreviewFixtures {
    static let schedule = BriefingSection(kind: .schedule, state: .ready,
        message: "PREVIEW · fictional events", fetchedAt: Date(), expiresAt: Date().addingTimeInterval(900),
        items: [BriefingItem(id: "preview-shift", title: "Preview work shift", detail: "Fictional preview fixture", date: Date().addingTimeInterval(3600), end: Date().addingTimeInterval(9 * 3600), source: "Preview", isShift: true)])
}
#Preview("Schedule card · preview data") {
    SectionCard(section: PreviewFixtures.schedule, expanded: true, isRead: false, pinned: [],
        toggleExpanded: {}, refresh: {}, markRead: {}, pin: { _ in }, openEvent: { _ in }, startActivity: { _ in })
        .padding().background(Color(.systemGroupedBackground))
}
#endif
