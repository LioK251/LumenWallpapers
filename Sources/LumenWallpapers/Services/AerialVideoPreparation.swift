import AVFoundation
import VideoToolbox
import ImageIO
import UniformTypeIdentifiers

enum AerialVideoPreparation {
    static func prepare(source: URL) async throws -> URL {
        guard FileManager.default.isReadableFile(atPath: source.path) else { throw LockScreenVideoError.videoMissing }
        let asset = AVURLAsset(url: source)
        guard try await asset.load(.isPlayable), !(try await asset.load(.hasProtectedContent)),
              let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let duration = try await asset.load(.duration)
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let frameRate = try await track.load(.nominalFrameRate)
        guard duration.seconds.isFinite, duration.seconds > 0,
              size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              frameRate.isFinite, frameRate > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let formats = try await track.load(.formatDescriptions)
        let isHEVC = !formats.isEmpty && formats.allSatisfy { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_HEVC }
        let hasMetadata = (try? hasTemporalMetadata(at: source)) ?? false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LumenAerial-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("video.mov")
        do {
            try Task.checkCancellation()
            if isHEVC, hasMetadata, source.pathExtension.lowercased() == "mov" {
                try FileManager.default.copyItem(at: source, to: output)
            } else if isHEVC, hasMetadata {
                guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                if #available(macOS 15.0, *) {
                    try await export.export(to: output, as: .mov)
                } else {
                    export.outputURL = output
                    export.outputFileType = .mov
                    // AVFoundation permits cancelExport concurrently with an active export.
                    nonisolated(unsafe) let legacyExport = export
                    await withTaskCancellationHandler {
                        await withCheckedContinuation { continuation in
                            legacyExport.exportAsynchronously { continuation.resume() }
                        }
                    } onCancel: { legacyExport.cancelExport() }
                    guard export.status == .completed else { throw export.error ?? CocoaError(.fileWriteUnknown) }
                }
            } else {
                try await encode(asset: asset, track: track, size: size, transform: transform,
                    frameRate: frameRate, duration: duration, to: output)
            }
            try Task.checkCancellation()
            guard try hasTemporalMetadata(at: output) else {
                throw LockScreenVideoError.incompatibleVideo
            }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1600, height: 1000)
            let (image, _) = try await generator.image(at: .zero)
            let preview = directory.appendingPathComponent("preview.png")
            guard let writer = CGImageDestinationCreateWithURL(preview as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw LockScreenVideoError.thumbnailFailed("Could not create the PNG preview.")
            }
            CGImageDestinationAddImage(writer, image, nil)
            guard CGImageDestinationFinalize(writer) else { throw LockScreenVideoError.thumbnailFailed("Could not write the PNG preview.") }
            return output
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func encode(asset: AVAsset, track: AVAssetTrack, size: CGSize, transform: CGAffineTransform,
                               frameRate: Float, duration: CMTime, to output: URL) async throws {
        let reader = try AVAssetReader(asset: asset)
        let read = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        ])
        read.alwaysCopiesSampleData = false
        guard reader.canAdd(read) else { throw LockScreenVideoError.incompatibleVideo }
        reader.add(read)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let write = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel,
                AVVideoExpectedSourceFrameRateKey: frameRate,
                kVTCompressionPropertyKey_BaseLayerFrameRate as String: max(1, frameRate / 2),
                AVVideoAllowFrameReorderingKey: true
            ]
        ])
        write.transform = transform
        guard writer.canAdd(write) else { throw LockScreenVideoError.incompatibleVideo }
        writer.add(write)
        guard reader.startReading(), writer.startWriting() else { throw reader.error ?? writer.error ?? CocoaError(.fileReadCorruptFile) }
        writer.startSession(atSourceTime: .zero)
        do {
            while let sample = read.copyNextSampleBuffer() {
                try Task.checkCancellation()
                while !write.isReadyForMoreMediaData {
                    guard writer.status == .writing else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
                    try await Task.sleep(for: .milliseconds(5))
                }
                guard write.append(sample) else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            }
            guard reader.status == .completed else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
            writer.endSession(atSourceTime: duration)
            write.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }
    }

    // Read sample-group atoms, avoiding matches inside compressed video bytes.
    static func hasTemporalMetadata(at url: URL) throws -> Bool {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        var groups = Set<String>()
        func scan(_ range: Range<Int>) throws {
            var offset = range.lowerBound
            func number(_ start: Int, count: Int) -> UInt64 {
                data[start..<start + count].reduce(0) { ($0 << 8) | UInt64($1) }
            }
            while offset + 8 <= range.upperBound {
                let shortSize = number(offset, count: 4)
                let header = shortSize == 1 ? 16 : 8
                guard offset + header <= range.upperBound else { throw CocoaError(.fileReadCorruptFile) }
                let length = shortSize == 0 ? UInt64(range.upperBound - offset) : shortSize == 1 ? number(offset + 8, count: 8) : shortSize
                guard length >= UInt64(header), length <= UInt64(range.upperBound - offset) else { throw CocoaError(.fileReadCorruptFile) }
                let end = offset + Int(length)
                let type = String(decoding: data[offset + 4..<offset + 8], as: UTF8.self)
                if ["moov", "trak", "mdia", "minf", "stbl"].contains(type) { try scan(offset + header..<end) }
                if ["sgpd", "sbgp"].contains(type), end - offset >= header + 8 {
                    groups.insert(String(decoding: data[offset + header + 4..<offset + header + 8], as: UTF8.self))
                }
                offset = end
            }
            guard offset == range.upperBound else { throw CocoaError(.fileReadCorruptFile) }
        }
        try scan(0..<data.count)
        return groups.contains("tscl") && groups.contains("tsas")
    }
}
