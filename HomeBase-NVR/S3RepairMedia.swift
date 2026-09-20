import AVFoundation
import CoreMedia
import Foundation

enum S3RepairSkip: String, Error {
    case unexpected, legacyOrInvalidTiming, identityMismatch, invalidMedia, oversized, changed, conflict
}
struct S3RepairCandidate: Sendable {
    let object: S3RepairObject
    let cameraID: String
    let shardID: String
    let encrypted: Bool
    /// Names only identify candidates. They never supply fabricated timing.
    static func parse(_ object: S3RepairObject, prefix: String, cameras: Set<String>) -> Self? {
        guard object.size > 0, object.key.utf8.starts(with: prefix.utf8), object.key.utf8.count <= 1024,
              object.key.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        let relative = String(object.key.dropFirst(prefix.count)), parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let separator = parts[0].range(of: "--", options: .backwards), separator.lowerBound != parts[0].startIndex,
              let camera = UUID(uuidString: String(parts[0][separator.upperBound...])), cameras.contains(camera.uuidString) else { return nil }
        let filename = String(parts[1]), encrypted = filename.hasSuffix(".mp4.hbnvr")
        let suffix = encrypted ? ".mp4.hbnvr" : ".mp4"
        guard filename.hasSuffix(suffix) else { return nil }
        let stem = String(filename.dropLast(suffix.count))
        guard stem.count == 61, stem[stem.index(stem.startIndex, offsetBy: 24)] == "_",
              let shard = UUID(uuidString: String(stem.suffix(36))) else { return nil }
        let date = String(stem.prefix(24))
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss.SSS'Z'"; formatter.isLenient = false
        guard formatter.date(from: date).map({ formatter.string(from: $0) == date }) == true else { return nil }
        return .init(object: object, cameraID: camera.uuidString, shardID: shard.uuidString, encrypted: encrypted)
    }
}

