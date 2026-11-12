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
            && (!usesLocalCatalog || (aerialPreferences()[localPathKey] as? String == manifestURL.path
                && aerialPreferences()[forceLocalKey] as? Bool == true))
    }

    static var isSelected: Bool {
        guard let assetID = configuredAssetID else { return false }
        guard !wallpaperStoreURLs.isEmpty else { return false }
        let display = UserDefaults.standard.string(forKey: "selectedDisplay") ?? "Built-in Display"
        let targets = Set(DesktopWallpaperController.targetScreens(for: display).compactMap(\.wallpaperDisplayUUID))
        return !targets.isEmpty && wallpaperStoreURLs.allSatisfy { url in
            guard let root = readPropertyList(at: url) else { return false }
            let allDisplays = display == "All Displays" || targets == Set(NSScreen.screens.compactMap(\.wallpaperDisplayUUID))
            return wallpaperSelectionMatches(assetID, in: root, targetDisplayIDs: targets, allDisplays: allDisplays)
        }
    }

    var hasStoredConfiguration: Bool {
        UserDefaults.standard.string(forKey: Self.configuredVideoPathDefaultsKey) != nil
    }

    func isConfigured(videoURL: URL) -> Bool {
        UserDefaults.standard.string(forKey: Self.configuredVideoPathDefaultsKey) == videoURL.path
            && Self.isInstalled
    }

    private var preparationTask: Task<URL, Error>?
    private var requestID = UUID()

    func cancelPendingInstallation() {
        preparationTask?.cancel()
        requestID = UUID()
    }

    static var isAvailable: Bool {
        !wallpaperStoreURLs.isEmpty && FileManager.default.isReadableFile(atPath: catalogBaseURL.path)
    }

    func installAndConfigure(videoURL: URL, display: String) async throws {
        try Task.checkCancellation()
        preparationTask?.cancel()
        requestID = UUID()
        let id = requestID
        let targets = Set(DesktopWallpaperController.targetScreens(for: display).compactMap(\.wallpaperDisplayUUID))
        guard !targets.isEmpty else { throw LockScreenVideoError.displayMissing }
        let allDisplays = display == "All Displays"
            || targets == Set(NSScreen.screens.compactMap(\.wallpaperDisplayUUID))
        let previousAssetID = Self.configuredAssetID
        let previousSource = UserDefaults.standard.string(forKey: Self.configuredVideoPathDefaultsKey)
        let assetID = previousAssetID ?? UUID().uuidString.uppercased()
        let alreadyPrepared = isConfigured(videoURL: videoURL)
        if alreadyPrepared, Self.hasCanonicalLumenAsset(assetID),
           (!Self.usesLocalCatalog || (try? Data(contentsOf: Self.catalogBaseURL)) == (try? Data(contentsOf: Self.appleCatalogBackupURL))),
           Self.wallpaperStoreURLs.allSatisfy({ url in
               guard let root = Self.readPropertyList(at: url) else { return false }
               return Self.wallpaperSelectionMatches(assetID, in: root, targetDisplayIDs: targets, allDisplays: allDisplays)
           }) { return }
        let prepared: URL?
        if alreadyPrepared {
            prepared = nil
        } else {
            let task = Task.detached(priority: .userInitiated) {
                try await AerialVideoPreparation.prepare(source: videoURL)
            }
            preparationTask = task
            prepared = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
        }
        defer { if let prepared { try? FileManager.default.removeItem(at: prepared.deletingLastPathComponent()) } }
        try Task.checkCancellation()
        guard id == requestID else { throw CancellationError() }
        let stores = Self.wallpaperStoreURLs
        do {
            try Self.withPreferenceRollback {
                try Self.withFileRollback(urls: Self.registrationFiles(assetID: assetID, stores: stores)) {
                    try Self.prepareAerialDirectories()
                    if let prepared {
                        try Self.installVideo(from: prepared, assetID: assetID)
                        try Self.installThumbnail(from: prepared, assetID: assetID)
                    }
                    try Self.registerAsset(assetID: assetID)
                    try Self.enableLocalCatalogIfNeeded()
                    try selectInstalledAsset(assetID: assetID, targets: targets, allDisplays: allDisplays)
                    UserDefaults.standard.set(assetID, forKey: Self.assetIDDefaultsKey)
                    UserDefaults.standard.set(videoURL.path, forKey: Self.configuredVideoPathDefaultsKey)
                }
            }
        } catch {
            UserDefaults.standard.set(previousAssetID, forKey: Self.assetIDDefaultsKey)
            UserDefaults.standard.set(previousSource, forKey: Self.configuredVideoPathDefaultsKey)
            Self.refreshWallpaperAgent()
            throw error
        }
        NSWorkspace.shared.noteFileSystemChanged(Self.aerialsURL.path)
        Self.refreshWallpaperAgent()
    }

    private static func registrationFiles(assetID: String, stores: [URL]) -> [URL] {
        Array(Set([manifestURL, legacyManifestURL, appleCatalogBackupURL, preferenceBackupURL,
                   videoURL(for: assetID), thumbnailURL(for: assetID)] + stores + stores.map(previousStoreURL)))
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

    private func selectInstalledAsset(assetID: String, targets: Set<String>, allDisplays: Bool) throws {
        try Self.backUpWallpaperStoreIfNeeded()
        let configuration = try Self.binaryPropertyList(["assetID": assetID])
        let desktopOptions = try Self.binaryPropertyList(["values": [
            "aerialShuffleFrequency": ["picker": ["_0": ["id": "shuffle_every_12_hours"]]]
        ]])
        let idleOptions = try Self.binaryPropertyList(["values": [
            "appearance": ["picker": ["_0": ["id": "automatic"]]]
        ]])
        for storeURL in Self.wallpaperStoreURLs {
            guard let root = Self.readPropertyList(at: storeURL) else { throw LockScreenVideoError.wallpaperStoreMissing }
            let restored: Any
            if let previous = Self.readPropertyList(at: Self.previousStoreURL(for: storeURL)),
               Self.containsSelectedAsset(assetID, in: root) {
                restored = try Self.restoringWallpaperSections(in: root, from: previous, assetID: assetID)
            } else { restored = root }
            let updated = try Self.selectingWallpaper(in: restored, configuration: configuration,
                desktopOptions: desktopOptions, idleOptions: idleOptions,
                targetDisplayIDs: targets, allDisplays: allDisplays)
            guard Self.wallpaperSelectionMatches(assetID, in: updated, targetDisplayIDs: targets, allDisplays: allDisplays) else {
                throw LockScreenVideoError.selectionFailed
            }
            try Self.writePropertyList(updated, to: storeURL)
        }
    }

    func restorePreviousWallpaper() throws {
        preparationTask?.cancel()
        requestID = UUID()
        guard let assetID = Self.configuredAssetID else { return }
        let stores = Self.restorationStoreURLs
        try Self.withPreferenceRollback {
            try Self.withFileRollback(urls: Self.registrationFiles(assetID: assetID, stores: stores)) {
                for storeURL in stores {
                    guard let current = Self.readPropertyList(at: storeURL) else { throw LockScreenVideoError.wallpaperStoreMissing }
                    if Self.containsSelectedAsset(assetID, in: current) {
                        guard let previous = Self.readPropertyList(at: Self.previousStoreURL(for: storeURL)) else {
                            throw LockScreenVideoError.invalidBackup
                        }
                        let restored = try Self.restoringWallpaperSections(in: current, from: previous, assetID: assetID)
                        try Self.writePropertyList(restored, to: storeURL)
                    }
                }
                try Self.unregisterAsset(assetID, at: Self.manifestURL)
                if Self.manifestURL != Self.legacyManifestURL { try Self.unregisterAsset(assetID, at: Self.legacyManifestURL) }
                try Self.restoreLocalCatalogPreferences()
                let files = [Self.videoURL(for: assetID), Self.thumbnailURL(for: assetID), Self.preferenceBackupURL]
                    + stores.map(Self.previousStoreURL)
                for url in files where FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
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

    private static var legacyManifestURL: URL { aerialsURL.appendingPathComponent("manifest/entries.json") }
    private static var usesLocalCatalog: Bool { ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 }
    private static var manifestURL: URL {
        usesLocalCatalog ? aerialsURL.appendingPathComponent("custom/Lumen/entries.json") : legacyManifestURL
    }
    private static var catalogBaseURL: URL {
        usesLocalCatalog
            ? URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions/WallpaperAerialsExtension.appex/Contents/Resources/entries.json")
            : legacyManifestURL
    }
    private static var appleCatalogBackupURL: URL { previousStoreDirectoryURL.appendingPathComponent("AppleCatalog.json") }
    private static var preferenceBackupURL: URL { previousStoreDirectoryURL.appendingPathComponent("AerialPreferences.plist") }
    private static let aerialPreferenceDomain = "com.apple.wallpaper.aerial"
    private static let localPathKey = "AerialManifestLocalPathOverride"
    private static let forceLocalKey = "AerialManifestForceLocal"


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
        selectionStoreURLs(in: wallpaperStoreURL.deletingLastPathComponent())
    }

    static func selectionStoreURLs(in directory: URL) -> [URL] {
        let legacy = directory.appendingPathComponent("Index.plist")
        let current = directory.appendingPathComponent("Index_v2.plist")
        // WallpaperAgent still reads the legacy index when content migration is disabled.
        return [legacy, current].filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static var restorationStoreURLs: [URL] {
        let directory = wallpaperStoreURL.deletingLastPathComponent()
        return [wallpaperStoreURL, directory.appendingPathComponent("Index_v2.plist")].filter {
            FileManager.default.fileExists(atPath: $0.path) || FileManager.default.fileExists(atPath: previousStoreURL(for: $0).path)
        }
    }

    private static var previousStoreDirectoryURL: URL {
        applicationSupportURL
            .appendingPathComponent("LumenWallpapers/WallpaperStoreBackup", isDirectory: true)
    }

    private static func previousStoreURL(for storeURL: URL) -> URL {
        previousStoreDirectoryURL.appendingPathComponent(storeURL.lastPathComponent + previousStoreSuffix)
    }

    private static var configuredAssetID: String? {
        UserDefaults.standard.string(forKey: assetIDDefaultsKey).flatMap { UUID(uuidString: $0)?.uuidString }
    }

    private static func videoURL(for assetID: String) -> URL {
        videosURL.appendingPathComponent("\(assetID).mov")
    }

    private static func thumbnailURL(for assetID: String) -> URL {
        thumbnailsURL.appendingPathComponent("\(assetID).png")
    }

    private static func prepareAerialDirectories() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: catalogBaseURL.path) else {
            throw LockScreenVideoError.aerialManifestMissing
        }
        try fileManager.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: previousStoreDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: videosURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: thumbnailsURL, withIntermediateDirectories: true)
    }

    private static func installVideo(from source: URL, assetID: String) throws {
        let fileManager = FileManager.default
        let destination = videoURL(for: assetID)
        let staging = videosURL.appendingPathComponent(".\(assetID)-\(UUID().uuidString).mov")
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.moveItem(at: source, to: staging)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: staging, to: destination)
    }

    private static func installThumbnail(from videoURL: URL, assetID: String) throws {
        let destination = thumbnailURL(for: assetID)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.copyItem(at: videoURL.deletingLastPathComponent().appendingPathComponent("preview.png"), to: destination)
    }

    private static func registerAsset(assetID: String) throws {
        var root: [String: Any]
        if usesLocalCatalog {
            let apple = try readManifest(at: catalogBaseURL)
            let oldApple = FileManager.default.fileExists(atPath: appleCatalogBackupURL.path) ? try readManifest(at: appleCatalogBackupURL) : nil
            let customURL: URL
            if FileManager.default.fileExists(atPath: manifestURL.path) { customURL = manifestURL }
            else if let path = aerialPreferences()[localPathKey] as? String, FileManager.default.fileExists(atPath: path) {
                customURL = URL(fileURLWithPath: path)
            } else { customURL = legacyManifestURL }
            let custom = FileManager.default.fileExists(atPath: customURL.path) ? try readManifest(at: customURL) : apple
            root = rebasingManifest(apple: apple, previousApple: oldApple ?? apple, custom: custom)
            try Data(contentsOf: catalogBaseURL).write(to: appleCatalogBackupURL, options: .atomic)
        } else { root = try readManifest(at: manifestURL) }
        guard var assets = root["assets"] as? [[String: Any]],
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

    private static func unregisterAsset(_ assetID: String, at manifestURL: URL) throws {
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

    private static func readManifest(at url: URL) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              root["assets"] is [[String: Any]], root["categories"] is [[String: Any]] else {
            throw LockScreenVideoError.invalidManifest
        }
        return root
    }

    static func rebasingManifest(apple: [String: Any], previousApple: [String: Any], custom: [String: Any]) -> [String: Any] {
        var result = apple
        for key in ["assets", "categories"] {
            let baseline = previousApple[key] as? [[String: Any]] ?? []
            var items = apple[key] as? [[String: Any]] ?? []
            for item in custom[key] as? [[String: Any]] ?? [] {
                guard let id = item["id"] as? String else { continue }
                let original = baseline.first { $0["id"] as? String == id }
                if let original, NSDictionary(dictionary: original).isEqual(to: item) { continue }
                items.removeAll { $0["id"] as? String == id }
                items.append(item)
            }
            result[key] = items
        }
        return result
    }

    private static func aerialPreferences(domain: String = aerialPreferenceDomain) -> [String: Any] {
        var values: [String: Any] = [:]
        for key in [localPathKey, forceLocalKey] {
            values[key] = CFPreferencesCopyValue(key as CFString, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
        return values
    }

    private static func writeAerialPreferences(_ values: [String: Any], domain: String = aerialPreferenceDomain) throws {
        for key in [localPathKey, forceLocalKey] {
            CFPreferencesSetValue(key as CFString, values[key] as CFPropertyList?, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
        guard CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw LockScreenVideoError.preferencesFailed
        }
    }

    static func withPreferenceRollback(domain: String = aerialPreferenceDomain, operation: () throws -> Void) throws {
        let previous = aerialPreferences(domain: domain)
        do { try operation() }
        catch {
            do { try writeAerialPreferences(previous, domain: domain) }
            catch { NSLog("Could not restore aerial preferences: %@", error.localizedDescription) }
            throw error
        }
    }

    private static func enableLocalCatalogIfNeeded() throws {
        guard usesLocalCatalog else { return }
        if !FileManager.default.fileExists(atPath: preferenceBackupURL.path) {
            try writePropertyList(aerialPreferences(), to: preferenceBackupURL)
        }
        try writeAerialPreferences([localPathKey: manifestURL.path, forceLocalKey: true])
    }

    static func restoredAerialPreferences(current: [String: Any], previous: [String: Any], catalogPath: String) -> [String: Any] {
        guard current[localPathKey] as? String == catalogPath else { return current }
        var result = current
        for key in [localPathKey, forceLocalKey] { result[key] = previous[key] }
        return result
    }

    private static func restoreLocalCatalogPreferences() throws {
        guard FileManager.default.fileExists(atPath: preferenceBackupURL.path) else { return }
        guard let previous = readPropertyList(at: preferenceBackupURL) as? [String: Any] else { throw LockScreenVideoError.invalidBackup }
        try writeAerialPreferences(restoredAerialPreferences(current: aerialPreferences(), previous: previous, catalogPath: manifestURL.path))
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
        guard !wallpaperStoreURLs.isEmpty else {
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

    static func selectingWallpaper(
        in value: Any, configuration: Data, desktopOptions: Data, idleOptions: Data,
        targetDisplayIDs: Set<String>, allDisplays: Bool
    ) throws -> Any {
        guard var root = value as? [String: Any], let defaults = root["SystemDefault"] as? [String: Any] else {
            throw LockScreenVideoError.wallpaperStoreMissing
        }
        if allDisplays {
            root = replacingWallpaperSections(in: root, configuration: configuration,
                desktopOptions: desktopOptions, idleOptions: idleOptions) as! [String: Any]
            guard var selectedDefaults = root["SystemDefault"] as? [String: Any],
                  let desktop = selectedDefaults["Desktop"] else { throw LockScreenVideoError.wallpaperStoreMissing }
            selectedDefaults["Type"] = "linked"
            selectedDefaults["Linked"] = desktop
            root["AllSpacesAndDisplays"] = selectedDefaults
            return root
        }
        func updateDisplays(_ container: [String: Any]) -> [String: Any] {
            var container = container
            var displays = container["Displays"] as? [String: Any] ?? [:]
            for id in targetDisplayIDs {
                displays[id] = replacingWallpaperSections(in: displays[id] ?? defaults,
                    configuration: configuration, desktopOptions: desktopOptions, idleOptions: idleOptions)
            }
            container["Displays"] = displays
            return container
        }
        root = updateDisplays(root)
        if var spaces = root["Spaces"] as? [String: Any] {
            for (id, space) in spaces {
                if let space = space as? [String: Any] { spaces[id] = updateDisplays(space) }
            }
            root["Spaces"] = spaces
        }
        root.removeValue(forKey: "AllSpacesAndDisplays")
        return root
    }

    static func replacingWallpaperSections(
        in value: Any,
        configuration: Data,
        desktopOptions: Data,
        idleOptions: Data
    ) -> Any {
        if let dictionary = value as? [String: Any] {
            var updated = dictionary
            if dictionary["Type"] != nil,
               let template = dictionary["Desktop"] ?? dictionary["Idle"] ?? dictionary["Linked"] {
                updated["Type"] = "individual"
                updated["Desktop"] = dictionary["Desktop"] ?? template
                updated["Idle"] = dictionary["Idle"] ?? template
            }
            for (key, child) in updated {
                if ["Desktop", "Idle", "Linked"].contains(key), var section = child as? [String: Any], section["Content"] != nil {
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
            let sections = ["Desktop", "Idle", "Linked"].compactMap { dictionary[$0] }
            if !sections.isEmpty, sections.allSatisfy({ containsSelectedAsset(assetID, in: $0) }) {
                updated["Type"] = previous?["Type"] ?? defaults?["Type"]
            } else if dictionary["Type"] as? String == "individual", let previous,
                      ["Desktop", "Idle", "Linked"].allSatisfy({ key in
                          let current = (dictionary[key] as? [String: Any])?["Content"] as? [String: Any] ?? [:]
                          let original = (previous[key] as? [String: Any])?["Content"] as? [String: Any] ?? [:]
                          return NSDictionary(dictionary: current).isEqual(to: original)
                      }) {
                updated["Type"] = previous["Type"]
            }
            for (key, child) in dictionary {
                if key == "Type" { continue }
                if key == "AllSpacesAndDisplays", let previous, previous[key] == nil,
                   wallpaperSelectionMatches(assetID, in: child) {
                    updated.removeValue(forKey: key)
                    continue
                }
                if ["Desktop", "Idle", "Linked"].contains(key), containsSelectedAsset(assetID, in: child) {
                    if let previous, previous[key] == nil {
                        updated.removeValue(forKey: key)
                        continue
                    }
                    guard let original = previous?[key] ?? defaults?[key] ?? defaults?["Linked"] ?? defaults?["Desktop"], !containsSelectedAsset(assetID, in: original) else {
                        throw LockScreenVideoError.invalidBackup
                    }
                    updated[key] = original
                } else {
                    updated[key] = try restoringWallpaperSections(in: child, from: previous?[key], assetID: assetID, fallback: defaults)
                }
            }
            if dictionary["SystemDefault"] != nil, dictionary["AllSpacesAndDisplays"] == nil,
               let global = previous?["AllSpacesAndDisplays"], containsSelectedAsset(assetID, in: dictionary),
               !hasUnrelatedChoiceChanges(in: dictionary, from: previous, assetID: assetID, fallback: defaults) {
                updated["AllSpacesAndDisplays"] = global
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

    private static func hasUnrelatedChoiceChanges(in value: Any, from backup: Any?, assetID: String, fallback: [String: Any]?) -> Bool {
        if let dictionary = value as? [String: Any] {
            let previous = backup as? [String: Any]
            for (key, child) in dictionary {
                if ["Desktop", "Idle", "Linked"].contains(key) {
                    guard !containsSelectedAsset(assetID, in: child), let section = child as? [String: Any] else { continue }
                    let original = (previous?[key] ?? fallback?[key] ?? fallback?["Linked"]) as? [String: Any]
                    let content = section["Content"] as? [String: Any] ?? [:]
                    let oldContent = original?["Content"] as? [String: Any] ?? [:]
                    if !NSDictionary(dictionary: content).isEqual(to: oldContent) { return true }
                } else if hasUnrelatedChoiceChanges(in: child, from: previous?[key], assetID: assetID, fallback: fallback) { return true }
            }
        } else if let array = value as? [Any] {
            let previous = backup as? [Any] ?? []
            return array.enumerated().contains { index, child in
                hasUnrelatedChoiceChanges(in: child, from: previous.indices.contains(index) ? previous[index] : nil, assetID: assetID, fallback: fallback)
            }
        }
        return false
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

    static func wallpaperSelectionMatches(_ assetID: String, in value: Any, targetDisplayIDs: Set<String>, allDisplays: Bool) -> Bool {
        if allDisplays {
            guard let root = value as? [String: Any],
                  let global = root["AllSpacesAndDisplays"] as? [String: Any],
                  global["Type"] as? String == "linked" else { return false }
            return wallpaperSelectionMatches(assetID, in: value)
        }
        guard let root = value as? [String: Any], !targetDisplayIDs.isEmpty else { return false }
        func matches(_ container: [String: Any]) -> Bool {
            guard let displays = container["Displays"] as? [String: Any] else { return false }
            return targetDisplayIDs.allSatisfy { id in
                guard let selection = displays[id] else { return false }
                return wallpaperSelectionMatches(assetID, in: selection)
            }
        }
        if root["AllSpacesAndDisplays"] != nil { return false }
        guard matches(root) else { return false }
        return (root["Spaces"] as? [String: [String: Any]] ?? [:]).values.allSatisfy(matches)
    }

    static func wallpaperSelectionMatches(_ assetID: String, in value: Any) -> Bool {
        var desktopFound = false
        var idleFound = false
        func matches(_ value: Any) -> Bool {
            if let dictionary = value as? [String: Any] {
                for (key, child) in dictionary {
                    if ["Desktop", "Idle", "Linked"].contains(key), let section = child as? [String: Any], section["Content"] != nil {
                        if key == "Linked" { desktopFound = true; idleFound = true }
                        else if key == "Desktop" { desktopFound = true } else { idleFound = true }
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
        process.arguments = ["WallpaperAgent", "WallpaperAerialsExtension"]
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

enum LockScreenVideoError: LocalizedError {
    case incompatibleVideo
    case preferencesFailed
    case displayMissing
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
        case .incompatibleVideo: "This video could not be prepared for the macOS lock screen. You can turn off Video Wallpaper to use a still preview."
        case .preferencesFailed: "Could not save macOS video wallpaper preferences."
        case .displayMissing: "The selected display is not connected."
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
