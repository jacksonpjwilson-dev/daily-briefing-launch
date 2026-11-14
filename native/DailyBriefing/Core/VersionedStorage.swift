import Foundation

public enum StoredDataError: LocalizedError, Equatable {
    case unsupportedVersion(Int), invalidDocument(String)
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): return "This data uses a newer format (version \(version)). The original has been preserved; update the app before restoring it."
        case .invalidDocument(let message): return "The saved data could not be read. Its original bytes have been preserved. \(message)"
        }
    }
}
public struct DecodedDocument<Value> { public let value: Value; public let version: Int }
public enum SnapshotCodec {
    public static let currentVersion = 2
    private struct Envelope: Codable { var schemaVersion: Int; var payload: BriefingSnapshot }
    public static func encode(_ snapshot: BriefingSnapshot) throws -> Data {
        try JSONEncoder().encode(Envelope(schemaVersion: currentVersion, payload: snapshot))
    }
    public static func decode(_ data: Data) throws -> DecodedDocument<BriefingSnapshot> {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StoredDataError.invalidDocument("Expected a briefing object.")
        }
        let version = object["schemaVersion"] as? Int ?? 1
        guard (1...currentVersion).contains(version) else { throw StoredDataError.unsupportedVersion(version) }
        let value = object["schemaVersion"] == nil
            ? try JSONDecoder().decode(BriefingSnapshot.self, from: data)
            : try JSONDecoder().decode(Envelope.self, from: data).payload
        guard value.generatedAt.timeIntervalSince1970.isFinite else { throw StoredDataError.invalidDocument("Invalid timestamp.") }
        return DecodedDocument(value: value, version: version)
    }
}

public extension BriefingSection {
    private enum Keys: String, CodingKey { case kind, state, message, fetchedAt, expiresAt, items, isGenerated, dependencies }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(kind: try c.decode(SectionKind.self, forKey: .kind), state: try c.decode(ProviderState.self, forKey: .state),
            message: try c.decodeIfPresent(String.self, forKey: .message) ?? "", fetchedAt: try c.decodeIfPresent(Date.self, forKey: .fetchedAt),
            expiresAt: try c.decodeIfPresent(Date.self, forKey: .expiresAt), items: try c.decodeIfPresent([BriefingItem].self, forKey: .items) ?? [],
            isGenerated: try c.decodeIfPresent(Bool.self, forKey: .isGenerated) ?? false,
            dependencies: try c.decodeIfPresent(Set<SectionKind>.self, forKey: .dependencies))
    }
}
public extension BriefingSnapshot {
    private enum Keys: String, CodingKey { case id, generatedAt, sections, nextDelivery, changes, readSections, pinnedItems, target, updatedAt, status, sourceVersions }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), generatedAt: try c.decode(Date.self, forKey: .generatedAt),
            sections: try c.decode([BriefingSection].self, forKey: .sections), nextDelivery: try c.decodeIfPresent(Date.self, forKey: .nextDelivery))
        changes = try c.decodeIfPresent([String].self, forKey: .changes) ?? []
        readSections = try c.decodeIfPresent(Set<SectionKind>.self, forKey: .readSections) ?? []
        pinnedItems = try c.decodeIfPresent(Set<String>.self, forKey: .pinnedItems) ?? []
        target = try c.decodeIfPresent(BriefingTarget.self, forKey: .target)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        status = try c.decodeIfPresent(SnapshotStatus.self, forKey: .status) ?? .complete
        sourceVersions = try c.decodeIfPresent([String: UUID].self, forKey: .sourceVersions) ?? [:]
    }
}
