import SwiftUI
import AppKit

@MainActor
final class LumenApplicationDelegate: NSObject, NSApplicationDelegate {
    var reopenMainWindow: (() -> Void)?
    var handoffWallpaperOnQuit: (() -> Bool)?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if handoffWallpaperOnQuit?() == false {
            reopenMainWindow?()
            return .terminateCancel
        }
        return .terminateNow
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
    @StateObject private var updates = ReleaseUpdateChecker()
    let applicationDelegate: LumenApplicationDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        DashboardView(model: model)
            .task { await updates.checkIfNeeded() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await updates.checkIfNeeded() }
            }
            .sheet(item: $updates.availableRelease) { release in
                VStack(alignment: .leading, spacing: 18) {
                    Label("Lumen \(release.tag_name) is available", systemImage: "arrow.down.circle.fill")
                        .font(.title2.weight(.semibold))
                    Text("A new version is ready on GitHub. View the release notes and download the latest app.")
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Dismiss") { updates.availableRelease = nil }
                            .keyboardShortcut(.cancelAction)
                        Spacer()
                        Button("View Release") {
                            NSWorkspace.shared.open(release.url)
                            updates.availableRelease = nil
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(28)
                .frame(width: 430)
                .onAppear { updates.markPresented(release) }
            }
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
