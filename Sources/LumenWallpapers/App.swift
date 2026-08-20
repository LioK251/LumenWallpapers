import SwiftUI
import AppKit
import AVKit
import AVFoundation
import ImageIO
import ServiceManagement
import UniformTypeIdentifiers
import IOKit.ps
import Darwin

@main
struct LumenWallpapersApp: App {
    @StateObject private var model = WallpaperModel()

    var body: some Scene {
        WindowGroup {
            DashboardView(model: model)
                .frame(minWidth: 1080, minHeight: 720)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        MenuBarExtra("Lumen", systemImage: "sparkles") {
            Button(model.isPlaying ? "Pause Wallpaper" : "Resume Wallpaper") { model.isPlaying.toggle() }
            Button("Settings") {
                model.activeTab = "Settings"
                NSApp.activate(ignoringOtherApps: true)
            }
            Divider()
            Button("Open Lumen") { NSApp.activate(ignoringOtherApps: true) }
            Button("Quit") { NSApp.terminate(nil) }
        }
    }
}

enum WallpaperKind: String, Codable { case procedural, video, image }

struct Wallpaper: Identifiable, Hashable, Codable {
    var id: UUID
    var title: String
    var subtitle: String
    var symbol: String
    var colors: [String]
    var category: String
    var kind: WallpaperKind
    var sourceURL: String?

    var swiftColors: [Color] { colors.map { Color(hex: $0) } }
    var url: URL? { sourceURL.flatMap(URL.init(fileURLWithPath:)) }
    var persistenceKey: String {
        kind == .procedural ? "builtin:\(title)" : "import:\(id.uuidString)"
    }

    static func builtIn(_ title: String, _ subtitle: String, _ symbol: String, _ colors: [String], _ category: String) -> Wallpaper {
        Wallpaper(id: UUID(), title: title, subtitle: subtitle, symbol: symbol, colors: colors, category: category, kind: .procedural, sourceURL: nil)
    }
}

@MainActor
final class WallpaperModel: NSObject, ObservableObject {
    private static let selectedWallpaperDefaultsKey = "selectedWallpaperPersistenceKey"
    private static let isPlayingDefaultsKey = "isPlaying"
    private static let selectedDisplayDefaultsKey = "selectedDisplay"
    private static let reduceQualityOnBatteryDefaultsKey = "reduceQualityOnBattery"
    private static let pauseOnFullscreenDefaultsKey = "pauseOnFullscreen"
    private static let pauseOnHighCPUDefaultsKey = "pauseOnHighCPU"
    private static let retinaRenderingDefaultsKey = "retinaRendering"

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
    @Published var activeTab = "Home"
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

    private var desktopController: DesktopWallpaperController?
    private let lockScreenVideoManager: LockScreenVideoManager
    private let performanceSampler = SystemPerformanceSampler()
    private var systemTimer: Timer?
    private var systemConditionsTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var occludedWallpaperScreens = Set<String>()

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
        isOnBattery = sample.isOnBattery
        if let cpuUsage = sample.cpuUsage {
            self.cpuUsage = cpuUsage
        }
        isHighCPUUsage = sample.isHighCPUUsage
        if effectiveIsPlaying != wasPlaying || isReducedQualityActive != wasReducedQuality {
            syncDesktopWallpaper()
        }
    }

    var filteredWallpapers: [Wallpaper] {
        let source = activeTab == "My Library" ? wallpapers.filter { $0.kind != .procedural } : wallpapers
        guard !searchText.isEmpty else { return source }
        return source.filter { $0.title.localizedCaseInsensitiveContains(searchText) || $0.category.localizedCaseInsensitiveContains(searchText) }
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
        syncDesktopWallpaper()
    }

