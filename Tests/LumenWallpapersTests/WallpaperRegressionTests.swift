import Testing
import Foundation
import AVFoundation
@testable import LumenWallpapers

@MainActor
struct WallpaperRegressionTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LumenTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func section(_ asset: String) throws -> [String: Any] {
        let configuration = try PropertyListSerialization.data(fromPropertyList: ["assetID": asset], format: .binary, options: 0)
        return ["Content": ["Choices": [["Provider": "com.apple.wallpaper.choice.aerials", "Configuration": configuration]]]]
    }

    @Test func rollbackRestoresFilesAndBackups() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original")
        let backup = root.appendingPathComponent("backup")
        let created = root.appendingPathComponent("new")
        try Data("original".utf8).write(to: original)
        try Data("recovery".utf8).write(to: backup)
        #expect(throws: CocoaError.self) {
            try LockScreenVideoManager.withFileRollback(urls: [original, backup, created]) {
                try Data("changed".utf8).write(to: original)
                try FileManager.default.removeItem(at: backup)
                try Data("created".utf8).write(to: created)
                throw CocoaError(.fileWriteUnknown)
            }
        }
        #expect(try Data(contentsOf: original) == Data("original".utf8))
        #expect(try Data(contentsOf: backup) == Data("recovery".utf8))
        #expect(!FileManager.default.fileExists(atPath: created.path))
    }

    @Test func selectionKeepsLegacyAndCurrentStoresInSync() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("Index.plist")
        let current = root.appendingPathComponent("Index_v2.plist")
        try Data().write(to: legacy)
        #expect(LockScreenVideoManager.selectionStoreURLs(in: root) == [legacy])
        try Data().write(to: current)
        #expect(LockScreenVideoManager.selectionStoreURLs(in: root) == [legacy, current])
    }

    @Test func preferenceRestoreHonorsOwnershipAndAbsence() {
        let pathKey = "AerialManifestLocalPathOverride"
        let forceKey = "AerialManifestForceLocal"
        let owned: [String: Any] = [pathKey: "/Lumen/entries.json", forceKey: true]
        #expect(LockScreenVideoManager.restoredAerialPreferences(current: owned, previous: [:], catalogPath: "/Lumen/entries.json").isEmpty)
        let other: [String: Any] = [pathKey: "/other/entries.json", forceKey: false]
        let restored = LockScreenVideoManager.restoredAerialPreferences(current: other, previous: owned, catalogPath: "/Lumen/entries.json")
        #expect(restored[pathKey] as? String == "/other/entries.json")
        #expect(restored[forceKey] as? Bool == false)
    }

    @Test func preferenceRollbackRestoresAnAbsentOverride() throws {
        let domain = "LumenRegression-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        #expect(throws: CocoaError.self) {
            try LockScreenVideoManager.withPreferenceRollback(domain: domain) {
                CFPreferencesSetValue("AerialManifestLocalPathOverride" as CFString, "/test/catalog" as CFString,
                    domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                CFPreferencesSetValue("AerialManifestForceLocal" as CFString, true as CFBoolean,
                    domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                throw CocoaError(.fileWriteUnknown)
            }
        }
        #expect(CFPreferencesCopyValue("AerialManifestLocalPathOverride" as CFString, domain as CFString,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost) == nil)
        #expect(CFPreferencesCopyValue("AerialManifestForceLocal" as CFString, domain as CFString,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost) == nil)
    }

    @Test func catalogRebaseUpdatesAppleAndPreservesCustomEntries() {
        let old: [String: Any] = ["version": 1, "assets": [["id": "apple", "name": "old"]], "categories": []]
        let current: [String: Any] = ["version": 2, "assets": [["id": "apple", "name": "new"], ["id": "new-apple"]], "categories": []]
        let custom: [String: Any] = ["version": 1, "assets": [["id": "apple", "name": "old"], ["id": "other-app"], ["id": "lumen"]], "categories": [["id": "other-category"]]]
        let result = LockScreenVideoManager.rebasingManifest(apple: current, previousApple: old, custom: custom)
        let assets = result["assets"] as? [[String: String]] ?? []
        #expect(result["version"] as? Int == 2)
        #expect(assets.first { $0["id"] == "apple" }?["name"] == "new")
        #expect(Set(assets.compactMap { $0["id"] }) == ["apple", "new-apple", "other-app", "lumen"])
        #expect((result["categories"] as? [[String: String]])?.first?["id"] == "other-category")
    }

    @Test func displayTargetingKeepsOtherScreensAndSelectsLinkedContent() throws {
        let original: [String: Any] = ["Type": "linked", "Linked": try section("apple")]
        let root: [String: Any] = ["SystemDefault": original, "AllSpacesAndDisplays": original,
            "Displays": ["internal": original, "external": original],
            "Spaces": ["space": ["Default": original, "Displays": ["external": original]]]]
        let data = try PropertyListSerialization.data(fromPropertyList: ["assetID": "lumen"], format: .binary, options: 0)
        let updated = try LockScreenVideoManager.selectingWallpaper(in: root, configuration: data,
            desktopOptions: Data(), idleOptions: Data(), targetDisplayIDs: ["internal"], allDisplays: false)
        #expect(LockScreenVideoManager.wallpaperSelectionMatches("lumen", in: updated, targetDisplayIDs: ["internal"], allDisplays: false))
        #expect(!LockScreenVideoManager.wallpaperSelectionMatches("lumen", in: updated, targetDisplayIDs: ["external"], allDisplays: false))
        let display = (updated as? [String: Any])?["Displays"] as? [String: [String: Any]]
        #expect(display?["external"]?["Type"] as? String == "linked")
        #expect(display?["internal"]?["Type"] as? String == "individual")
        #expect(LockScreenVideoManager.wallpaperSelectionMatches("lumen", in: display?["internal"]?["Linked"] ?? [:]) == false)
        #expect((updated as? [String: Any])?["AllSpacesAndDisplays"] == nil)
        let restored = try LockScreenVideoManager.restoringWallpaperSections(in: updated, from: root, assetID: "lumen")
        #expect(((restored as? [String: Any])?["AllSpacesAndDisplays"] as? [String: Any])?["Type"] as? String == "linked")
        let restoredDisplays = (restored as? [String: Any])?["Displays"] as? [String: [String: Any]]
        #expect(restoredDisplays?["internal"]?["Type"] as? String == "linked")
        #expect(restoredDisplays?["internal"]?["Desktop"] == nil)
    }

    @Test func restorationPreservesUserChangesAndNewSpaces() throws {
        let apple = try section("apple")
        let lumen = try section("lumen")
        let changed = try section("user")
        let defaults: [String: Any] = ["Type": "individual", "Desktop": apple, "Idle": apple]
        let previous: [String: Any] = ["SystemDefault": defaults]
        let current: [String: Any] = ["SystemDefault": ["Type": "individual", "Desktop": changed, "Idle": lumen],
            "Spaces": ["new": ["Default": ["Type": "individual", "Desktop": lumen, "Idle": lumen]]]]
        let restored = try LockScreenVideoManager.restoringWallpaperSections(in: current, from: previous, assetID: "lumen")
        #expect(!LockScreenVideoManager.containsDesktopAsset("lumen", in: restored))
        #expect(LockScreenVideoManager.containsDesktopAsset("user", in: restored))
        #expect(LockScreenVideoManager.containsDesktopAsset("apple", in: restored))
    }

    @Test func allDisplaysCreatesAndRestoresMissingGlobalSelection() throws {
        let original: [String: Any] = ["Type": "individual", "Desktop": try section("apple"), "Idle": try section("apple")]
        let root: [String: Any] = ["SystemDefault": original,
            "Displays": ["internal": original], "Spaces": ["": ["Default": original]]]
        let configuration = try PropertyListSerialization.data(fromPropertyList: ["assetID": "lumen"], format: .binary, options: 0)
        let updated = try LockScreenVideoManager.selectingWallpaper(in: root, configuration: configuration,
            desktopOptions: Data(), idleOptions: Data(), targetDisplayIDs: ["internal"], allDisplays: true)
        let global = (updated as? [String: Any])?["AllSpacesAndDisplays"] as? [String: Any]
        #expect(global?["Type"] as? String == "linked")
        #expect(global?["Desktop"] != nil)
        #expect(global?["Idle"] != nil)
        #expect(LockScreenVideoManager.wallpaperSelectionMatches("lumen", in: global ?? [:]))
        #expect(LockScreenVideoManager.wallpaperSelectionMatches("lumen", in: updated, targetDisplayIDs: ["internal"], allDisplays: true))
        let restored = try LockScreenVideoManager.restoringWallpaperSections(in: updated, from: root, assetID: "lumen")
        #expect((restored as? [String: Any])?["AllSpacesAndDisplays"] == nil)
        #expect(!LockScreenVideoManager.containsDesktopAsset("lumen", in: restored))
        #expect(LockScreenVideoManager.containsDesktopAsset("apple", in: restored))
    }

    @Test func restoringOneScreenPreservesChangesOnAnother() throws {
        let original: [String: Any] = ["Type": "individual", "Desktop": try section("apple"), "Idle": try section("apple")]
        let root: [String: Any] = ["SystemDefault": original,
            "AllSpacesAndDisplays": ["Type": "linked", "Linked": try section("apple")],
            "Displays": ["internal": original, "external": original]]
        let data = try PropertyListSerialization.data(fromPropertyList: ["assetID": "lumen"], format: .binary, options: 0)
        var current = try #require(try LockScreenVideoManager.selectingWallpaper(in: root, configuration: data,
            desktopOptions: Data(), idleOptions: Data(), targetDisplayIDs: ["internal"], allDisplays: false) as? [String: Any])
        var displays = try #require(current["Displays"] as? [String: [String: Any]])
        displays["external"]?["Desktop"] = try section("user")
        current["Displays"] = displays
        let restored = try LockScreenVideoManager.restoringWallpaperSections(in: current, from: root, assetID: "lumen")
        #expect(LockScreenVideoManager.containsDesktopAsset("user", in: restored))
        #expect(!LockScreenVideoManager.containsDesktopAsset("lumen", in: restored))
        #expect((restored as? [String: Any])?["AllSpacesAndDisplays"] == nil)
    }

    @Test func corruptLibraryIsNeverOverwritten() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.json")
        #expect(try WallpaperLibrary.load(from: url).isEmpty)
        let corrupt = Data("invalid json".utf8)
        try corrupt.write(to: url)
        #expect(throws: (any Error).self) { try WallpaperLibrary.save([], to: url) }
        #expect(try Data(contentsOf: url) == corrupt)
    }

    @Test func videoPosterCacheSeparatesFilesAndInvalidatesEdits() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mov")
        try Data([1]).write(to: source)
        let first = VideoPosterCache.posterURL(for: source, in: root)
        try Data([1, 2]).write(to: source)
        #expect(VideoPosterCache.posterURL(for: source, in: root) != first)
        #expect(VideoPosterCache.posterURL(for: root.appendingPathComponent("other.mov"), in: root) != first)
    }

    @Test func temporalMetadataParserRejectsVideoPayloadAndTruncatedAtoms() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("video.mov")
        func atom(_ type: String, _ payload: Data) -> Data {
            var size = UInt32(payload.count + 8).bigEndian
            return withUnsafeBytes(of: &size) { Data($0) } + Data(type.utf8) + payload
        }
        let groups = atom("sgpd", Data(repeating: 0, count: 4) + Data("tscl".utf8))
            + atom("sgpd", Data(repeating: 0, count: 4) + Data("tsas".utf8))
        try atom("mdat", groups).write(to: url)
        #expect(try !AerialVideoPreparation.hasTemporalMetadata(at: url))
        try atom("moov", atom("trak", atom("mdia", atom("minf", atom("stbl", groups))))).write(to: url)
        #expect(try AerialVideoPreparation.hasTemporalMetadata(at: url))
        try Data([0, 0, 0, 100, 109, 111, 111, 118]).write(to: url)
        #expect(throws: CocoaError.self) { try AerialVideoPreparation.hasTemporalMetadata(at: url) }
    }

    @Test func videoConversionPreservesDurationAndOrientation() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mp4")
        let writer = try AVAssetWriter(outputURL: source, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64, AVVideoHeightKey: 48])
        let transform = CGAffineTransform(rotationAngle: .pi / 2)
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 48
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<24 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var pixel: CVPixelBuffer?
            #expect(CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &pixel) == kCVReturnSuccess)
            let buffer = try #require(pixel)
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(frame * 10), CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            #expect(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 12)))
        }
        writer.endSession(atSourceTime: CMTime(seconds: 2, preferredTimescale: 12))
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        let output = try await AerialVideoPreparation.prepare(source: source)
        defer { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let actualTransform = try await track.load(.preferredTransform)
        #expect(abs(duration.seconds - 2) < 0.1)
        #expect(abs(actualTransform.b - transform.b) < 0.001)
        #expect(try AerialVideoPreparation.hasTemporalMetadata(at: output))
        let copied = try await AerialVideoPreparation.prepare(source: output)
        defer { try? FileManager.default.removeItem(at: copied.deletingLastPathComponent()) }
        #expect(try Data(contentsOf: copied) == Data(contentsOf: output))
        let coordinator = VideoSurface.Coordinator(url: output, reducedQuality: false)
        for _ in 0..<100 where coordinator.player.currentItem == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        let item = try #require(coordinator.player.currentItem)
        coordinator.update(url: output, isPlaying: false, reducedQuality: true)
        #expect(coordinator.player.currentItem === item)
        #expect(item.preferredMaximumResolution == CGSize(width: 1280, height: 720))
        coordinator.update(url: output, isPlaying: false, reducedQuality: false)
        #expect(coordinator.player.currentItem === item)
        #expect(item.preferredMaximumResolution == .zero)
    }
}
