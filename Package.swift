// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LumenWallpapers",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "LumenWallpapers", targets: ["LumenWallpapers"])],
    targets: [
        .executableTarget(
            name: "LumenWallpapers",
            exclude: ["lumenwallpaper.png"]
        )
    ]
)