    private func updateWallpaperOcclusion(screenKey: String, isVisible: Bool) {
        if isVisible {
            occludedWallpaperScreens.remove(screenKey)
        } else {
            occludedWallpaperScreens.insert(screenKey)
        }
        isFullscreenAppActive = !occludedWallpaperScreens.isEmpty
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
        do {
            var imported: [Wallpaper] = []
            for url in panel.urls {
                let safeName = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "/", with: "-")
                let destination = uniqueDestination(named: safeName, ext: url.pathExtension)
                try FileManager.default.copyItem(at: url, to: destination)
                let isVideo = ["mov", "mp4", "m4v", "avi"].contains(url.pathExtension.lowercased())
                imported.append(Wallpaper(id: UUID(), title: url.deletingPathExtension().lastPathComponent, subtitle: isVideo ? "Imported video" : "Imported image", symbol: isVideo ? "play.rectangle.fill" : "photo.fill", colors: ["334155", "0F172A"], category: "My Library", kind: isVideo ? .video : .image, sourceURL: destination.path))
            }
            wallpapers.append(contentsOf: imported)
            persistImported()
            if let first = imported.first { select(first) }
        } catch { importError = "Could not import this file: \(error.localizedDescription)" }
    }

    private func uniqueDestination(named: String, ext: String) -> URL {
        var candidate = libraryURL.appendingPathComponent("\(named).\(ext)")
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) { candidate = libraryURL.appendingPathComponent("\(named) \(index).\(ext)"); index += 1 }
        return candidate
    }

    private func persistImported() {
        let imported = wallpapers.filter { $0.kind != .procedural }
        if let data = try? JSONEncoder().encode(imported) { try? data.write(to: libraryURL.appendingPathComponent("library.json"), options: .atomic) }
    }

    func remove(_ wallpaper: Wallpaper) {
        guard wallpaper.kind != .procedural else { return }
        if let url = wallpaper.url {
            if lockScreenVideoEnabled, lockScreenVideoManager.isConfigured(videoURL: url) {
                try? lockScreenVideoManager.restorePreviousWallpaper()
                lockScreenVideoEnabled = false
            }
            try? FileManager.default.removeItem(at: url)
        }
        wallpapers.removeAll { $0.id == wallpaper.id }
        persistImported()
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
        wallpapers[index].title = trimmed
        if selected.id == wallpaper.id {
            selected = wallpapers[index]
        }
        persistImported()
    }

    private static func loadLibrary(from url: URL) -> [Wallpaper] { guard let data = try? Data(contentsOf: url), let items = try? JSONDecoder().decode([Wallpaper].self, from: data) else { return [] }; return items }
}

struct DashboardView: View {
    @ObservedObject var model: WallpaperModel
    @State private var showImportHelp = false
    @State private var renameTarget: Wallpaper?
    @State private var removeTarget: Wallpaper?

    var body: some View {
        ZStack {
            FullscreenWallpaperBackground(
                wallpaper: model.selected,
                isPlaying: model.effectiveIsPlaying,
                reducedQuality: model.isReducedQualityActive,
                retinaRendering: model.retinaRendering
            )
            Color.black.opacity(0.12)
                .ignoresSafeArea()
            LinearGradient(colors: [.black.opacity(0.08), .clear, .black.opacity(0.84)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            VStack(spacing: 0) {
                TopGlassBar(model: model, showImportHelp: $showImportHelp)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 32) {
                        if model.activeTab == "Home" {
                            HeroShowcase(model: model)
                            WallpaperRow(title: "Recommended for you", wallpapers: Array(model.filteredWallpapers.prefix(6)), model: model, onRename: { renameTarget = $0 }, onRemove: { removeTarget = $0 })
                            WallpaperRow(title: "My media", wallpapers: model.wallpapers.filter { $0.kind != .procedural }, model: model, emptyText: "Import a video or image to start your library", onRename: { renameTarget = $0 }, onRemove: { removeTarget = $0 })
                            PerformanceBar(model: model)
                        } else if model.activeTab == "Settings" {
                            SettingsView(model: model)
                        } else {
                            LibraryGrid(model: model, wallpapers: model.filteredWallpapers, title: model.activeTab == "Explore" ? "Explore all wallpapers" : "My Library", emptyText: model.activeTab == "Explore" ? "No wallpapers match your search" : "Import a video or image to start your library", onRename: { renameTarget = $0 }, onRemove: { removeTarget = $0 })
                        }
                    }
                    .padding(.horizontal, 46)
                    .padding(.top, 12)
                    .padding(.bottom, 36)
                }
            }
        }
        .alert("Import failed", isPresented: Binding(get: { model.importError != nil }, set: { if !$0 { model.importError = nil } })) { Button("OK") {} } message: { Text(model.importError ?? "") }
        .alert("Remove wallpaper?", isPresented: Binding(get: { removeTarget != nil }, set: { if !$0 { removeTarget = nil } })) {
            Button("Cancel", role: .cancel) { removeTarget = nil }
            Button("Remove", role: .destructive) {
                if let wallpaper = removeTarget { model.remove(wallpaper) }
                removeTarget = nil
            }
        } message: {
            Text("\(removeTarget?.title ?? "This wallpaper") will be removed from My Library.")
        }
        .sheet(isPresented: $showImportHelp) { ImportHelpView() }
        .sheet(item: $renameTarget) { wallpaper in
            RenameWallpaperView(wallpaper: wallpaper) { title in
                model.rename(wallpaper, to: title)
                renameTarget = nil
            }
        }
        .onAppear { model.startDesktopWallpaper() }
        .animation(.easeInOut(duration: 0.36), value: model.selected.id)
        .animation(.easeInOut(duration: 0.24), value: model.activeTab)
    }
}

