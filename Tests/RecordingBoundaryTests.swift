import XCTest
import Foundation
import AVFoundation

final class RecordingBoundaryTests: XCTestCase {
    private func waitUntil(_ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(4)
        while !condition(), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(condition())
    }

    // The final previous interval and the interval to the keyframe are distinct.
    // 66 -> 33 ms reproduced the old 33 ms overlap; 33 -> 66 produced a gap.
    private func video(previous: UInt32, next: UInt32, wrap: Bool = false,
                       newEpoch: Bool = false) throws -> [EncodedMedia] {
        let encoded = try StoreTests.video(count: 16)
        var ticks = (0..<14).map { UInt32($0) * 6300 }
        ticks += [ticks.last! + previous, ticks.last! + previous + next]
        let origin = wrap ? UInt32.max - 45000 : 0
        let epoch = UUID().uuidString, replacement = UUID().uuidString
        return encoded.enumerated().map { index, input in
            let utc = 1_790_000_000 + Double(ticks[index]) / 90000
            var result = EncodedMedia(codec: input.codec, clockRate: input.clockRate,
                parameterSets: input.parameterSets,
                frame: .init(payload: input.frame.payload, timestamp: origin &+ ticks[index], keyFrame: input.frame.keyFrame),
                receivedAt: Date(timeIntervalSince1970: utc), receivedUptime: 100 + Double(ticks[index]) / 90000, ssrc: 42)
            result.time = RecordingTime(cameraUTC: nil, receivedUTC: utc, canonicalUTC: utc,
                canonicalSource: .received, epochID: newEpoch && index == 15 ? replacement : epoch)
            result.tags = ["unrelated": "preserved", "frame": String(index)]
            return result
        }
    }

