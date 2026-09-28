import SwiftUI
import AppKit
import AVKit
import AVFoundation
import QuickLookThumbnailing

@MainActor
enum WallpaperImageCache {
    private static let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.totalCostLimit = 128 * 1024 * 1024
        return cache
    }()

    static func image(for url: URL) -> NSImage? {
        if let image = cache.object(forKey: url as NSURL) { return image }
        guard let image = NSImage(contentsOf: url) else { return nil }
        let cost = Int(image.size.width * image.size.height * 4)
        cache.setObject(image, forKey: url as NSURL, cost: cost)
        return image
    }
}

@MainActor
final class VideoPosterCache {
    static let shared = VideoPosterCache()

    private let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()
    private var requests: [URL: Task<NSImage?, Never>] = [:]

    func image(for url: URL) async -> NSImage? {
        if let image = cache.object(forKey: url as NSURL) { return image }
        if let task = requests[url] { return await task.value }

        let task = Task<NSImage?, Never> {
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: 440, height: 264),
                scale: 1,
                representationTypes: .thumbnail
            )
            return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        }
        requests[url] = task
        let image = await task.value
        requests[url] = nil
        if let image {
            let cost = Int(image.size.width * image.size.height * 4)
            cache.setObject(image, forKey: url as NSURL, cost: cost)
        }
        return image
    }
}

struct VideoPosterView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                LinearGradient(colors: [Color(hex: "334155"), Color(hex: "0F172A")], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: image != nil)
        .task(id: url) {
            image = nil
            let poster = await VideoPosterCache.shared.image(for: url)
            guard !Task.isCancelled else { return }
            image = poster
        }
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
                Image(nsImage: WallpaperImageCache.image(for: url) ?? NSImage())
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(colors: wallpaper.swiftColors, startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
    }
}

/// Fills the app window with imported still images.
///
/// The app background is intentionally a full-bleed surface: fitting an unusually wide
/// image (for example, 5000×2237) leaves horizontal bars, so the excess edges are
/// cropped instead of being replaced with a blurred duplicate of the image.
struct WallpaperPreviewImage: View {
    let image: NSImage

    var body: some View {
        GeometryReader { proxy in
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
        }
    }
}

struct LiveWallpaperCanvas: View {
    let wallpaper: Wallpaper
    let isPlaying: Bool
    let reducedQuality: Bool

    private var frameInterval: Double {
        reducedQuality ? 1.0 / 15.0 : 1.0 / 24.0
    }

    private var blobCount: Int {
        reducedQuality ? 4 : 8
    }

    var body: some View {
        let colors = wallpaper.swiftColors
        ZStack {
            StaticWallpaperBackground(colors: colors)
            TimelineView(.animation(minimumInterval: isPlaying ? frameInterval : 3600, paused: !isPlaying)) { context in
                Canvas { graphics, size in
                    let rect = CGRect(origin: .zero, size: size)
                    let t = context.date.timeIntervalSinceReferenceDate
                    for index in 0..<blobCount {
                        let x = size.width * (0.12 + CGFloat(index % 3) * 0.39) + sin(t * 0.2 + Double(index)) * (reducedQuality ? 48 : 90)
                        let y = size.height * (0.18 + CGFloat(index / 3) * 0.32) + cos(t * 0.16 + Double(index)) * (reducedQuality ? 28 : 52)
                        let radius = (reducedQuality ? 64 : 80) + CGFloat(index * (reducedQuality ? 6 : 9))
                        graphics.fill(
                            Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                            with: .radialGradient(
                                Gradient(colors: [colors[index % colors.count].opacity(0.56), .clear]),
                                center: CGPoint(x: x, y: y),
                                startRadius: 0,
                                endRadius: radius
                            )
                        )
                    }
                    // Keep the moving-layer scrim above the blobs; the static gradient is cached below.
                    graphics.fill(Path(rect), with: .color(.black.opacity(0.12)))
                }
            }
        }
    }
}

private struct StaticWallpaperBackground: View {
    let colors: [Color]

    var body: some View {
        Canvas { graphics, size in
            let rect = CGRect(origin: .zero, size: size)
            graphics.fill(
                Path(rect),
                with: .linearGradient(
                    Gradient(colors: colors.map { $0.opacity(0.9) }),
                    startPoint: CGPoint(x: 0, y: size.height),
                    endPoint: CGPoint(x: size.width, y: 0)
                )
            )
        }
    }
}

struct VideoSurface: NSViewRepresentable {
    @Environment(\.displayScale) private var displayScale
    let url: URL
    let isPlaying: Bool
    let reducedQuality: Bool
    var videoGravity: AVLayerVideoGravity = .resizeAspectFill
    var onReady: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(url: url, reducedQuality: reducedQuality) }

    func makeNSView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView(videoGravity: videoGravity)
        view.playerLayer.player = context.coordinator.player
        view.playerLayer.contentsScale = displayScale
        view.onReady = onReady
        context.coordinator.setPlaying(isPlaying)
        return view
    }

    func updateNSView(_ view: PlayerContainerView, context: Context) {
        view.playerLayer.contentsScale = displayScale
        view.playerLayer.videoGravity = videoGravity
        view.onReady = onReady
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
    var onReady: (() -> Void)? {
        didSet {
            if playerLayer.isReadyForDisplay {
                DispatchQueue.main.async { [weak self] in
                    self?.onReady?()
                }
            }
        }
    }
    private var readinessObserver: NSKeyValueObservation?

    private func observeReadiness() {
        readinessObserver = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            DispatchQueue.main.async { [weak self] in
                self?.onReady?()
            }
        }
    }

    init(videoGravity: AVLayerVideoGravity = .resizeAspectFill) {
        super.init(frame: .zero)
        wantsLayer = true
        playerLayer.videoGravity = videoGravity
        layer?.addSublayer(playerLayer)
        observeReadiness()
    }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
        observeReadiness()
    }
    required init?(coder: NSCoder) { nil }
    override func layout() { super.layout(); playerLayer.frame = bounds }
}