struct FullscreenWallpaperBackground: View {
    @Environment(\.displayScale) private var nativeDisplayScale
    let wallpaper: Wallpaper
    let isPlaying: Bool
    let reducedQuality: Bool
    let retinaRendering: Bool
    var body: some View {
        Group {
            if wallpaper.kind == .procedural {
                LiveWallpaperCanvas(wallpaper: wallpaper, isPlaying: isPlaying, reducedQuality: reducedQuality)
            } else if wallpaper.kind == .video, let url = wallpaper.url {
                VideoSurface(url: url, isPlaying: isPlaying, reducedQuality: reducedQuality)
            } else if let url = wallpaper.url {
                Image(nsImage: NSImage(contentsOf: url) ?? NSImage()).resizable().scaledToFill()
            } else {
                Color.black
            }
        }
        .id(wallpaper.id)
        .transition(.opacity)
        .ignoresSafeArea()
        .scaleEffect(1.01)
        .environment(\.displayScale, retinaRendering && !reducedQuality ? nativeDisplayScale : 1)
        .animation(.easeInOut(duration: 0.55), value: wallpaper.id)
    }
}

struct TopGlassBar: View {
    @ObservedObject var model: WallpaperModel; @Binding var showImportHelp: Bool
    var body: some View {
        HStack {
            Spacer()

            HStack(spacing: 3) {
                ForEach(["Home", "Explore", "My Library", "Settings"], id: \.self) { tab in
                    Button(tab) {
                        withAnimation(.easeInOut(duration: 0.28)) {
                            model.activeTab = tab
                        }
                    }
                        .buttonStyle(GlassTabStyle(isSelected: model.activeTab == tab))
                }
            }
            .padding(4)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.18)))
            .shadow(color: .black.opacity(0.18), radius: 16, y: 8)

            Spacer()

            HStack(spacing: 6) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                    TextField("Search", text: $model.searchText)
                        .textFieldStyle(.plain)
                        .frame(width: 96)
                }
                .padding(.horizontal, 12)
                .frame(height: 42)
                .background(.black.opacity(0.2), in: Capsule())

                Button { model.importWallpaper() } label: { Image(systemName: "plus") }
                    .buttonStyle(GlassIconStyle())
                    .help("Import wallpaper")
                Button { showImportHelp = true } label: { Image(systemName: "questionmark") }
                    .buttonStyle(GlassIconStyle())
                    .help("How to add wallpapers")
            }
            .padding(4)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.18)))
            .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
    }
}

struct HeroShowcase: View {
    @ObservedObject var model: WallpaperModel
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Spacer(minLength: 180)
            Text(model.selected.category.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(1.6)
                .foregroundStyle(.white.opacity(0.66))
            Text(model.selected.title)
                .font(.system(size: 46, weight: .semibold, design: .rounded))
                .lineLimit(1)
            Text(model.selected.subtitle)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
            HStack(spacing: 9) {
                Button { model.isPlaying.toggle() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(LiquidButtonStyle())
                Button { model.importWallpaper() } label: {
                    Label("Import media", systemImage: "plus")
                }
                .buttonStyle(LiquidButtonStyle())
                Menu {
                    Button("Built-in Display") { model.selectedDisplay = "Built-in Display" }
                    Button("External Display") { model.selectedDisplay = "External Display" }
                    Button("All Displays") { model.selectedDisplay = "All Displays" }
                } label: {
                    Label(model.selectedDisplay, systemImage: "display.2")
                }
                .buttonStyle(LiquidButtonStyle())
            }
        }
        .id(model.selected.id)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .frame(maxWidth: .infinity, minHeight: 430, alignment: .bottomLeading)
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.42), value: model.selected.id)
    }
}

struct WallpaperRow: View {
    let title: String
    let wallpapers: [Wallpaper]
    @ObservedObject var model: WallpaperModel
    var emptyText: String? = nil
    let onRename: (Wallpaper) -> Void
    let onRemove: (Wallpaper) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title).font(.system(size: 22, weight: .semibold, design: .rounded))
                Spacer()
                if !wallpapers.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.28)) {
                            model.activeTab = title == "My media" ? "My Library" : "Explore"
                        }
                    } label: {
                        Text("See all")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.68))
                            .frame(minWidth: 62, minHeight: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if wallpapers.isEmpty {
                Text(emptyText ?? "").font(.system(size: 13)).foregroundStyle(.white.opacity(0.58)).padding(.vertical, 20)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(wallpapers) { wallpaper in
                            WallpaperCard(
                                wallpaper: wallpaper,
                                isSelected: wallpaper.id == model.selected.id,
                                onSelect: { model.select(wallpaper) },
                                onRename: onRename,
                                onRemove: onRemove
                            )
                        }
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.24), value: wallpapers.map(\.id))
    }
}

