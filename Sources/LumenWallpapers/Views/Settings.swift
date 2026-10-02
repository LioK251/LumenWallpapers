import SwiftUI
import AppKit

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
                    symbol: "sparkles",
                    isOn: $model.retinaRendering
                )
            }

            SettingsSection(title: "Discover Sources") {
                SettingsTextFieldRow(
                    title: "Wallhaven API Key",
                    description: "Optional key from wallhaven.cc/account — required by Wallhaven for NSFW results.",
                    symbol: "photo.badge.checkmark",
                    placeholder: "Paste your Wallhaven API key",
                    text: $model.wallhavenAPIKey
                )
                SettingsTextFieldRow(
                    title: "Pexels API Key",
                    description: "Free key from pexels.com/api — powers video results in the Discover tab.",
                    symbol: "video.badge.plus",
                    placeholder: "Paste your Pexels API key",
                    text: $model.pexelsAPIKey
                )
                SettingsToggleRow(
                    title: "Include NSFW image results",
                    description: "Allow Wallhaven searches to include NSFW and sketchy content.",
                    symbol: "eye.trianglebadge.exclamationmark",
                    isOn: $model.allowNSFWSearch
                )
            }

            SettingsSection(title: "System") {
                SettingsToggleRow(
                    title: "Keep Animating After Quit",
                    description: "Continue live wallpaper in a small background process after closing Lumen.",
                    symbol: "sparkles.tv",
                    isOn: $model.keepAnimatingAfterQuit
                )
                SettingsToggleRow(
                    title: "Video Wallpaper",
                    description: "Use selected videos on the desktop and lock screen. This stays enabled when you choose an image.",
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

            SettingsSection(title: "About Lumen") {
                HStack {
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")")
                    Spacer()
                    Link(destination: ReleaseUpdateChecker.repositoryURL) {
                        Label("GitHub", systemImage: "arrow.up.right.square")
                    }
                }
                .padding(.vertical, 16)
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

private struct SettingsTextFieldRow: View {
    let title: String
    let description: String
    let symbol: String
    let placeholder: String
    @Binding var text: String

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
            SecureField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .frame(width: 220, height: 30)
                .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(height: 1)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(isSelected ? 1 : 0.7))
            .frame(minWidth: 78, minHeight: 36)
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.97 : 1))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct GlassIconStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .frame(width: 36, height: 36)
            .contentShape(Circle())
            .background(.white.opacity(configuration.isPressed ? 0.18 : 0.09), in: Circle())
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.94 : 1))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct LiquidButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .contentShape(Capsule())
            .background(.black.opacity(0.35), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.2)))
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.97 : 1))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