enum S3RepairMedia {
    /// One bounded object at a time. No plaintext temp files and no decoding or
    /// re-encoding; sample timestamps provide the exclusive end of the shard.
    static func inspect(_ bytes: Data, candidate: S3RepairCandidate, store: RecordingStoreConfiguration,
                        passwords: [String]) async throws -> S3ShardMetadata {
        let source = S3RepairMemoryAsset(data: try plaintext(bytes, candidate: candidate, passwords: passwords))
        return try await withTaskCancellationHandler {
            defer { source.cancel() }
            let (timing, track) = try await inspectHeader(source)
            guard timing.storeID == store.id, timing.cameraID == candidate.cameraID,
                  timing.shardID == candidate.shardID else { throw S3RepairSkip.identityMismatch }
            let end = try sampleEnd(source, track: track, timing: timing)
            try Task.checkCancellation()
            let s3 = store.s3!
            let metadata = S3ShardMetadata(id: timing.shardID, storeID: store.id, cameraID: timing.cameraID,
                bucket: s3.bucket, region: s3.region, expectedOwner: s3.expectedOwner, prefix: s3.prefix,
                key: candidate.object.key, capturedAt: Date(timeIntervalSince1970: timing.time.canonicalUTC),
                size: Int64(bytes.count), sha256: S3ShardMetadata.hash(bytes),
                encryption: candidate.encrypted ? RecordingEncryption.format : nil, timing: timing, endTicks: end)
            try S3PlaybackShard(id: metadata.id, key: metadata.key, size: metadata.size, sha256: metadata.sha256,
                encryption: metadata.encryption, timing: timing, endTicks: end).validate(store: store)
            return metadata
        } onCancel: { source.cancel() }
    }
    private static func plaintext(_ bytes: Data, candidate: S3RepairCandidate, passwords: [String]) throws -> Data {
        try Task.checkCancellation()
        guard bytes.count == candidate.object.size else { throw S3RepairReadFailure.size(expected: candidate.object.size, actual: bytes.count) }
        guard bytes.count <= AWSS3RepairReader.maximumObjectBytes else { throw S3RepairSkip.oversized }
        let plaintext: Data
        if candidate.encrypted {
            guard bytes.starts(with: RecordingEncryption.magic),
                  (try? RecordingEncryption.validateEnvelopeHeader(Data(bytes.prefix(RecordingEncryption.headerSize)), size: Int64(bytes.count))) != nil else {
                throw S3RepairSkip.unexpected
            }
            var opened: Data?
            for password in passwords {
                try Task.checkCancellation()
                if let result = try? RecordingEncryption.decrypt(bytes, password: password) { opened = result; break }
            }
            guard let opened else { throw S3RepairFailure.password }
            plaintext = opened
        } else {
            guard !bytes.starts(with: RecordingEncryption.magic) else { throw S3RepairSkip.unexpected }
            plaintext = bytes
        }
        return plaintext
    }
    /// Reuse the already downloaded object. Decode only selected keyframes,
    /// handing each finished JPEG directly to the shared upload pool.
    static func thumbnails(_ bytes: Data, candidate: S3RepairCandidate, store: RecordingStoreConfiguration,
                           passwords: [String], metadata: S3ObjectMetadata, slots: [Double], cancellation: Cancellation,
                           accept: (S3ObjectMetadata, Data) async throws -> Void) async throws {
        guard !slots.isEmpty else { return }
        let source = S3RepairMemoryAsset(data: try plaintext(bytes, candidate: candidate, passwords: passwords))
        try await withTaskCancellationHandler {
            defer { source.cancel() }
            let (timing, track) = try await inspectHeader(source)
            guard metadata.timing == timing, let endTicks = metadata.endTicks else { throw S3RepairSkip.identityMismatch }
            let valid = Set(S3Thumbnail.slots(start: timing.time.canonicalUTC,
                end: timing.time.canonicalUTC + Double(endTicks) / Double(timing.timescale)))
            guard Set(slots).isSubset(of: valid) else { throw S3RepairSkip.invalidMedia }
            let reader = try AVAssetReader(asset: source.asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil); output.alwaysCopiesSampleData = false
            reader.add(output); guard reader.startReading() else { throw S3RepairSkip.invalidMedia }
            defer { reader.cancelReading() }
            let wanted = slots.sorted()
            var index = 0, keyframe: CMSampleBuffer?, keyTime = 0.0
            func emit(until time: Double, inclusive: Bool = false) async throws {
                while index < wanted.count, wanted[index] < time || (inclusive && wanted[index] == time) {
                    try Task.checkCancellation()
                    guard !cancellation.isStopped else { throw CancellationError() }
                    let slot = wanted[index]; index += 1
                    guard let keyframe, keyTime <= slot, slot - keyTime <= 120 else { continue }
                    let info = S3ThumbnailInfo(storeID: store.id, cameraID: candidate.cameraID, slot: slot, timestamp: keyTime)
                    let (object, data) = try S3Thumbnail.render(keyframe, info: info, store: store, cancellation: cancellation)
                    try await accept(object, data)
                }
            }
            while let sample = output.copyNextSampleBuffer(), index < wanted.count {
                try Task.checkCancellation()
                guard !cancellation.isStopped else { throw CancellationError() }
                if CMSampleBufferGetNumSamples(sample) == 0 { continue }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                let time = timing.time.canonicalUTC + CMTimeGetSeconds(pts)
                try await emit(until: time)
                let attributes = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]]
                if attributes?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool != true { keyframe = sample; keyTime = time }
                try await emit(until: time, inclusive: true)
            }
            if index < wanted.count {
                guard reader.status == .completed else { throw S3RepairSkip.invalidMedia }
                try await emit(until: timing.time.canonicalUTC + Double(endTicks) / Double(timing.timescale))
            }
        } onCancel: { source.cancel() }
    }
    private static func inspectHeader(_ source: S3RepairMemoryAsset) async throws -> (ShardTimingMetadata, AVAssetTrack) {
        try await withThrowingTaskGroup(of: (ShardTimingMetadata, AVAssetTrack).self) { group in
            group.addTask {
                let items = try await source.asset.load(.metadata)
                guard items.count <= 128 else { throw S3RepairSkip.legacyOrInvalidTiming }
                var timing: ShardTimingMetadata?
                for item in items {
                    try Task.checkCancellation()
                    guard let string = try await item.load(.stringValue), string.utf8.count <= 65536,
                          let value = try? JSONDecoder().decode(ShardTimingMetadata.self, from: Data(string.utf8)),
                          value.format == ShardTimingMetadata.key else { continue }
                    guard timing == nil, (try? value.validate()) != nil else { throw S3RepairSkip.legacyOrInvalidTiming }
                    timing = value
                }
                guard let timing else { throw S3RepairSkip.legacyOrInvalidTiming }
                let tracks = try await source.asset.loadTracks(withMediaType: .video)
                guard tracks.count == 1, let track = tracks.first else { throw S3RepairSkip.invalidMedia }
                return (timing, track)
            }
            group.addTask { try await Task.sleep(for: .seconds(15)); source.cancel(); throw S3RepairSkip.invalidMedia }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
    private static func sampleEnd(_ source: S3RepairMemoryAsset, track: AVAssetTrack, timing: ShardTimingMetadata) throws -> Int64 {
        let reader = try AVAssetReader(asset: source.asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil); output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw S3RepairSkip.invalidMedia }
        reader.add(output); guard reader.startReading() else { throw S3RepairSkip.invalidMedia }
        defer { reader.cancelReading() }
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        var previous: Int64 = -1, end: Int64 = 0, count = 0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            // Fragmented MP4 readers may emit an empty segment-boundary marker.
            if CMSampleBufferGetNumSamples(sample) == 0 { continue }
            guard !source.cancelled, ProcessInfo.processInfo.systemUptime < deadline, count < 1_000_000,
                  CMSampleBufferGetNumSamples(sample) == 1, let format = CMSampleBufferGetFormatDescription(sample),
                  [kCMVideoCodecType_H264, kCMVideoCodecType_HEVC].contains(CMFormatDescriptionGetMediaSubType(format)) else { throw S3RepairSkip.invalidMedia }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample), duration = CMSampleBufferGetDuration(sample)
            let dts = CMSampleBufferGetDecodeTimeStamp(sample)
            guard pts.isNumeric, duration.isNumeric, duration > .zero,
                  !dts.isValid || dts == pts else { throw S3RepairSkip.invalidMedia }
            let p = CMTimeConvertScale(pts, timescale: Int32(timing.timescale), method: .default).value
            let d = CMTimeConvertScale(duration, timescale: Int32(timing.timescale), method: .default).value
            guard p >= 0, p > previous, d > 0, p < Int64.max - d else { throw S3RepairSkip.invalidMedia }
            if count == 0 {
                let attributes = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]]
                guard p == 0, attributes?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool != true else { throw S3RepairSkip.invalidMedia }
            }
            previous = p; end = p + d; count += 1
        }
        try Task.checkCancellation()
        guard reader.status == .completed, count > 0 else { throw S3RepairSkip.invalidMedia }
        return end
    }
}

