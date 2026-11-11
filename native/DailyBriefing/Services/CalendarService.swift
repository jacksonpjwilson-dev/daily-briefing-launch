import EventKit
import Foundation

@MainActor @Observable final class CalendarService {
    let store = EKEventStore()
    var calendars: [EKCalendar] = []
    var status = EKEventStore.authorizationStatus(for: .event)
    func request() async throws {
        _ = try await store.requestFullAccessToEvents()
        reload()
    }
    func reload() {
        status = EKEventStore.authorizationStatus(for: .event)
        calendars = status == .fullAccess ? store.calendars(for: .event).sorted { $0.title < $1.title } : []
    }
    func events(preferences: AppPreferences, from start: Date, to end: Date) -> [BriefingItem] {
        reload()
        var items: [BriefingItem] = []
        if status == .fullAccess {
            let selected = calendars.filter { preferences.calendarIDs.contains($0.calendarIdentifier) || $0.calendarIdentifier == preferences.workCalendarID }
            if !selected.isEmpty {
                let predicate = store.predicateForEvents(withStart: start, end: end, calendars: selected)
                items = store.events(matching: predicate).map { event in
                    BriefingItem(id: "\(event.eventIdentifier ?? "event")@\(event.startDate.timeIntervalSince1970)",
                        title: event.title ?? "Calendar event", detail: [event.location, event.isAllDay ? "All day" : nil].compactMap { $0 }.joined(separator: " · "),
                        date: event.startDate, end: event.endDate, source: event.calendar.title,
                        isShift: preferences.scheduleSource == "calendar" && !event.isAllDay && event.calendar.calendarIdentifier == preferences.workCalendarID)
                }
            }
        }
        // Manual entries override calendar shifts on the same local date.
        let manual = preferences.manualShifts.filter { $0.start >= start && $0.start < end }
        let c = Calendar.autoupdatingCurrent
        items.removeAll { item in item.isShift && manual.contains { shift in item.date.map { c.isDate($0, inSameDayAs: shift.start) } == true } }
        items += manual.map { BriefingItem(id: $0.id.uuidString, title: $0.title, detail: "Manual override", date: $0.start, end: $0.end, source: "Manual schedule", isShift: true) }
        return items.sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
    }
    func event(id: String) -> EKEvent? {
        let identifier = id.components(separatedBy: "@").dropLast().joined(separator: "@")
        return store.event(withIdentifier: identifier)
    }
    func reminders(request: Bool = false) async -> BriefingSection {
        do {
            if request { _ = try await store.requestFullAccessToReminders() }
            guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
                return BriefingSection(kind: .tasks, state: .permissionDenied, message: "Allow Reminders in Connections to include your tasks.")
            }
            let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
            let reminders: [EKReminder] = await withCheckedContinuation { continuation in
                store.fetchReminders(matching: predicate) { continuation.resume(returning: $0 ?? []) }
            }
            let items = reminders.sorted { ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture) }.prefix(50).map {
                BriefingItem(id: $0.calendarItemIdentifier, title: $0.title ?? "Reminder", detail: $0.priority > 0 ? "Priority \($0.priority)" : "", date: $0.dueDateComponents?.date, source: "Apple Reminders")
            }
            return BriefingSection(kind: .tasks, state: .ready, message: items.isEmpty ? "No outstanding reminders." : "", fetchedAt: Date(), expiresAt: Date().addingTimeInterval(900), items: items)
        } catch { return BriefingSection(kind: .tasks, state: .failed, message: error.localizedDescription) }
    }
}
