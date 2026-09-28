import SwiftUI
import AppKit

enum DiscoverSource: String, CaseIterable, Identifiable {
    case wallhaven = "Images"
    case pexels = "Video"
    var id: String { rawValue }
}

struct DiscoverView: View {
    @ObservedObject var model: WallpaperModel
    @State private var source: DiscoverSource = .wallhaven

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Discover")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                Spacer()
                Picker("", selection: $source) {
                    ForEach(DiscoverSource.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
            }

            if source == .wallhaven {
                WallhavenDiscoverPane(model: model)
            } else {
                PexelsDiscoverPane(model: model)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct WallhavenDiscoverPane: View {
    @ObservedObject var model: WallpaperModel
    @StateObject private var browse = WallhavenBrowseModel()
    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 18)]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Wallpaper images")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Link("Browse on wallhaven.cc ↗", destination: URL(string: "https://wallhaven.cc")!)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
            }

            HStack(spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                    TextField("Search Wallhaven (e.g. \"cyberpunk\", \"nature\")", text: $browse.query)
                        .textFieldStyle(.plain)
                        .onSubmit { browse.runSearch(includeNSFW: model.allowNSFWSearch, apiKey: model.wallhavenAPIKey) }
                }
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(.black.opacity(0.2), in: Capsule())
                .frame(maxWidth: 380)

                Button("Search") { browse.runSearch(includeNSFW: model.allowNSFWSearch, apiKey: model.wallhavenAPIKey) }
                    .buttonStyle(LiquidButtonStyle())
            }

            Text(model.allowNSFWSearch ? "Wallhaven results include NSFW and sketchy content. Wallpapers are community-submitted — tap a card's link to check the uploader's terms before commercial use." : "SFW results only, pulled from Wallhaven's public API. Wallpapers are community-submitted — tap a card's link to check the uploader's terms before commercial use.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))

            if let error = browse.errorMessage {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
            }

            if browse.results.isEmpty && !browse.isLoading {
                Text("Search above to browse wallpapers you can import into your library.")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.58))
                    .padding(.vertical, 32)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                    ForEach(browse.results) { item in
                        WallhavenCard(item: item, model: model)
                            .onAppear { browse.loadMoreIfNeeded(currentItem: item, includeNSFW: model.allowNSFWSearch, apiKey: model.wallhavenAPIKey) }
                    }
                }
            }

            if browse.isLoading {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
                .padding(.vertical, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { if browse.results.isEmpty { browse.runSearch(includeNSFW: model.allowNSFWSearch, apiKey: model.wallhavenAPIKey) } }
        .onChange(of: model.allowNSFWSearch) { _, includeNSFW in
            browse.runSearch(includeNSFW: includeNSFW, apiKey: model.wallhavenAPIKey)
        }
        .onChange(of: model.wallhavenAPIKey) { _, apiKey in
            browse.runSearch(includeNSFW: model.allowNSFWSearch, apiKey: apiKey)
        }
    }
}

struct WallhavenCard: View {
    let item: WallhavenWallpaper
    @ObservedObject var model: WallpaperModel
    @State private var isHovered = false
    @State private var isDownloading = false
    private var downloadedWallpaper: Wallpaper? {
        model.wallpaperForWallhaven(item)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                AsyncImage(url: URL(string: item.thumbs.large)) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        Color.black.opacity(0.3)
                    default:
                        Color.black.opacity(0.2).overlay(ProgressView().controlSize(.small))
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
                            _ = await model.downloadWallhaven(item)
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
            Text(item.resolution)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            Link("View on Wallhaven", destination: URL(string: item.url) ?? URL(string: "https://wallhaven.cc")!)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(width: 220, alignment: .leading)
        .scaleEffect(isHovered ? 1.025 : 1)
        .opacity(isHovered ? 1 : 0.94)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.18)) { isHovered = hovering }
        }
    }
}
