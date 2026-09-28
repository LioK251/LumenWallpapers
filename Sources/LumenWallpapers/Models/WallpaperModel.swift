import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class WallpaperModel: NSObject, ObservableObject {
    private static let selectedWallpaperDefaultsKey = "selectedWallpaperPersistenceKey"
    private static let isPlayingDefaultsKey = "isPlaying"
    private static let selectedDisplayDefaultsKey = "selectedDisplay"
    private static let reduceQualityOnBatteryDefaultsKey = "reduceQualityOnBattery"
    private static let pauseOnFullscreenDefaultsKey = "pauseOnFullscreen"
    private static let pauseOnHighCPUDefaultsKey = "pauseOnHighCPU"
    private static let retinaRenderingDefaultsKey = "retinaRendering"
    private static let pexelsAPIKeyDefaultsKey = "pexelsAPIKey"
    private static let wallhavenAPIKeyDefaultsKey = "wallhavenAPIKey"
    private static let allowNSFWSearchDefaultsKey = "allowNSFWSearch"

    @Published var selected: Wallpaper
    @Published var isPlaying: Bool {
        didSet {
            UserDefaults.standard.set(isPlaying, forKey: Self.isPlayingDefaultsKey)
            syncDesktopWallpaper()
        }
    }
    @Published var selectedDisplay: String {
        didSet {
            UserDefaults.standard.set(selectedDisplay, forKey: Self.selectedDisplayDefaultsKey)
            syncDesktopWallpaper()
        }
    }
    @Published var activeTab = "Home" {
        didSet {
            if activeTab == "Settings", Int(cpuUsage.rounded()) != Int(latestCPUUsage.rounded()) {
                cpuUsage = latestCPUUsage
            }
        }
    }
    @Published var searchText = ""
    @Published private(set) var wallpapers: [Wallpaper]
    @Published var importError: String?
    @Published var launchAtLoginEnabled = false
    @Published private(set) var lockScreenVideoEnabled = LockScreenVideoManager.isInstalled
    @Published var reduceQualityOnBattery: Bool {
        didSet {
            UserDefaults.standard.set(reduceQualityOnBattery, forKey: Self.reduceQualityOnBatteryDefaultsKey)
            syncDesktopWallpaper()
        }
    }
    @Published var pauseOnFullscreen: Bool {
        didSet {
            UserDefaults.standard.set(pauseOnFullscreen, forKey: Self.pauseOnFullscreenDefaultsKey)
            syncDesktopWallpaper()
        }
    }
    @Published var pauseOnHighCPU: Bool {
        didSet {
            UserDefaults.standard.set(pauseOnHighCPU, forKey: Self.pauseOnHighCPUDefaultsKey)
            syncDesktopWallpaper()
        }
    }
    @Published var retinaRendering: Bool {
        didSet {
            UserDefaults.standard.set(retinaRendering, forKey: Self.retinaRenderingDefaultsKey)
            syncDesktopWallpaper()
        }
    }
    @Published private(set) var isOnBattery = false
    @Published private(set) var isFullscreenAppActive = false
    @Published private(set) var isHighCPUUsage = false
    @Published private(set) var cpuUsage = 0.0
    @Published private(set) var isSystemSleeping = false
    @Published private(set) var areScreensSleeping = false
    @Published var pexelsAPIKey: String {
        didSet {
            UserDefaults.standard.set(pexelsAPIKey, forKey: Self.pexelsAPIKeyDefaultsKey)
            refreshRecommendations(debounce: true)
        }
    }
    @Published var wallhavenAPIKey: String {
        didSet {
            UserDefaults.standard.set(wallhavenAPIKey, forKey: Self.wallhavenAPIKeyDefaultsKey)
            refreshRecommendations(debounce: true)
        }
    }
    @Published var allowNSFWSearch: Bool {
        didSet {
            UserDefaults.standard.set(allowNSFWSearch, forKey: Self.allowNSFWSearchDefaultsKey)
            refreshRecommendations()
        }
    }
    @Published private(set) var recommendations: [DiscoverRecommendation] = []

    private var desktopController: DesktopWallpaperController?
    private let lockScreenVideoManager: LockScreenVideoManager
    private let performanceSampler = SystemPerformanceSampler()
    private var systemTimer: Timer?
    private var systemConditionsTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var screenConfigurationObserver: NSObjectProtocol?
    private var occludedWallpaperScreens = Set<String>()
    private var recommendationTask: Task<Void, Never>?
    private var latestCPUUsage = 0.0

    private let libraryURL: URL
    private let builtIns: [Wallpaper] = [
        .builtIn("Cloudline", "Soft sky / 4K", "cloud.sun.fill", ["2563EB", "E5E7EB", "22D3EE"], "Sky")
    ]

    override init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        libraryURL = base.appendingPathComponent("LumenWallpapers/Library", isDirectory: true)
        lockScreenVideoManager = LockScreenVideoManager()
        wallpapers = []
        isPlaying = Self.storedBool(forKey: Self.isPlayingDefaultsKey, defaultValue: true)
        selectedDisplay = UserDefaults.standard.string(forKey: Self.selectedDisplayDefaultsKey) ?? "Built-in Display"
        reduceQualityOnBattery = Self.storedBool(forKey: Self.reduceQualityOnBatteryDefaultsKey, defaultValue: true)
        pauseOnFullscreen = Self.storedBool(forKey: Self.pauseOnFullscreenDefaultsKey, defaultValue: true)
        pauseOnHighCPU = Self.storedBool(forKey: Self.pauseOnHighCPUDefaultsKey, defaultValue: true)
        retinaRendering = Self.storedBool(forKey: Self.retinaRenderingDefaultsKey, defaultValue: true)
        pexelsAPIKey = UserDefaults.standard.string(forKey: Self.pexelsAPIKeyDefaultsKey) ?? ""
        wallhavenAPIKey = UserDefaults.standard.string(forKey: Self.wallhavenAPIKeyDefaultsKey) ?? ""
        allowNSFWSearch = Self.storedBool(forKey: Self.allowNSFWSearchDefaultsKey, defaultValue: false)
        try? FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        LegacyWallpaperMigration.cleanupOldSnapshotState(directory: libraryURL)
        let stored = WallpaperModel.loadLibrary(from: libraryURL.appendingPathComponent("library.json"))
        let availableWallpapers = builtIns + stored.filter { item in
            item.url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        }
        wallpapers = availableWallpapers
        let savedKey = UserDefaults.standard.string(forKey: Self.selectedWallpaperDefaultsKey)
        selected = availableWallpapers.first { $0.persistenceKey == savedKey } ?? availableWallpapers[0]
        super.init()
        launchAtLoginEnabled = LaunchAtLoginManager.isEnabled
        if lockScreenVideoManager.hasStoredConfiguration {
            if selected.kind == .video, let url = selected.url {
                try? lockScreenVideoManager.configure(videoURL: url, title: selected.title)
            } else if !lockScreenVideoManager.configuredVideoIsAvailable {
                try? lockScreenVideoManager.restorePreviousWallpaper()
            }
            lockScreenVideoEnabled = LockScreenVideoManager.isInstalled
        }
        startSystemMonitoring()
    }

    var effectiveIsPlaying: Bool {
        isPlaying
            && !isSystemSleeping
            && !areScreensSleeping
            && !(pauseOnFullscreen && isFullscreenAppActive)
            && !(pauseOnHighCPU && isHighCPUUsage)
    }

    var isReducedQualityActive: Bool {
        reduceQualityOnBattery && isOnBattery
    }

    var pauseReason: String? {
        if !isPlaying { return "Paused manually" }
        if isSystemSleeping || areScreensSleeping { return "Paused while the Mac is sleeping" }
        if pauseOnFullscreen && isFullscreenAppActive { return "Paused for a full-screen app" }
        if pauseOnHighCPU && isHighCPUUsage { return "Paused because CPU usage is high" }
        return nil
    }

    private static func storedBool(forKey key: String, defaultValue: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue
    }

    private func startSystemMonitoring() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        let pauseNotifications: [(Notification.Name, Bool)] = [
            (NSWorkspace.willSleepNotification, true),
            (NSWorkspace.screensDidSleepNotification, true),
            (NSWorkspace.didWakeNotification, false),
            (NSWorkspace.screensDidWakeNotification, false)
        ]
        for (name, sleeping) in pauseNotifications {
            let observer = notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if sleeping {
                        if name == NSWorkspace.screensDidSleepNotification {
                            self.areScreensSleeping = true
                        } else {
                            self.isSystemSleeping = true
                        }
                    } else {
                        if name == NSWorkspace.screensDidWakeNotification {
                            self.areScreensSleeping = false
                        } else {
                            self.isSystemSleeping = false
                        }
                    }
                    self.syncDesktopWallpaper()
                }
            }
            workspaceObservers.append(observer)
        }

        let timer = Timer(timeInterval: 1.5, target: self, selector: #selector(systemTimerFired), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        systemTimer = timer
        updateSystemConditions()
    }

    @objc private func systemTimerFired() {
        updateSystemConditions()
    }

    private func updateSystemConditions() {
        systemConditionsTask?.cancel()
        let sampler = performanceSampler
        systemConditionsTask = Task { @MainActor [weak self] in
            let sample = await Task.detached(priority: .utility) {
                await sampler.sample()
            }.value
            guard !Task.isCancelled else { return }
            self?.applySystemConditions(sample)
        }
    }

    private func applySystemConditions(_ sample: SystemPerformanceSample) {
        let wasPlaying = effectiveIsPlaying
        let wasReducedQuality = isReducedQualityActive
        if isOnBattery != sample.isOnBattery {
            isOnBattery = sample.isOnBattery
        }
        if let cpuUsage = sample.cpuUsage {
            latestCPUUsage = cpuUsage
            if activeTab == "Settings", Int(self.cpuUsage.rounded()) != Int(cpuUsage.rounded()) {
                self.cpuUsage = cpuUsage
            }
        }
        if isHighCPUUsage != sample.isHighCPUUsage {
            isHighCPUUsage = sample.isHighCPUUsage
        }
        if effectiveIsPlaying != wasPlaying || isReducedQualityActive != wasReducedQuality {
            syncDesktopWallpaper()
        }
    }

    var filteredWallpapers: [Wallpaper] {
        let source = activeTab == "My Library" ? wallpapers.filter { $0.kind != .procedural } : wallpapers
        guard !searchText.isEmpty else { return source }
        return source.filter { $0.title.localizedCaseInsensitiveContains(searchText) || $0.category.localizedCaseInsensitiveContains(searchText) }
    }

    func wallpaperForWallhaven(_ item: WallhavenWallpaper) -> Wallpaper? {
        wallpapers.first {
            $0.attributionURL == item.url
                || $0.sourceURL?.contains("wallhaven-\(item.id)") == true
                || $0.title == "Wallhaven \(item.id)"
        }
    }

    func wallpaperForPexels(_ item: PexelsVideo) -> Wallpaper? {
        wallpapers.first {
            $0.attributionURL == item.url
                || $0.sourceURL?.contains("pexels-\(item.id)") == true
                || $0.title == "Pexels \(item.id)"
        }
    }

    func refreshRecommendations(debounce: Bool = false) {
        recommendationTask?.cancel()
        let apiKey = pexelsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        recommendationTask = Task { @MainActor [weak self] in
            if debounce {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
            }
            var items: [DiscoverRecommendation] = []
            if let imageResult = try? await WallhavenAPI.search(
                query: "",
                page: 1,
                sorting: "random",
                includeNSFW: self?.allowNSFWSearch ?? false,
                apiKey: self?.wallhavenAPIKey ?? ""
            ) {
                items.append(contentsOf: imageResult.items.shuffled().prefix(4).map(DiscoverRecommendation.image))
            }
            if !apiKey.isEmpty, let videoResult = try? await PexelsAPI.search(query: "wallpaper", page: 1, apiKey: apiKey) {
                items.append(contentsOf: videoResult.items.shuffled().prefix(4).map(DiscoverRecommendation.video))
            }
            guard !Task.isCancelled else { return }
            self?.recommendations = items.shuffled()
        }
    }

    func startDesktopWallpaper() {
        guard desktopController == nil else { return }
        let controller = DesktopWallpaperController()
        controller.onOcclusionChange = { [weak self] screenKey, isVisible in
            Task { @MainActor [weak self] in
                self?.updateWallpaperOcclusion(screenKey: screenKey, isVisible: isVisible)
            }
        }
        desktopController = controller
        screenConfigurationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncDesktopWallpaper()
            }
        }
        syncDesktopWallpaper()
    }

    private func updateWallpaperOcclusion(screenKey: String, isVisible: Bool) {
        let wasPlaying = effectiveIsPlaying
        if isVisible {
            occludedWallpaperScreens.remove(screenKey)
        } else {
            occludedWallpaperScreens.insert(screenKey)
        }
        let fullscreenIsActive = !occludedWallpaperScreens.isEmpty
        if isFullscreenAppActive != fullscreenIsActive {
            isFullscreenAppActive = fullscreenIsActive
        }
        if effectiveIsPlaying != wasPlaying {
            syncDesktopWallpaper()
        }
    }

    func syncDesktopWallpaper() {
        desktopController?.apply(
            wallpaper: selected,
            isPlaying: effectiveIsPlaying,
            display: selectedDisplay,
            reducedQuality: isReducedQualityActive,
            retinaRendering: retinaRendering,
            isSuspended: isSystemSleeping || areScreensSleeping
        )
    }

    func select(_ wallpaper: Wallpaper) {
        guard wallpapers.contains(where: { $0.id == wallpaper.id }) else { return }
        selected = wallpaper
        UserDefaults.standard.set(wallpaper.persistenceKey, forKey: Self.selectedWallpaperDefaultsKey)
        syncDesktopWallpaper()
        if lockScreenVideoEnabled {
            if wallpaper.kind == .video, let url = wallpaper.url {
                try? lockScreenVideoManager.configure(videoURL: url, title: wallpaper.title)
            } else {
                try? lockScreenVideoManager.restorePreviousWallpaper()
                lockScreenVideoEnabled = false
            }
        }
    }

    func configureLockScreenVideo() {
        guard selected.kind == .video, let url = selected.url else {
            importError = "Select an imported video before setting up Video Wallpaper."
            return
        }

        do {
            try lockScreenVideoManager.installAndConfigure(videoURL: url, title: selected.title)
            lockScreenVideoEnabled = true
        } catch {
            lockScreenVideoEnabled = LockScreenVideoManager.isInstalled
            importError = "Could not set up Video Wallpaper: \(error.localizedDescription)"
        }
    }

    func setLockScreenVideo(_ enabled: Bool) {
        if enabled {
            configureLockScreenVideo()
            return
        }

        do {
            try lockScreenVideoManager.restorePreviousWallpaper()
            lockScreenVideoEnabled = false
        } catch {
            importError = "Could not restore the previous wallpaper: \(error.localizedDescription)"
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try LaunchAtLoginManager.enable()
            } else {
                try LaunchAtLoginManager.disable()
            }
            launchAtLoginEnabled = LaunchAtLoginManager.isEnabled
        } catch {
            launchAtLoginEnabled = LaunchAtLoginManager.isEnabled
            importError = "Could not update Launch at Login: \(error.localizedDescription)"
        }
    }

    func importWallpaper() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie, .image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        var copiedURLs: [URL] = []
        do {
            var imported: [Wallpaper] = []
            for url in panel.urls {
                let safeName = safeFileStem(url.deletingPathExtension().lastPathComponent)
                let destination = uniqueDestination(named: safeName, ext: url.pathExtension)
                try FileManager.default.copyItem(at: url, to: destination)
                copiedURLs.append(destination)
                let isVideo = ["mov", "mp4", "m4v", "avi"].contains(url.pathExtension.lowercased())
                imported.append(Wallpaper(id: UUID(), title: url.deletingPathExtension().lastPathComponent, subtitle: isVideo ? "Imported video" : "Imported image", symbol: isVideo ? "play.rectangle.fill" : "photo.fill", colors: ["334155", "0F172A"], category: "My Library", kind: isVideo ? .video : .image, sourceURL: destination.path))
            }
            try persistImported(wallpapers + imported)
            wallpapers.append(contentsOf: imported)
            if let first = imported.first { select(first) }
        } catch {
            copiedURLs.forEach { try? FileManager.default.removeItem(at: $0) }
            importError = "Could not import this file: \(error.localizedDescription)"
        }
    }

    func downloadWallhaven(_ item: WallhavenWallpaper) async -> Bool {
        if let existing = wallpaperForWallhaven(item) {
            select(existing)
            return true
        }
        guard let remoteURL = URL(string: item.path) else {
            importError = "That wallpaper doesn't have a downloadable file."
            return false
        }
        do {
            let (tempURL, response) = try await URLSession.shared.download(from: remoteURL)
            defer { try? FileManager.default.removeItem(at: tempURL) }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                importError = "Could not download this wallpaper (server error)."
                return false
            }
            if let existing = wallpaperForWallhaven(item) {
                select(existing)
                return true
            }
            let fallback = WebPageMetadata.suggestedName(
                from: response,
                remoteURL: remoteURL,
                sourceURL: item.source.flatMap(URL.init(string:))
            ) ?? "Wallpaper \(item.id)"
            let title = await WebPageMetadata.title(for: item.url, fallback: fallback)
            if let existing = wallpaperForWallhaven(item) {
                select(existing)
                return true
            }
            let ext = remoteURL.pathExtension.isEmpty ? "jpg" : remoteURL.pathExtension
            let destination = uniqueDestination(named: safeFileStem(title), ext: ext)
            try FileManager.default.moveItem(at: tempURL, to: destination)
            let wallpaper = Wallpaper(
                id: UUID(),
                title: title,
                subtitle: "\(item.resolution) · from Wallhaven",
                symbol: "photo.fill",
                colors: ["334155", "0F172A"],
                category: "Discover",
                kind: .image,
                sourceURL: destination.path,
                attributionURL: item.url
            )
            do {
                try persistImported(wallpapers + [wallpaper])
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
            wallpapers.append(wallpaper)
            select(wallpaper)
            return true
        } catch {
            importError = "Could not download this wallpaper: \(error.localizedDescription)"
            return false
        }
    }

    func downloadPexelsVideo(_ video: PexelsVideo) async -> Bool {
        if let existing = wallpaperForPexels(video) {
            select(existing)
            return true
        }
        guard let file = video.bestDownloadFile, let remoteURL = URL(string: file.link) else {
            importError = "This Pexels video doesn't have a downloadable file."
            return false
        }
        do {
            let (tempURL, response) = try await URLSession.shared.download(from: remoteURL)
            defer { try? FileManager.default.removeItem(at: tempURL) }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                importError = "Could not download this video (server error)."
                return false
            }
            if let existing = wallpaperForPexels(video) {
                select(existing)
                return true
            }
            let fallback = WebPageMetadata.suggestedName(from: response, remoteURL: remoteURL)
                ?? "Pexels Video \(video.id)"
            let title = await WebPageMetadata.title(for: video.url, fallback: fallback)
            if let existing = wallpaperForPexels(video) {
                select(existing)
                return true
            }
            let destination = uniqueDestination(named: safeFileStem(title), ext: "mp4")
            try FileManager.default.moveItem(at: tempURL, to: destination)
            let wallpaper = Wallpaper(
                id: UUID(),
                title: title,
                subtitle: "\(file.width ?? video.width)×\(file.height ?? video.height) · from Pexels",
                symbol: "play.rectangle.fill",
                colors: ["334155", "0F172A"],
                category: "Discover",
                kind: .video,
                sourceURL: destination.path,
                attributionURL: video.url
            )
            do {
                try persistImported(wallpapers + [wallpaper])
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
            wallpapers.append(wallpaper)
            select(wallpaper)
            return true
        } catch {
            importError = "Could not download this video: \(error.localizedDescription)"
            return false
        }
    }

    private func uniqueDestination(named: String, ext: String) -> URL {
        var candidate = libraryURL.appendingPathComponent("\(named).\(ext)")
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) { candidate = libraryURL.appendingPathComponent("\(named) \(index).\(ext)"); index += 1 }
        return candidate
    }

    private func safeFileStem(_ title: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:*?\"<>|\\")
        let cleaned = title.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "wallpaper" : String(cleaned.prefix(96))
    }

    private func persistImported(_ items: [Wallpaper]) throws {
        let imported = items.filter { $0.kind != .procedural }
        let data = try JSONEncoder().encode(imported)
        try data.write(to: libraryURL.appendingPathComponent("library.json"), options: .atomic)
    }

    func remove(_ wallpaper: Wallpaper) {
        guard wallpaper.kind != .procedural,
              wallpapers.contains(where: { $0.id == wallpaper.id }) else { return }
        let remaining = wallpapers.filter { $0.id != wallpaper.id }
        do {
            try persistImported(remaining)
        } catch {
            importError = "Could not update the library: \(error.localizedDescription)"
            return
        }
        if let url = wallpaper.url {
            do {
                if lockScreenVideoEnabled, lockScreenVideoManager.isConfigured(videoURL: url) {
                    try lockScreenVideoManager.restorePreviousWallpaper()
                    lockScreenVideoEnabled = false
                }
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            } catch {
                try? persistImported(wallpapers)
                importError = "Could not remove this wallpaper: \(error.localizedDescription)"
                return
            }
        }
        wallpapers = remaining
        if selected.id == wallpaper.id, let fallback = wallpapers.first {
            select(fallback)
        } else {
            syncDesktopWallpaper()
        }
    }

    func rename(_ wallpaper: Wallpaper, to title: String) {
        guard wallpaper.kind != .procedural else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = wallpapers.firstIndex(where: { $0.id == wallpaper.id }) else { return }
        var updated = wallpapers
        updated[index].title = trimmed
        do {
            try persistImported(updated)
        } catch {
            importError = "Could not rename this wallpaper: \(error.localizedDescription)"
            return
        }
        wallpapers = updated
        if selected.id == wallpaper.id {
            selected = wallpapers[index]
        }
    }

    private static func loadLibrary(from url: URL) -> [Wallpaper] { guard let data = try? Data(contentsOf: url), let items = try? JSONDecoder().decode([Wallpaper].self, from: data) else { return [] }; return items }
}
