import Foundation

struct WallpaperAgentConfiguration: Codable, Equatable {
    let wallpaper: Wallpaper
    let display: String
    let isPlaying: Bool
    let reduceQualityOnBattery: Bool
    let pauseOnFullscreen: Bool
    let pauseOnHighCPU: Bool
    let retinaRendering: Bool
    var sessionID: String? = nil

    var canAnimate: Bool {
        sessionID != nil && isPlaying && wallpaper.kind != .image
    }

    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LumenWallpapers/agent.json")
    }

    func save() throws {
        let url = Self.fileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    static func load(from url: URL = fileURL) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}
