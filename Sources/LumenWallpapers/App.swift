import SwiftUI
import AppKit

@MainActor
final class LumenApplicationDelegate: NSObject, NSApplicationDelegate {
    var reopenMainWindow: (() -> Void)?
    var handoffWallpaperOnQuit: (() -> Void)?

    func applicationWillTerminate(_ notification: Notification) {
        handoffWallpaperOnQuit?()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        reopenMainWindow?()
        return true
    }
}

@main
struct LumenWallpapersApp: App {
    @NSApplicationDelegateAdaptor(LumenApplicationDelegate.self) private var applicationDelegate
    @StateObject private var model = WallpaperModel()
    @Environment(\.openWindow) private var openWindow

    private func showMainWindow(tab: String? = nil) {
        if let tab {
            model.activeTab = tab
        }
        NSApp.unhide(nil)
        openWindow(id: "main")
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        Window("Lumen", id: "main") {
            MainWindowRoot(model: model, applicationDelegate: applicationDelegate)
                .frame(minWidth: 1080, minHeight: 720)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        MenuBarExtra("Lumen", systemImage: "sparkles") {
            Button(model.isPlaying ? "Pause Wallpaper" : "Resume Wallpaper") { model.isPlaying.toggle() }
            Button("Settings") {
                showMainWindow(tab: "Settings")
            }
            Divider()
            Button("Open Lumen") { showMainWindow() }
            Button("Quit") { NSApp.terminate(nil) }
        }
    }
}

private struct MainWindowRoot: View {
    @ObservedObject var model: WallpaperModel
    let applicationDelegate: LumenApplicationDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        DashboardView(model: model)
            .onAppear {
                applicationDelegate.handoffWallpaperOnQuit = { model.handoffWallpaperOnQuit() }
                applicationDelegate.reopenMainWindow = {
                    NSApp.unhide(nil)
                    openWindow(id: "main")
                    DispatchQueue.main.async {
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
            }
    }
}
