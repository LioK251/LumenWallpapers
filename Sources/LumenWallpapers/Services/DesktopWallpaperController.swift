import SwiftUI
import AppKit

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
        let builtInScreen = NSScreen.screens.first(where: \.isBuiltIn)
        let screens = NSScreen.screens
            .filter { screen in
                display == "All Displays"
                    || (display == "Built-in Display"
                        ? screen == (builtInScreen ?? NSScreen.main)
                        : builtInScreen.map { screen != $0 } ?? true)
            }
            .sorted { $0.persistenceKey < $1.persistenceKey }
        let targetScreenKeys = screens.map(\.persistenceKey)
        let structureChanged = activeWallpaper != wallpaper || activeTargetScreenKeys != targetScreenKeys

        // Sleep keeps the window and player objects alive; wake-up only changes visibility.
        if isSuspended {
            for (index, screen) in screens.enumerated() where index < hostViews.count {
                updateWindow(
                    at: index,
                    screen: screen,
                    wallpaper: wallpaper,
                    isPlaying: false,
                    reducedQuality: reducedQuality,
                    retinaRendering: retinaRendering
                )
            }
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
