import Foundation
import AVFoundation
import CoreMedia
import UniformTypeIdentifiers

/// Segment output has no URL and never creates a temporary media file. A fresh
/// writer per shard gives each result its own initialization segment.
final class MemoryMP4Shard: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
    let capturedAt: Date
    let timing: ShardTimingMetadata?
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let format: CMFormatDescription
    private let clock: Int32
    private var last: UInt32
    private var ticks: Int64 = 0
    private var duration: Int64
    private(set) var samples = 0
    private(set) var inputBytes: Int64 = 0
    private let lock = NSLock()
    private var segments: [Data] = []
    private var initialization = false
    private var outputBytes: Int64 = 0
    private var finished = false
    var endTicks: Int64 { ticks + duration }
    var residentBytes: Int64 { lock.lock(); defer { lock.unlock() }; return max(inputBytes, outputBytes) }
    init(codec: String, sets: [Data], clock: UInt32, timestamp: UInt32, capturedAt: Date = Date(), timing: ShardTimingMetadata? = nil) throws {
        guard clock > 0, clock <= Int32.max, ["H264", "H265"].contains(codec) else { throw ServiceError("Unsupported S3 video format.") }
        self.capturedAt = capturedAt; self.timing = timing; self.clock = Int32(clock); last = timestamp; duration = max(1, Int64(clock) / 15)
        format = try MP4Shard.format(codec: codec, sets: sets)
        writer = AVAssetWriter(contentType: .mpeg4Movie)
        writer.metadata = try timing?.assetMetadata() ?? []
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = .indefinite
        writer.initialSegmentStartTime = .zero
        input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        input.expectsMediaDataInRealTime = true
        super.init()
        writer.delegate = self
        guard writer.canAdd(input) else { throw ServiceError("S3 MP4 writer rejected camera codec.") }
        writer.add(input)
        guard writer.startWriting() else { throw failure("start") }
        writer.startSession(atSourceTime: .zero)
    }
    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data, segmentType: AVAssetSegmentType) {
        lock.lock(); defer { lock.unlock() }
        if segmentType == .initialization { initialization = true }
        segments.append(Data(segmentData)); outputBytes += Int64(segmentData.count)
    }
    func elapsed(_ timestamp: UInt32) -> Double { Double(ticks + Int64(Int32(bitPattern: timestamp &- last))) / Double(clock) }
    func append(_ frame: EncodedVideoFrame) throws {
        let delta = Int64(Int32(bitPattern: frame.timestamp &- last))
        guard !finished, samples == 0 || delta > 0 else { throw ServiceError("S3 recording requires a no-B-frame camera profile with increasing timestamps.") }
        if samples > 0 { ticks += delta; duration = delta }; last = frame.timestamp
        try MP4WriterWait.untilReady(ready: { self.input.isReadyForMoreMediaData },
            failure: { self.writer.status == .writing ? nil : self.failure("accept video") },
            timeoutMessage: "S3 RAM MP4 writer remained backpressured for 30 seconds.")
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: frame.payload.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: frame.payload.count, flags: 0, blockBufferOut: &block) == noErr, let block else { throw ServiceError("Could not allocate S3 video sample.") }
        let copied = frame.payload.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: $0.count) }
        var timing = CMSampleTimingInfo(duration: CMTime(value: duration, timescale: clock), presentationTimeStamp: CMTime(value: ticks, timescale: clock), decodeTimeStamp: .invalid)
        var size = frame.payload.count, sample: CMSampleBuffer?
        guard copied == noErr, CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { throw ServiceError("Could not construct S3 sample.") }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(), Unmanaged.passUnretained(frame.keyFrame ? kCFBooleanFalse : kCFBooleanTrue).toOpaque())
        }
        guard input.append(sample) else { throw failure("append") }
        samples += 1; inputBytes += Int64(frame.payload.count)
    }
    func finish(timeout: Double = 30) throws -> Data {
        guard !finished, samples > 0 else { throw ServiceError("Empty or already finalized S3 shard.") }
        finished = true
        writer.endSession(atSourceTime: CMTime(value: ticks + duration, timescale: clock))
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        guard done.wait(timeout: .now() + timeout) == .success, writer.status == .completed else { throw failure("finalize") }
        lock.lock(); defer { lock.unlock() }
        guard initialization, segments.count >= 2 else { throw ServiceError("S3 MP4 is missing its initialization or media segment.") }
        var result = Data(); result.reserveCapacity(Int(outputBytes))
        for segment in segments { result.append(segment) }
        segments.removeAll(); outputBytes = 0
        return result
    }
    private func failure(_ operation: String) -> ServiceError { ServiceError("S3 RAM MP4 could not \(operation): \(MP4WriterWait.errorCodes(writer.error)). Incomplete video cannot be recovered by an S3 store.") }
}
