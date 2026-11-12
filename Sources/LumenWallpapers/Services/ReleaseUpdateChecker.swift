import Foundation
import Combine

struct GitHubRelease: Decodable, Identifiable {
    let tag_name: String
    let draft: Bool
    let prerelease: Bool
    let published_at: Date?
    var id: String { tag_name }
    var url: URL { ReleaseUpdateChecker.repositoryURL.appendingPathComponent("releases/tag").appendingPathComponent(tag_name) }

    static func normalizedVersion(_ version: String) -> String {
        version.hasPrefix("v") ? String(version.dropFirst()) : version
    }

    static func latestUpdate(in releases: [GitHubRelease], installedVersion: String) -> GitHubRelease? {
        let stable = releases.filter { !$0.draft && !$0.prerelease && $0.published_at != nil }
        let installedTag = normalizedVersion(installedVersion)
        guard let installed = stable.first(where: { normalizedVersion($0.tag_name) == installedTag }),
              let installedDate = installed.published_at else { return nil }
        return stable.filter {
            normalizedVersion($0.tag_name) != installedTag && $0.published_at! > installedDate
        }.max { $0.published_at! < $1.published_at! }
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

    func shouldPresent(_ release: GitHubRelease) -> Bool {
        !release.draft && !release.prerelease && release.published_at != nil
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
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var releases: [GitHubRelease] = []
            var page = 1
            while true {
                try Task.checkCancellation()
                var request = URLRequest(url: URL(string: "https://api.github.com/repos/LioK251/LumenWallpapers/releases?per_page=100&page=\(page)")!)
                request.timeoutInterval = 15
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("Lumen/\(installed)", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
                let batch = try decoder.decode([GitHubRelease].self, from: data)
                releases.append(contentsOf: batch)
                if batch.count < 100 { break }
                page += 1
            }
            if let release = GitHubRelease.latestUpdate(in: releases, installedVersion: installed), shouldPresent(release) {
                availableRelease = release
            }
        } catch {
            if Task.isCancelled { lastCheck = nil }
        }
    }
}