struct LibraryGrid: View {
    @ObservedObject var model: WallpaperModel
    let wallpapers: [Wallpaper]
    let title: String
    let emptyText: String
    let onRename: (Wallpaper) -> Void
    let onRemove: (Wallpaper) -> Void

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 18)]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(.system(size: 28, weight: .semibold, design: .rounded))

            if wallpapers.isEmpty {
                Text(emptyText)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.58))
                    .padding(.vertical, 32)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                    ForEach(wallpapers) { wallpaper in
                        WallpaperCard(
                            wallpaper: wallpaper,
                            isSelected: wallpaper.id == model.selected.id,
                            onSelect: { model.select(wallpaper) },
                            onRename: onRename,
                            onRemove: onRemove
                        )
                    }
                }
            }
        }
    }
}

struct WallpaperCard: View {
    let wallpaper: Wallpaper
    let isSelected: Bool
    let onSelect: () -> Void
    let onRename: (Wallpaper) -> Void
    let onRemove: (Wallpaper) -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                WallpaperMediaView(wallpaper: wallpaper, isPlaying: false, reducedQuality: true)
                    .frame(width: 220, height: 132)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .contentShape(RoundedRectangle(cornerRadius: 16))
                    .onTapGesture(perform: onSelect)
                if wallpaper.kind == .video {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .padding(8)
                        .background(.black.opacity(0.48), in: Circle())
                        .padding(9)
                }
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(7)
                        .background(.white, in: Circle())
                        .padding(9)
                }
                if wallpaper.kind != .procedural && isHovered {
                    HStack(spacing: 6) {
                        Button { onRename(wallpaper) } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(CardActionButtonStyle())
                        .help("Rename wallpaper")

                        Button { onRemove(wallpaper) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(CardActionButtonStyle())
                        .help("Remove wallpaper")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(9)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            Text(wallpaper.title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .onTapGesture(perform: onSelect)
            Text(wallpaper.subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .onTapGesture(perform: onSelect)
        }
        .frame(width: 220, alignment: .leading)
        .scaleEffect(isHovered ? 1.025 : 1)
        .opacity(isHovered ? 1 : 0.94)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.18)) {
                isHovered = hovering
            }
        }
    }
}

struct CardActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .frame(width: 30, height: 30)
            .contentShape(Circle())
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().stroke(.white.opacity(0.22)))
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

struct WallpaperMediaView: View {
    let wallpaper: Wallpaper
    let isPlaying: Bool
    let reducedQuality: Bool

    var body: some View {
        Group {
            if wallpaper.kind == .procedural {
                LiveWallpaperCanvas(wallpaper: wallpaper, isPlaying: isPlaying, reducedQuality: reducedQuality)
            } else if wallpaper.kind == .video, let url = wallpaper.url {
                VideoSurface(url: url, isPlaying: isPlaying, reducedQuality: reducedQuality)
            } else if let url = wallpaper.url {
                Image(nsImage: NSImage(contentsOf: url) ?? NSImage())
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(colors: wallpaper.swiftColors, startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
    }
}

struct LiveWallpaperCanvas: View {
    let wallpaper: Wallpaper
    let isPlaying: Bool
    let reducedQuality: Bool

    private var frameInterval: Double {
        reducedQuality ? 1.0 / 15.0 : 1.0 / 30.0
    }

    private var blobCount: Int {
        reducedQuality ? 4 : 8
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: isPlaying ? frameInterval : 3600, paused: !isPlaying)) { context in
            Canvas { graphics, size in
                let rect = CGRect(origin: .zero, size: size)
                graphics.fill(
                    Path(rect),
                    with: .linearGradient(
                        Gradient(colors: wallpaper.swiftColors.map { $0.opacity(0.9) }),
                        startPoint: CGPoint(x: 0, y: size.height),
                        endPoint: CGPoint(x: size.width, y: 0)
                    )
                )
                let t = context.date.timeIntervalSinceReferenceDate
                for index in 0..<blobCount {
                    let x = size.width * (0.12 + CGFloat(index % 3) * 0.39) + sin(t * 0.2 + Double(index)) * (reducedQuality ? 48 : 90)
                    let y = size.height * (0.18 + CGFloat(index / 3) * 0.32) + cos(t * 0.16 + Double(index)) * (reducedQuality ? 28 : 52)
                    let radius = (reducedQuality ? 64 : 80) + CGFloat(index * (reducedQuality ? 6 : 9))
                    graphics.fill(
                        Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                        with: .radialGradient(
                            Gradient(colors: [wallpaper.swiftColors[index % wallpaper.swiftColors.count].opacity(0.56), .clear]),
                            center: CGPoint(x: x, y: y),
                            startRadius: 0,
                            endRadius: radius
                        )
                    )
                }
                graphics.fill(Path(rect), with: .color(.black.opacity(0.12)))
            }
        }
    }
}

struct VideoSurface: NSViewRepresentable {
    @Environment(\.displayScale) private var displayScale
    let url: URL
    let isPlaying: Bool
    let reducedQuality: Bool

