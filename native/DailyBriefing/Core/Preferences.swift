import Foundation

public struct AppPreferences: Codable, Equatable, Sendable {
    public var name = "Jackson"
    public var scheduling = SchedulingPreferences()
    public var notificationPolicy = NotificationPolicy()
    public var notificationsEnabled = false
    public var calendarIDs: Set<String> = []
    public var workCalendarID = ""
    public var scheduleSource = "calendar"
    public var manualShifts: [ManualShift] = []
    public var sectionOrder = SectionKind.allCases
    public var hiddenSections: Set<SectionKind> = []
    public var newsTopics = "World, Technology, Aviation"
    public var newsFeed = "https://feeds.bbci.co.uk/news/rss.xml"
    public var airports = "CYKF"
    public var teams = "Philadelphia 76ers, San Antonio Spurs"
    public var fahrenheit = false
    public var appearance = "system"
    public var cloudSync = false
    public var summaryLength = "Quick"
    public var aiEndpoint = ""
    public var aiConsent = false
    public var monitoringEndpoint = ""
    public var speechRate: Float = 0.45
    public var voiceID = ""
    public var widgetSection = SectionKind.schedule
    public var retentionDays = 30
    public init() {}
}

public extension AppPreferences {
    static func changedSources(from old: Self, to new: Self) -> Set<SectionKind> {
        var changed = old.hiddenSections.symmetricDifference(new.hiddenSections)
        if old.calendarIDs != new.calendarIDs || old.workCalendarID != new.workCalendarID || old.scheduleSource != new.scheduleSource || old.manualShifts != new.manualShifts || old.scheduling != new.scheduling { changed.insert(.schedule) }
        if old.fahrenheit != new.fahrenheit { changed.insert(.weather) }
        if old.newsFeed != new.newsFeed || old.newsTopics != new.newsTopics { changed.insert(.news) }
        if old.airports != new.airports { changed.insert(.aviation) }
        if old.teams != new.teams { changed.insert(.sports) }
        if old.aiEndpoint != new.aiEndpoint || old.aiConsent != new.aiConsent || old.summaryLength != new.summaryLength { changed.insert(.summary) }
        if !changed.isEmpty { changed.insert(.summary) }
        return changed
    }
}
public struct PreferencesDocument: Codable, Sendable {
    public var schemaVersion = 2
    public var preferences: AppPreferences
    public var sourceVersions: [String: UUID]
    public var annotations = AnnotationLedger()
    public var annotationsSeeded = false
    public init(preferences: AppPreferences = AppPreferences()) {
        self.preferences = preferences
        sourceVersions = Dictionary(uniqueKeysWithValues: SectionKind.allCases.map { ($0.rawValue, UUID()) })
    }
}
public enum PreferencesCodec {
    public static func encode(_ value: PreferencesDocument) throws -> Data { try JSONEncoder().encode(value) }
    public static func decode(_ data: Data) throws -> PreferencesDocument {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw StoredDataError.invalidDocument("Expected settings.") }
        guard json["schemaVersion"] == nil || json["schemaVersion"] is Int else {
            throw StoredDataError.invalidDocument("The settings version is invalid.")
        }
        let version = json["schemaVersion"] as? Int ?? 1
        guard (1...2).contains(version) else { throw StoredDataError.unsupportedVersion(version) }
        if version == 2 && !(json["preferences"] is [String: Any]) {
            throw StoredDataError.invalidDocument("The versioned settings payload is missing or invalid.")
        }
        let payload = (json["preferences"] as? [String: Any]) ?? json
        let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AppPreferences())) as! [String: Any]
        func merge(_ original: [String: Any], _ incoming: [String: Any]) -> [String: Any] {
            var value = original
            for (key, element) in incoming {
                if let a = original[key] as? [String: Any], let b = element as? [String: Any] { value[key] = merge(a, b) }
                else { value[key] = element }
            }
            return value
        }
        var preferences = try JSONDecoder().decode(AppPreferences.self, from: JSONSerialization.data(withJSONObject: merge(defaults, payload)))
        preferences.sectionOrder = preferences.sectionOrder.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        preferences.sectionOrder += SectionKind.allCases.filter { !preferences.sectionOrder.contains($0) }
        preferences.retentionDays = min(365, max(7, preferences.retentionDays))
        preferences.scheduling.leadMinutes = min(240, max(0, preferences.scheduling.leadMinutes))
        preferences.scheduling.weekdayMinute = min(1439, max(0, preferences.scheduling.weekdayMinute))
        preferences.scheduling.weekendMinute = min(1439, max(0, preferences.scheduling.weekendMinute))
        guard preferences.manualShifts.allSatisfy({ $0.start.timeIntervalSince1970.isFinite && $0.end > $0.start }) else {
            throw StoredDataError.invalidDocument("A saved manual shift has invalid dates.")
        }
        var document = PreferencesDocument(preferences: preferences)
        if version == 2, let versions = json["sourceVersions"] {
            let decoded = try JSONDecoder().decode([String: UUID].self, from: JSONSerialization.data(withJSONObject: versions))
            document.sourceVersions.merge(decoded) { _, existing in existing }
        }
        if let annotations = json["annotations"] {
            document.annotations = try JSONDecoder().decode(AnnotationLedger.self, from: JSONSerialization.data(withJSONObject: annotations))
        }
        document.annotationsSeeded = json["annotationsSeeded"] as? Bool ?? false
        return document
    }
}
/// A failed decode is never overwritten by automatic saves. Originals and the last good copy stay local.
public final class PreferencesPersistence {
    public static let currentKey = "preferences.v2"
    public static let legacyKey = "preferences.v1"
    public static let backupKey = "preferences.lastGood"
    public static let recoveryKey = "preferences.recoveryOriginal"
    private let defaults: UserDefaults
    public private(set) var document: PreferencesDocument
    public private(set) var recoveryRequired = false
    public private(set) var notice: String?
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults; document = PreferencesDocument()
        if let data = defaults.data(forKey: Self.currentKey) ?? defaults.data(forKey: Self.legacyKey) {
            do {
                document = try PreferencesCodec.decode(data)
                if defaults.data(forKey: Self.currentKey) == nil {
                    defaults.set(data, forKey: Self.backupKey)
                }
                // Persist filled defaults/revision IDs once, including partial V2 documents.
                try persist()
            } catch {
                recoveryRequired = true; notice = error.localizedDescription
                defaults.set(data, forKey: Self.recoveryKey)
            }
        } else { try? persist() }
    }
    public func save(_ proposed: AppPreferences) {
        var next = proposed
        if next.aiEndpoint != document.preferences.aiEndpoint { next.aiConsent = false }
        let changed = AppPreferences.changedSources(from: document.preferences, to: next)
        document.preferences = next
        for kind in changed { document.sourceVersions[kind.rawValue] = UUID() }
        guard !recoveryRequired else { return }
        do { try persist() } catch { recoveryRequired = true; notice = error.localizedDescription }
    }
    public func seedAnnotations(_ snapshots: [BriefingSnapshot]) {
        guard !document.annotationsSeeded else { return }
        for snapshot in snapshots.sorted(by: { $0.generatedAt < $1.generatedAt }) { document.annotations.record(snapshot) }
        document.annotationsSeeded = true
        if !recoveryRequired { do { try persist() } catch { recoveryRequired = true; notice = error.localizedDescription } }
    }
    public func recordAnnotations(_ snapshot: BriefingSnapshot) {
        document.annotations.record(snapshot)
        if !recoveryRequired { do { try persist() } catch { recoveryRequired = true; notice = error.localizedDescription } }
    }
    public func invalidate(_ kinds: Set<SectionKind>) {
        for kind in kinds.union([.summary]) { document.sourceVersions[kind.rawValue] = UUID() }
        if !recoveryRequired { do { try persist() } catch { recoveryRequired = true; notice = error.localizedDescription } }
    }
    @discardableResult public func restoreLastGood() -> Bool {
        guard let data = defaults.data(forKey: Self.backupKey) else { return false }
        do {
            document = try PreferencesCodec.decode(data); recoveryRequired = false
            // Do not rotate the good backup with a previously unreadable current document.
            defaults.removeObject(forKey: Self.currentKey)
            try persist(); notice = "Restored the last readable settings. The original recovery data remains preserved."
            return true
        } catch { notice = error.localizedDescription; return false }
    }
    public func keepCurrent() {
        recoveryRequired = false
        defaults.removeObject(forKey: Self.currentKey)
        do { try persist(); notice = "Saved current settings. The unreadable original remains preserved for recovery." }
        catch { recoveryRequired = true; notice = error.localizedDescription }
    }
    private func persist() throws {
        let data = try PreferencesCodec.encode(document)
        if let old = defaults.data(forKey: Self.currentKey), (try? PreferencesCodec.decode(old)) != nil {
            defaults.set(old, forKey: Self.backupKey)
        }
        defaults.set(data, forKey: Self.currentKey)
    }
}
