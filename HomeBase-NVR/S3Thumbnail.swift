import Foundation
import CoreMedia
import CryptoKit

/// JPEG contents are self-describing even when downloaded without a manifest.
/// Its IPTC caption is inside the encrypted envelope, never an S3 header.
struct S3ThumbnailInfo: Codable, Equatable, Sendable {
    var format = "hbnvr-s3-thumbnail"
    var version = 1
    let storeID: String
    let cameraID: String
    let slot: Double
    let timestamp: Double
    func validate() throws {
        guard format == "hbnvr-s3-thumbnail", version == 1, UUID(uuidString: storeID) != nil,
              UUID(uuidString: cameraID) != nil, slot.isFinite, timestamp.isFinite,
              slot >= 600, slot < 253402300799, slot.truncatingRemainder(dividingBy: 1200) == 600,
              timestamp >= 0, timestamp <= slot, slot - timestamp <= 120 else {
            throw ServiceError("Invalid thumbnail identity or time.")
        }
    }
}

enum S3Thumbnail {
    static let interval = 1200.0
    static let offset = 600.0
    static let maximumBytes = 8 * 1024 * 1024
    static func firstSlot(atOrAfter time: Double) -> Double { ceil((time - offset) / interval) * interval + offset }
    static func slots(start: Double, end: Double) -> [Double] {
        guard start.isFinite, end.isFinite, start >= 0, end > start, end - start <= 31 * 86400 else { return [] }
        return Array(stride(from: firstSlot(atOrAfter: start), to: end, by: interval))
    }
    static func key(prefix: String, camera: String, slot: Double, encrypted: Bool) -> String {
        let date = Date(timeIntervalSince1970: slot), formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.calendar = Calendar(identifier: .gregorian); formatter.dateFormat = "yyyy-MM-dd/HH-mm"
        return S3PlaybackPublisher.root(prefix: prefix, camera: camera) + "thumbnails/" + formatter.string(from: date) + (encrypted ? ".jpg.hbnvr" : ".jpg")
    }
    /// Stable object identity coalesces live/repair/replay for the same slot.
    static func id(store: String, camera: String, slot: Double) -> String {
        var bytes = Array(SHA256.hash(data: Data("\(store.lowercased())/\(camera.lowercased())/\(Int64(slot))".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 15) | 0x80; bytes[8] = (bytes[8] & 63) | 0x80 // UUIDv8: application-defined SHA-256 identity.
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])).uuidString
    }
    static func listed(_ key: String, prefix: String, cameras: Set<String>) -> Bool {
        guard key.hasPrefix(prefix + ".hbnvr/playback/v1/") else { return false }
        let parts = String(key.dropFirst((prefix + ".hbnvr/playback/v1/").count)).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 4, let camera = UUID(uuidString: String(parts[0])), cameras.contains(camera.uuidString),
              parts[1] == "thumbnails" else { return false }
        let encrypted = parts[3].hasSuffix(".jpg.hbnvr"), suffix = encrypted ? ".jpg.hbnvr" : ".jpg"
        guard parts[3].hasSuffix(suffix) else { return false }
        let date = String(parts[2]) + "/" + String(parts[3].dropLast(suffix.count)), formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.calendar = Calendar(identifier: .gregorian); formatter.dateFormat = "yyyy-MM-dd/HH-mm"; formatter.isLenient = false
        guard let instant = formatter.date(from: date), formatter.string(from: instant) == date else { return false }
        let slot = instant.timeIntervalSince1970
        return slot >= 600 && slot.truncatingRemainder(dividingBy: interval) == offset &&
            key == self.key(prefix: prefix, camera: camera.uuidString, slot: slot, encrypted: encrypted)
    }
    static func sample(_ media: EncodedMedia, sets: [Data]) throws -> CMSampleBuffer {
        guard media.frame.keyFrame, !media.frame.payload.isEmpty, ["H264", "H265"].contains(media.codec) else {
            throw ServiceError("Thumbnail requires an encoded H.264/H.265 keyframe.")
        }
        let format = try MP4Shard.format(codec: media.codec, sets: sets)
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: media.frame.payload.count,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: media.frame.payload.count, flags: 0,
            blockBufferOut: &block) == noErr, let block else { throw ServiceError("Cannot allocate thumbnail sample.") }
        let copied = media.frame.payload.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: $0.count) }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 15), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var size = media.frame.payload.count, sample: CMSampleBuffer?
        guard copied == noErr, CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { throw ServiceError("Cannot create thumbnail sample.") }
        return sample
    }
    static func render(_ sample: CMSampleBuffer, info: S3ThumbnailInfo, store: RecordingStoreConfiguration,
                       cancellation: Cancellation = Cancellation()) throws -> (S3ObjectMetadata, Data) {
        try info.validate()
        let description = String(decoding: try JSONEncoder().encode(info), as: UTF8.self)
        let image = try ThumbnailJPEG.render(sample, size: .init(width: 1280, height: 720),
            work: MediaWork(cancellation: cancellation), description: description)
        var bytes = image.data
        let encrypted = store.s3?.clientEncryption?.enabled == true
        if encrypted {
            guard let password = store.s3?.clientEncryption?.password else { throw ServiceError("Thumbnail encryption password unavailable; refusing plaintext.") }
            bytes = try RecordingEncryption.encrypt(bytes, password: password)
        }
        let s3 = store.s3!
        var metadata = S3ObjectMetadata(id: id(store: store.id, camera: info.cameraID, slot: info.slot),
            storeID: store.id, cameraID: info.cameraID, bucket: s3.bucket, region: s3.region, expectedOwner: s3.expectedOwner,
            prefix: s3.prefix, key: key(prefix: s3.prefix, camera: info.cameraID, slot: info.slot, encrypted: encrypted),
            capturedAt: Date(timeIntervalSince1970: info.slot), size: Int64(bytes.count), sha256: S3ObjectMetadata.hash(bytes),
            encryption: encrypted ? RecordingEncryption.format : nil)
        metadata.schemaVersion = 2; metadata.thumbnail = info
        return (metadata, bytes)
    }
}

/// Store-queue selection retains just the latest compressed keyframe. Rendering
/// happens off that queue, not in the primary recording path.
struct S3ThumbnailSelection {
    struct Frame { let media: EncodedMedia; let sets: [Data]; let time: RecordingTime }
    private var keyframe: Frame?
    private var previous: Double?
    private var epoch: String?
    mutating func observe(_ media: EncodedMedia, sets: [Data], time: RecordingTime) -> (Frame, Double)? {
        if epoch != time.epochID { keyframe = nil; previous = nil; epoch = time.epochID }
        let now = time.canonicalUTC
        let slot = S3Thumbnail.firstSlot(atOrAfter: previous.map { $0.nextUp } ?? now)
        if media.frame.keyFrame { // Do not select a future keyframe for a crossed mark.
            if now <= slot { keyframe = Frame(media: media, sets: sets, time: time) }
        }
        let selected = keyframe
        defer {
            previous = now
            if media.frame.keyFrame { keyframe = Frame(media: media, sets: sets, time: time) }
        }
        guard slot <= now, let selected, selected.time.canonicalUTC <= slot,
              slot - selected.time.canonicalUTC <= 120 else { return nil }
        return (selected, slot)
    }
}
