import SwiftUI
import AppKit

struct PexelsDiscoverPane: View {
    @ObservedObject var model: WallpaperModel
    @StateObject private var browse = PexelsBrowseModel()
    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 18)]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Video wallpapers")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Link("Get a free Pexels API key ↗", destination: URL(string: "https://www.pexels.com/api/")!)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
            }

            if model.pexelsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("No Pexels API key yet")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Pexels' free API gives you royalty-free 4K video clips you can set as live wallpapers. Grab a key (instant, no cost) and paste it into Settings → Discover Sources.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                    Button {
                        model.activeTab = "Settings"
                    } label: {
                        Label("Open Settings", systemImage: "gearshape")
                    }
                    .buttonStyle(LiquidButtonStyle())
                }
                .padding(18)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.12)))
            } else {
                HStack(spacing: 8) {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass")
                        TextField("Search Pexels (e.g. \"rain\", \"city night\")", text: $browse.query)
                            .textFieldStyle(.plain)
                            .onSubmit { browse.runSearch(apiKey: model.pexelsAPIKey) }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(.black.opacity(0.2), in: Capsule())
                    .frame(maxWidth: 380)

                    Button("Search") { browse.runSearch(apiKey: model.pexelsAPIKey) }
                        .buttonStyle(LiquidButtonStyle())
                }

                Text("Royalty-free video clips from Pexels, downloaded at up to 4K. Free to use, no attribution required — the source link on each card is there if you want to credit the creator anyway.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))

                if let error = browse.errorMessage {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(.orange)
                }

                if browse.results.isEmpty && !browse.isLoading {
                    Text("Search above to browse video clips you can import as live wallpapers.")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.58))
                        .padding(.vertical, 32)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                        ForEach(browse.results) { item in
                            PexelsVideoCard(item: item, model: model)
                                .onAppear { browse.loadMoreIfNeeded(currentItem: item, apiKey: model.pexelsAPIKey) }
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            if browse.results.isEmpty, !model.pexelsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                browse.runSearch(apiKey: model.pexelsAPIKey)
            }
        }
        .onChange(of: model.pexelsAPIKey) { _, apiKey in
            if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                browse.runSearch(apiKey: apiKey)
            }
        }
    }
}

struct PexelsVideoCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let item: PexelsVideo
    @ObservedObject var model: WallpaperModel
    @State private var isHovered = false
    @State private var isDownloading = false

    private var downloadedWallpaper: Wallpaper? {
        model.wallpaperForPexels(item)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                AsyncImage(url: item.previewImageURL, transaction: Transaction(animation: reduceMotion ? nil : .easeOut(duration: 0.18))) { phase in
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
                .overlay(alignment: .topLeading) {
                    Text(item.durationLabel)
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(9)
                }
                .overlay {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .padding(9)
                        .background(.black.opacity(0.4), in: Circle())
                }

                Button {
                    if let downloadedWallpaper {
                        model.select(downloadedWallpaper)
                    } else if !isDownloading {
                        isDownloading = true
                        Task {
                            _ = await model.downloadPexelsVideo(item)
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
            .overlay(alignment: .bottomLeading) {
                DiscoverRemoveButton(wallpaper: downloadedWallpaper, isHovered: isHovered, model: model)
                    .padding(9)
            }
            Text("\(item.width)×\(item.height)")
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            Link("View on Pexels", destination: URL(string: item.url) ?? URL(string: "https://www.pexels.com")!)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(width: 220, alignment: .leading)
        .scaleEffect(reduceMotion ? 1 : (isHovered ? 1.015 : 1))
        .opacity(isHovered ? 1 : 0.96)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
