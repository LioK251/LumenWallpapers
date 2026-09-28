import SwiftUI
import Foundation

struct WallhavenThumbs: Codable, Hashable {
    let large: String
    let original: String
    let small: String
}

struct WallhavenWallpaper: Codable, Identifiable, Hashable {
    let id: String
    let url: String
    let short_url: String
    let source: String?
    let resolution: String
    let file_type: String
    let category: String
    let purity: String
    let path: String
    let thumbs: WallhavenThumbs
}

private struct WallhavenMeta: Codable {
    let current_page: Int?
    let last_page: Int?
}

private struct WallhavenSearchResponse: Codable {
    let data: [WallhavenWallpaper]
    let meta: WallhavenMeta?
}

enum WallhavenError: LocalizedError {
    case invalidResponse
    case rateLimited
    case unauthorized
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Wallhaven returned an unexpected response."
        case .rateLimited: return "Too many requests to Wallhaven — please wait a moment and try again."
        case .unauthorized: return "Wallhaven rejected the API key. Check it in Settings."
        case .http(let code): return "Wallhaven request failed (HTTP \(code))."
        }
    }
}

enum WallhavenAPI {
    static func search(
        query: String,
        page: Int = 1,
        sorting: String? = nil,
        includeNSFW: Bool = false,
        apiKey: String = ""
    ) async throws -> (items: [WallhavenWallpaper], currentPage: Int, lastPage: Int) {
        var components = URLComponents(string: "https://wallhaven.cc/api/v1/search")!
        var queryItems = [
            URLQueryItem(name: "categories", value: "111"),
            URLQueryItem(name: "purity", value: includeNSFW ? "111" : "100"),
            URLQueryItem(name: "sorting", value: sorting ?? (query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "toplist" : "relevance")),
            URLQueryItem(name: "page", value: String(page))
        ]
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { queryItems.append(URLQueryItem(name: "q", value: trimmed)) }
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAPIKey.isEmpty {
            queryItems.append(URLQueryItem(name: "apikey", value: trimmedAPIKey))
        }
        components.queryItems = queryItems

        let request = URLRequest(url: components.url!)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WallhavenError.invalidResponse }
        if http.statusCode == 401 { throw WallhavenError.unauthorized }
        if http.statusCode == 429 { throw WallhavenError.rateLimited }
        guard (200...299).contains(http.statusCode) else { throw WallhavenError.http(http.statusCode) }
        let decoded = try JSONDecoder().decode(WallhavenSearchResponse.self, from: data)
        return (decoded.data, decoded.meta?.current_page ?? page, decoded.meta?.last_page ?? page)
    }
}