    private func sampleTimes(_ path: String, expected: [EncodedMedia], endTicks: Int64) async throws {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output); XCTAssertTrue(reader.startReading())
        var points: [(Int64, Int64)] = []
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) == 0 { continue }
            points.append((CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sample), timescale: 90000, method: .default).value,
                           CMTimeConvertScale(CMSampleBufferGetDuration(sample), timescale: 90000, method: .default).value))
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertEqual(points.count, expected.count)
        for index in points.indices {
            let pts = Int64(expected[index].frame.timestamp &- expected[0].frame.timestamp)
            let next = index + 1 < expected.count
                ? Int64(expected[index + 1].frame.timestamp &- expected[0].frame.timestamp) : endTicks
            XCTAssertEqual(points[index].0, pts)
            XCTAssertEqual(points[index].1, next - pts, "sample \(index)")
        }
        let tags = try XCTUnwrap(VideoTagMP4.read(Data(contentsOf: URL(fileURLWithPath: path))))
        for sample in expected {
            XCTAssertEqual(tags.tags(at: Int64(sample.frame.timestamp &- expected[0].frame.timestamp)), sample.tags)
        }
        let duration = try await track.load(.timeRange).duration
        XCTAssertEqual(CMTimeConvertScale(duration, timescale: 90000, method: .default).value, endTicks)
    }

    func testLocalRolloverUsesActualNextIntervalInManifestAndMP4() async throws {
        for (previous, next, wrap) in [(UInt32(5940), UInt32(2970), false), (2970, 5940, true)] {
            let helper = StoreTests(), root = try helper.temporary()
            defer { try? FileManager.default.removeItem(atPath: root) }
            var config = try helper.config(root + "/local"); config.shardDuration = "1s"
            let camera = UUID().uuidString, store = try LocalRecordingStore(configuration: config)
            let frames = try video(previous: previous, next: next, wrap: wrap)
            for frame in frames { store.accept(.media(camera: camera, name: "Boundary", frame)) }
            XCTAssertTrue(store.finish(timeout: 30)); XCTAssertNil(store.snapshot().lastError)
            let path = config.directory + "/Boundary"
            let directory = LocalRecordingLayout.Directory(path: path, fd: try StoreDirectory.openDirectory(path))
            let manifest = try LocalRecordingManifest(directory: directory, identity: .init(storeID: config.id, cameraID: camera),
                owner: geteuid(), readOnly: true)
            let rows = try manifest.recordings().sorted { $0.start < $1.start }
            XCTAssertEqual(rows.count, 2)
            let first = try XCTUnwrap(rows.first), second = try XCTUnwrap(rows.last)
            let boundary = Int64(frames[15].frame.timestamp &- frames[0].frame.timestamp)
            XCTAssertEqual(first.endTicks, boundary)
            XCTAssertEqual(first.end, second.start, accuracy: 0.000001)
            XCTAssertEqual(first.timing.time.epochID, second.timing.time.epochID)
            try await sampleTimes(path + "/" + first.filename, expected: Array(frames.prefix(15)), endTicks: boundary)
            try await sampleTimes(path + "/" + second.filename, expected: [frames[15]], endTicks: second.endTicks)
        }
    }

    func testS3RolloverUsesActualNextIntervalInManifestAndMP4() async throws {
        for (previous, next) in [(UInt32(5940), UInt32(2970)), (2970, 5940)] {
            let helper = StoreTests(), root = try helper.temporary()
            defer { try? FileManager.default.removeItem(atPath: root) }
            var config = try S3Tests().config(); config.shardDuration = "1s"
            let network = FakeS3(); await network.configure(automatic: true)
            let store = try S3RecordingStore(configuration: config, spoolRoot: root + "/spool", factory: { _ in network }, log: { _ in })
            let camera = UUID().uuidString, frames = try video(previous: previous, next: next)
            for frame in frames { store.accept(.media(camera: camera, name: "Boundary", frame)) }
            store.accept(.end(camera: camera))
            try await S3Tests().eventually { store.snapshot().s3?.confirmedUploads == 2 }
            XCTAssertTrue(store.finish(timeout: 30)); XCTAssertNil(store.snapshot().lastError)
            let attempts = await network.attempts.sorted { $0.metadata.capturedAt < $1.metadata.capturedAt }
            XCTAssertEqual(attempts.count, 2)
            let first = try XCTUnwrap(attempts.first), second = try XCTUnwrap(attempts.last)
            let boundary = Int64(frames[15].frame.timestamp &- frames[0].frame.timestamp)
            XCTAssertEqual(first.metadata.endTicks, boundary)
            let timing = try XCTUnwrap(first.metadata.timing)
            XCTAssertEqual(timing.time.canonicalUTC + Double(boundary) / 90000,
                try XCTUnwrap(second.metadata.timing).time.canonicalUTC, accuracy: 0.000001)
            let path = root + "/first.mp4"
            try SecureFiles.atomicWrite(first.payload.read(offset: 0, count: Int(first.metadata.size)), to: path, mode: 0o600)
            try await sampleTimes(path, expected: Array(frames.prefix(15)), endTicks: boundary)
        }
    }

    func testEpochChangeDoesNotUseNewEpochAsPreviousBoundary() async throws {
        let helper = StoreTests(), root = try helper.temporary()
        defer { try? FileManager.default.removeItem(atPath: root) }
        var config = try helper.config(root + "/local"); config.shardDuration = "1s"
        let camera = UUID().uuidString, store = try LocalRecordingStore(configuration: config)
        let frames = try video(previous: 5940, next: 2970, newEpoch: true)
        for frame in frames { store.accept(.media(camera: camera, name: "Boundary", frame)) }
        XCTAssertTrue(store.finish(timeout: 30)); XCTAssertNil(store.snapshot().lastError)
        let path = config.directory + "/Boundary"
        let directory = LocalRecordingLayout.Directory(path: path, fd: try StoreDirectory.openDirectory(path))
        let manifest = try LocalRecordingManifest(directory: directory, identity: .init(storeID: config.id, cameraID: camera), owner: geteuid(), readOnly: true)
        let rows = try manifest.recordings().sorted { $0.start < $1.start }
        XCTAssertEqual(rows.count, 2)
        let first = try XCTUnwrap(rows.first), second = try XCTUnwrap(rows.last)
        XCTAssertNotEqual(first.timing.time.epochID, second.timing.time.epochID)
        let estimatedEnd = Int64(frames[14].frame.timestamp &- frames[0].frame.timestamp) + 5940
        XCTAssertEqual(first.endTicks, estimatedEnd)
        XCTAssertGreaterThan(first.end, second.start)
        try await sampleTimes(path + "/" + first.filename, expected: Array(frames.prefix(15)), endTicks: estimatedEnd)
    }

    func testPendingFramePublishesLiveTagsImmediately() throws {
        let helper = StoreTests(), root = try helper.temporary()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let config = try helper.config(root + "/local"), camera = UUID().uuidString
        let store = try LocalRecordingStore(configuration: config)
        defer { _ = store.finish(timeout: 30) }
        let frames = try video(previous: 5940, next: 2970)
        store.accept(.media(camera: camera, name: "Boundary", frames[0]))
        try waitUntil { store.snapshot().recordedFrames == 1 }
        let path = config.directory + "/Boundary"
        let directory = LocalRecordingLayout.Directory(path: path, fd: try StoreDirectory.openDirectory(path))
        let manifest = try LocalRecordingManifest(directory: directory, identity: .init(storeID: config.id, cameraID: camera), owner: geteuid(), readOnly: true)
        let row = try XCTUnwrap(manifest.recordings().first)
        let live = try XCTUnwrap(RecordingRAMCache.shared.tagSnapshot(row: row))
        XCTAssertEqual(live.frames, 1)
        XCTAssertEqual(live.timeline?.tags(at: 0), frames[0].tags)
        store.accept(.media(camera: camera, name: "Boundary", frames[1]))
        try waitUntil { store.snapshot().recordedFrames == 2 }
        let latest = try XCTUnwrap(RecordingRAMCache.shared.tagSnapshot(row: row))
        XCTAssertEqual(latest.frames, 2)
        XCTAssertEqual(latest.timeline?.tags(at: 6300), frames[1].tags)
    }
}