    func makeCoordinator() -> Coordinator { Coordinator(url: url, reducedQuality: reducedQuality) }

    func makeNSView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.playerLayer.player = context.coordinator.player
        view.playerLayer.contentsScale = displayScale
        context.coordinator.setPlaying(isPlaying)
        return view
    }

    func updateNSView(_ view: PlayerContainerView, context: Context) {
        view.playerLayer.contentsScale = displayScale
        context.coordinator.update(url: url, isPlaying: isPlaying, reducedQuality: reducedQuality)
    }

    final class Coordinator {
        let player = AVQueuePlayer()
        private var looper: AVPlayerLooper?
        private var currentURL: URL
        private var reducedQuality: Bool

        init(url: URL, reducedQuality: Bool) {
            currentURL = url
            self.reducedQuality = reducedQuality
            player.isMuted = true
            player.actionAtItemEnd = .none
            player.automaticallyWaitsToMinimizeStalling = false
            looper = makeLooper(for: url)
        }

        func update(url: URL, isPlaying: Bool, reducedQuality: Bool) {
            if url != currentURL || reducedQuality != self.reducedQuality {
                looper = nil
                player.removeAllItems()
                currentURL = url
                self.reducedQuality = reducedQuality
                looper = makeLooper(for: url)
            }
            setPlaying(isPlaying)
        }

        func setPlaying(_ playing: Bool) { playing ? player.play() : player.pause() }

        private func makeLooper(for url: URL) -> AVPlayerLooper {
            let item = AVPlayerItem(url: url)
            if reducedQuality {
                item.preferredPeakBitRate = 2_000_000
                item.preferredMaximumResolution = CGSize(width: 1280, height: 720)
            }
            return AVPlayerLooper(player: player, templateItem: item)
        }
    }
}

final class PlayerContainerView: NSView {
    let playerLayer = AVPlayerLayer()
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); wantsLayer = true; playerLayer.videoGravity = .resizeAspectFill; layer?.addSublayer(playerLayer) }
    required init?(coder: NSCoder) { nil }
    override func layout() { super.layout(); playerLayer.frame = bounds }
}

struct PerformanceBar: View {
    @ObservedObject var model: WallpaperModel
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "leaf.fill").foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 3) {
                Text("Optimized for your Mac").font(.system(size: 14, weight: .semibold))
                Text(model.pauseReason ?? (model.isReducedQualityActive ? "Battery mode is reducing wallpaper quality." : "Wallpaper playback is running normally."))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.56))
            }
            Spacer()
            Button {
                model.activeTab = "Settings"
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(LiquidButtonStyle())
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(.white.opacity(0.12)))
    }
}

struct SettingsView: View {
    @ObservedObject var model: WallpaperModel

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Settings")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                Text("Control playback, power usage, and display quality.")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.62))
            }

            SettingsSection(title: "Playback") {
                SettingsToggleRow(
                    title: "Motion",
                    description: "Allow animated wallpapers to play.",
                    symbol: "play.fill",
                    isOn: $model.isPlaying
                )
                SettingsToggleRow(
                    title: "Pause when an app is full-screen",
                    description: "Pause while another app uses a full-screen window.",
                    symbol: "arrow.up.left.and.arrow.down.right",
                    isOn: $model.pauseOnFullscreen
                )
                SettingsToggleRow(
                    title: "Pause on high CPU usage",
                    description: "Pause after sustained system CPU usage above 80%.",
                    symbol: "gauge.with.dots.needle.67percent",
                    isOn: $model.pauseOnHighCPU
                )
            }

            SettingsSection(title: "Power & Display") {
                SettingsToggleRow(
                    title: "Reduce quality on battery",
                    description: "Use lower frame rate and video quality when running on battery.",
                    symbol: "battery.50percent",
                    isOn: $model.reduceQualityOnBattery
                )
                SettingsToggleRow(
                    title: "Retina rendering",
                    description: "Render wallpaper windows at the display's native scale.",
                    symbol: "sparkles.tv",
                    isOn: $model.retinaRendering
                )
            }

            SettingsSection(title: "System") {
                SettingsToggleRow(
                    title: "Video Wallpaper",
                    description: "Install the selected video in macOS Wallpaper for Desktop and Lock Screen.",
                    symbol: "rectangle.on.rectangle",
                    isOn: Binding(
                        get: { model.lockScreenVideoEnabled },
                        set: { model.setLockScreenVideo($0) }
                    )
                )
                SettingsToggleRow(
                    title: "Launch at Login",
                    description: "Start Lumen automatically when you sign in.",
                    symbol: "power",
                    isOn: Binding(
                        get: { model.launchAtLoginEnabled },
                        set: { model.setLaunchAtLogin($0) }
                    )
                )
            }

            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                Text(model.isOnBattery ? "On battery" : "Connected to power")
                Text("•")
                Text("CPU \(Int(model.cpuUsage.rounded()))%")
                if model.isFullscreenAppActive {
                    Text("• Full-screen app detected")
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.58))
        }
        .frame(maxWidth: 760, alignment: .leading)
        .padding(.top, 34)
        .padding(.bottom, 20)
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.5))
                .padding(.bottom, 8)
            VStack(spacing: 0) {
                content()
            }
            .padding(.horizontal, 18)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.12)))
        }
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let description: String
    let symbol: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 24)
                .foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 14)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(height: 1)
        }
    }
}

