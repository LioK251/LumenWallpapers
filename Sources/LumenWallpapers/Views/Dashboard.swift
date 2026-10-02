import SwiftUI
import AppKit

struct DashboardView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                            if model.recommendations.isEmpty {
                                WallpaperRow(title: "Recommended for you", wallpapers: Array(model.filteredWallpapers.prefix(6)), model: model, onRename: { renameTarget = $0 }, onRemove: { removeTarget = $0 })
                            } else {
                                RecommendationRow(model: model, recommendations: model.recommendations)
                            }
                            WallpaperRow(title: "My media", wallpapers: model.wallpapers.filter { $0.kind != .procedural }, model: model, emptyText: "Import a video or image to start your library", onRename: { renameTarget = $0 }, onRemove: { removeTarget = $0 })
                            PerformanceBar(model: model)
                        } else if model.activeTab == "Discover" {
                            DiscoverView(model: model)
                        } else if model.activeTab == "Settings" {
                            SettingsView(model: model)
                        } else {
                            LibraryGrid(model: model, wallpapers: model.filteredWallpapers, title: "My Library", emptyText: "Import a video or image to start your library", onRename: { renameTarget = $0 }, onRemove: { removeTarget = $0 })
                        }
                    }
                    .id(model.activeTab)
                    .transition(.opacity)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.activeTab)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 46)
                    .padding(.top, 12)
                    .padding(.bottom, 36)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .alert("Lumen", isPresented: Binding(get: { model.importError != nil }, set: { if !$0 { model.importError = nil } })) { Button("OK") {} } message: { Text(model.importError ?? "") }
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
        .task { model.refreshRecommendations() }
    }
}

struct FullscreenWallpaperBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var nativeDisplayScale
    @State private var layers: [Wallpaper]
    @State private var outgoingID: UUID?
    @State private var outgoingOpacity = 0.0
    @State private var readyVideoID: UUID?
    @State private var transitionID = UUID()
    @State private var transitionTask: Task<Void, Never>?
    @State private var isFadingOut = false
    let wallpaper: Wallpaper
    let isPlaying: Bool
    let reducedQuality: Bool
    let retinaRendering: Bool

    init(wallpaper: Wallpaper, isPlaying: Bool, reducedQuality: Bool, retinaRendering: Bool) {
        self.wallpaper = wallpaper
        self.isPlaying = isPlaying
        self.reducedQuality = reducedQuality
        self.retinaRendering = retinaRendering
        _layers = State(initialValue: [wallpaper])
    }

    var body: some View {
        ZStack {
            ForEach(layers) { item in
                media(for: item, onReady: item.id == wallpaper.id ? {
                    guard layers.first?.id == item.id else { return }
                    guard readyVideoID != item.id else { return }
                    readyVideoID = item.id
                    if outgoingID != nil { fadeOut(transitionID) }
                } : nil)
                .opacity(item.id == outgoingID ? outgoingOpacity : 1)
                .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
        .environment(\.displayScale, retinaRendering && !reducedQuality ? nativeDisplayScale : 1)
        .onChange(of: wallpaper) { previous, next in
            guard previous.id != next.id else {
                layers = layers.map { $0.id == next.id ? next : $0 }
                return
            }
            transitionTask?.cancel()
            transitionID = UUID()
            readyVideoID = nil
            guard !reduceMotion else {
                layers = [next]
                outgoingID = nil
                isFadingOut = false
                return
            }
            if next.id == outgoingID {
                layers = [next]
                outgoingID = nil
                isFadingOut = false
                return
            }
            let prior = isFadingOut ? previous : (layers.first { $0.id == outgoingID } ?? previous)
            isFadingOut = false
            layers = [next, prior]
            outgoingID = prior.id
            outgoingOpacity = 1
            let id = transitionID
            if next.kind != .video {
                fadeOut(id)
            } else {
                transitionTask = Task {
                    try? await Task.sleep(for: .milliseconds(800))
                    guard !Task.isCancelled else { return }
                    fadeOut(id)
                }
            }
        }
        .onChange(of: reduceMotion) { _, enabled in
            if enabled {
                transitionTask?.cancel()
                layers = [wallpaper]
                outgoingID = nil
            }
        }
        .onDisappear { transitionTask?.cancel() }
    }

    @ViewBuilder
    private func media(for item: Wallpaper, onReady: (() -> Void)?) -> some View {
        if item.kind == .procedural {
            LiveWallpaperCanvas(wallpaper: item, isPlaying: isPlaying, reducedQuality: reducedQuality)
        } else if item.kind == .video, let url = item.url {
            VideoSurface(url: url, isPlaying: isPlaying, reducedQuality: reducedQuality, onReady: onReady)
        } else if let url = item.url {
            WallpaperPreviewImage(image: WallpaperImageCache.image(for: url) ?? NSImage())
        } else {
            Color.black
        }
    }

    private func fadeOut(_ id: UUID) {
        guard transitionID == id, outgoingID != nil, !isFadingOut else { return }
        transitionTask?.cancel()
        isFadingOut = true
        withAnimation(.easeInOut(duration: 0.24)) {
            outgoingOpacity = 0
        }
        transitionTask = Task {
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled, transitionID == id else { return }
            layers.removeAll { $0.id == outgoingID }
            outgoingID = nil
        }
    }
}

struct TopGlassBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var tabNamespace
    @ObservedObject var model: WallpaperModel; @Binding var showImportHelp: Bool
    var body: some View {
        HStack {
            Spacer()

            HStack(spacing: 3) {
                ForEach(["Home", "Discover", "My Library", "Settings"], id: \.self) { tab in
                    Button(tab) {
                        model.activeTab = tab
                    }
                    .buttonStyle(GlassTabStyle(isSelected: model.activeTab == tab))
                    .background {
                        if model.activeTab == tab {
                            Capsule()
                                .fill(.white.opacity(0.16))
                                .matchedGeometryEffect(id: "activeTab", in: tabNamespace)
                        }
                    }
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: model.activeTab)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: WallpaperModel
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Spacer(minLength: 180)
            Text(model.selected.category.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(1.6)
                .foregroundStyle(.white.opacity(0.66))
                .contentTransition(.opacity)
            Text(model.selected.title)
                .font(.system(size: 46, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .contentTransition(.opacity)
            Text(model.selected.subtitle)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
                .contentTransition(.opacity)
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
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.selected.id)
        .frame(maxWidth: .infinity, minHeight: 430, alignment: .bottomLeading)
        .padding(.bottom, 8)
    }
}

struct WallpaperRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                        model.activeTab = "My Library"
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
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: wallpapers.map(\.id))
    }
}

struct RecommendationRow: View {
    @ObservedObject var model: WallpaperModel
    let recommendations: [DiscoverRecommendation]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Recommended for you")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                Spacer()
                Button {
                    model.refreshRecommendations()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(GlassIconStyle())
                .help("Refresh recommendations")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(recommendations) { recommendation in
                        RecommendationCard(recommendation: recommendation, model: model)
                    }
                }
            }
        }
    }
}

