import Foundation
import Testing
@testable import LumenWallpapers

struct APIRegressionTests {
    @Test func updatesFollowPublicationDatesAcrossVersionReset() {
        let old = release("v1.0.8.1", day: 1)
        let installed = release("v0.1.9", day: 2)
        let next = release("0.1.10", day: 3)
        #expect(GitHubRelease.latestUpdate(in: [old, installed], installedVersion: "0.1.9") == nil)
        #expect(GitHubRelease.latestUpdate(in: [next, old, installed], installedVersion: "0.1.9")?.id == next.id)
        #expect(GitHubRelease.latestUpdate(in: [old, installed], installedVersion: "1.0.8.1")?.id == installed.id)
    }

    @Test func unpublishedInstallsAndUnstableReleasesDoNotPrompt() {
        let installed = release("0.1.9", day: 1)
        let stable = release("0.1.10", day: 2)
        let preview = release("0.2.0", day: 3, prerelease: true)
        let draft = release("0.3.0", day: 4, draft: true)
        let unpublished = GitHubRelease(tag_name: "0.4.0", draft: false, prerelease: false, published_at: nil)
        #expect(GitHubRelease.latestUpdate(in: [stable, preview, draft], installedVersion: "0.1.9") == nil)
        #expect(GitHubRelease.latestUpdate(in: [preview, draft, unpublished, installed, stable], installedVersion: "0.1.9")?.id == stable.id)
        #expect(GitHubRelease.latestUpdate(in: [installed, release("0.1.10", day: 1)], installedVersion: "0.1.9") == nil)
    }

    @MainActor @Test func presentedUpdatesAreRememberedInIsolatedDefaults() throws {
        let suite = "LumenAPIRegressionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let checker = ReleaseUpdateChecker(defaults: defaults)
        let next = release("0.1.10", day: 2)
        #expect(checker.shouldPresent(next))
        #expect(!checker.shouldPresent(release("0.2.0", day: 3, prerelease: true)))
        #expect(!checker.shouldPresent(release("0.3.0", day: 4, draft: true)))
        checker.markPresented(next)
        checker.markPresented(next)
        #expect(!checker.shouldPresent(next))
        #expect(defaults.stringArray(forKey: "shownReleaseUpdateVersions") == ["0.1.10"])
    }

    @Test func releasePublicationDateDecodesFromGitHubJSON() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let json = #"{"tag_name":"v0.1.9","draft":false,"prerelease":false,"published_at":"2026-11-12T09:00:00Z"}"#
        let release = try decoder.decode(GitHubRelease.self, from: Data(json.utf8))
        #expect(release.published_at != nil)
    }

    @Test func pexelsRejectsMissingInvalidOrOversizeDimensions() {
        let files = [
            file(1, 7680, 4320), file(2, 2160, 3841), file(3, 3840, 2161),
            file(4, 1920, nil), file(5, nil, 1080), file(6, -1, 1080), file(7, 1920, 0),
            file(8, 1920, 1080, type: "video/webm")
        ]
        #expect(video(files).bestDownloadFile == nil)
    }

    @Test func pexelsChoosesLargestValidAreaInEitherOrientation() {
        let landscape = file(1, 3840, 2160)
        let portrait = file(2, 2160, 3840)
        let wide = file(3, 3840, 1080)
        #expect(video([wide, landscape, file(4, 7680, 4320)]).bestDownloadFile?.id == landscape.id)
        #expect(video([wide, portrait]).bestDownloadFile?.id == portrait.id)
    }

    @MainActor @Test func disablingNSFWClearsResultsAndRejectsCancelledSearch() async {
        let search = ControlledWallhavenSearch()
        let model = WallhavenBrowseModel(search: search.search)
        let unsafe = wallpaper("unsafe", purity: "nsfw")
        let safe = wallpaper("safe", purity: "sfw")
        model.runSearch(includeNSFW: true)
        let first = await search.nextRequest()
        await first.complete(with: [unsafe])
        #expect(model.results.map(\.id) == [unsafe.id])

        model.runSearch(includeNSFW: true)
        let stale = await search.nextRequest()
        model.runSearch(includeNSFW: false)
        #expect(model.results.isEmpty)
        let current = await search.nextRequest()
        #expect(!current.includeNSFW)
        await current.complete(with: [safe])
        await stale.complete(with: [unsafe])
        #expect(model.results.map(\.id) == [safe.id])
        #expect(!model.isLoading)
        #expect(model.errorMessage == nil)
    }

    private func release(_ tag: String, day: Int, draft: Bool = false, prerelease: Bool = false) -> GitHubRelease {
        GitHubRelease(tag_name: tag, draft: draft, prerelease: prerelease, published_at: Date(timeIntervalSince1970: Double(day) * 86_400))
    }

    private func file(_ id: Int, _ width: Int?, _ height: Int?, type: String = "video/mp4") -> PexelsVideoFile {
        PexelsVideoFile(id: id, quality: "hd", width: width, height: height, file_type: type, link: "https://example.invalid/\(id).mp4")
    }

    private func video(_ files: [PexelsVideoFile]) -> PexelsVideo {
        PexelsVideo(id: 1, width: 3840, height: 2160, duration: 30, url: "https://example.invalid/video", video_files: files, video_pictures: [])
    }

    private func wallpaper(_ id: String, purity: String) -> WallhavenWallpaper {
        WallhavenWallpaper(id: id, url: "", short_url: "", source: nil, resolution: "1920x1080", file_type: "image/jpeg", category: "general", purity: purity, path: "", thumbs: WallhavenThumbs(large: "", original: "", small: ""))
    }
}

@MainActor
private final class ControlledWallhavenSearch {
    typealias Response = (items: [WallhavenWallpaper], currentPage: Int, lastPage: Int)

    @MainActor
    final class Request {
        let includeNSFW: Bool
        let response: CheckedContinuation<Response, any Error>
        var returned: CheckedContinuation<Void, Never>?

        init(includeNSFW: Bool, response: CheckedContinuation<Response, any Error>) {
            self.includeNSFW = includeNSFW
            self.response = response
        }

        func complete(with items: [WallhavenWallpaper]) async {
            await withCheckedContinuation { continuation in
                returned = continuation
                response.resume(returning: (items, 1, 1))
            }
        }
    }

    private var pending: [Request] = []
    private var waiter: CheckedContinuation<Request, Never>?

    func search(query: String, page: Int, includeNSFW: Bool, apiKey: String) async throws -> Response {
        var request: Request?
        let result = try await withCheckedThrowingContinuation { continuation in
            let newRequest = Request(includeNSFW: includeNSFW, response: continuation)
            request = newRequest
            if let waiter {
                self.waiter = nil
                waiter.resume(returning: newRequest)
            } else {
                pending.append(newRequest)
            }
        }
        request?.returned?.resume()
        return result
    }

    func nextRequest() async -> Request {
        if !pending.isEmpty { return pending.removeFirst() }
        return await withCheckedContinuation { waiter = $0 }
    }
}
