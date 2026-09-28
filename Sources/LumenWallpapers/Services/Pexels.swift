import SwiftUI
import Foundation

struct PexelsVideoFile: Codable, Hashable {
    let id: Int
    let quality: String?
    let width: Int?
    let height: Int?
    let file_type: String?
    let link: String
}

struct PexelsVideoPicture: Codable, Hashable {
    let id: Int
    let picture: String
}

struct PexelsVideo: Codable, Identifiable, Hashable {
    let id: Int
    let width: Int
    let height: Int
    let duration: Int
    let url: String
    let video_files: [PexelsVideoFile]
    let video_pictures: [PexelsVideoPicture]

    /// Largest MP4 file at or below 4K, so we never pull down an 8K master by accident.
    var bestDownloadFile: PexelsVideoFile? {
        let mp4Files = video_files.filter { ($0.file_type ?? "").contains("mp4") }
        return mp4Files.filter { ($0.width ?? 0) > 0 && ($0.width ?? 0) <= 3840 }
            .max { ($0.width ?? 0) < ($1.width ?? 0) }
            ?? mp4Files.max { ($0.width ?? 0) < ($1.width ?? 0) }
    }

    var previewImageURL: URL? { URL(string: video_pictures.first?.picture ?? "") }

    var durationLabel: String {
        String(format: "%d:%02d", duration / 60, duration % 60)
    }
}

private struct PexelsSearchResponse: Codable {
    let videos: [PexelsVideo]
    let page: Int
    let total_results: Int
    let next_page: String?
}

enum PexelsError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case rateLimited
    case unauthorized
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Add a free Pexels API key in Settings to browse videos."
        case .invalidResponse: return "Pexels returned an unexpected response."
        case .rateLimited: return "Too many requests to Pexels — please wait a moment and try again."
        case .unauthorized: return "That Pexels API key was rejected. Double-check it in Settings."
        case .http(let code): return "Pexels request failed (HTTP \(code))."
        }
    }
}

enum PexelsAPI {
    static func search(query: String, page: Int, apiKey: String) async throws -> (items: [PexelsVideo], hasMore: Bool) {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw PexelsError.missingAPIKey }

        var components = URLComponents(string: "https://api.pexels.com/videos/search")!
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        components.queryItems = [
            URLQueryItem(name: "query", value: trimmedQuery.isEmpty ? "wallpaper" : trimmedQuery),
            URLQueryItem(name: "per_page", value: "24"),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "orientation", value: "landscape"),
            URLQueryItem(name: "size", value: "large")
        ]

        var request = URLRequest(url: components.url!)
        request.setValue(trimmedKey, forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PexelsError.invalidResponse }
        if http.statusCode == 401 { throw PexelsError.unauthorized }
        if http.statusCode == 429 { throw PexelsError.rateLimited }
        guard (200...299).contains(http.statusCode) else { throw PexelsError.http(http.statusCode) }
        let decoded = try JSONDecoder().decode(PexelsSearchResponse.self, from: data)
        return (decoded.videos, decoded.next_page != nil)
    }
}

@MainActor
final class PexelsBrowseModel: ObservableObject {
    @Published var query: String = ""
    @Published private(set) var results: [PexelsVideo] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private var currentPage = 1
    private var hasMorePages = false
    private var searchTask: Task<Void, Never>?
    private var searchID = UUID()

    func runSearch(apiKey: String) {
        searchTask?.cancel()
        searchID = UUID()
        let q = query
        let id = searchID
        isLoading = true
        searchTask = Task { [weak self] in
            await self?.performSearch(query: q, page: 1, append: false, apiKey: apiKey, searchID: id)
        }
    }

    func loadMoreIfNeeded(currentItem item: PexelsVideo, apiKey: String) {
        guard !isLoading, hasMorePages, results.last?.id == item.id else { return }
        let q = query
        let nextPage = currentPage + 1
        searchID = UUID()
        let id = searchID
        isLoading = true
        searchTask = Task { [weak self] in
            await self?.performSearch(query: q, page: nextPage, append: true, apiKey: apiKey, searchID: id)
        }
    }

    private func performSearch(query: String, page: Int, append: Bool, apiKey: String, searchID: UUID) async {
        guard searchID == self.searchID else { return }
        isLoading = true
        errorMessage = nil
        do {
            let (items, hasMore) = try await PexelsAPI.search(query: query, page: page, apiKey: apiKey)
            guard !Task.isCancelled, searchID == self.searchID else { return }
            currentPage = page
            hasMorePages = hasMore
            results = append ? results + items : items
        } catch {
            if !Task.isCancelled, searchID == self.searchID {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
        if searchID == self.searchID { isLoading = false }
    }
}
