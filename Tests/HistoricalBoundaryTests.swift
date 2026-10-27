import XCTest
import Foundation
import Darwin
import AVFoundation

private actor HistoricalBoundaryReader: S3RepairReading {
    let objects: [String: Data]
    var reads: [String] = []
    init(objects: [String: Data]) { self.objects = objects }
    func list(after: String?) async throws -> S3RepairPage { throw ServiceError("Unexpected listing") }
    func read(_ object: S3RepairObject) async throws -> Data { throw ServiceError("Unexpected unindexed read") }
    func readIndexed(_ shard: S3PlaybackShard) async throws -> Data {
        reads.append(shard.id)
        guard let data = objects[shard.id] else { throw ServiceError("Unexpected object") }
        return data
    }
}

/// Every file/index mutation here is confined to a newly-created /private/tmp store.
/// Direct finalization deliberately retains the pre-boundary-aware writer's inferred tail.
final class HistoricalBoundaryTests: XCTestCase {
    private struct Fixture {
        let config: RecordingStoreConfiguration
        let manager: RecordingStoreManager
        let camera: String
        let directory: LocalRecordingLayout.Directory
        let index: LocalRecordingManifest
        let first: LocalRecordingManifest.Recording
        let second: LocalRecordingManifest.Recording

        func engine() -> HistoricalTagEngine {
            HistoricalTagEngine(configs: [config], manager: manager,
                factory: { _, _ in throw ServiceError("Unexpected network access") },
                credentials: nil, password: nil, cancellation: Cancellation())
        }
        func selection(_ start: Double, _ end: Double, timeline: MediaTimeline = .canonical,
                       epoch: String? = nil, startOffset: Int = 0, endOffset: Int = 0) -> HistoricalTagRequest.Selection {
            .init(cameraID: camera, timeline: timeline, epochID: epoch,
                start: .init(timestamp: start, frameOffset: startOffset),
                end: .init(timestamp: end, frameOffset: endOffset))
        }
        func request(_ selection: HistoricalTagRequest.Selection, value: String? = "new",
                     inspect: Bool = false, revisions: [String: String]? = nil) -> HistoricalTagRequest {
            .init(jobID: UUID().uuidString,
                edits: [.init(selection: selection, key: "person", value: value)],
                expectedRevisions: revisions, inspect: inspect)
        }
        func bytes(_ row: LocalRecordingManifest.Recording) throws -> Data {
            try Data(contentsOf: URL(fileURLWithPath: directory.path + "/" + row.filename))
        }
    }

