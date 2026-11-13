import Foundation

public struct SnapshotAccessPolicy: Codable, Equatable, Sendable {
    public var enabled: Set<SectionKind>
    public var calendarAllowed: Bool
    public var remindersAllowed: Bool
    public var locationAllowed: Bool
    public var calendarIDs: Set<String>
    public var manualIDs: Set<String>
    public var aiAllowed: Bool
    public var sourceVersions: [String: UUID]
    public init(enabled: Set<SectionKind>, calendarAllowed: Bool = true, remindersAllowed: Bool = true,
                locationAllowed: Bool = true, calendarIDs: Set<String> = [], manualIDs: Set<String> = [],
                aiAllowed: Bool = false, sourceVersions: [String: UUID] = [:]) {
        self.enabled = enabled; self.calendarAllowed = calendarAllowed; self.remindersAllowed = remindersAllowed
        self.locationAllowed = locationAllowed; self.calendarIDs = calendarIDs; self.manualIDs = manualIDs
        self.aiAllowed = aiAllowed; self.sourceVersions = sourceVersions
    }
    public func applying(to original: BriefingSnapshot, historical: Bool = false) -> BriefingSnapshot {
        var value = original
        var redacted: Set<SectionKind> = []
        value.sections = original.sections.compactMap { raw in
            guard enabled.contains(raw.kind) else { redacted.insert(raw.kind); return nil }
            var section = raw
            if !historical && original.sourceVersions[raw.kind.rawValue] != sourceVersions[raw.kind.rawValue] {
                section.items = []; section.state = .missingData; section.message = "Source settings changed. Refresh this section."
            }
            switch raw.kind {
            case .schedule:
                section.items = section.items.filter { item in
                    if item.origin == .manual || (item.origin == nil && manualIDs.contains(item.id)) { return manualIDs.contains(item.id) }
                    // Unproven legacy calendar provenance is retained in the private archive, not exported.
                    return calendarAllowed && item.calendarIdentifier.map(calendarIDs.contains) == true
                }
                if !calendarAllowed {
                    section.state = section.items.isEmpty ? .permissionDenied : .partial
                    section.message = "Calendar access is unavailable. Only authorized manual entries are shown."
                }
            case .tasks where !remindersAllowed:
                section.items = []; section.state = .permissionDenied; section.message = "Reminders access is unavailable."
            case .weather where !locationAllowed:
                section.items = []; section.state = .permissionDenied; section.message = "Location access is unavailable."
            case .summary where raw.isGenerated && !aiAllowed:
                section.items = []; section.state = .disconnected; section.message = "AI is disabled. Refresh for a source roll-up."
            default: break
            }
            if section.items != raw.items { redacted.insert(raw.kind) }
            return section
        }
        if let index = value.sections.firstIndex(where: { $0.kind == .summary }) {
            let dependencies = value.sections[index].dependencies ?? Set(original.sections.filter { $0.kind != .summary }.map(\.kind))
            if !dependencies.isDisjoint(with: redacted) || !dependencies.isSubset(of: enabled) {
                redacted.insert(.summary)
                value.sections[index].items = []; value.sections[index].state = .missingData
                value.sections[index].message = "Summary hidden because source access or settings changed. Regenerate it from enabled sources."
            }
        }
        // Change descriptions and annotations must not become a side channel for hidden sources.
        value.changes = value.changes.filter { message in
            SectionKind.allCases.filter { !enabled.contains($0) || redacted.contains($0) }.allSatisfy { !message.hasPrefix($0.title) && message != "Added \($0.title)." }
        }
        let visibleIDs = Set(value.sections.flatMap(\.items).map(\.id))
        value.pinnedItems.formIntersection(visibleIDs)
        value.readSections.formIntersection(Set(value.sections.map(\.kind)))
        value.readSections.subtract(redacted)
        return value
    }
}

/// The gate is written first. A reader always re-applies the current gate, even to an old snapshot.
/// A corrupt/missing/future gate fails closed; a legacy payload cannot bypass it.
public struct SharedCacheDocument: Codable, Sendable {
    public var schemaVersion = 2
    public var policy: SnapshotAccessPolicy
    public var snapshot: BriefingSnapshot
    public init(policy: SnapshotAccessPolicy, snapshot: BriefingSnapshot) { self.policy = policy; self.snapshot = snapshot }
}
public struct SharedCacheStore {
    private let directory: URL
    public init(directory: URL) { self.directory = directory }
    private var gateURL: URL { directory.appendingPathComponent("briefing-access-v2.json") }
    private var snapshotURL: URL { directory.appendingPathComponent("briefing-v1.json") }
    private struct Gate: Codable { var schemaVersion = 2; var policy: SnapshotAccessPolicy }
    private func write(_ data: Data, to url: URL) throws {
        var options: Data.WritingOptions = [.atomic]
        #if canImport(Darwin)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try data.write(to: url, options: options)
    }
    public func replacePolicy(_ policy: SnapshotAccessPolicy) throws {
        do { try write(JSONEncoder().encode(Gate(policy: policy)), to: gateURL) }
        catch {
            // Do not leave an old readable payload if the new privacy gate cannot be committed.
            try? FileManager.default.removeItem(at: snapshotURL)
            throw error
        }
    }
    public func save(_ snapshot: BriefingSnapshot, policy: SnapshotAccessPolicy) throws {
        try replacePolicy(policy)
        try write(SnapshotCodec.encode(policy.applying(to: snapshot)), to: snapshotURL)
    }
    public func read() throws -> SharedCacheDocument {
        let gate = try JSONDecoder().decode(Gate.self, from: Data(contentsOf: gateURL))
        guard gate.schemaVersion == 2 else { throw StoredDataError.unsupportedVersion(gate.schemaVersion) }
        let snapshot = try SnapshotCodec.decode(Data(contentsOf: snapshotURL)).value
        return SharedCacheDocument(policy: gate.policy, snapshot: gate.policy.applying(to: snapshot))
    }
}
