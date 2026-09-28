import AppKit

enum LegacyWallpaperMigration {
    private static let originalDesktopImagesDefaultsKey = "originalDesktopImageURLs"

    static func cleanupOldSnapshotState(directory: URL) {
        let defaults = UserDefaults.standard
        let originals = defaults.dictionary(forKey: originalDesktopImagesDefaultsKey) as? [String: String] ?? [:]
        for screen in NSScreen.screens {
            guard let value = originals[screen.persistenceKey], let url = URL(string: value) else { continue }
            let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
            try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
        }
        defaults.removeObject(forKey: originalDesktopImagesDefaultsKey)
        defaults.removeObject(forKey: "useLockScreenSnapshot")

        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for file in files where file.pathExtension.lowercased() == "png" && file.lastPathComponent.hasPrefix("lock-screen-snapshot") {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
