import SwiftUI
import Foundation

enum WallpaperKind: String, Codable { case procedural, video, image }

struct Wallpaper: Identifiable, Hashable, Codable {
    var id: UUID
    var title: String
    var subtitle: String
    var symbol: String
    var colors: [String]
    var category: String
    var kind: WallpaperKind
    var sourceURL: String?
    var attributionURL: String? = nil

    var swiftColors: [Color] {
        colors.isEmpty ? [Color(hex: "334155")] : colors.map { Color(hex: $0) }
    }
    var url: URL? { sourceURL.flatMap(URL.init(fileURLWithPath:)) }
    var persistenceKey: String {
        kind == .procedural ? "builtin:\(title)" : "import:\(id.uuidString)"
    }

    static func builtIn(_ title: String, _ subtitle: String, _ symbol: String, _ colors: [String], _ category: String) -> Wallpaper {
        Wallpaper(id: UUID(), title: title, subtitle: subtitle, symbol: symbol, colors: colors, category: category, kind: .procedural, sourceURL: nil)
    }
}
