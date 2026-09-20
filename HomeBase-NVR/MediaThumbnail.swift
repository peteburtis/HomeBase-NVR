import Foundation
import CoreMedia
import CoreImage
import ImageIO
import VideoToolbox

/// A point in exactly the same timelines/relative anchors as frame requests.
/// Size is a pixel bounding box, not points; preserve aspect ratio, never upscale.
struct MediaThumbnailRequest: Codable {
    struct Size: Codable { let width: Int; let height: Int }
    let requestID: String
    var operation = "thumbnail"
    let cameraID: String
    var timeline: MediaTimeline? = nil
    let timestamp: Double
    var relativeTo: String? = nil
    let size: Size
    var selectedTimeline: MediaTimeline { timeline ?? .canonical }
    func resolve(now: Double, live: RecordingTime?) throws -> (timestamp: Double, anchor: Double?) {
        guard operation == "thumbnail", CameraConfiguration.printable(requestID, limit: 64), requestID.utf8.count <= 64,
              UUID(uuidString: cameraID) != nil, timestamp.isFinite, abs(timestamp) < 100_000_000_000,
              (1...2048).contains(size.width), (1...2048).contains(size.height),
              relativeTo == nil || timestamp <= 0 else {
            throw ServiceError(.invalidMessage, "Expected thumbnail, a camera UUID, request ID, finite timestamp, and pixel width/height from 1 to 2048. Relative timestamps must be nonpositive.")
        }
        let anchor = try MediaTimeSelection.anchor(relativeTo: relativeTo, timeline: selectedTimeline, now: now, live: live)
        let resolved = timestamp + (anchor ?? 0)
        guard resolved.isFinite, abs(resolved) < 100_000_000_000 else {
            throw ServiceError(.invalidMessage, "Timestamp is outside the supported Unix timestamp bounds.")
        }
        return (resolved, anchor)
    }
}

struct MediaThumbnail: Codable {
    let mimeType: String
    let width: Int
    let height: Int
    let byteCount: Int
    let timestamp: Double // Actual selected keyframe time in the requested timeline.
    let time: RecordingTime // All three original shard anchors; absent camera time stays absent.
    let presentationTicks: Int64
    let timescale: UInt32
    let keyFrame: Bool
}

enum MediaThumbnailResponse {
    // Separate admission from the eight media sessions. No recording queue is
    // involved, and an overloaded thumbnail caller gets a retryable error.
    private static let slots = DispatchSemaphore(value: 2)
    static func run(_ request: MediaThumbnailRequest, provider: LocalMediaProvider, work: MediaWork,
                    emit: (MediaMessage) throws -> Void, bytes: (Data) throws -> Void) throws {
        try work.check()
        let resolved = try request.resolve(now: provider.now(), live: request.relativeTo == "live" ? provider.live(request.cameraID) : nil)
        guard slots.wait(timeout: .now()) == .success else { throw ServiceError(.unavailable, "Thumbnail workers are busy; retry later.") }
        defer { slots.signal() }
        var begin = MediaMessage(type: "begin", requestID: request.requestID)
        begin.cameraID = request.cameraID; begin.timeline = request.selectedTimeline
        begin.timestamp = resolved.timestamp; begin.anchor = resolved.anchor
        try emit(begin)
        // A point must actually be covered. Do not manufacture a thumbnail for
        // a gap by walking backwards into arbitrary old footage.
        let range = MediaRange(start: resolved.timestamp, end: resolved.timestamp.nextUp)
        let sources = try provider.catalog(camera: request.cameraID, range: range, timeline: request.selectedTimeline, work: work)
        let pieces = try LocalMediaProvider.plan(sources, range: range, work: work)
        var result: (MediaThumbnail, Data)?
        for piece in pieces {
            try work.check()
            let query = MediaRequest(requestID: request.requestID, operation: "frames", cameraID: request.cameraID,
                timeline: request.selectedTimeline, range: range)
            // Reuse precisely the frame reader's validated source and preceding
            // keyframe selection. It returns after one sample, with no GOP replay.
            _ = try LocalMediaReader.read(piece, number: 0, request: query, work: work,
                emit: { _ in }, bytes: { _ in }, keyframe: { sample, segment in
                    let image = try ThumbnailJPEG.render(sample, size: request.size, work: work)
                    let pts = CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sample),
                        timescale: Int32(segment.timescale), method: .default).value
                    let timestamp = request.selectedTimeline.anchor(segment.time)! + Double(pts) / Double(segment.timescale)
                    result = (MediaThumbnail(mimeType: "image/jpeg", width: image.width, height: image.height,
                        byteCount: image.data.count, timestamp: timestamp, time: segment.time,
                        presentationTicks: pts, timescale: segment.timescale, keyFrame: true), image.data)
                })
            if result != nil { break }
        }
        if let (thumbnail, data) = result {
            var message = MediaMessage(type: "thumbnail", requestID: request.requestID); message.thumbnail = thumbnail
            try emit(message)
            for offset in stride(from: 0, to: data.count, by: MediaLimits.messageBytes) {
                try work.check()
                try bytes(data.subdata(in: offset..<min(offset + MediaLimits.messageBytes, data.count)))
            }
        }
        var end = MediaMessage(type: "end", requestID: request.requestID)
        end.outcome = result == nil ? "unavailable" : "complete"; end.frames = result == nil ? 0 : 1
        try emit(end)
    }
}

