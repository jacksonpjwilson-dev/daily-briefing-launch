import Foundation

public enum SourceTimestamp {
    public static func parse(_ string: String?) -> Date? {
        guard let string else { return nil }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f.date(from: string) { return date }
        f.formatOptions = [.withInternetDateTime]; return f.date(from: string)
    }
}
public struct AviationReport: Decodable, Sendable {
    public var icaoId: String?
    public var rawOb: String?
    public var rawTAF: String?
    public var reportTime: String?
    public var issueTime: String?
    public var obsTime: Double?
    public var validTimeTo: Double?
}
public struct AviationProductResult: Sendable {
    public var product: String
    public var records: [AviationReport]
    public var error: String?
    public init(product: String, records: [AviationReport] = [], error: String? = nil) {
        self.product = product; self.records = records; self.error = error
    }
}
public enum AviationReports {
    public static func section(_ results: [AviationProductResult], now: Date) -> BriefingSection {
        var items: [BriefingItem] = [], messages: [String] = []
        for result in results {
            if let error = result.error { messages.append("\(result.product.uppercased()) unavailable: \(error)") }
            if result.error == nil && result.records.isEmpty { messages.append("No \(result.product.uppercased()) report was supplied.") }
            for report in result.records {
                guard let raw = report.rawOb ?? report.rawTAF else { continue }
                let issued = SourceTimestamp.parse(report.reportTime ?? report.issueTime) ?? report.obsTime.map(Date.init(timeIntervalSince1970:))
                let expires = result.product == "metar" ? issued?.addingTimeInterval(2 * 3600) : report.validTimeTo.map(Date.init(timeIntervalSince1970:))
                let valid = issued.map { $0 <= now.addingTimeInterval(60) } == true && expires.map { $0 > now } == true
                let warning = valid ? "" : "Report validity is expired or unknown — verify with the official source.\n"
                items.append(BriefingItem(id: "aviation:\(report.icaoId ?? "unknown"):\(result.product)",
                    title: "\(report.icaoId ?? "Airport") \(result.product.uppercased())", detail: warning + raw,
                    date: issued, url: URL(string: "https://aviationweather.gov/"), source: "NOAA Aviation Weather Center",
                    origin: .provider, sourceExpiresAt: expires ?? .distantPast))
            }
        }
        let fresh = items.filter { $0.sourceExpiresAt.map { $0 > now } == true }
        let state: ProviderState = items.isEmpty ? (messages.contains(where: { $0.contains("unavailable:") }) ? .failed : .missingData) : fresh.isEmpty ? .stale : !messages.isEmpty || fresh.count != items.count ? .partial : .ready
        return BriefingSection(kind: .aviation, state: state,
            message: (["Reference only. Use official operational briefing products for flight decisions. Check report issue and validity times."] + messages).joined(separator: " "),
            fetchedAt: now, expiresAt: min(fresh.compactMap(\.sourceExpiresAt).min() ?? now, now.addingTimeInterval(1800)), items: items)
    }
}
