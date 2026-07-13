#if DEBUG && canImport(ReplayKit)
import AVFoundation
import CoreMedia
import Foundation
import IOSDebugCore

final class UncheckedSendableSampleBuffer: @unchecked Sendable {
    let value: CMSampleBuffer
    init(_ value: CMSampleBuffer) { self.value = value }
}

protocol RecordingWriting: Sendable {
    func append(_ sample: UncheckedSendableSampleBuffer) async throws
    func finish() async throws
}

actor RecordingWriter: RecordingWriting {
    private let outputURL: URL
    private var assetWriter: AVAssetWriter?
    private var input: AVAssetWriterInput?

    init(outputURL: URL) { self.outputURL = outputURL }

    func append(_ sample: UncheckedSendableSampleBuffer) async throws {
        if assetWriter == nil { try configure(with: sample.value) }
        guard let assetWriter, let input else { throw WriterFailure.configuration }
        guard input.isReadyForMoreMediaData else { throw WriterFailure.notReady }
        guard input.append(sample.value) else {
            throw assetWriter.error ?? WriterFailure.append(assetWriter.status.rawValue)
        }
    }

    func finish() async throws {
        do {
            guard let assetWriter, let input else { throw WriterFailure.empty }
            input.markAsFinished()
            await assetWriter.finishWriting()
            guard assetWriter.status == .completed else {
                throw assetWriter.error ?? WriterFailure.finish(assetWriter.status.rawValue)
            }
            let data = try Data(contentsOf: outputURL, options: .mappedIfSafe)
            guard (1...IOSDebugProtocol.maximumMP4Bytes).contains(data.count) else {
                throw WriterFailure.invalidFile
            }
            _ = SHA256.hexDigest(data)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    private func configure(with sample: CMSampleBuffer) throws {
        guard
            let format = CMSampleBufferGetFormatDescription(sample),
            CMFormatDescriptionGetMediaType(format) == kCMMediaType_Video
        else { throw WriterFailure.configuration }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        guard dimensions.width > 0, dimensions.height > 0 else { throw WriterFailure.configuration }
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(dimensions.width),
            AVVideoHeightKey: Int(dimensions.height),
        ]
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        writerInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(writerInput) else { throw WriterFailure.configuration }
        writer.add(writerInput)
        guard writer.startWriting() else { throw writer.error ?? WriterFailure.configuration }
        writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sample))
        assetWriter = writer
        input = writerInput
    }

    private enum WriterFailure: Error {
        case configuration
        case empty
        case notReady
        case append(Int)
        case finish(Int)
        case invalidFile
    }
}
#endif