enum ThumbnailJPEG {
    struct Image { let data: Data; let width: Int; let height: Int }
    // The service runs without a GUI login. Software Core Image is sufficient
    // for these bounded thumbnails and does not require a WindowServer context.
    private static let context = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
    private final class Decoded: @unchecked Sendable {
        let lock = NSLock()
        var result: Result<CVPixelBuffer, Error>?
        func finish(_ status: OSStatus, _ image: CVPixelBuffer?) {
            lock.lock(); defer { lock.unlock() }
            if status == noErr, let image { result = .success(image) }
            else { result = .failure(ServiceError(.unavailable, "Could not decode recording keyframe.")) }
        }
        func get() -> Result<CVPixelBuffer, Error>? { lock.lock(); defer { lock.unlock() }; return result }
    }
    static func render(_ sample: CMSampleBuffer, size: MediaThumbnailRequest.Size, work: MediaWork, description: String? = nil) throws -> Image {
        try work.check()
        guard let format = CMSampleBufferGetFormatDescription(sample) else { throw ServiceError("Missing video format.") }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        guard dimensions.width > 0, dimensions.height > 0, dimensions.width <= 8192, dimensions.height <= 8192,
              Int64(dimensions.width) * Int64(dimensions.height) <= 33_554_432 else {
            throw ServiceError(.unavailable, "Source dimensions exceed thumbnail decoder limits.")
        }
        var session: VTDecompressionSession?
        let attributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary
        guard VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format,
            decoderSpecification: nil, imageBufferAttributes: attributes, outputCallback: nil,
            decompressionSessionOut: &session) == noErr, let session else { throw ServiceError("Cannot create thumbnail decoder.") }
        defer { VTDecompressionSessionInvalidate(session) }
        let decoded = Decoded()
        guard VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil,
            outputHandler: { status, _, image, _, _ in decoded.finish(status, image) }) == noErr else {
            throw ServiceError(.unavailable, "Could not decode recording keyframe.")
        }
        let deadline = min(work.deadline, ProcessInfo.processInfo.systemUptime + 10)
        while decoded.get() == nil {
            try work.check()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ServiceError(.timeout, "Thumbnail decoding timed out.") }
            Thread.sleep(forTimeInterval: 0.005)
        }
        try work.check()
        let input = CIImage(cvPixelBuffer: try decoded.get()!.get())
        let ratio = min(1, Double(size.width) / input.extent.width, Double(size.height) / input.extent.height)
        let width = max(1, Int(floor(input.extent.width * ratio)))
        let height = max(1, Int(floor(input.extent.height * ratio)))
        let image = input.transformed(by: CGAffineTransform(scaleX: ratio, y: ratio))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        guard let color = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: color) else { throw ServiceError("Cannot render thumbnail.") }
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer, "public.jpeg" as CFString, 1, nil) else { throw ServiceError("Cannot create JPEG thumbnail.") }
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.8]
        if let description { properties[kCGImagePropertyIPTCDictionary] = [kCGImagePropertyIPTCCaptionAbstract: description] }
        CGImageDestinationAddImage(destination, cg, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ServiceError("Cannot encode JPEG thumbnail.") }
        let data = buffer as Data
        guard
              !data.isEmpty, data.count <= 8 * 1024 * 1024 else { throw ServiceError("Cannot encode bounded JPEG thumbnail.") }
        try work.check()
        return Image(data: data, width: width, height: height)
    }
}
