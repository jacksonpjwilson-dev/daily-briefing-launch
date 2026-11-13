import Observation
import Foundation
import CoreLocation
import WeatherKit
#if canImport(FoundationXML)
import FoundationXML
#endif

protocol SectionProvider {
    var kind: SectionKind { get }
    func fetch(preferences: AppPreferences) async throws -> BriefingSection
}
enum ProviderError: LocalizedError {
    case invalidEndpoint, response(Int), unavailable(String)
    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Configure a valid HTTPS endpoint."
        case .response(let code): "Source returned HTTP \(code)."
        case .unavailable(let message): message
        }
    }
}
enum HTTP {
    static func data(from url: URL) async throws -> Data {
        guard url.scheme == "https" else { throw ProviderError.invalidEndpoint }
        var request = URLRequest(url: url); request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
            throw ProviderError.response((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard data.count <= 2_000_000 else { throw ProviderError.unavailable("Source response exceeds 2 MB.") }
        return data
    }
    static func failed(_ kind: SectionKind, error: Error) -> BriefingSection {
        let code = (error as NSError).code
        let offline = (error as NSError).domain == NSURLErrorDomain && [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut].contains(code)
        return BriefingSection(kind: kind, state: offline ? .offline : .failed, message: error.localizedDescription)
    }
}
@MainActor @Observable final class LocationService: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var location: CLLocation?
    var status: CLAuthorizationStatus = .notDetermined
    override init() { super.init(); manager.delegate = self; status = manager.authorizationStatus }
    func reloadAuthorization() {
        status = manager.authorizationStatus
        if ![.authorizedAlways, .authorizedWhenInUse].contains(status) { location = nil }
    }
    func requestIfAuthorized() {
        if [.authorizedAlways, .authorizedWhenInUse].contains(manager.authorizationStatus) { manager.requestLocation() }
    }
    func request() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        else if [.authorizedAlways, .authorizedWhenInUse].contains(manager.authorizationStatus) { manager.requestLocation() }
    }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let authorization = manager.authorizationStatus
        Task { @MainActor in self.status = authorization; self.requestIfAuthorized() }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let latest = locations.last
        Task { @MainActor in self.location = latest }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.location = nil }
    }
}
struct WeatherProvider {
    func fetch(location: CLLocation?, fahrenheit: Bool, targetDay: Date = Date()) async throws -> BriefingSection {
        guard Bundle.main.object(forInfoDictionaryKey: "WeatherKitConfigured") as? Bool == true else {
            return BriefingSection(kind: .weather, state: .disconnected, message: "Weather is not connected. Complete the weather setup described in Settings before requesting local forecasts.")
        }
        guard let location, abs(location.timestamp.timeIntervalSinceNow) < 3600 else {
            return BriefingSection(kind: .weather, state: .missingData, message: "Enable location in Connections to request local weather.")
        }
        let weather = try await WeatherService.shared.weather(for: location)
        let unit: UnitTemperature = fahrenheit ? .fahrenheit : .celsius
        let formatter = MeasurementFormatter(); formatter.unitOptions = .providedUnit
        func temperature(_ value: Measurement<UnitTemperature>) -> String { formatter.string(from: value.converted(to: unit)) }
        var items = [BriefingItem(id: "weather.current", title: "\(temperature(weather.currentWeather.temperature)) · \(weather.currentWeather.condition.description)",
            detail: "Wind \(weather.currentWeather.wind.speed.formatted())", date: weather.currentWeather.date, source: "Apple Weather")]
        if let day = weather.dailyForecast.forecast.first(where: { Calendar.autoupdatingCurrent.isDate($0.date, inSameDayAs: targetDay) }) {
            items.append(BriefingItem(id: "weather.day.\(day.date.timeIntervalSince1970)", title: "High \(temperature(day.highTemperature)) · Low \(temperature(day.lowTemperature))",
                detail: "Precipitation \(Int(day.precipitationChance * 100))%", date: day.date, source: "Apple Weather"))
        }
        items += weather.hourlyForecast.forecast.filter { $0.date >= Date() && Calendar.autoupdatingCurrent.isDate($0.date, inSameDayAs: targetDay) }.prefix(6).map {
            BriefingItem(id: "weather.hour.\($0.date.timeIntervalSince1970)", title: temperature($0.temperature), detail: "\($0.condition.description) · Rain \(Int($0.precipitationChance * 100))%", date: $0.date, source: "Apple Weather")
        }
        if let alerts = weather.weatherAlerts {
            items += alerts.map { BriefingItem(id: "weather.alert.\($0.detailsURL.absoluteString)", title: $0.summary, detail: "Weather alert", url: $0.detailsURL, source: $0.source) }
        }
        let attribution = try await WeatherService.shared.attribution
        items.append(BriefingItem(id: "weather.attribution", title: "Weather attribution and legal information", url: attribution.legalPageURL, source: "Apple Weather", attributionImageURL: attribution.combinedMarkDarkURL))
        return BriefingSection(kind: .weather, state: Date().timeIntervalSince(weather.currentWeather.date) < 3600 ? .ready : .stale, fetchedAt: Date(), expiresAt: min(Date().addingTimeInterval(1800), weather.currentWeather.date.addingTimeInterval(3600)), items: items)
    }
}
struct AviationProvider: SectionProvider {
    let kind = SectionKind.aviation
    func fetch(preferences: AppPreferences) async throws -> BriefingSection {
        let airports = preferences.airports.uppercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.range(of: "^[A-Z]{4}$", options: .regularExpression) != nil }.prefix(5)
        guard !airports.isEmpty else { return BriefingSection(kind: kind, state: .missingData, message: "Configure an ICAO airport code.") }
        let ids = airports.joined(separator: ",")
        return await withTaskGroup(of: AviationProductResult.self) { group in
            for product in ["metar", "taf"] {
                group.addTask {
                    do {
                        var parts = URLComponents(string: "https://aviationweather.gov/api/data/\(product)")!
                        parts.queryItems = [URLQueryItem(name: "ids", value: ids), URLQueryItem(name: "format", value: "json")]
                        let records = try JSONDecoder().decode([AviationReport].self, from: await HTTP.data(from: parts.url!))
                        return AviationProductResult(product: product, records: records)
                    } catch { return AviationProductResult(product: product, error: error.localizedDescription) }
                }
            }
            var results: [AviationProductResult] = []
            for await result in group { results.append(result) }
            return AviationReports.section(results.sorted { $0.product < $1.product }, now: Date())
        }
    }
}
struct NewsProvider: SectionProvider {
    let kind = SectionKind.news
    func fetch(preferences: AppPreferences) async throws -> BriefingSection {
        guard let url = URL(string: preferences.newsFeed), url.scheme == "https" else { throw ProviderError.invalidEndpoint }
        let data = try await HTTP.data(from: url)
        let delegate = FeedParser(); let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse() else { throw ProviderError.unavailable("The feed could not be parsed. Supply an RSS feed URL.") }
        let topics = preferences.newsTopics.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        let filtered = topics.isEmpty ? delegate.items : delegate.items.filter { item in topics.contains { (item.title + " " + item.detail).lowercased().contains($0) } }
        return BriefingSection(kind: kind, state: .ready, message: filtered.isEmpty ? "No headlines match your topics. Clear topics to show all headlines." : "",
            fetchedAt: Date(), expiresAt: Date().addingTimeInterval(1800), items: Array(filtered.prefix(12)))
    }
}
private final class FeedParser: NSObject, XMLParserDelegate {
    var items: [BriefingItem] = []
    private var fields: [String: String] = [:], element = "", inside = false
    private var seen: Set<String> = []
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        element = name
        if name == "item" { inside = true; fields = [:] }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if inside { fields[element, default: ""] += string } }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { if let s = String(data: CDATABlock, encoding: .utf8), inside { fields[element, default: ""] += s } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard name == "item" else { return }; inside = false
        let title = fields["title", default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        let link = fields["link", default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let url = URL(string: link), url.scheme == "https", seen.insert(title.lowercased()).inserted else { return }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let description = fields["description", default: ""].replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        items.append(BriefingItem(id: link, title: title, detail: description, date: fields["pubDate"].flatMap(formatter.date(from:)), url: url, source: url.host ?? "RSS"))
    }
}
// OAuth-backed email and licensed sports sources implement this boundary; no bundled scores or inbox samples.
protocol EmailProvider { func importantMessages() async throws -> BriefingSection }
protocol SportsProvider { func updates(teams: [String]) async throws -> BriefingSection }
protocol AISummaryProvider { func summarize(sections: [BriefingSection], length: String) async throws -> BriefingSection }
struct HTTPSummaryProvider: AISummaryProvider {
    let endpoint: URL
    struct Request: Encodable { var sections: [BriefingSection]; var length: String }
    struct Response: Decodable { var summary: String }
    func summarize(sections: [BriefingSection], length: String) async throws -> BriefingSection {
        guard endpoint.scheme == "https" else { throw ProviderError.invalidEndpoint }
        var request = URLRequest(url: endpoint); request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = try KeychainStore.read(service: "ai", endpoint: endpoint) { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(Request(sections: sections.filter { $0.kind != .summary && $0.isFresh(at: Date()) && !$0.isGenerated }.map { section in var section = section; section.items.removeAll { $0.sourceExpiresAt.map { $0 <= Date() } == true }; return section }, length: length))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ProviderError.response((response as? HTTPURLResponse)?.statusCode ?? 0) }
        let result = try JSONDecoder().decode(Response.self, from: data)
        guard !result.summary.isEmpty else { throw ProviderError.unavailable("Summary provider returned empty text.") }
        return BriefingSection(kind: .summary, state: .ready, message: "AI interpretation — verify against original sources.", fetchedAt: Date(), expiresAt: Date().addingTimeInterval(1800),
            items: [BriefingItem(title: result.summary, source: "Configured AI provider")], isGenerated: true)
    }
}
