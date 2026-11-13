import SwiftUI
import SwiftData
import EventKit
import BackgroundTasks
@preconcurrency import UserNotifications

@main @MainActor struct DailyBriefingApp: App {
    @State private var settings: SettingsStore
    @State private var controller: BriefingController?
    private let container: ModelContainer?
    private let startupError: String?
    init() {
        UNUserNotificationCenter.current().delegate = LocalNotificationRouter.shared
        let settings = SettingsStore(); _settings = State(initialValue: settings)
        do {
            let container = try Persistence.container(cloud: settings.value.cloudSync)
            self.container = container; startupError = nil
            _controller = State(initialValue: BriefingController(settings: settings, container: container))
        } catch {
            container = nil; startupError = error.localizedDescription; _controller = State(initialValue: nil)
        }
    }
    var body: some Scene {
        WindowGroup {
            if let container, let controller {
                RootView(controller: controller, settings: settings)
                    .modelContainer(container)
                    .preferredColorScheme(settings.value.appearance == "dark" ? .dark : settings.value.appearance == "light" ? .light : nil)
            } else {
                ContentUnavailableView {
                    Label("Storage needs attention", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text(startupError ?? "Could not open the briefing store. Your data has not been deleted.")
                } actions: {
                    Button("Use local storage on next launch") { settings.value.cloudSync = false }
                }
            }
        }
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) { await performBackgroundRefresh() }
    }
    private func performBackgroundRefresh() async {
        if let controller { await controller.refresh(background: true) }
    }
}
struct RootView: View {
    @Bindable var controller: BriefingController
    @Bindable var settings: SettingsStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = 0
    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { DashboardView(controller: controller, settings: settings) }
                .tabItem { Label("Today", systemImage: "sun.max.fill") }.tag(0)
            NavigationStack { HistoryView(controller: controller) }
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }.tag(1)
            NavigationStack { SettingsView(settings: settings, controller: controller) }
                .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }.tag(2)
        }
        .tint(.cyan)
        .task {
            controller.calendar.reload()
            IntentRouter.consume(into: controller)
            await controller.tick()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                IntentRouter.consume(into: controller)
                controller.location.requestIfAuthorized()
                Task {
                    await ShiftActivities.endExpired()
                    await controller.tick()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
            Task { await controller.sourceUpdated([.schedule, .tasks]) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name.NSSystemTimeZoneDidChange)) { _ in Task { await controller.refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: IntentRouter.notification)) { _ in
            selectedTab = 0; IntentRouter.consume(into: controller)
        }
        .onChange(of: controller.location.status) { _, _ in Task { await controller.tick() } }
        .onChange(of: controller.location.location?.timestamp) { _, _ in
            if controller.accessPolicy.enabled.contains(.weather) { Task { await controller.sourceUpdated([.weather]) } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in Task { await controller.tick() } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in Task { await controller.tick() } }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { break }
                await controller.tick()
            }
        }
        .onOpenURL { url in
            guard url.scheme == "dailybriefing" else { return }
            selectedTab = 0
            if url.host == "refresh" { Task { await controller.refresh() } }
            else { controller.route = SectionKind(rawValue: url.host ?? "") }
        }
    }
}

@MainActor private final class LocalNotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = LocalNotificationRouter()
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              response.notification.request.identifier.hasPrefix("briefing.") else { return }
        await MainActor.run { IntentRouter.request("today") }
    }
}
