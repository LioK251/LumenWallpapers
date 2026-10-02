import AppKit
import CryptoKit
import AVFoundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum PersistentWallpaperManager {
    static func apply(wallpaper: Wallpaper, display: String) throws {
        if wallpaper.kind == .video, let url = wallpaper.url,
           LockScreenVideoManager().isConfigured(videoURL: url), LockScreenVideoManager.isSelected { return }
        try apply(imageURL: prepare(wallpaper: wallpaper), display: display)
    }

    static func prepare(wallpaper: Wallpaper) throws -> URL {
        try imageURL(for: wallpaper, in: previewDirectory)
    }

    static func apply(imageURL: URL, display: String) throws {
        NSWorkspace.shared.noteFileSystemChanged(imageURL.path)
        for screen in DesktopWallpaperController.targetScreens(for: display) {
            let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
            try NSWorkspace.shared.setDesktopImageURL(imageURL, for: screen, options: options)
        }
    }

    private static var previewDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LumenWallpapers/PersistentPreviews", isDirectory: true)
    }

    static func imageURL(for wallpaper: Wallpaper, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let image: CGImage
        if wallpaper.kind == .image {
            guard let url = wallpaper.url,
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  let decodedImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(width, height)
                  ] as CFDictionary) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            image = decodedImage
        } else if wallpaper.kind == .video {
            guard let url = wallpaper.url else { throw CocoaError(.fileNoSuchFile) }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 3840, height: 2160)
            do {
                image = try generator.copyCGImage(at: .zero, actualTime: nil)
            } catch {
                image = try generator.copyCGImage(at: CMTime(seconds: 0.2, preferredTimescale: 600), actualTime: nil)
            }
        } else {
            let size = CGSize(width: 2560, height: 1440)
            let renderer = ImageRenderer(content: LiveWallpaperCanvas(
                wallpaper: wallpaper,
                isPlaying: false,
                reducedQuality: false,
                snapshotTime: 0
            ).frame(width: size.width, height: size.height))
            renderer.proposedSize = ProposedViewSize(size)
            renderer.scale = 1
            guard let renderedImage = renderer.nsImage,
                  let tiff = renderedImage.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let renderedCGImage = bitmap.cgImage else {
                throw CocoaError(.fileWriteUnknown)
            }
            image = renderedCGImage
        }

        let staging = directory.appendingPathComponent(".\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: staging) }
        guard let writer = CGImageDestinationCreateWithURL(staging as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer) else { throw CocoaError(.fileWriteUnknown) }
        let data = try Data(contentsOf: staging)
        let revision = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let revisionDirectory = directory.appendingPathComponent(revision, isDirectory: true)
        try FileManager.default.createDirectory(at: revisionDirectory, withIntermediateDirectories: true)
        let destination = revisionDirectory.appendingPathComponent("Lumen.png")
        if !FileManager.default.fileExists(atPath: destination.path) {
            try data.write(to: destination, options: .atomic)
        }
        return destination
    }
}
