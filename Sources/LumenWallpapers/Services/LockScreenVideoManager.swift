import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class LockScreenVideoManager {
    private static let configuredVideoPathDefaultsKey = "lockScreenVideoSourcePath"
    private static let assetIDDefaultsKey = "lockScreenVideoAerialAssetID"
    private static let aerialProvider = "com.apple.wallpaper.choice.aerials"
    private static let categoryID = "4C554D45-4E00-4000-8000-000000000001"
    private static let subcategoryID = "4C554D45-4E00-4000-8000-000000000002"
    private static let categoryName = "Lumen"
    private static let shotIDPrefix = "LUMEN_"
    private static let previousStoreSuffix = ".before-lumen"

    static var isInstalled: Bool {
        guard let assetID = configuredAssetID,
              FileManager.default.fileExists(atPath: videoURL(for: assetID).path),
              FileManager.default.fileExists(atPath: thumbnailURL(for: assetID).path) else {
            return false
        }
        return manifestContainsAsset(assetID)
    }

    static var isSelected: Bool {
        guard let assetID = configuredAssetID else { return false }
        guard !wallpaperStoreURLs.isEmpty else { return false }
        return wallpaperStoreURLs.allSatisfy { url in
            guard let root = readPropertyList(at: url) else { return false }
            return wallpaperSelectionMatches(assetID, in: root)
        }
    }

    var hasStoredConfiguration: Bool {
        UserDefaults.standard.string(forKey: Self.configuredVideoPathDefaultsKey) != nil
    }

    func isConfigured(videoURL: URL) -> Bool {
        UserDefaults.standard.string(forKey: Self.configuredVideoPathDefaultsKey) == videoURL.path
            && Self.isInstalled
    }

    func installAndConfigure(videoURL: URL) throws {
        let selectionIsCurrent = isConfigured(videoURL: videoURL) && Self.isSelected
        if selectionIsCurrent, let assetID = Self.configuredAssetID, Self.hasCanonicalLumenAsset(assetID) { return }
        let previousAssetID = Self.configuredAssetID
        let previousSource = UserDefaults.standard.string(forKey: Self.configuredVideoPathDefaultsKey)
        let assetID = previousAssetID ?? UUID().uuidString.uppercased()
        let stores = Self.wallpaperStoreURLs
        do {
            try Self.withFileRollback(urls: [Self.manifestURL, Self.videoURL(for: assetID), Self.thumbnailURL(for: assetID)] + stores + stores.map(Self.previousStoreURL)) {
                try configure(videoURL: videoURL, assetID: assetID)
                try selectInstalledAsset()
            }
        } catch {
            UserDefaults.standard.set(previousAssetID, forKey: Self.assetIDDefaultsKey)
            UserDefaults.standard.set(previousSource, forKey: Self.configuredVideoPathDefaultsKey)
            Self.refreshWallpaperAgent()
            throw error
        }
    }

    private func configure(videoURL: URL, assetID: String) throws {
        guard FileManager.default.isReadableFile(atPath: videoURL.path) else {
            throw LockScreenVideoError.videoMissing
        }
        if isConfigured(videoURL: videoURL), let assetID = Self.configuredAssetID {
            if !Self.hasCanonicalLumenAsset(assetID) {
                try Self.registerAsset(assetID: assetID)
                NSWorkspace.shared.noteFileSystemChanged(Self.aerialsURL.path)
                Self.refreshWallpaperAgent()
            }
            return
        }

        try Self.prepareAerialDirectories()
        try Self.installVideo(from: videoURL, assetID: assetID)
        try Self.installThumbnail(from: videoURL, assetID: assetID)
        try Self.registerAsset(assetID: assetID)

        UserDefaults.standard.set(assetID, forKey: Self.assetIDDefaultsKey)
        UserDefaults.standard.set(videoURL.path, forKey: Self.configuredVideoPathDefaultsKey)
        NSWorkspace.shared.noteFileSystemChanged(Self.aerialsURL.path)
        Self.refreshWallpaperAgent()
    }

    static func withFileRollback(urls: [URL], operation: () throws -> Void) throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("LumenRollback-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        var snapshots: [(URL, URL?)] = []
        var preserveBackup = false
        defer { if !preserveBackup { try? manager.removeItem(at: directory) } }
        for (index, url) in urls.enumerated() {
            if manager.fileExists(atPath: url.path) {
                let backup = directory.appendingPathComponent(String(index))
                try manager.copyItem(at: url, to: backup)
                snapshots.append((url, backup))
            } else {
                snapshots.append((url, nil))
            }
        }
        do { try operation() }
        catch {
            for (url, backup) in snapshots {
                do {
                    if let backup {
                        if manager.fileExists(atPath: url.path) {
                            _ = try manager.replaceItemAt(url, withItemAt: backup)
                        } else {
                            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                            try manager.moveItem(at: backup, to: url)
                        }
                    } else if manager.fileExists(atPath: url.path) {
                        try manager.removeItem(at: url)
                    }
                } catch {
                    preserveBackup = true
                    NSLog("Could not restore wallpaper file %@; recovery files are in %@: %@", url.path, directory.path, error.localizedDescription)
                }
            }
            throw error
        }
    }

    private func selectInstalledAsset() throws {
        guard let assetID = Self.configuredAssetID else {
            throw LockScreenVideoError.registrationFailed
        }
        try Self.backUpWallpaperStoreIfNeeded()
        let configuration = try Self.binaryPropertyList(["assetID": assetID])
        let desktopOptions = try Self.binaryPropertyList([
            "values": [
                "aerialShuffleFrequency": [
                    "picker": ["_0": ["id": "shuffle_every_12_hours"]]
                ]
            ]
        ])
        let idleOptions = try Self.binaryPropertyList([
            "values": [
                "appearance": ["picker": ["_0": ["id": "automatic"]]]
            ]
        ])
        var selectedInPrimaryStore = false
        for storeURL in Self.wallpaperStoreURLs {
            guard let root = Self.readPropertyList(at: storeURL) else {
                throw LockScreenVideoError.wallpaperStoreMissing
            }
            let updated = Self.replacingWallpaperSections(
                in: root,
                configuration: configuration,
                desktopOptions: desktopOptions,
                idleOptions: idleOptions
            )
            try Self.writePropertyList(updated, to: storeURL)
            if storeURL == Self.wallpaperStoreURL {
                selectedInPrimaryStore = Self.wallpaperSelectionMatches(assetID, in: updated)
            }
        }
        Self.refreshWallpaperAgent()

        guard selectedInPrimaryStore else {
            throw LockScreenVideoError.selectionFailed
        }
    }

    func restorePreviousWallpaper() throws {
        let fileManager = FileManager.default
        for storeURL in Self.wallpaperStoreURLs {
            let backupURL = Self.previousStoreURL(for: storeURL)
            if let assetID = Self.configuredAssetID,
               let current = Self.readPropertyList(at: storeURL),
               Self.containsSelectedAsset(assetID, in: current) {
                guard let previous = Self.readPropertyList(at: backupURL) else {
                    throw LockScreenVideoError.invalidBackup
                }
                let restored = try Self.restoringWallpaperSections(in: current, from: previous, assetID: assetID)
                try Self.writePropertyList(restored, to: storeURL)
            }
            if fileManager.fileExists(atPath: backupURL.path) {
                try fileManager.removeItem(at: backupURL)
            }
        }

        if let assetID = Self.configuredAssetID {
            try Self.unregisterAsset(assetID)
            for url in [Self.videoURL(for: assetID), Self.thumbnailURL(for: assetID)]
                where fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }

        UserDefaults.standard.removeObject(forKey: Self.configuredVideoPathDefaultsKey)
        NSWorkspace.shared.noteFileSystemChanged(Self.aerialsURL.path)
        Self.refreshWallpaperAgent()
    }

    private static var applicationSupportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    private static var aerialsURL: URL {
        applicationSupportURL.appendingPathComponent("com.apple.wallpaper/aerials", isDirectory: true)
    }

    private static var manifestURL: URL {
        aerialsURL.appendingPathComponent("manifest/entries.json")
    }

    private static var videosURL: URL {
        aerialsURL.appendingPathComponent("videos", isDirectory: true)
    }

    private static var thumbnailsURL: URL {
        aerialsURL.appendingPathComponent("thumbnails", isDirectory: true)
    }

    private static var wallpaperStoreURL: URL {
        applicationSupportURL.appendingPathComponent("com.apple.wallpaper/Store/Index.plist")
    }

    private static var wallpaperStoreURLs: [URL] {
        let directory = wallpaperStoreURL.deletingLastPathComponent()
        return [
            wallpaperStoreURL,
            directory.appendingPathComponent("Index_v2.plist")
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static var previousStoreDirectoryURL: URL {
        applicationSupportURL
            .appendingPathComponent("LumenWallpapers/WallpaperStoreBackup", isDirectory: true)
    }

    private static func previousStoreURL(for storeURL: URL) -> URL {
        previousStoreDirectoryURL.appendingPathComponent(storeURL.lastPathComponent + previousStoreSuffix)
    }

    private static var configuredAssetID: String? {
        UserDefaults.standard.string(forKey: assetIDDefaultsKey)
    }

    private static func videoURL(for assetID: String) -> URL {
        videosURL.appendingPathComponent("\(assetID).mov")
    }

    private static func thumbnailURL(for assetID: String) -> URL {
        thumbnailsURL.appendingPathComponent("\(assetID).png")
    }

    private static func prepareAerialDirectories() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw LockScreenVideoError.aerialManifestMissing
        }
        try fileManager.createDirectory(at: videosURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: thumbnailsURL, withIntermediateDirectories: true)
    }

    private static func installVideo(from source: URL, assetID: String) throws {
        let fileManager = FileManager.default
        let destination = videoURL(for: assetID)
        let staging = videosURL.appendingPathComponent(".\(assetID)-\(UUID().uuidString).mov")
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.copyItem(at: source, to: staging)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: staging, to: destination)
    }

    private static func installThumbnail(from videoURL: URL, assetID: String) throws {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1600, height: 1000)
        let image: CGImage
        do {
            image = try generator.copyCGImage(at: CMTime(seconds: 0.2, preferredTimescale: 600), actualTime: nil)
        } catch {
            do {
                image = try generator.copyCGImage(at: .zero, actualTime: nil)
            } catch {
                throw LockScreenVideoError.thumbnailFailed(error.localizedDescription)
            }
        }

        let destination = thumbnailURL(for: assetID)
        let staging = thumbnailsURL.appendingPathComponent(".\(assetID)-\(UUID().uuidString).png")
        guard let writer = CGImageDestinationCreateWithURL(
            staging as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw LockScreenVideoError.thumbnailFailed("Could not create the PNG preview.")
        }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer) else {
            throw LockScreenVideoError.thumbnailFailed("Could not write the PNG preview.")
        }

        let fileManager = FileManager.default
        defer { try? fileManager.removeItem(at: staging) }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: staging, to: destination)
    }

    private static func registerAsset(assetID: String) throws {
        guard let data = try? Data(contentsOf: manifestURL),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var assets = root["assets"] as? [[String: Any]],
              var categories = root["categories"] as? [[String: Any]] else {
            throw LockScreenVideoError.invalidManifest
        }

        assets.removeAll { item in
            item["id"] as? String == assetID
                || (item["shotID"] as? String)?.hasPrefix(shotIDPrefix) == true
        }
        categories.removeAll { item in
            guard let id = item["id"] as? String else { return false }
            return id == categoryID || id == subcategoryID
        }

        let suffix = String(assetID.replacingOccurrences(of: "-", with: "").suffix(8))
        let previewURL = thumbnailURL(for: assetID).absoluteString
        assets.append([
            "accessibilityLabel": categoryName,
            "categories": [categoryID],
            "id": assetID,
            "includeInShuffle": false,
            "localizedNameKey": categoryName,
            "pointsOfInterest": ["0": "\(shotIDPrefix)\(suffix)_0"],
            "preferredOrder": 0,
            "previewImage": previewURL,
            "shotID": "\(shotIDPrefix)\(suffix)",
            "showInTopLevel": true,
            "subcategories": [subcategoryID],
            "url-4K-SDR-240FPS": videoURL(for: assetID).absoluteString,
            "videoGravity": "resize"
        ])
        categories.append([
            "id": categoryID,
            "localizedDescriptionKey": categoryName,
            "localizedNameKey": categoryName,
            "preferredOrder": 0,
            "previewImage": previewURL,
            "representativeAssetID": assetID,
            "subcategories": [[
                "id": subcategoryID,
                "localizedDescriptionKey": categoryName,
                "localizedNameKey": categoryName,
                "preferredOrder": 0,
                "previewImage": previewURL,
                "representativeAssetID": assetID
            ]]
        ])
        root["assets"] = assets
        root["categories"] = categories

        let updated = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try updated.write(to: manifestURL, options: .atomic)
    }

    private static func unregisterAsset(_ assetID: String) throws {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return }
        guard let data = try? Data(contentsOf: manifestURL),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var assets = root["assets"] as? [[String: Any]],
              var categories = root["categories"] as? [[String: Any]] else {
            throw LockScreenVideoError.invalidManifest
        }
        assets.removeAll { item in
            item["id"] as? String == assetID
                || (item["shotID"] as? String)?.hasPrefix(shotIDPrefix) == true
        }
        categories.removeAll { item in
            guard let id = item["id"] as? String else { return false }
            return id == categoryID || id == subcategoryID
        }
        root["assets"] = assets
        root["categories"] = categories
        let updated = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try updated.write(to: manifestURL, options: .atomic)
    }

    private static func manifestContainsAsset(_ assetID: String) -> Bool {
        guard let data = try? Data(contentsOf: manifestURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = root["assets"] as? [[String: Any]] else { return false }
        return assets.contains { $0["id"] as? String == assetID }
    }

    private static func hasCanonicalLumenAsset(_ assetID: String) -> Bool {
        guard let data = try? Data(contentsOf: manifestURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = root["assets"] as? [[String: Any]],
              let categories = root["categories"] as? [[String: Any]] else { return false }
        let lumenAssets = assets.filter {
            $0["id"] as? String == assetID
                || ($0["shotID"] as? String)?.hasPrefix(shotIDPrefix) == true
        }
        let lumenCategories = categories.filter {
            let id = $0["id"] as? String
            return id == categoryID || id == subcategoryID
        }
        return lumenAssets.count == 1
            && lumenCategories.count == 1
            && lumenAssets[0]["id"] as? String == assetID
            && lumenAssets[0]["localizedNameKey"] as? String == categoryName
            && lumenAssets[0]["accessibilityLabel"] as? String == categoryName
    }

    private static func backUpWallpaperStoreIfNeeded() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: wallpaperStoreURL.path) else {
            throw LockScreenVideoError.wallpaperStoreMissing
        }
        try fileManager.createDirectory(
            at: previousStoreDirectoryURL,
            withIntermediateDirectories: true
        )
        for storeURL in wallpaperStoreURLs {
            let backupURL = previousStoreURL(for: storeURL)
            guard !fileManager.fileExists(atPath: backupURL.path) else { continue }
            try fileManager.copyItem(at: storeURL, to: backupURL)
        }
    }

    static func replacingWallpaperSections(
        in value: Any,
        configuration: Data,
        desktopOptions: Data,
        idleOptions: Data
    ) -> Any {
        if let dictionary = value as? [String: Any] {
            var updated = dictionary
            for (key, child) in dictionary {
                if (key == "Desktop" || key == "Idle"), var section = child as? [String: Any], section["Content"] != nil {
                    let options = key == "Desktop" ? desktopOptions : idleOptions
                    section["Content"] = [
                        "Choices": [[
                            "Configuration": configuration,
                            "Files": [],
                            "Provider": aerialProvider
                        ]],
                        "EncodedOptionValues": options,
                        "Shuffle": "$null"
                    ]
                    section["LastSet"] = Date()
                    section["LastUse"] = Date()
                    updated[key] = section
                } else {
                    updated[key] = replacingWallpaperSections(
                        in: child,
                        configuration: configuration,
                        desktopOptions: desktopOptions,
                        idleOptions: idleOptions
                    )
                }
            }
            return updated
        }
        if let array = value as? [Any] {
            return array.map {
                replacingWallpaperSections(
                    in: $0,
                    configuration: configuration,
                    desktopOptions: desktopOptions,
                    idleOptions: idleOptions
                )
            }
        }
        return value
    }

    static func restoringWallpaperSections(in value: Any, from backup: Any?, assetID: String, fallback: [String: Any]? = nil) throws -> Any {
        if let dictionary = value as? [String: Any] {
            let previous = backup as? [String: Any]
            let defaults = fallback ?? previous?["SystemDefault"] as? [String: Any]
            var updated = dictionary
            for (key, child) in dictionary {
                if (key == "Desktop" || key == "Idle"), containsSelectedAsset(assetID, in: child) {
                    guard let original = previous?[key] ?? defaults?[key], !containsSelectedAsset(assetID, in: original) else {
                        throw LockScreenVideoError.invalidBackup
                    }
                    updated[key] = original
                } else {
                    updated[key] = try restoringWallpaperSections(in: child, from: previous?[key], assetID: assetID, fallback: defaults)
                }
            }
            return updated
        }
        if let array = value as? [Any] {
            let previous = backup as? [Any] ?? []
            return try array.enumerated().map { index, child in
                try restoringWallpaperSections(in: child, from: previous.indices.contains(index) ? previous[index] : nil, assetID: assetID, fallback: fallback)
            }
        }
        return value
    }

    static func containsDesktopAsset(_ assetID: String, in value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            return dictionary.contains { key, child in
                key == "Desktop" ? containsSelectedAsset(assetID, in: child) : containsDesktopAsset(assetID, in: child)
            }
        }
        if let array = value as? [Any] {
            return array.contains { containsDesktopAsset(assetID, in: $0) }
        }
        return false
    }

    static func wallpaperSelectionMatches(_ assetID: String, in value: Any) -> Bool {
        var desktopFound = false
        var idleFound = false
        func matches(_ value: Any) -> Bool {
            if let dictionary = value as? [String: Any] {
                for (key, child) in dictionary {
                    if (key == "Desktop" || key == "Idle"), let section = child as? [String: Any], section["Content"] != nil {
                        if key == "Desktop" { desktopFound = true } else { idleFound = true }
                        if !containsSelectedAsset(assetID, in: child) { return false }
                    } else if !matches(child) { return false }
                }
            } else if let array = value as? [Any] {
                return array.allSatisfy(matches)
            }
            return true
        }
        return matches(value) && desktopFound && idleFound
    }

    private static func containsSelectedAsset(_ assetID: String, in value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            if dictionary["Provider"] as? String == aerialProvider,
               let configuration = dictionary["Configuration"] as? Data,
               configurationAssetID(configuration) == assetID {
                return true
            }
            return dictionary.values.contains { containsSelectedAsset(assetID, in: $0) }
        }
        if let array = value as? [Any] {
            return array.contains { containsSelectedAsset(assetID, in: $0) }
        }
        return false
    }

    private static func configurationAssetID(_ data: Data) -> String? {
        guard let propertyList = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let configuration = propertyList as? [String: Any] else { return nil }
        return configuration["assetID"] as? String
    }

    private static func readPropertyList(at url: URL) -> Any? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil)
    }

    private static func writePropertyList(_ value: Any, to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        try data.write(to: url, options: .atomic)
    }

    private static func binaryPropertyList(_ value: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }

    private static func refreshWallpaperAgent() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["WallpaperAgent"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // WallpaperAgent will notice the catalog change on its next refresh.
        }
    }
}

private enum LockScreenVideoError: LocalizedError {
    case videoMissing
    case aerialManifestMissing
    case invalidManifest
    case wallpaperStoreMissing
    case invalidBackup
    case registrationFailed
    case selectionFailed
    case thumbnailFailed(String)

    var errorDescription: String? {
        switch self {
        case .videoMissing: "The selected video file is unavailable."
        case .aerialManifestMissing: "Open System Settings > Wallpaper once so macOS can initialize its video wallpaper catalog, then try again."
        case .invalidManifest: "The macOS video wallpaper catalog could not be read."
        case .wallpaperStoreMissing: "The macOS wallpaper selection store could not be found."
        case .invalidBackup: "The previous wallpaper selection backup is invalid."
        case .registrationFailed: "The Lumen video wallpaper was not registered."
        case .selectionFailed: "macOS did not select the Lumen video wallpaper."
        case .thumbnailFailed(let message): "Could not create the wallpaper preview: \(message)"
        }
    }
}
