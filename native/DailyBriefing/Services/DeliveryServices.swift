import Observation
import Foundation
import UserNotifications
import BackgroundTasks
import ActivityKit
import AVFoundation
import WatchConnectivity
import WidgetKit

@MainActor enum NotificationService {
    static func request() async throws -> Bool {
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([UNNotificationCategory(identifier: "BRIEFING", actions: [], intentIdentifiers: [])])
        return try await center.requestAuthorization(options: [.alert, .sound, .badge])
    }
    static func schedule(dates: [Date], preferences: AppPreferences) async throws {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.filter { $0.identifier.hasPrefix("briefing.") }.map(\.identifier))
        guard preferences.notificationsEnabled else { return }
        for date in dates.prefix(7) where preferences.notificationPolicy.allows(date, calendar: .autoupdatingCurrent) {
            let content = UNMutableNotificationContent()
            content.title = "Time for your Daily Briefing"
            content.body = "Open to refresh your briefing. Cached information is available offline."
            content.sound = .default; content.categoryIdentifier = "BRIEFING"
            // A local reminder does not claim generation succeeded in the background.
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSinceNow), repeats: false)
            try await center.add(UNNotificationRequest(identifier: NotificationPolicy.identifier(for: date), content: content, trigger: trigger))
        }
    }
}
@MainActor enum BackgroundRefresh {
    static let identifier = "com.example.DailyBriefing.refresh"
    static func schedule(at date: Date?) throws {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = date ?? Date().addingTimeInterval(3600)
        try BGTaskScheduler.shared.submit(request)
    }
}
@MainActor @Observable final class SpeechService {
    private let synthesizer = AVSpeechSynthesizer()
    var isSpeaking: Bool { synthesizer.isSpeaking }
    var isPaused: Bool { synthesizer.isPaused }
    func play(_ text: String, preferences: AppPreferences) {
        synthesizer.stopSpeaking(at: .immediate)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let utterance = AVSpeechUtterance(string: text); utterance.rate = preferences.speechRate
        if !preferences.voiceID.isEmpty { utterance.voice = AVSpeechSynthesisVoice(identifier: preferences.voiceID) }
        synthesizer.speak(utterance)
    }
    func pause() { synthesizer.pauseSpeaking(at: .word) }
    func resume() { synthesizer.continueSpeaking() }
    func stop() { synthesizer.stopSpeaking(at: .immediate); try? AVAudioSession.sharedInstance().setActive(false) }
}
@MainActor enum ShiftActivities {
    static func start(_ item: BriefingItem) async throws {
        await endAll()
        guard ActivityAuthorizationInfo().areActivitiesEnabled, let start = item.date,
              let end = item.end, start > Date(), start.timeIntervalSinceNow <= 4 * 3600 else {
            throw ProviderError.unavailable("Start a countdown within four hours of an upcoming shift. Enable Live Activities in system settings.")
        }
        let state = ShiftActivityAttributes.ContentState(startsAt: start, endsAt: end)
        // Dismiss at shift start; bounded to the countdown rather than the entire day.
        _ = try Activity<ShiftActivityAttributes>.request(attributes: .init(title: item.title),
            content: ActivityContent(state: state, staleDate: start), pushType: nil)
    }
    static func endAll() async {
        for activity in Activity<ShiftActivityAttributes>.activities { await activity.end(nil, dismissalPolicy: .immediate) }
    }
    static func endExpired() async {
        for activity in Activity<ShiftActivityAttributes>.activities where activity.content.state.startsAt <= Date() {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
// App-to-Watch transfer is encrypted by the system. The watch keeps only the latest snapshot.
final class WatchBridge: NSObject, WCSessionDelegate {
    static let shared = WatchBridge()
    override init() {
        super.init()
        if WCSession.isSupported() { WCSession.default.delegate = self; WCSession.default.activate() }
    }
    func publish(_ snapshot: BriefingSnapshot) throws {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isPaired, WCSession.default.isWatchAppInstalled else { return }
        try WCSession.default.updateApplicationContext(["snapshot": JSONEncoder().encode(snapshot)])
    }
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}
struct HealthReport: Encodable {
    var lastSuccessfulGeneration: Date?
    var nextScheduledBriefing: Date?
    var providers: [ProviderHealth]
    var integrationErrors: [String]
    var deliveryErrors: [String]
    var failedRefreshAttempts: Int
    var version: String
    var build: String
    struct ProviderHealth: Encodable { var section: SectionKind; var state: ProviderState; var lastRefresh: Date? }
}
protocol HealthReporter { func send(_ report: HealthReport) async throws }
struct HTTPSHealthReporter: HealthReporter {
    let endpoint: URL
    func send(_ report: HealthReport) async throws {
        guard endpoint.scheme == "https", let token = KeychainStore.read(account: "monitoring"), !token.isEmpty else { throw ProviderError.invalidEndpoint }
        var request = URLRequest(url: endpoint); request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(report)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let code = (response as? HTTPURLResponse)?.statusCode, (200...299).contains(code) else { throw ProviderError.unavailable("Monitoring endpoint rejected the report.") }
    }
}
