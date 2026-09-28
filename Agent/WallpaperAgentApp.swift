import AppKit
import Darwin
import Foundation

@main
@MainActor
struct LumenWallpaperAgent {
    private static var delegate: WallpaperAgentDelegate?

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let delegate = WallpaperAgentDelegate()
        self.delegate = delegate
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class WallpaperAgentDelegate: NSObject, NSApplicationDelegate {
    private let parentPID: pid_t
    private let configurationURL: URL
    private let controller = DesktopWallpaperController()
    private let sampler = SystemPerformanceSampler()
    private var configuration: WallpaperAgentConfiguration?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var isOnBattery = false
    private var isHighCPUUsage = false
    private var isFullscreenAppActive = false
    private var occludedScreenKeys = Set<String>()
    private var isSystemSleeping = false
    private var areScreensSleeping = false
    private var isActive = false
    private var isSampling = false
    private var lockDescriptor: Int32 = -1

    override init() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--parent-pid"), arguments.indices.contains(index + 1) {
            parentPID = pid_t(arguments[index + 1]) ?? 0
        } else {
            parentPID = 0
        }
        if let index = arguments.firstIndex(of: "--configuration"), arguments.indices.contains(index + 1) {
            configurationURL = URL(fileURLWithPath: arguments[index + 1])
        } else {
            configurationURL = WallpaperAgentConfiguration.fileURL
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            configuration = try WallpaperAgentConfiguration.load(from: configurationURL)
        } catch {
            NSApp.terminate(nil)
            return
        }
        let lockPath = configurationURL.deletingLastPathComponent()
            .appendingPathComponent("agent.lock").path
        lockDescriptor = open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard lockDescriptor >= 0, flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            NSApp.terminate(nil)
            return
        }

        controller.onOcclusionChange = { [weak self] screenKey, isVisible in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasFullscreen = self.isFullscreenAppActive
                if isVisible {
                    self.occludedScreenKeys.remove(screenKey)
                } else {
                    self.occludedScreenKeys.insert(screenKey)
                }
                self.isFullscreenAppActive = !self.occludedScreenKeys.isEmpty
                if self.configuration?.pauseOnFullscreen == true, wasFullscreen != self.isFullscreenAppActive {
                    self.sync()
                }
            }
        }

        let center = NSWorkspace.shared.notificationCenter
        for (name, isSleeping) in [
            (NSWorkspace.willSleepNotification, true),
            (NSWorkspace.screensDidSleepNotification, true),
            (NSWorkspace.didWakeNotification, false),
            (NSWorkspace.screensDidWakeNotification, false)
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if name == NSWorkspace.screensDidSleepNotification || name == NSWorkspace.screensDidWakeNotification {
                        self.areScreensSleeping = isSleeping
                    } else {
                        self.isSystemSleeping = isSleeping
                    }
                    self.sync()
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sync() }
        })

        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    private func tick() {
        if parentPID > 0, kill(parentPID, 0) == 0 { return }
        if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.lumen.wallpapers").isEmpty {
            NSApp.terminate(nil)
            return
        }
        if let updated = try? WallpaperAgentConfiguration.load(from: configurationURL), updated != configuration {
            configuration = updated
            sync()
        }
        if !isActive {
            isActive = true
            sync()
        }
        guard !isSampling else { return }
        isSampling = true
        Task {
            let sample = await sampler.sample()
            isSampling = false
            let oldQuality = isOnBattery
            let oldCPU = isHighCPUUsage
            isOnBattery = sample.isOnBattery
            isHighCPUUsage = sample.isHighCPUUsage
            if oldQuality != isOnBattery || oldCPU != isHighCPUUsage { sync() }
        }
    }

    private func sync() {
        guard isActive, let configuration else { return }
        controller.apply(
            wallpaper: configuration.wallpaper,
            isPlaying: configuration.isPlaying
                && !isSystemSleeping
                && !areScreensSleeping
                && !(configuration.pauseOnFullscreen && isFullscreenAppActive)
                && !(configuration.pauseOnHighCPU && isHighCPUUsage),
            display: configuration.display,
            reducedQuality: configuration.reduceQualityOnBattery && isOnBattery,
            retinaRendering: configuration.retinaRendering,
            isSuspended: isSystemSleeping || areScreensSleeping
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        if lockDescriptor >= 0 { close(lockDescriptor) }
    }
}
