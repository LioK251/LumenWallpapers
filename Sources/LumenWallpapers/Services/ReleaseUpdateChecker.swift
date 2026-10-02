import Foundation
import Combine

struct GitHubRelease: Decodable, Identifiable {
    let tag_name: String
    let draft: Bool
    let prerelease: Bool
    var id: String { tag_name }
    var url: URL { ReleaseUpdateChecker.repositoryURL.appendingPathComponent("releases/tag").appendingPathComponent(tag_name) }

    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        func components(_ value: String) -> [Int]? {
            let normalized = value.hasPrefix("v") ? String(value.dropFirst()) : value
            let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count >= 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) else { return nil }
            let numbers = parts.compactMap { Int($0) }
            return numbers.count == parts.count ? numbers : nil
        }
        guard let lhs = components(candidate), let rhs = components(installed) else { return false }
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }
}

@MainActor
final class ReleaseUpdateChecker: ObservableObject {
    nonisolated static let repositoryURL = URL(string: "https://github.com/LioK251/LumenWallpapers")!
    @Published var availableRelease: GitHubRelease?
    private let defaults: UserDefaults
    private var lastCheck: Date?
    private var isChecking = false
    private static let shownVersionsKey = "shownReleaseUpdateVersions"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func markPresented(_ release: GitHubRelease) {
        var versions = defaults.stringArray(forKey: Self.shownVersionsKey) ?? []
        if !versions.contains(release.id) {
            versions.append(release.id)
            defaults.set(versions, forKey: Self.shownVersionsKey)
        }
    }

    func shouldPresent(_ release: GitHubRelease, installed: String) -> Bool {
        !release.draft && !release.prerelease
            && GitHubRelease.isNewer(release.tag_name, than: installed)
            && !(defaults.stringArray(forKey: Self.shownVersionsKey) ?? []).contains(release.id)
    }

    func checkIfNeeded() async {
        guard !isChecking, availableRelease == nil,
              lastCheck.map({ Date().timeIntervalSince($0) >= 21_600 }) ?? true,
              let installed = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { return }
        isChecking = true
        lastCheck = Date()
        defer { isChecking = false }
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/LioK251/LumenWallpapers/releases/latest")!)
            request.timeoutInterval = 15
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Lumen/\(installed)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            if shouldPresent(release, installed: installed) { availableRelease = release }
        } catch {
            if Task.isCancelled { lastCheck = nil }
        }
    }
}