struct ImportHelpView: View { @Environment(\.dismiss) private var dismiss; var body: some View { VStack(alignment: .leading, spacing: 18) { HStack { Image(systemName: "plus.circle.fill").foregroundStyle(.cyan); Text("Add your own wallpapers").font(.system(size: 21, weight: .semibold, design: .rounded)); Spacer(); Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }; Text("Use the + button in the top bar or Import media on the main preview. Lumen copies the selected files into its own library, so you can safely move the originals later.").foregroundStyle(.secondary); Divider(); Text("Supported files").font(.headline); Text("Videos: .mov, .mp4, .m4v, .avi\nImages: .jpg, .jpeg, .png, .heic").foregroundStyle(.secondary); Text("Where to get them").font(.headline); Text("Use videos you created yourself, royalty-free clips from sites such as Pexels, Pixabay, Mixkit, or NASA media, and wallpapers you have permission to use. Avoid copyrighted videos from streaming services or content you do not own.").foregroundStyle(.secondary); Spacer() }.padding(28).frame(width: 470, height: 390).background(.ultraThinMaterial) } }

struct RenameWallpaperView: View {
    @Environment(\.dismiss) private var dismiss
    let wallpaper: Wallpaper
    let onSave: (String) -> Void
    @State private var title: String

    init(wallpaper: Wallpaper, onSave: @escaping (String) -> Void) {
        self.wallpaper = wallpaper
        self.onSave = onSave
        _title = State(initialValue: wallpaper.title)
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Rename wallpaper")
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .help("Close")
            }

            TextField("Wallpaper name", text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    guard !trimmedTitle.isEmpty else { return }
                    onSave(trimmedTitle)
                    dismiss()
                }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(trimmedTitle)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedTitle.isEmpty)
            }
        }
        .padding(26)
        .frame(width: 390)
        .background(.ultraThinMaterial)
    }
}

struct GlassTabStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
            .foregroundStyle(.white.opacity(isSelected ? 1 : 0.7))
            .frame(minWidth: 78, minHeight: 36)
            .contentShape(Capsule())
            .background(isSelected ? .white.opacity(0.16) : .clear, in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct GlassIconStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .frame(width: 36, height: 36)
            .contentShape(Circle())
            .background(.white.opacity(configuration.isPressed ? 0.18 : 0.09), in: Circle())
    }
}

struct LiquidButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .contentShape(Capsule())
            .background(.black.opacity(0.35), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.2)))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

enum LaunchAtLoginManager {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func enable() throws {
        try SMAppService.mainApp.register()
    }

    static func disable() throws {
        try SMAppService.mainApp.unregister()
    }
}

struct SystemPerformanceSample: Sendable {
    let isOnBattery: Bool
    let cpuUsage: Double?
    let isHighCPUUsage: Bool
}

actor SystemPerformanceSampler {
    private var previousCPUTicks: [UInt32]?
    private var consecutiveHighCPUSamples = 0

    func sample() -> SystemPerformanceSample {
        let cpuUsage = sampleCPUUsage()
        if let cpuUsage, cpuUsage >= 80 {
            consecutiveHighCPUSamples += 1
        } else {
            consecutiveHighCPUSamples = 0
        }

        return SystemPerformanceSample(
            isOnBattery: Self.isOnBatteryPower,
            cpuUsage: cpuUsage,
            isHighCPUUsage: consecutiveHighCPUSamples >= 2
        )
    }

    private static var isOnBatteryPower: Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else {
            return false
        }
        return source as String == kIOPSBatteryPowerValue
    }

    private func sampleCPUUsage() -> Double? {
        var cpuInfo = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &cpuInfo) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = withUnsafeBytes(of: cpuInfo.cpu_ticks) {
            Array($0.bindMemory(to: UInt32.self))
        }
        guard let previousCPUTicks else {
            self.previousCPUTicks = ticks
            return nil
        }
        self.previousCPUTicks = ticks
        let deltas = zip(ticks, previousCPUTicks).map { current, previous in
            current >= previous ? UInt64(current - previous) : UInt64(current)
        }
        let total = deltas.reduce(0, +)
        guard total > 0, deltas.count > Int(CPU_STATE_IDLE) else { return nil }
        let idle = deltas[Int(CPU_STATE_IDLE)]
        return Double(total - idle) / Double(total) * 100
    }
}