struct RecommendationCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let recommendation: DiscoverRecommendation
    @ObservedObject var model: WallpaperModel
    @State private var isDownloading = false
    @State private var isHovered = false

    private var downloadedWallpaper: Wallpaper? {
        switch recommendation {
        case .image(let item): return model.wallpaperForWallhaven(item)
        case .video(let item): return model.wallpaperForPexels(item)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                AsyncImage(url: recommendation.previewURL, transaction: Transaction(animation: reduceMotion ? nil : .easeOut(duration: 0.18))) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    case .failure: Color.black.opacity(0.3)
                    default: Color.black.opacity(0.2).overlay(ProgressView().controlSize(.small))
                    }
                }
                .frame(width: 220, height: 132)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .contentShape(RoundedRectangle(cornerRadius: 16))
                .onTapGesture {
                    if let downloadedWallpaper { model.select(downloadedWallpaper) }
                }

                Button {
                    if let downloadedWallpaper {
                        model.select(downloadedWallpaper)
                    } else if !isDownloading {
                        isDownloading = true
                        Task {
                            switch recommendation {
                            case .image(let item): _ = await model.downloadWallhaven(item)
                            case .video(let item): _ = await model.downloadPexelsVideo(item)
                            }
                            isDownloading = false
                        }
                    }
                } label: {
                    if isDownloading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: downloadedWallpaper == nil ? "arrow.down" : "checkmark")
                    }
                }
                .buttonStyle(CardActionButtonStyle())
                .padding(9)
                .help(downloadedWallpaper == nil ? "Download and use wallpaper" : "Use downloaded wallpaper")
            }
            Text(recommendation.title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            Text(recommendation.subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.56))
        }
        .frame(width: 220, alignment: .leading)
        .scaleEffect(reduceMotion ? 1 : (isHovered ? 1.015 : 1))
        .opacity(isHovered ? 1 : 0.96)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isHovered)
        .onHover { isHovered = $0 }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let wallpaper: Wallpaper
    let isSelected: Bool
    let onSelect: () -> Void
    let onRename: (Wallpaper) -> Void
    let onRemove: (Wallpaper) -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if wallpaper.kind == .video, let url = wallpaper.url {
                        VideoPosterView(url: url)
                    } else {
                        WallpaperMediaView(wallpaper: wallpaper, isPlaying: false, reducedQuality: true)
                    }
                }
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
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
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
        .scaleEffect(reduceMotion ? 1 : (isHovered ? 1.015 : 1))
        .opacity(isHovered ? 1 : 0.96)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(isSelected ? 0.65 : 0), lineWidth: 1.5))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isHovered)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isSelected)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

struct CardActionButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .frame(width: 30, height: 30)
            .contentShape(Circle())
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().stroke(.white.opacity(0.22)))
            .opacity(configuration.isPressed ? 0.65 : 1)
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.94 : 1))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