/// Same RAM-only AVFoundation loading strategy as the GUI S3 reader.
private final class S3RepairMemoryAsset: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let asset: AVURLAsset
    private let data: Data
    private let queue = DispatchQueue(label: "hbnvr.repair.media")
    private let lock = NSLock()
    private var stopped = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    init(data: Data) {
        self.data = data
        asset = AVURLAsset(url: URL(string: "hbnvr-repair://recording/" + UUID().uuidString + ".mp4")!,
            options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
        super.init(); asset.resourceLoader.setDelegate(self, queue: queue)
    }
    func cancel() { lock.lock(); stopped = true; lock.unlock(); asset.cancelLoading() }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        do {
            guard !cancelled, request.request.url == asset.url else { throw S3RepairSkip.invalidMedia }
            if let info = request.contentInformationRequest {
                info.contentType = AVFileType.mp4.rawValue; info.contentLength = Int64(data.count); info.isByteRangeAccessSupported = true
            }
            if let read = request.dataRequest {
                var offset = max(read.requestedOffset, read.currentOffset)
                guard read.requestedOffset >= 0, offset >= 0, offset <= data.count, read.requestedLength >= 0,
                      read.requestedOffset <= Int64.max - Int64(read.requestedLength) else { throw S3RepairSkip.invalidMedia }
                let end = read.requestsAllDataToEndOfResource ? Int64(data.count) : min(Int64(data.count), read.requestedOffset + Int64(read.requestedLength))
                while offset < end, !request.isCancelled {
                    guard !cancelled else { throw CancellationError() }
                    let next = min(end, offset + 1024 * 1024)
                    read.respond(with: data.subdata(in: Int(offset)..<Int(next))); offset = next
                }
            }
            if !request.isCancelled { request.finishLoading() }
        } catch { request.finishLoading(with: NSError(domain: "HBNVRRepairMedia", code: 1)) }
        return true
    }
}