extension Color { init(hex: String) { let value = UInt64(hex, radix: 16) ?? 0; self.init(red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255, blue: Double(value & 0xff) / 255) } }

private extension NSColor {
    convenience init(hex: String) {
        let value = UInt64(hex, radix: 16) ?? 0
        self.init(
            red: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }
}

private extension NSScreen {
    var persistenceKey: String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (deviceDescription[key] as? NSNumber)?.stringValue ?? localizedName
    }
}

@MainActor
final class DesktopWallpaperController {
    var onOcclusionChange: ((_ screenKey: String, _ isVisible: Bool) -> Void)?

    private var windows: [NSWindow] = []
    private var hostViews: [NSHostingView<AnyView>] = []
    private var windowScreenKeys: [String] = []
    private var occlusionObservers: [NSObjectProtocol] = []
    private var activeWallpaper: Wallpaper?
    private var activeTargetScreenKeys: [String] = []

    func apply(
        wallpaper: Wallpaper,
        isPlaying: Bool,
        display: String,
        reducedQuality: Bool,
        retinaRendering: Bool,
        isSuspended: Bool
    ) {
        let screens = NSScreen.screens
            .filter {
                display == "All Displays"
                    || (display == "Built-in Display" ? $0 == NSScreen.main : $0 != NSScreen.main)
            }
            .sorted { $0.persistenceKey < $1.persistenceKey }
        let targetScreenKeys = screens.map(\.persistenceKey)
        let structureChanged = activeWallpaper != wallpaper || activeTargetScreenKeys != targetScreenKeys

        // Sleep keeps the window and player objects alive; wake-up only changes visibility.
        if isSuspended {
            removeOcclusionObservers()
            windowScreenKeys.forEach { onOcclusionChange?($0, true) }
            windows.forEach { $0.orderOut(nil) }
            return
        }

        if structureChanged || windows.count != screens.count || hostViews.count != screens.count {
            rebuildWindows(
                wallpaper: wallpaper,
                isPlaying: isPlaying,
                reducedQuality: reducedQuality,
                retinaRendering: retinaRendering,
                screens: screens,
                targetScreenKeys: targetScreenKeys
            )
            return
        }

        for (index, screen) in screens.enumerated() {
            updateWindow(
                at: index,
                screen: screen,
                wallpaper: wallpaper,
                isPlaying: isPlaying,
                reducedQuality: reducedQuality,
                retinaRendering: retinaRendering
            )
        }
        installOcclusionObservers()
        windows.forEach { $0.orderFrontRegardless() }
        for (window, screenKey) in zip(windows, windowScreenKeys) {
            onOcclusionChange?(screenKey, window.occlusionState.contains(.visible))
        }
    }

    private func rebuildWindows(
        wallpaper: Wallpaper,
        isPlaying: Bool,
        reducedQuality: Bool,
        retinaRendering: Bool,
        screens: [NSScreen],
        targetScreenKeys: [String]
    ) {
        removeOcclusionObservers()
        windowScreenKeys.forEach { onOcclusionChange?($0, true) }
        windowScreenKeys.removeAll()
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        hostViews.removeAll()

        activeWallpaper = wallpaper
        activeTargetScreenKeys = targetScreenKeys

        for screen in screens {
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            let hostView = NSHostingView(
                rootView: AnyView(makeRootView(
                    wallpaper: wallpaper,
                    isPlaying: isPlaying,
                    reducedQuality: reducedQuality,
                    retinaRendering: retinaRendering,
                    screen: screen
                ))
            )
            hostView.wantsLayer = true
            hostView.layer?.contentsScale = retinaRendering ? screen.backingScaleFactor : 1
            window.contentView = hostView
            windows.append(window)
            hostViews.append(hostView)
            windowScreenKeys.append(screen.persistenceKey)
        }

        installOcclusionObservers()
        windows.forEach { $0.orderFrontRegardless() }
        for (window, screenKey) in zip(windows, windowScreenKeys) {
            onOcclusionChange?(screenKey, window.occlusionState.contains(.visible))
        }
    }

    private func updateWindow(
        at index: Int,
        screen: NSScreen,
        wallpaper: Wallpaper,
        isPlaying: Bool,
        reducedQuality: Bool,
        retinaRendering: Bool
    ) {
        let scale = retinaRendering ? screen.backingScaleFactor : 1
        windows[index].setFrame(screen.frame, display: true)
        hostViews[index].rootView = AnyView(makeRootView(
            wallpaper: wallpaper,
            isPlaying: isPlaying,
            reducedQuality: reducedQuality,
            retinaRendering: retinaRendering,
            screen: screen
        ))
        hostViews[index].layer?.contentsScale = scale
    }