    private func fixture(boundary: Int64 = 12000, differentEpoch: Bool = false,
                         rtpShift: UInt32 = 0, receivedShift: Double = 0, endExtra: Int64 = 0,
                         quantized: Bool = false, thirdBoundary: Int64? = nil, epochs: [String]? = nil) throws -> Fixture {
        let root = "/private/tmp/hbnvr-history-boundary-" + UUID().uuidString
        try SecureFiles.ensureDirectory(root, owner: geteuid(), mode: 0o700)
        var config = try StoreTests().config(root + "/recordings")
        config.retentionPeriod = "1y"
        let manager = RecordingStoreManager(spoolRoot: root + "/spool")
        try manager.install(config)
        addTeardownBlock { _ = manager.stop(); try? FileManager.default.removeItem(atPath: root) }
        let camera = UUID().uuidString, epoch = epochs?.first ?? UUID().uuidString
        let rootFD = try StoreDirectory.openDirectory(config.directory)
        defer { close(rootFD) }
        let directory = try LocalRecordingLayout.cameraDirectory(root: config.directory, fd: rootFD,
            store: config.id, camera: camera, name: "Boundary Camera", owner: geteuid())
        let index = try LocalRecordingManifest(directory: directory,
            identity: .init(storeID: config.id, cameraID: camera), owner: geteuid())
        let encoded = try XCTUnwrap(StoreTests.video(count: 1).first)
        let base = Date().timeIntervalSince1970 - 3600
        let rtp = UInt32.max - 8000 // The legitimate boundary crosses the RTP wrap.
        let offsets = [Int64(0), boundary] + (thirdBoundary.map { [$0] } ?? [])
        for (number, offset) in offsets.enumerated() {
            let elapsed = Double(offset) / 90000
            let time = RecordingTime(cameraUTC: base - 1 + elapsed,
                receivedUTC: base + elapsed + (number == 1 ? receivedShift : 0),
                canonicalUTC: base - 1 + elapsed, canonicalSource: .camera,
                epochID: number == 1 && differentEpoch ? (epochs?.last ?? UUID().uuidString) : epoch)
            let firstTimestamp = rtp &+ UInt32(offset) &+ (number == 1 ? rtpShift : 0)
            let sample = EncodedMedia(codec: encoded.codec, clockRate: 90000,
                parameterSets: encoded.parameterSets,
                frame: .init(payload: encoded.frame.payload, timestamp: firstTimestamp, keyFrame: true),
                receivedAt: Date(timeIntervalSince1970: time.receivedUTC), receivedUptime: 100 + elapsed,
                cameraUTC: time.cameraUTC, ssrc: 42, time: time)
            let timing = ShardTimingMetadata(storeID: config.id, cameraID: camera, media: sample, time: time)
            if quantized {
                let (filename, tags) = try legacyQuantizedShard(directory, sample: sample, timing: timing)
                try index.begin(id: timing.shardID, temporaryName: filename + ".recording", finalName: filename,
                    start: Date(timeIntervalSince1970: time.canonicalUTC), timescale: 90000,
                    sourceTimestamp: firstTimestamp, timing: timing)
                try index.complete(id: timing.shardID, filename: filename, endTicks: 14850 + (number == 0 ? endExtra : 0),
                    frames: 3, tags: tags)
                continue
            }
            let writer = try MP4Shard(directory: directory, codec: sample.codec, sets: sample.parameterSets,
                clock: sample.clockRate, firstTimestamp: firstTimestamp, capturedAt: sample.receivedAt, timing: timing)
            try index.begin(id: timing.shardID, temporaryName: writer.temporaryName, finalName: writer.finalName,
                start: Date(timeIntervalSince1970: time.canonicalUTC), timescale: 90000, sourceTimestamp: firstTimestamp, timing: timing)
            for tick in [UInt32(0), 3000, 9000] {
                try writer.append(.init(payload: sample.frame.payload, timestamp: firstTimestamp &+ tick, keyFrame: true),
                    tags: ["person": "old", "untouched": "retained", "original": "yes"])
            }
            try writer.finish()
            XCTAssertEqual(writer.endTicks, 15000)
            try index.complete(id: timing.shardID, filename: writer.finalName,
                endTicks: writer.endTicks + (number == 0 ? endExtra : 0), frames: writer.sampleCount, tags: writer.tagTimeline)
        }
        let rows = try index.recordings()
        XCTAssertEqual(rows.count, offsets.count)
        return Fixture(config: config, manager: manager, camera: camera, directory: directory,
            index: index, first: rows[0], second: rows[1])
    }

