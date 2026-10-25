import Foundation
@preconcurrency import AVFoundation
import CoreMedia

enum HistoricalFrameIndex {
    struct Index: Sendable {
        let ticks: [Int64]
        /// Maximum uncertainty of a stored PTS, in source RTP ticks. Older
        /// writers let AVFoundation choose a coarser MP4 track timescale.
        let rounding: Double
    }
    static func read(_ output: AVAssetReaderTrackOutput, reader: AVAssetReader, timescale: UInt32,
                     end: Int64, work: MediaWork) throws -> [Int64] {
        try readIndex(output, reader: reader, timescale: timescale, end: end, work: work).ticks
    }
    static func readIndex(_ output: AVAssetReaderTrackOutput, reader: AVAssetReader, timescale: UInt32,
                          end: Int64, work: MediaWork) throws -> Index {
        var ticks: [Int64] = [], rounding: Double = 0
        while let sample = output.copyNextSampleBuffer() {
            try work.check()
            if CMSampleBufferGetNumSamples(sample) == 0 { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample), dts = CMSampleBufferGetDecodeTimeStamp(sample)
            guard ticks.count < 1_000_000, CMSampleBufferGetNumSamples(sample) == 1,
                  pts.isNumeric, pts.timescale > 0, !dts.isValid || dts == pts else { throw ServiceError("Unsupported or oversized frame sequence.") }
            let tick = CMTimeConvertScale(pts, timescale: Int32(timescale), method: .default).value
            guard tick >= 0, (tick < end), tick > (ticks.last ?? -1) else { throw ServiceError("Non-monotonic recording frame sequence.") }
            ticks.append(tick)
            if pts.timescale != Int32(timescale) {
                // Half a native tick for writing, plus half a source tick for
                // CMTimeConvertScale's nearest-integer read conversion.
                rounding = max(rounding, 0.5 * Double(timescale) / Double(pts.timescale) + 0.5)
            }
        }
        guard reader.status == .completed, ticks.first == 0 else { throw ServiceError("Could not read a complete frame index.") }
        return Index(ticks: ticks, rounding: rounding)
    }
    static func remote(_ data: Data, shard: S3PlaybackShard, work: MediaWork) async throws -> [Int64] {
        try await remoteIndex(data, shard: shard, work: work).ticks
    }
    static func remoteIndex(_ data: Data, shard: S3PlaybackShard, work: MediaWork) async throws -> Index {
        let source = S3RepairMemoryAsset(data: data)
        defer { source.cancel() }
        return try await withThrowingTaskGroup(of: Index.self) { group in
            group.addTask {
                guard try await ShardTimingMetadata.read(from: source.asset) == shard.timing else { throw ServiceError("Remote recording identity does not match its manifest.") }
                let tracks = try await source.asset.loadTracks(withMediaType: .video)
                guard tracks.count == 1, let track = tracks.first else { throw ServiceError("Recording must have one video track.") }
                let reader = try AVAssetReader(asset: source.asset)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                output.alwaysCopiesSampleData = false
                reader.add(output); guard reader.startReading() else { throw ServiceError("Cannot read recording frames.") }
                defer { reader.cancelReading() }
                return try readIndex(output, reader: reader, timescale: shard.timing.timescale, end: shard.endTicks, work: work)
            }
            group.addTask { try await Task.sleep(for: .seconds(30)); source.cancel(); throw ServiceError(.timeout, "Frame inspection timed out.") }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}