    private func makeRootView(
        wallpaper: Wallpaper,
        isPlaying: Bool,
        reducedQuality: Bool,
        retinaRendering: Bool,
        screen: NSScreen
    ) -> some View {
        WallpaperMediaView(
            wallpaper: wallpaper,
            isPlaying: isPlaying,
            reducedQuality: reducedQuality
        )
        .environment(\.displayScale, retinaRendering ? screen.backingScaleFactor : 1)
    }

    private func installOcclusionObservers() {
        guard occlusionObservers.isEmpty else { return }
        for (window, screenKey) in zip(windows, windowScreenKeys) {
            let observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                Task { @MainActor [weak self, weak window] in
                    guard let self, let window else { return }
                    self.onOcclusionChange?(screenKey, window.occlusionState.contains(.visible))
                }
            }
            occlusionObservers.append(observer)
        }
    }

    private func removeOcclusionObservers() {
        let notificationCenter = NotificationCenter.default
        occlusionObservers.forEach(notificationCenter.removeObserver)
        occlusionObservers.removeAll()
    }
}

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
        guard isInstalled else { return false }
        guard let assetID = configuredAssetID,
              let root = readPropertyList(at: wallpaperStoreURL) else { return false }
        return containsSelectedAsset(assetID, in: root)
    }

    var configuredVideoIsAvailable: Bool {
        guard let assetID = Self.configuredAssetID else { return false }
        return FileManager.default.isReadableFile(atPath: Self.videoURL(for: assetID).path)
    }

    var hasStoredConfiguration: Bool {
        UserDefaults.standard.string(forKey: Self.assetIDDefaultsKey) != nil
            || UserDefaults.standard.string(forKey: Self.configuredVideoPathDefaultsKey) != nil
    }

    func isConfigured(videoURL: URL) -> Bool {
        UserDefaults.standard.string(forKey: Self.configuredVideoPathDefaultsKey) == videoURL.path
            && Self.isInstalled
    }

    func installAndConfigure(videoURL: URL, title: String) throws {
        try configure(videoURL: videoURL, title: title)
        try selectInstalledAsset()
    }

    func configure(videoURL: URL) throws {
        let title = videoURL.deletingPathExtension().lastPathComponent
        try configure(videoURL: videoURL, title: title)
    }

    func configure(videoURL: URL, title: String) throws {
        guard FileManager.default.isReadableFile(atPath: videoURL.path) else {
            throw LockScreenVideoError.videoMissing
        }
        if isConfigured(videoURL: videoURL) {
            return
        }

        let assetID = Self.configuredAssetID ?? UUID().uuidString.uppercased()
        try Self.prepareAerialDirectories()
        try Self.installVideo(from: videoURL, assetID: assetID)
        try Self.installThumbnail(from: videoURL, assetID: assetID)
        try Self.registerAsset(assetID: assetID, title: Self.sanitizedTitle(title))

        UserDefaults.standard.set(assetID, forKey: Self.assetIDDefaultsKey)
        UserDefaults.standard.set(videoURL.path, forKey: Self.configuredVideoPathDefaultsKey)
        NSWorkspace.shared.noteFileSystemChanged(Self.aerialsURL.path)
        Self.refreshWallpaperAgent()
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
                selectedInPrimaryStore = Self.containsSelectedAsset(assetID, in: updated)
            }
        }
        Self.refreshWallpaperAgent()

        guard selectedInPrimaryStore else {
            throw LockScreenVideoError.selectionFailed
        }
    }

    func restorePreviousWallpaper() throws {
        let fileManager = FileManager.default
        let shouldRestoreSelection = Self.isSelected
        for storeURL in Self.wallpaperStoreURLs {
            let backupURL = Self.previousStoreURL(for: storeURL)
            if shouldRestoreSelection, fileManager.fileExists(atPath: backupURL.path) {
                guard let previous = Self.readPropertyList(at: backupURL) else {
                    throw LockScreenVideoError.invalidBackup
                }
                try Self.writePropertyList(previous, to: storeURL)
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
        UserDefaults.standard.removeObject(forKey: Self.assetIDDefaultsKey)
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
            throw LockScreenVideoError.thumbnailFailed(error.localizedDescription)
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

    private static func registerAsset(assetID: String, title: String) throws {
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
            "accessibilityLabel": title,
            "categories": [categoryID],
            "id": assetID,
            "includeInShuffle": false,
            "localizedNameKey": title,
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

    private static func replacingWallpaperSections(
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

    private static func sanitizedTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Lumen Wallpaper" : trimmed
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