    /// Reproduce the actual older MP4 timing grid independently of the repaired writer.
    /// Raw RTP PTS [0,2970,8910] and inferred end14850 are kept in the manifest,
    /// while the old AVFoundation video time scale rounds compressed-sample PTS.
    private func legacyQuantizedShard(_ directory: LocalRecordingLayout.Directory, sample: EncodedMedia,
                                      timing: ShardTimingMetadata) throws -> (String, VideoTagTimeline) {
        let filename = try LocalRecordingLayout.availableStem(in: directory.fd, at: sample.receivedAt) + ".mp4"
        let writer = try AVAssetWriter(outputURL: URL(fileURLWithPath: directory.path + "/" + filename), fileType: .mp4)
        writer.metadata = try timing.assetMetadata()
        writer.movieTimeScale = 600
        let format = try MP4Shard.format(codec: sample.codec, sets: sample.parameterSets)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        input.mediaTimeScale = 600
        writer.add(input)
        guard writer.startWriting() else { throw ServiceError("Legacy fixture could not start") }
        writer.startSession(atSourceTime: .zero)
        for (pts, duration) in [(Int64(0), Int64(6000)), (2970, 2970), (8910, 5940)] {
            try MP4WriterWait.untilReady(ready: { input.isReadyForMoreMediaData }, failure: { nil }, timeoutMessage: "Legacy fixture stalled")
            var block: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: sample.frame.payload.count,
                blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: sample.frame.payload.count,
                flags: 0, blockBufferOut: &block) == noErr, let block else { throw ServiceError("Legacy fixture allocation failed") }
            let copied = sample.frame.payload.withUnsafeBytes {
                CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: $0.count)
            }
            var timing = CMSampleTimingInfo(duration: CMTime(value: duration, timescale: 90000),
                presentationTimeStamp: CMTime(value: pts, timescale: 90000), decodeTimeStamp: .invalid)
            var size = sample.frame.payload.count, buffer: CMSampleBuffer?
            guard copied == noErr, CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format,
                sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &buffer) == noErr,
                let buffer, input.append(buffer) else { throw ServiceError("Legacy fixture sample failed") }
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        guard done.wait(timeout: .now() + 30) == .success, writer.status == .completed else { throw ServiceError("Legacy fixture finalization failed") }
        let tags = VideoTagTimeline(changes: [.init(ticks: 0, frame: 0,
            tags: ["person": "old", "untouched": "retained", "original": "yes"])])
        let fd = openat(directory.fd, filename, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ServiceError("Legacy fixture could not open") }
        defer { close(fd) }
        try VideoTagMP4.append(tags, fd: fd)
        guard fchmod(fd, 0o600) == 0, fsync(fd) == 0 else { throw ServiceError("Legacy fixture could not secure file") }
        return (filename, tags)
    }

    func testLegacy600ScalePTSQuantizationStillProvesVariableSpacingBoundary() async throws {
        let f = try fixture(boundary: 11880, quantized: true)
        let source = LocalMediaProvider.Source(directory: f.directory, owner: geteuid(), row: f.first,
            range: .init(start: f.first.start, end: f.first.end))
        let ticks = try LocalMediaReader.frameTicks(source, work: MediaWork())
        XCTAssertEqual(ticks.count, 3)
        XCTAssertNotEqual(ticks, [0, 2970, 8910]) // This fixture really rounded the original RTP PTS.
        XCTAssertNotEqual(ticks[2] * 2 - ticks[1], f.first.endTicks)
        let before = try [f.bytes(f.first), f.bytes(f.second)]
        let selection = f.selection(f.first.start, f.second.end)
        let (inspection, _) = try await f.engine().run(f.request(selection, inspect: true)) { _ in }
        XCTAssertEqual(inspection.state, "completed")
        XCTAssertTrue(inspection.gaps.isEmpty)
        XCTAssertEqual(try [f.bytes(f.first), f.bytes(f.second)], before)
        let frames = f.selection(f.first.start, f.first.start, startOffset: 2, endOffset: 5)
        let (edited, _) = try await f.engine().run(f.request(frames)) { _ in }
        XCTAssertEqual(edited.results.count, 2)
        XCTAssertEqual(try f.index.historicalTags(id: f.first.id)?.tags(at: ticks[2])?["person"], "new")
        let second = try XCTUnwrap(f.index.historicalTags(id: f.second.id))
        XCTAssertEqual(second.tags(at: ticks[0])?["person"], "new")
        XCTAssertEqual(second.tags(at: ticks[1])?["person"], "new")
        XCTAssertEqual(second.tags(at: ticks[2])?["person"], "old")
        XCTAssertEqual(second.tags(at: ticks[1])?["untouched"], "retained")
    }

    func testLegacyVariableSpacingInspectionAcrossBoundaryAllTimelinesAndEpochSelectorsIsReadOnly() async throws {
        let f = try fixture(), before = try [f.bytes(f.first), f.bytes(f.second)]
        XCTAssertEqual(f.first.end - f.second.start, 1.0 / 30, accuracy: 0.000001)
        for timeline in [MediaTimeline.canonical, .camera, .received] {
            let start = try XCTUnwrap(timeline.anchor(f.first.timing.time))
            let next = try XCTUnwrap(timeline.anchor(f.second.timing.time))
            for epoch in [nil, f.first.timing.time.epochID] {
                let request = f.request(f.selection(start, next + 0.1, timeline: timeline, epoch: epoch), inspect: true)
                let (status, data) = try await f.engine().run(request) { _ in }
                XCTAssertEqual(status.state, "completed")
                XCTAssertTrue(status.gaps.isEmpty)
                let inspected = try JSONDecoder().decode([FootageTagInspection].self, from: XCTUnwrap(data))
                XCTAssertEqual(inspected.count, 1, "Identical adjacent footage states coalesce across storage boundaries")
                let span = try XCTUnwrap(inspected.first)
                XCTAssertEqual(span.cameraID, f.camera)
                XCTAssertEqual(span.timeline, timeline)
                XCTAssertEqual(span.epochID, f.first.timing.time.epochID)
                XCTAssertEqual(span.start, start, accuracy: 0.000001)
                XCTAssertEqual(span.end, next + 0.1, accuracy: 0.000001)
                XCTAssertEqual(span.tags.values["person"], "old")
                XCTAssertTrue(span.tags.complete)
                let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [[String: Any]])
                XCTAssertTrue(wire.allSatisfy { $0["storeID"] == nil && $0["shardID"] == nil && $0["endTicks"] == nil })
            }
        }
        XCTAssertEqual(try [f.bytes(f.first), f.bytes(f.second)], before)
        XCTAssertEqual(try f.index.recordings().map(\.inode), [f.first.inode, f.second.inode])
    }

    func testBoundaryEditsPreserveOtherKeysAndExcludePrecedingPhantomTail() async throws {
        let f = try fixture()
        let selection = f.selection(f.first.start + 9000.0 / 90000, f.second.start + 6000.0 / 90000)
        let (status, _) = try await f.engine().run(f.request(selection)) { _ in }
        XCTAssertEqual(status.results.count, 2)
        let first = try XCTUnwrap(f.index.historicalTags(id: f.first.id))
        let second = try XCTUnwrap(f.index.historicalTags(id: f.second.id))
        XCTAssertEqual(first.tags(at: 3000)?["person"], "old")
        XCTAssertEqual(first.tags(at: 9000)?["person"], "new")
        XCTAssertEqual(second.tags(at: 0)?["person"], "new")
        XCTAssertEqual(second.tags(at: 3000)?["person"], "new")
        XCTAssertEqual(second.tags(at: 9000)?["person"], "old")
        for tags in [first, second] {
            for tick in [Int64(0), 3000, 9000] {
                XCTAssertEqual(tags.tags(at: tick)?["untouched"], "retained")
                XCTAssertEqual(tags.tags(at: tick)?["original"], "yes")
            }
        }
        let firstBytes = try f.bytes(f.first)
        let exactBoundary = f.selection(f.second.start, f.second.start + 6000.0 / 90000)
        let (removed, _) = try await f.engine().run(f.request(exactBoundary, value: nil)) { _ in }
        XCTAssertEqual(removed.results.map(\.shardID), [f.second.id])
        XCTAssertEqual(try f.bytes(f.first), firstBytes)
        let after = try XCTUnwrap(f.index.historicalTags(id: f.second.id))
        XCTAssertNil(after.tags(at: 0)?["person"])
        XCTAssertNil(after.tags(at: 3000)?["person"])
        XCTAssertEqual(after.tags(at: 9000)?["person"], "old")
        XCTAssertEqual(after.tags(at: 0)?["untouched"], "retained")
    }

    func testFrameOffsetsCountRealSamplesOnceAcrossLegacyBoundary() async throws {
        let f = try fixture()
        // Combined PTS: A0, A3000, A9000, B0, B3000, B9000.
        let selection = f.selection(f.first.start, f.first.start, startOffset: 2, endOffset: 5)
        let (status, _) = try await f.engine().run(f.request(selection)) { _ in }
        XCTAssertEqual(status.results.count, 2)
        XCTAssertTrue(status.gaps.isEmpty)
        XCTAssertEqual(try f.index.historicalTags(id: f.first.id)?.tags(at: 9000)?["person"], "new")
        XCTAssertEqual(try f.index.historicalTags(id: f.second.id)?.tags(at: 0)?["person"], "new")
        XCTAssertEqual(try f.index.historicalTags(id: f.second.id)?.tags(at: 3000)?["person"], "new")
        XCTAssertEqual(try f.index.historicalTags(id: f.second.id)?.tags(at: 9000)?["person"], "old")
    }

    func testActualSampleOverlapCannotBeDisambiguatedBySameEpoch() async throws {
        // Boundary at the last sample duplicates its PTS; earlier boundary interleaves samples.
        for boundary in [Int64(9000), 6000] {
            let f = try fixture(boundary: boundary), before = try [f.bytes(f.first), f.bytes(f.second)]
            for epoch in [nil, f.first.timing.time.epochID] {
                let request = f.request(f.selection(f.first.start, f.second.end, epoch: epoch))
                do { _ = try await f.engine().run(request) { _ in }; XCTFail("Overlapping samples were accepted") }
                catch { XCTAssertTrue(error is ServiceError) }
            }
            XCTAssertEqual(try [f.bytes(f.first), f.bytes(f.second)], before)
        }
    }

    func testQuantizedLastSampleCannotBeNormalizedAcrossItsUncertainty() async throws {
        let f = try fixture(boundary: 8910, quantized: true)
        let before = try [f.bytes(f.first), f.bytes(f.second)]
        // The original last PTS equals the successor start. Even if the MP4
        // rounds that PTS down, its measured uncertainty crosses the boundary.
        let request = f.request(f.selection(f.first.start, f.second.end, epoch: f.first.timing.time.epochID))
        do { _ = try await f.engine().run(request) { _ in }; XCTFail("A potentially duplicated rounded sample was accepted") }
        catch { XCTAssertTrue(error is ServiceError) }
        XCTAssertEqual(try [f.bytes(f.first), f.bytes(f.second)], before)
    }

    func testFrameOffsetInsideOneRecordingIgnoresLaterAmbiguousLookahead() async throws {
        let f = try fixture(boundary: 9000)
        // The duplicated PTS at 9000 is outside this selection, which ends at A3000.
        let selection = f.selection(f.first.start, f.first.start, endOffset: 1)
        let (status, _) = try await f.engine().run(f.request(selection)) { _ in }
        XCTAssertEqual(status.results.map(\.shardID), [f.first.id])
        XCTAssertEqual(try f.index.historicalTags(id: f.first.id)?.tags(at: 0)?["person"], "new")
        XCTAssertEqual(try f.index.historicalTags(id: f.first.id)?.tags(at: 3000)?["person"], "old")
        XCTAssertEqual(try f.index.historicalTags(id: f.second.id)?.tags(at: 0)?["person"], "old")
    }

    func testFrameOffsetToSuccessorDoesNotTraversePastItsBoundaryIntoThirdShard() async throws {
        let f = try fixture(thirdBoundary: 14000)
        let third = try XCTUnwrap(f.index.recordings().last)
        let originals = try [f.bytes(f.first), f.bytes(third)]
        // A's inferred end15000 contains B0 at12000 and C0 at14000. Offset3
        // lands on B0; the actual B/C overlap occurs after this selection.
        let selection = f.selection(f.first.start, f.second.start + 0.01, startOffset: 3)
        let (status, _) = try await f.engine().run(f.request(selection)) { _ in }
        XCTAssertEqual(status.results.map(\.shardID), [f.second.id])
        XCTAssertEqual(try f.index.historicalTags(id: f.second.id)?.tags(at: 0)?["person"], "new")
        XCTAssertEqual(try f.index.historicalTags(id: f.second.id)?.tags(at: 3000)?["person"], "old")
        XCTAssertEqual(try [f.bytes(f.first), f.bytes(third)], originals)
    }

    func testDistinctEpochOverlapStillRequiresExplicitEpoch() async throws {
        let f = try fixture(differentEpoch: true), before = try [f.bytes(f.first), f.bytes(f.second)]
        do {
            _ = try await f.engine().run(f.request(f.selection(f.first.start, f.second.end))) { _ in }
            XCTFail("Overlapping epochs were accepted")
        } catch { XCTAssertTrue(error is ServiceError) }
        let request = f.request(f.selection(f.first.start, f.second.end, epoch: f.first.timing.time.epochID), inspect: true)
        let (_, data) = try await f.engine().run(request) { _ in }
        let inspected = try JSONDecoder().decode([FootageTagInspection].self, from: XCTUnwrap(data))
        XCTAssertEqual(inspected.count, 1)
        XCTAssertEqual(inspected.first?.epochID, f.first.timing.time.epochID)
        XCTAssertEqual(try XCTUnwrap(inspected.first).start, f.first.start, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(inspected.first).end, f.first.end, accuracy: 0.000001)
        XCTAssertEqual(try [f.bytes(f.first), f.bytes(f.second)], before)
    }

    func testPublicCoverageAcrossEpochsUsesTimeOrderAndHidesStorageCoordinates() async throws {
        let epochs = ["FFFFFFFF-FFFF-4FFF-BFFF-FFFFFFFFFFFF", "00000000-0000-4000-8000-000000000000"]
        let f = try fixture(differentEpoch: true, receivedShift: 2, epochs: epochs)
        let start = f.first.timing.time.receivedUTC
        let end = f.second.timing.time.receivedUTC + Double(f.second.endTicks) / Double(f.second.timescale)
        let selection = f.selection(start, end, timeline: .received)
        let (status, _) = try await f.engine().run(f.request(selection)) { _ in }
        XCTAssertEqual(status.gaps.count, 1)
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(status)) as? [String: Any])
        let results = try XCTUnwrap(wire["results"] as? [[String: Any]])
        XCTAssertEqual(results.compactMap { $0["epochID"] as? String }, epochs)
        XCTAssertTrue(results.allSatisfy { row in
            ["storeID", "shardID", "revision", "publication"].allSatisfy { row[$0] == nil }
        })
        XCTAssertLessThan(try XCTUnwrap(results.first?["start"] as? Double),
                          try XCTUnwrap(results.last?["start"] as? Double))
        let (_, data) = try await f.engine().run(f.request(selection, inspect: true)) { _ in }
        let spans = try JSONDecoder().decode([FootageTagInspection].self, from: XCTUnwrap(data))
        XCTAssertEqual(spans.map(\.epochID), epochs)
        XCTAssertLessThan(spans[0].end, spans[1].start)
        XCTAssertTrue(spans.allSatisfy { $0.tags.values["person"] == "new" })
    }

    func testMatchingEpochAloneDoesNotPermitInconsistentRTPOrClockAnchors() async throws {
        for (rtpShift, receivedShift) in [(UInt32(3000), 0.0), (UInt32(0), 0.05)] {
            let f = try fixture(rtpShift: rtpShift, receivedShift: receivedShift)
            let request = f.request(f.selection(f.first.start, f.second.end, epoch: f.first.timing.time.epochID))
            do { _ = try await f.engine().run(request) { _ in }; XCTFail("Inconsistent timing was normalized") }
            catch { XCTAssertTrue(error is ServiceError) }
        }
    }

    func testOverlapMustMatchTheWritersActualTailExtrapolation() async throws {
        for quantized in [false, true] {
            let f = try fixture(boundary: quantized ? 11880 : 12000, endExtra: 1000, quantized: quantized)
            let request = f.request(f.selection(f.first.start, f.second.end, epoch: f.first.timing.time.epochID))
            do { _ = try await f.engine().run(request) { _ in }; XCTFail("Unexplained duration overlap was accepted") }
            catch { XCTAssertTrue(error is ServiceError) }
        }
    }

    func testBoundaryRevisionConflictDoesNotPartiallyCommit() async throws {
        let f = try fixture(), before = try [f.bytes(f.first), f.bytes(f.second)]
        let revisions = [f.config.id + "/" + f.first.id: try HistoricalTags.revision(f.index.historicalTags(id: f.first.id)),
                         f.config.id + "/" + f.second.id: "stale"]
        let request = f.request(f.selection(f.first.start, f.second.end), revisions: revisions)
        do { _ = try await f.engine().run(request) { _ in }; XCTFail("Stale boundary revision was accepted") }
        catch { XCTAssertEqual((error as? ServiceError)?.message, "Tag revision conflict; inspect again before editing.") }
        XCTAssertEqual(try [f.bytes(f.first), f.bytes(f.second)], before)
        XCTAssertEqual(try f.index.recordings().map(\.inode), [f.first.inode, f.second.inode])
    }

    func testFinalSourceFramePropagationStopsAtProvenBoundaryInDifferentStore() async throws {
        let f = try fixture(), target = try StoreTests().config(f.config.directory + "-mirror")
        try f.manager.install(target)
        let fd = try StoreDirectory.openDirectory(target.directory)
        defer { close(fd) }
        let directory = try LocalRecordingLayout.cameraDirectory(root: target.directory, fd: fd,
            store: target.id, camera: f.camera, name: "Boundary Camera", owner: geteuid())
        let index = try LocalRecordingManifest(directory: directory,
            identity: .init(storeID: target.id, cameraID: f.camera), owner: geteuid())
        let encoded = try XCTUnwrap(StoreTests.video(count: 1).first)
        let sample = EncodedMedia(codec: encoded.codec, clockRate: 90000, parameterSets: encoded.parameterSets,
            frame: .init(payload: encoded.frame.payload, timestamp: f.first.timing.rtpTimestamp, keyFrame: true),
            receivedAt: Date(timeIntervalSince1970: f.first.timing.time.receivedUTC),
            receivedUptime: 100, cameraUTC: f.first.timing.time.cameraUTC, ssrc: 42, time: f.first.timing.time)
        let timing = ShardTimingMetadata(storeID: target.id, cameraID: f.camera, media: sample, time: f.first.timing.time)
        let writer = try MP4Shard(directory: directory, codec: sample.codec, sets: sample.parameterSets,
            clock: sample.clockRate, firstTimestamp: sample.frame.timestamp, capturedAt: sample.receivedAt, timing: timing)
        try index.begin(id: timing.shardID, temporaryName: writer.temporaryName, finalName: writer.finalName,
            start: Date(timeIntervalSince1970: timing.time.canonicalUTC), timescale: 90000,
            sourceTimestamp: sample.frame.timestamp, timing: timing)
        // This store uses a single shard across both source shards.
        for tick in [UInt32(0), 3000, 9000, 12000, 15000, 21000] {
            try writer.append(.init(payload: sample.frame.payload, timestamp: sample.frame.timestamp &+ tick, keyFrame: true),
                tags: ["person": "old", "untouched": "retained"])
        }
        try writer.finish()
        try index.complete(id: timing.shardID, filename: writer.finalName,
            endTicks: writer.endTicks, frames: writer.sampleCount, tags: writer.tagTimeline)
        for selection in [HistoricalTagRequest.Selection(shardID: f.first.id, sourceStoreID: f.config.id, allFrames: true),
                          .init(shardID: f.first.id, sourceStoreID: f.config.id, startFrame: 2, endFrame: 3)] {
            let engine = HistoricalTagEngine(configs: [f.config, target], manager: f.manager,
                factory: { _, _ in throw ServiceError("Unexpected network access") },
                credentials: nil, password: nil, cancellation: Cancellation())
            let request = HistoricalTagRequest(jobID: UUID().uuidString,
                edits: [.init(selection: selection, key: "person", value: "new")])
            let (status, _) = try await engine.run(request) { _ in }
            XCTAssertEqual(Set(status.results.map(\.shardID)), [f.first.id, timing.shardID])
            let tags = try XCTUnwrap(index.historicalTags(id: timing.shardID))
            XCTAssertEqual(tags.tags(at: 9000)?["person"], "new")
            XCTAssertEqual(tags.tags(at: 12000)?["person"], "old")
            XCTAssertEqual(tags.tags(at: 15000)?["person"], "old")
            XCTAssertEqual(tags.tags(at: 9000)?["untouched"], "retained")
        }
        XCTAssertEqual(try f.index.historicalTags(id: f.first.id)?.tags(at: 9000)?["person"], "new")
    }

    func testLegacyS3OverlapRequiresVerifiedSamplesAndChangesOnlyTagMetadata() async throws {
        let f = try fixture(boundary: 11880, quantized: true)
        let root = "/private/tmp/hbnvr-history-boundary-s3-" + UUID().uuidString
        try SecureFiles.ensureDirectory(root, owner: geteuid(), mode: 0o700)
        var config = try S3Tests().config()
        config.id = f.config.id // The immutable embedded identities must match the remote journal.
        let network = FakeS3()
        let manager = RecordingStoreManager(spoolRoot: root + "/spool", transportFactory: { _ in network })
        try manager.install(config)
        defer { _ = manager.stop(); try? FileManager.default.removeItem(atPath: root) }
        let sink = try manager.repairSink(config: config, cameras: [f.camera], cameraStillExists: { _ in true })
        let objects = try Dictionary(uniqueKeysWithValues: [f.first, f.second].map { ($0.id, try f.bytes($0)) })
        for row in [f.first, f.second] {
            var metadata = S3ShardMetadata.make(store: config, camera: f.camera, name: "Boundary Camera",
                capturedAt: Date(timeIntervalSince1970: row.timing.time.receivedUTC), data: objects[row.id]!, id: row.id)
            metadata.timing = row.timing; metadata.endTicks = row.endTicks
            metadata.tagMetadata = try .freeze(XCTUnwrap(f.index.historicalTags(id: row.id)), password: nil)
            _ = try await sink.merge(metadata, Cancellation())
        }
        let original = try manager.historicalS3(config.id).historicalShards().sorted { $0.start < $1.start }
        let request = f.request(f.selection(f.first.start, f.second.end))
        let unreadable = HistoricalTagEngine(configs: [config], manager: manager,
            factory: { _, _ in throw ServiceError("No object-read access") },
            credentials: nil, password: nil, cancellation: Cancellation())
        let snapshot = try unreadable.snapshot(.init(cameraID: f.camera,
            ranges: [.init(start: f.first.start, end: f.second.end)], keys: ["person", "untouched"]))
        XCTAssertFalse(snapshot.isEmpty, "Metadata snapshots do not need S3 GetObject even for legacy overlap")
        XCTAssertTrue(snapshot.allSatisfy { $0.tags.values["untouched"] == "retained" })
        do { _ = try await unreadable.run(request) { _ in }; XCTFail("Unverified remote overlap was accepted") }
        catch { XCTAssertTrue(error is ServiceError) }
        XCTAssertEqual(try manager.historicalS3(config.id).historicalShards().sorted { $0.start < $1.start }, original)
        let reader = HistoricalBoundaryReader(objects: objects)
        let engine = HistoricalTagEngine(configs: [config], manager: manager, factory: { _, _ in reader },
            credentials: nil, password: nil, cancellation: Cancellation())
        let (status, _) = try await engine.run(request) { _ in }
        XCTAssertEqual(status.results.count, 2)
        XCTAssertTrue(status.results.allSatisfy { $0.publication == "s3-queued" })
        let reads = await reader.reads
        XCTAssertTrue(reads.contains(f.first.id))
        let edited = try manager.historicalS3(config.id).historicalShards().sorted { $0.start < $1.start }
        for (before, after) in zip(original, edited) {
            XCTAssertEqual(after.key, before.key)
            XCTAssertEqual(after.size, before.size)
            XCTAssertEqual(after.sha256, before.sha256)
            XCTAssertEqual(after.endTicks, before.endTicks)
            XCTAssertEqual(after.tagMetadata?.timeline?.tags(at: 0)?["person"], "new")
            XCTAssertEqual(after.tagMetadata?.timeline?.tags(at: 0)?["untouched"], "retained")
        }
        let uploads = await network.attempts
        XCTAssertTrue(uploads.isEmpty)
        XCTAssertEqual(try f.bytes(f.first), objects[f.first.id])
        XCTAssertEqual(try f.bytes(f.second), objects[f.second.id])
    }
}