enum WebPageMetadata {
    static func title(for page: String, fallback: String) async -> String {
        guard let url = URL(string: page) else { return fallback }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return fallback }
            let html = String(decoding: data, as: UTF8.self)
            let htmlRange = NSRange(html.startIndex..<html.endIndex, in: html)
            if let metaExpression = try? NSRegularExpression(pattern: #"<meta\b[^>]*>"#, options: [.caseInsensitive]) {
                for match in metaExpression.matches(in: html, options: [], range: htmlRange) {
                    guard let tagRange = Range(match.range, in: html) else { continue }
                    let tag = String(html[tagRange])
                    guard let key = attribute(named: "property", in: tag) ?? attribute(named: "name", in: tag),
                          ["og:title", "twitter:title", "title"].contains(key.lowercased()),
                          let content = attribute(named: "content", in: tag),
                          let value = cleanedTitle(content, fallback: fallback) else { continue }
                    return value
                }
            }
            for pattern in [#"<title[^>]*>(.*?)</title>"#, #"<h1[^>]*>(.*?)</h1>"#] {
                guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
                      let match = expression.firstMatch(in: html, options: [], range: htmlRange),
                      match.numberOfRanges > 1,
                      let valueRange = Range(match.range(at: 1), in: html),
                      let value = cleanedTitle(String(html[valueRange]), fallback: fallback) else { continue }
                return value
            }
        } catch {
            // A readable fallback title is still better than failing the download.
        }
        return fallback
    }

    static func suggestedName(
        from response: URLResponse,
        remoteURL: URL,
        sourceURL: URL? = nil
    ) -> String? {
        if let http = response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           let filename = attribute(named: "filename", in: disposition),
           let title = cleanedTitle(URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent, fallback: "") {
            return title
        }
        for url in [sourceURL, remoteURL].compactMap({ $0 }) {
            let stem = url.deletingPathExtension().lastPathComponent
            if let title = cleanedTitle(stem, fallback: "") { return title }
        }
        return nil
    }

    private static func attribute(named name: String, in value: String) -> String? {
        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*[\"']([^\"']*)[\"']"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = expression.firstMatch(in: value, options: [], range: NSRange(value.startIndex..<value.endIndex, in: value)),
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return decodeHTMLEntities(String(value[range])).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanedTitle(_ raw: String, fallback: String) -> String? {
        let value = decodeHTMLEntities(raw)
            .replacingOccurrences(of: "Wallhaven - ", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: " - Wallhaven", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "Wallhaven wallpaper", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.lowercased() != "wallhaven" else { return nil }

        let withoutSiteSuffix = value
            .replacingOccurrences(of: #"\s*[-|]\s*wallhaven\.cc\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\|\s*\d{3,5}x\d{3,5}\s+wallpaper\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !withoutSiteSuffix.isEmpty else { return nil }

        let normalized = withoutSiteSuffix.replacingOccurrences(of: "_", with: "-")
        let looksLikeWallhavenID = normalized.range(of: #"^(?:wallhaven[-_])?#?[a-z0-9]{5,10}$"#, options: [.regularExpression, .caseInsensitive]) != nil
        let looksLikeGeneratedID = normalized.range(of: #"^(?:wallpaper|pexels(?:[- ]video)?)[-_ ]?[a-z0-9]+$"#, options: [.regularExpression, .caseInsensitive]) != nil
        if looksLikeWallhavenID || looksLikeGeneratedID {
            return fallback.isEmpty ? nil : fallback
        }
        return withoutSiteSuffix
    }

    private static func decodeHTMLEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#039;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#x2F;", with: "/")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}

enum DiscoverRecommendation: Identifiable, Hashable {
    case image(WallhavenWallpaper)
    case video(PexelsVideo)

    var id: String {
        switch self {
        case .image(let item): return "image-\(item.id)"
        case .video(let item): return "video-\(item.id)"
        }
    }

    var title: String {
        switch self {
        case .image(let item): return "Wallpaper \(item.id)"
        case .video(let item): return "Video \(item.id)"
        }
    }

    var subtitle: String {
        switch self {
        case .image(let item): return "\(item.resolution) · Wallhaven"
        case .video(let item): return "\(item.width)×\(item.height) · Pexels"
        }
    }

    var previewURL: URL? {
        switch self {
        case .image(let item): return URL(string: item.thumbs.large)
        case .video(let item): return item.previewImageURL
        }
    }
}

@MainActor
final class WallhavenBrowseModel: ObservableObject {
    @Published var query: String = ""
    @Published private(set) var results: [WallhavenWallpaper] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private var currentPage = 1
    private var lastPage = 1
    private var searchTask: Task<Void, Never>?
    private var searchID = UUID()
    private var hasSearchedOnce = false

    func runSearch(includeNSFW: Bool = false, apiKey: String = "") {
        searchTask?.cancel()
        searchID = UUID()
        hasSearchedOnce = true
        let q = query
        let id = searchID
        isLoading = true
        searchTask = Task { [weak self] in
            await self?.performSearch(query: q, page: 1, append: false, includeNSFW: includeNSFW, apiKey: apiKey, searchID: id)
        }
    }

    func loadMoreIfNeeded(currentItem item: WallhavenWallpaper, includeNSFW: Bool = false, apiKey: String = "") {
        guard hasSearchedOnce, !isLoading, currentPage < lastPage, results.last?.id == item.id else { return }
        let q = query
        let nextPage = currentPage + 1
        searchID = UUID()
        let id = searchID
        isLoading = true
        searchTask = Task { [weak self] in
            await self?.performSearch(query: q, page: nextPage, append: true, includeNSFW: includeNSFW, apiKey: apiKey, searchID: id)
        }
    }

    private func performSearch(query: String, page: Int, append: Bool, includeNSFW: Bool, apiKey: String, searchID: UUID) async {
        guard searchID == self.searchID else { return }
        isLoading = true
        errorMessage = nil
        do {
            let (items, current, last) = try await WallhavenAPI.search(query: query, page: page, includeNSFW: includeNSFW, apiKey: apiKey)
            guard !Task.isCancelled, searchID == self.searchID else { return }
            currentPage = current
            lastPage = last
            results = append ? results + items : items
        } catch {
            if !Task.isCancelled, searchID == self.searchID {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
        if searchID == self.searchID { isLoading = false }
    }
}
