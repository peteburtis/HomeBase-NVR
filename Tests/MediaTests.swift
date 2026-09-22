import XCTest
import Foundation
import Darwin
import AVFoundation
import CoreMedia

final class MediaTests: XCTestCase {
    let base: Double = 1_800_000_000
    struct Fixture {
        let root: String
        let config: RecordingStoreConfiguration
        let camera: String
        let samples: [EncodedMedia]
        let store: LocalRecordingStore
        var provider: LocalMediaProvider { LocalMediaProvider(configurations: { [config] }, ram: nil) }
        var ramProvider: LocalMediaProvider { LocalMediaProvider(configurations: { [config] }) }
        var folder: String { config.directory + "/Test Camera" }
    }
    func fixture(codec: CMVideoCodecType = kCMVideoCodecType_H264, cameraClock: Bool = true,
                 shard: String = "1m", count: Int = 45, largeFrames: Bool = false,
                 initialCount: Int? = nil, timestampSkewPerFrame: UInt32 = 0,
                 startUTC: Double? = nil, cameraID: String? = nil,
                 tags: (Int) -> [String: String] = { _ in [:] }) throws -> Fixture {
        let root = "/private/tmp/hbnvr-media-tests-" + UUID().uuidString
        try SecureFiles.ensureDirectory(root, owner: geteuid(), mode: 0o700)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: root) }
        let directory = root + "/recordings"
        try StoreDirectory.create(directory, owner: geteuid(), daemon: geteuid())
        var config = RecordingStoreConfiguration(directory: directory, ownerUID: geteuid(), ownerUUID: try StoreDirectory.identity(geteuid()))
        config.shardDuration = shard
        let camera = cameraID ?? UUID().uuidString, store = try LocalRecordingStore(configuration: config)
        addTeardownBlock { _ = store.finish(timeout: 10) }
        var timeline = RecordingTimeline(), samples: [EncodedMedia] = []
        for (number, input) in try StoreTests.video(codec: codec, count: count).enumerated() {
            let timestamp = input.frame.timestamp &+ UInt32(number) &* timestampSkewPerFrame
            let offset = Double(timestamp) / Double(input.clockRate)
            var payload = input.frame.payload
            if largeFrames {
                // H.264 filler NAL exercises multi-record payloads without changing
                // the picture or requiring a large-resolution test encoder.
                let filler = Data([0x0c]) + Data(repeating: 0xff, count: 150_000) + Data([0x80])
                var length = UInt32(filler.count).bigEndian
                withUnsafeBytes(of: &length) { payload.append(contentsOf: $0) }; payload.append(filler)
            }
            var sample = EncodedMedia(codec: input.codec, clockRate: input.clockRate, parameterSets: input.parameterSets,
                frame: .init(payload: payload, timestamp: timestamp, keyFrame: input.frame.keyFrame),
                receivedAt: Date(timeIntervalSince1970: (startUTC ?? base) + 0.4 + offset), receivedUptime: 100 + offset,
                cameraUTC: cameraClock ? (startUTC ?? base) + offset : nil, ssrc: 42, tags: tags(number))
            sample.time = try timeline.observe(sample); samples.append(sample)
            if initialCount == nil || samples.count <= initialCount! {
                store.accept(.media(camera: camera, name: "Test Camera", sample))
            }
        }
        if initialCount == nil { XCTAssertTrue(store.finish(timeout: 10)) }
        else { XCTAssertTrue(store.flush(timeout: 10)) }
        XCTAssertNil(store.snapshot().lastError)
        return Fixture(root: root, config: config, camera: camera, samples: samples, store: store)
    }
    func testNeighborsSearchAcrossDaysAndBothArchiveEndsInSelectedStoreWithoutFrames() throws {
        let first = try fixture(), later = try fixture(startUTC: base + 3 * 86400, cameraID: first.camera)
        let writer = try LocalRecordingStore(configuration: first.config)
        for sample in later.samples { writer.accept(.media(camera: first.camera, name: "Test Camera", sample)) }
        XCTAssertTrue(writer.finish(timeout: 10))
        let provider = first.provider
        func around(_ at: Double) throws -> MediaNeighbors {
            let output = try response(request(first.camera, start: at, end: at + 0.001, operation: "neighbors"), provider: provider)
            XCTAssertEqual(output.messages.map(\.type), ["begin", "neighbors", "end"])
            XCTAssertEqual(output.messages.last?.outcome, "complete")
            XCTAssertTrue(output.payloads.isEmpty)
            return try XCTUnwrap(output.messages[1].neighbors)
        }
        let middle = try around(base + 86400)
        XCTAssertEqual(middle.previous?.start, base)
        XCTAssertEqual(middle.next?.start, base + 3 * 86400)
        XCTAssertNil(try around(base - 86400).previous)
        XCTAssertEqual(try around(base - 86400).next?.start, base)
        XCTAssertNil(try around(base + 4 * 86400).next)
        XCTAssertEqual(try around(base + 4 * 86400).previous?.start, base + 3 * 86400)
        let other = try provider.neighbors(camera: UUID().uuidString, range: .init(start: base, end: base + 1), timeline: .canonical, work: MediaWork())
        XCTAssertEqual(other, MediaNeighbors())
    }
    func testNeighborsSkipDeletedFilesAndNeverTreatMissingStoreOrCancellationAsArchiveEnd() throws {
        let first = try fixture(), later = try fixture(startUTC: base + 60, cameraID: first.camera)
        let writer = try LocalRecordingStore(configuration: first.config)
        for sample in later.samples { writer.accept(.media(camera: first.camera, name: "Test Camera", sample)) }
        XCTAssertTrue(writer.finish(timeout: 10))
        let provider = first.provider
        let query = MediaRange(start: base + 100, end: base + 101)
        let source = try XCTUnwrap(provider.catalog(camera: first.camera,
            range: .init(start: base + 60, end: base + 70), timeline: .canonical, work: MediaWork()).first)
        try FileManager.default.removeItem(atPath: source.directory.path + "/" + source.row.filename)
        XCTAssertEqual(try provider.neighbors(camera: first.camera, range: query, timeline: .canonical, work: MediaWork()).previous?.start, base)
        let cancellation = Cancellation(); cancellation.stop()
        XCTAssertThrowsError(try provider.neighbors(camera: first.camera, range: query, timeline: .canonical, work: MediaWork(cancellation: cancellation)))
        try FileManager.default.removeItem(atPath: first.config.directory)
        XCTAssertThrowsError(try provider.neighbors(camera: first.camera, range: query, timeline: .canonical, work: MediaWork()))
    }
    func testNeighborsIncludeActiveRAMAndGrowingDiskAndRespectTimeline() throws {
        let f = try fixture(count: 180, initialCount: 45)
        let query = MediaRange(start: base + 100, end: base + 101)
        let memory = try f.ramProvider.neighbors(camera: f.camera, range: query, timeline: .canonical, work: MediaWork())
        XCTAssertEqual(memory.previous?.end ?? 0, base + 3, accuracy: 0.1)
        XCTAssertNil(memory.next)
        let received = try f.ramProvider.neighbors(camera: f.camera, range: query, timeline: .received, work: MediaWork())
        XCTAssertEqual(received.previous!.end - memory.previous!.end, 0.4, accuracy: 0.001)
        let noClock = try fixture(cameraClock: false)
        XCTAssertEqual(try noClock.provider.neighbors(camera: noClock.camera, range: query, timeline: .camera, work: MediaWork()), MediaNeighbors())
    }
    func testCoarseMP4ClockDoesNotRejectTheLastFrame() throws {
        let f = try fixture(timestampSkewPerFrame: 3)
        let result = try response(request(f.camera, start: base, end: base + 4), provider: f.provider)
        XCTAssertEqual(result.payloads.count, 45)
        XCTAssertEqual(result.payloads, f.samples.map { $0.frame.payload })
        XCTAssertEqual(try LocalMediaReader.boundedDuration(8000, presentation: 5512000, end: 5519970,
            sourceScale: 600, outputScale: 90000), 7970)
        XCTAssertThrowsError(try LocalMediaReader.boundedDuration(9000, presentation: 5512000, end: 5519970,
            sourceScale: 600, outputScale: 90000))
    }
    func testGrowingBothCodecsReadBeforeCommitAndSeeNewFragments() throws {
        for codec in [kCMVideoCodecType_H264, kCMVideoCodecType_HEVC] {
            let f = try fixture(codec: codec, count: 180, initialCount: 45)
            let query = request(f.camera, start: base, end: base + 12)
            var first = try response(query, provider: f.provider)
            let deadline = Date().addingTimeInterval(3)
            while first.payloads.isEmpty, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02); first = try response(query, provider: f.provider)
            }
            XCTAssertGreaterThan(first.payloads.count, 0)
            XCTAssertLessThan(first.payloads.count, 45) // Accepted does not mean on disk.
            XCTAssertEqual(first.payloads, Array(f.samples.prefix(first.payloads.count).map { $0.frame.payload }))
            XCTAssertEqual(first.messages.last?.outcome, "partial")
            XCTAssertEqual(f.store.snapshot().completedShards, 0)
            let original = try f.provider.catalog(camera: f.camera, range: query.range, timeline: .canonical, work: MediaWork())
            let source = try XCTUnwrap(original.first)
            XCTAssertEqual(source.row.state, .recording)
            XCTAssertEqual(source.row.endTicks, 0) // No five-second manifest checkpoint needed.
            XCTAssertGreaterThan(source.endTicks, 0)
            let availability = try response(request(f.camera, start: base, end: base + 12, operation: "availability"), provider: f.provider)
            let edge = try XCTUnwrap(availability.messages.first { $0.type == "available" }?.range?.end)
            let last = try XCTUnwrap(first.messages.compactMap(\.frame).last)
            XCTAssertEqual(edge, base + Double(last.presentationTicks + last.durationTicks) / 90000, accuracy: 0.001)
            for sample in f.samples.dropFirst(45) { f.store.accept(.media(camera: f.camera, name: "Test Camera", sample)) }
            XCTAssertTrue(f.store.flush(timeout: 10))
            var later = try response(query, provider: f.provider)
            while later.payloads.count <= first.payloads.count, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02); later = try response(query, provider: f.provider)
            }
            XCTAssertGreaterThan(later.payloads.count, first.payloads.count)
            XCTAssertLessThan(later.payloads.count, 180)
            XCTAssertEqual(later.payloads, Array(f.samples.prefix(later.payloads.count).map { $0.frame.payload }))
            XCTAssertEqual(f.store.snapshot().activeRecordings, 1)
            XCTAssertEqual(f.store.snapshot().completedShards, 0)
            // A request's prefix doesn't grow underneath its AVAssetReader.
            var frozenFrames: UInt64 = 0
            for piece in try LocalMediaProvider.plan(original, range: query.range) {
                frozenFrames += try LocalMediaReader.read(piece, number: 0, request: query, work: MediaWork(), emit: { _ in }, bytes: { _ in }).frames
            }
            XCTAssertEqual(frozenFrames, UInt64(first.payloads.count))
            XCTAssertTrue(f.store.finish(timeout: 10)); XCTAssertNil(f.store.snapshot().lastError)
            XCTAssertThrowsError(try source.growing?.check())
            let final = try response(query, provider: f.provider)
            XCTAssertEqual(final.payloads, f.samples.map { $0.frame.payload })
            XCTAssertEqual(final.messages.last?.outcome, "complete")
        }
    }
    func testActiveReaderCannotDelayFinalizationOrReadRewrittenLayout() throws {
        let f = try fixture(count: 180, initialCount: 180)
        Thread.sleep(forTimeInterval: 0.1)
        let query = request(f.camera, start: base, end: base + 12)
        var frames = 0
        XCTAssertThrowsError(try MediaResponse.run(query, provider: f.provider, work: MediaWork(), emit: { message in
            if message.frame != nil { frames += 1 }
        }, bytes: { _ in
            if frames == 1 { XCTAssertTrue(f.store.finish(timeout: 10)) }
        }))
        XCTAssertGreaterThan(frames, 0)
        XCTAssertEqual(f.store.snapshot().completedShards, 1)
        XCTAssertEqual(try response(query, provider: f.provider).payloads.count, 180)
    }
    func testConcurrentAppendingAndRepeatedReadsUseCompletePrefixes() throws {
        let f = try fixture(count: 180, initialCount: 45)
        Thread.sleep(forTimeInterval: 0.1)
        let appended = DispatchGroup(); appended.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { appended.leave() }
            for sample in f.samples.dropFirst(45) {
                f.store.accept(.media(camera: f.camera, name: "Test Camera", sample))
                Thread.sleep(forTimeInterval: 0.002)
            }
            _ = f.store.flush(timeout: 5)
        }
        defer { _ = appended.wait(timeout: .now() + 10) }
        let query = request(f.camera, start: base, end: base + 12)
        for _ in 0..<8 {
            let result = try response(query, provider: f.provider)
            XCTAssertGreaterThan(result.payloads.count, 0)
            XCTAssertEqual(result.payloads, Array(f.samples.prefix(result.payloads.count).map { $0.frame.payload }))
            XCTAssertEqual(result.messages.last?.outcome, "partial")
        }
        XCTAssertEqual(appended.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(f.store.snapshot().recordedFrames, 180)
        XCTAssertEqual(f.store.snapshot().completedShards, 0)
        XCTAssertNil(f.store.snapshot().lastError)
    }
    func testIncompleteFragmentBoundariesAndCancellation() throws {
        func box(_ type: String, _ length: UInt32, payload: Data = Data()) -> Data {
            var size = length.bigEndian
            return withUnsafeBytes(of: &size) { Data($0) } + Data(type.utf8) + payload
        }
        let initialized = box("ftyp", 8) + box("mdat", 12, payload: Data(repeating: 1, count: 4)) + box("moov", 8)
        func prefix(_ data: Data, work: MediaWork = MediaWork()) throws -> Int64 {
            try GrowingMediaFile.completePrefix(size: Int64(data.count), work: work) { offset, count in
                Data(data[Int(offset)..<Int(offset) + count])
            }
        }
        XCTAssertEqual(try prefix(box("ftyp", 8) + box("mdat", 0)), 0)
        XCTAssertEqual(try prefix(initialized + box("mdat", 0) + Data(repeating: 2, count: 100)), Int64(initialized.count))
        XCTAssertEqual(try prefix(initialized + box("mdat", 12, payload: Data(repeating: 1, count: 4)) + box("moof", 20)), Int64(initialized.count))
        let complete = initialized + box("mdat", 8) + box("moof", 8)
        XCTAssertEqual(try prefix(complete + Data([1, 2, 3])), Int64(complete.count))
        XCTAssertEqual(try prefix(complete + box("mdat", 1, payload: Data(repeating: 0xff, count: 8))), Int64(complete.count))
        let cancellation = Cancellation(); cancellation.stop()
        XCTAssertThrowsError(try prefix(complete, work: MediaWork(cancellation: cancellation)))
    }
    func testActivePlaybackDoesNotAdoptReplacementsOrOrphanedFiles() throws {
        let f = try fixture(count: 45, initialCount: 45)
        Thread.sleep(forTimeInterval: 0.1)
        let query = request(f.camera, start: base, end: base + 3)
        let source = try XCTUnwrap(f.provider.catalog(camera: f.camera, range: query.range, timeline: .canonical, work: MediaWork()).first)
        let path = f.folder + "/" + source.row.filename
        let moved = path + ".moved"
        try FileManager.default.moveItem(atPath: path, toPath: moved)
        try SecureFiles.atomicWrite(Data(contentsOf: URL(fileURLWithPath: moved)), to: path, mode: 0o600)
        XCTAssertThrowsError(try response(query, provider: f.provider))
        try FileManager.default.removeItem(atPath: path)
        try FileManager.default.moveItem(atPath: moved, toPath: path)
        XCTAssertFalse(try response(query, provider: f.provider).payloads.isEmpty)
        // Even a valid index + valid MP4 isn't enough without an active writer.
        source.growing?.file.invalidate()
        XCTAssertEqual(try response(query, provider: f.provider).messages.last?.outcome, "unavailable")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(f.store.finish(timeout: 10))
        XCTAssertEqual(try response(query, provider: f.provider).payloads.count, 45)
    }
    func testActivePrefixKeyframesTimelinesAndRelativeLiveRange() throws {
        let f = try fixture(count: 180, initialCount: 180)
        Thread.sleep(forTimeInterval: 0.1)
        for timeline in [MediaTimeline.canonical, .camera, .received] {
            let offset = timeline == .received ? 0.4 : 0
            let result = try response(request(f.camera, start: base + 9.5 + offset, end: base + 10.25 + offset, timeline: timeline), provider: f.provider)
            XCTAssertEqual(result.messages.first { $0.segment != nil }?.segment?.range.start, base + 9 + offset)
            XCTAssertEqual(result.payloads, Array(f.samples[135..<154].map { $0.frame.payload }))
            XCTAssertEqual(result.messages.last?.outcome, "complete")
        }
        let live = try XCTUnwrap(f.samples.last?.time)
        let provider = LocalMediaProvider(configurations: { [f.config] }, live: { _ in live }, ram: nil)
        var query = request(f.camera, start: -5, end: 0); query.relativeTo = "live"
        let result = try response(query, provider: provider)
        XCTAssertEqual(result.messages.first?.anchor, live.canonicalUTC)
        XCTAssertEqual(result.messages.last?.outcome, "partial")
        XCTAssertGreaterThan(result.payloads.count, 0)
        XCTAssertLessThan(try XCTUnwrap(result.messages.first { $0.type == "gap" }?.range?.start), live.canonicalUTC)
        XCTAssertEqual(f.store.snapshot().completedShards, 0)
    }
    func testRequestSpansFinalizedAndStillRecordingShards() throws {
        let f = try fixture(shard: "6s", count: 210, initialCount: 210)
        Thread.sleep(forTimeInterval: 0.1)
        let result = try response(request(f.camera, start: base + 11.5, end: base + 14), provider: f.provider)
        XCTAssertEqual(f.store.snapshot().completedShards, 2)
        XCTAssertEqual(f.store.snapshot().activeRecordings, 1)
        XCTAssertEqual(result.messages.compactMap(\.segment).map(\.range.start), [base + 11, base + 12])
        XCTAssertEqual(result.payloads, Array(f.samples[165..<195].map { $0.frame.payload }))
        XCTAssertEqual(result.messages.last?.outcome, "partial")
    }
    func testNewShardBeforeFirstFragmentIsUnavailableWithoutClosingIt() throws {
        let f = try fixture(count: 1, initialCount: 1)
        let result = try response(request(f.camera, start: base, end: base + 1), provider: f.provider)
        XCTAssertEqual(result.messages.last?.outcome, "unavailable")
        XCTAssertEqual(f.store.snapshot().activeRecordings, 1)
        XCTAssertEqual(f.store.snapshot().completedShards, 0)
    }
    func testRAMServesFirstFrameBeforeAnyReadableDiskFragment() throws {
        let f = try fixture(count: 1, initialCount: 1)
        let query = request(f.camera, start: base, end: base + 0.05)
        XCTAssertEqual(try response(query, provider: f.provider).messages.last?.outcome, "unavailable")
        let result = try response(query, provider: f.ramProvider)
        XCTAssertEqual(result.messages.last?.outcome, "complete")
        XCTAssertEqual(result.payloads, f.samples.map { $0.frame.payload })
        XCTAssertEqual(result.messages.compactMap(\.frame).first?.keyFrame, true)
        XCTAssertEqual(f.store.snapshot().completedShards, 0)
    }
    func testRAMAndGrowingDiskRoundTripBothCodecsWithoutDuplicateFrames() async throws {
        for codec in [kCMVideoCodecType_H264, kCMVideoCodecType_HEVC] {
            let f = try fixture(codec: codec, count: 180, initialCount: 180)
            let query = request(f.camera, start: base, end: base + 12)
            let result = try response(query, provider: f.ramProvider)
            XCTAssertEqual(result.messages.last?.outcome, "complete")
            XCTAssertGreaterThan(f.store.snapshot().playbackRAMBytes ?? 0, 0)
            XCTAssertEqual(result.payloads, f.samples.map { $0.frame.payload })
            XCTAssertEqual(result.messages.compactMap(\.frame).map(\.presentationTicks), f.samples.map { Int64($0.frame.timestamp) })
            let sources = try f.ramProvider.catalog(camera: f.camera, range: query.range, timeline: .canonical, work: MediaWork())
            let memory = try XCTUnwrap(sources.first { $0.memory != nil }?.memory)
            XCTAssertGreaterThan(memory.startTicks, 0) // Readable history retired, not a whole-shard RAM copy.
            XCTAssertEqual(memory.frames.first?.key, true)
            let segment = try XCTUnwrap(result.messages.compactMap(\.segment).first)
            let writer = try MemoryMP4Shard(codec: segment.codec, sets: segment.parameterSets, clock: segment.timescale, timestamp: 0)
            for (frame, data) in zip(result.messages.compactMap(\.frame), result.payloads) {
                try writer.append(.init(payload: data, timestamp: UInt32(frame.presentationTicks), keyFrame: frame.keyFrame))
            }
            let path = f.root + "/ram-response.mp4"
            try SecureFiles.atomicWrite(writer.finish(), to: path, mode: 0o600)
            let asset = AVURLAsset(url: URL(fileURLWithPath: path))
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first), outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(output); XCTAssertTrue(reader.startReading())
            var decoded = 0; while output.copyNextSampleBuffer() != nil { decoded += 1 }
            XCTAssertEqual(reader.status, .completed); XCTAssertEqual(decoded, 180)
            XCTAssertTrue(f.store.finish(timeout: 10))
            XCTAssertEqual(f.store.snapshot().playbackRAMBytes, 0)
            XCTAssertTrue(memory.frames.allSatisfy { $0.sample == nil })
            XCTAssertEqual(try response(query, provider: f.ramProvider).payloads, result.payloads)
        }
    }
    func testOneRequestSpansClosedMP4GrowingMP4AndRAM() throws {
        let f = try fixture(shard: "6s", count: 210, initialCount: 210)
        let query = request(f.camera, start: base + 11.5, end: base + 14)
        let result = try response(query, provider: f.ramProvider)
        XCTAssertEqual(result.messages.last?.outcome, "complete")
        XCTAssertEqual(result.payloads, Array(f.samples[165..<210].map { $0.frame.payload }))
        XCTAssertEqual(result.messages.compactMap(\.segment).map(\.range.start), [base + 11, base + 12, base + 13])
        XCTAssertEqual(f.store.snapshot().completedShards, 2)
        XCTAssertEqual(f.store.snapshot().activeRecordings, 1)
    }
    func testRAMLatestFramesUseAllTimelinesAndLiveAnchor() throws {
        let f = try fixture(count: 10, initialCount: 10)
        for timeline in [MediaTimeline.canonical, .camera, .received] {
            let offset = timeline == .received ? 0.4 : 0
            let result = try response(request(f.camera, start: base + offset, end: base + offset + 0.6, timeline: timeline), provider: f.ramProvider)
            XCTAssertEqual(result.messages.last?.outcome, "complete")
            XCTAssertFalse(result.payloads.isEmpty)
        }
        let live = try XCTUnwrap(f.samples.last?.time)
        let provider = LocalMediaProvider(configurations: { [f.config] }, live: { _ in live })
        var query = request(f.camera, start: -0.4, end: 0); query.relativeTo = "live"
        let result = try response(query, provider: provider)
        XCTAssertEqual(result.messages.first?.anchor, live.canonicalUTC)
        XCTAssertEqual(result.messages.last?.outcome, "complete")
        XCTAssertTrue(result.messages.compactMap(\.frame).contains(where: \.preroll))
    }
    func testPlaybackMemoryPressureDoesNotStopOrLoseRecording() throws {
        let f = try fixture(count: 180, initialCount: 45)
        RecordingRAMCache.shared.memoryPressure(true)
        defer { RecordingRAMCache.shared.memoryPressure(false) }
        for sample in f.samples.dropFirst(45) { f.store.accept(.media(camera: f.camera, name: "Test Camera", sample)) }
        XCTAssertTrue(f.store.flush(timeout: 10))
        let query = request(f.camera, start: base, end: base + 12)
        let sources = try f.ramProvider.catalog(camera: f.camera, range: query.range, timeline: .canonical, work: MediaWork())
        XCTAssertTrue(sources.allSatisfy { $0.memory == nil })
        XCTAssertGreaterThan(try response(query, provider: f.ramProvider).payloads.count, 0)
        XCTAssertTrue(f.store.finish(timeout: 10)); XCTAssertNil(f.store.snapshot().lastError)
        XCTAssertEqual(f.store.snapshot().recordedFrames, 180)
        XCTAssertEqual(try response(query, provider: f.ramProvider).payloads, f.samples.map { $0.frame.payload })
    }
    func testRAMWeakSnapshotsSharedBlocksBoundsPruningAndResume() throws {
        let f = try fixture()
        let row = try XCTUnwrap(f.provider.catalog(camera: f.camera, range: .init(start: base, end: base + 3), timeline: .canonical, work: MediaWork()).first?.row)
        let cache = RecordingRAMCache(limits: .init(totalBytes: 20, tailBytes: 12, tailFrames: 8, tailSeconds: 30), maintenance: false)
        let tail = cache.open(timing: row.timing, codec: "H264", sets: f.samples[0].parameterSets)
        defer { tail.close() }
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: 4,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: 4, flags: 0, blockBufferOut: &block), noErr)
        let buffer = try XCTUnwrap(block)
        tail.append(block: buffer, pts: 0, duration: 6000, key: true)
        let first = try XCTUnwrap(cache.snapshot(row: row))
        XCTAssertTrue(first.frames[0].sample?.block === buffer) // Shared object, no copied payload.
        for index in 1..<8 { tail.append(block: buffer, pts: Int64(index * 6000), duration: 6000, key: index.isMultiple(of: 2)) }
        XCTAssertLessThanOrEqual(cache.retainedBytes, 12)
        XCTAssertNil(first.frames[0].sample) // Merely retaining a request never pins history.
        let before = try XCTUnwrap(cache.snapshot(row: row))
        XCTAssertTrue(before.frames[0].key)
        cache.advanceDisk(shard: row.id, through: 42_000)
        XCTAssertLessThanOrEqual(cache.retainedBytes, 8)
        cache.memoryPressure(true)
        XCTAssertEqual(cache.retainedBytes, 0)
        XCTAssertTrue(before.frames.allSatisfy { $0.sample == nil })
        tail.append(block: buffer, pts: 48_000, duration: 6000, key: true)
        XCTAssertNil(cache.snapshot(row: row))
        cache.memoryPressure(false)
        tail.append(block: buffer, pts: 54_000, duration: 6000, key: false)
        XCTAssertNil(cache.snapshot(row: row))
        tail.append(block: buffer, pts: 60_000, duration: 6000, key: true)
        XCTAssertEqual(cache.snapshot(row: row)?.frames.count, 1)
        tail.append(block: buffer, pts: 66_000, duration: 6000, key: false)
        tail.append(block: buffer, pts: 72_000, duration: 6000, key: false)
        let otherTiming = ShardTimingMetadata(storeID: UUID().uuidString, cameraID: UUID().uuidString,
            media: f.samples[0], time: try XCTUnwrap(f.samples[0].time))
        let other = cache.open(timing: otherTiming, codec: "H264", sets: []); defer { other.close() }
        for i in 0..<3 { other.append(block: buffer, pts: Int64(i * 6000), duration: 6000, key: i == 0) }
        XCTAssertLessThanOrEqual(cache.retainedBytes, 20)
        XCTAssertNil(cache.snapshot(row: row)) // Global quota evicts the oldest GOP first.
        other.close()
        tail.close(); XCTAssertEqual(cache.retainedBytes, 0)
    }
    func testRAMAndFinalizedVariableRateSampleTimesAgree() throws {
        let f = try fixture(count: 5, initialCount: 0)
        var timeline = RecordingTimeline()
        let timestamps: [UInt32] = [0, 6000, 18000, 27000, 39000]
        for (sample, timestamp) in zip(f.samples, timestamps) {
            let seconds = Double(timestamp) / 90000
            var media = EncodedMedia(codec: sample.codec, clockRate: 90000, parameterSets: sample.parameterSets,
                frame: .init(payload: sample.frame.payload, timestamp: timestamp, keyFrame: sample.frame.keyFrame),
                receivedAt: Date(timeIntervalSince1970: base + 0.4 + seconds), receivedUptime: 100 + seconds,
                cameraUTC: base + seconds, ssrc: 42)
            media.time = try timeline.observe(media)
            f.store.accept(.media(camera: f.camera, name: "Test Camera", media))
        }
        XCTAssertTrue(f.store.flush(timeout: 5))
        let query = request(f.camera, start: base, end: base + 0.56)
        let ram = try response(query, provider: f.ramProvider)
        XCTAssertTrue(f.store.finish(timeout: 10))
        let disk = try response(query, provider: f.ramProvider)
        XCTAssertEqual(ram.payloads, disk.payloads)
        XCTAssertEqual(ram.messages.compactMap(\.frame).map(\.presentationTicks), disk.messages.compactMap(\.frame).map(\.presentationTicks))
        XCTAssertEqual(ram.messages.compactMap(\.frame).map(\.durationTicks), disk.messages.compactMap(\.frame).map(\.durationTicks))
    }
    func testRAMSnapshotMovedToDiskReturnsRetryWithoutPinningIt() throws {
        let f = try fixture(count: 45, initialCount: 45)
        let query = request(f.camera, start: base, end: base + 3)
        let sources = try f.ramProvider.catalog(camera: f.camera, range: query.range, timeline: .canonical, work: MediaWork())
        let source = try XCTUnwrap(sources.first { $0.memory != nil })
        XCTAssertTrue(f.store.finish(timeout: 10))
        XCTAssertThrowsError(try LocalMediaReader.read(.init(source: source, range: source.range), number: 0,
            request: query, work: MediaWork(), emit: { _ in }, bytes: { _ in })) {
                XCTAssertEqual(($0 as? ServiceError)?.code, .unavailable)
        }
        XCTAssertEqual(try response(query, provider: f.ramProvider).payloads.count, 45)
    }
    func testRAMRetiresToDiskWithoutAnyPlaybackRequests() throws {
        let f = try fixture(count: 180, initialCount: 180)
        Thread.sleep(forTimeInterval: 0.1)
        RecordingRAMCache.shared.maintain()
        XCTAssertLessThan(f.store.snapshot().playbackRAMBytes ?? Int.max, f.samples.reduce(0) { $0 + $1.frame.payload.count })
        XCTAssertEqual(f.store.snapshot().completedShards, 0)
        XCTAssertEqual(try response(request(f.camera, start: base, end: base + 12), provider: f.ramProvider).payloads.count, 180)
    }
    func testRAMFrameAndAgeBoundsDropUndecodableSuffixUntilNextKey() throws {
        let f = try fixture()
        let row = try XCTUnwrap(f.provider.catalog(camera: f.camera, range: .init(start: base, end: base + 3), timeline: .canonical, work: MediaWork()).first?.row)
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: 4,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: 4, flags: 0, blockBufferOut: &block), noErr)
        let buffer = try XCTUnwrap(block)
        for limits in [RecordingRAMCache.Limits(totalBytes: 100, tailBytes: 100, tailFrames: 2, tailSeconds: 30),
                       .init(totalBytes: 100, tailBytes: 100, tailFrames: 100, tailSeconds: 0.1)] {
            let cache = RecordingRAMCache(limits: limits, maintenance: false)
            let tail = cache.open(timing: row.timing, codec: "H264", sets: []); defer { tail.close() }
            for i in 0..<3 { tail.append(block: buffer, pts: Int64(i * 6000), duration: 6000, key: i == 0) }
            XCTAssertNil(cache.snapshot(row: row)); XCTAssertEqual(cache.retainedBytes, 0)
            tail.append(block: buffer, pts: 18000, duration: 6000, key: false)
            XCTAssertNil(cache.snapshot(row: row))
            tail.append(block: buffer, pts: 24000, duration: 6000, key: true)
            XCTAssertEqual(cache.snapshot(row: row)?.frames.count, 1)
        }
    }
    func request(_ camera: String, start: Double, end: Double, operation: String = "frames", timeline: MediaTimeline = .canonical) -> MediaRequest {
        MediaRequest(requestID: UUID().uuidString, operation: operation, cameraID: camera, timeline: timeline, range: .init(start: start, end: end))
    }
    func response(_ request: MediaRequest, provider: LocalMediaProvider) throws -> (messages: [MediaMessage], payloads: [Data]) {
        var messages: [MediaMessage] = [], payloads: [Data] = []
        try MediaResponse.run(request, provider: provider, work: MediaWork(), emit: {
            messages.append($0); if $0.frame != nil { payloads.append(Data()) }
        }, bytes: { payloads[payloads.count - 1].append($0) })
        return (messages, payloads)
    }
    func testRangeValidationDefaultsAndStableRelativeAnchors() throws {
        let camera = UUID().uuidString
        let decoded = try JSONDecoder().decode(MediaRequest.self, from: Data("{\"requestID\":\"a\",\"operation\":\"frames\",\"cameraID\":\"\(camera)\",\"range\":{\"start\":1,\"end\":2}}".utf8))
        XCTAssertEqual(decoded.timeline, .canonical)
        let time = RecordingTime(cameraUTC: 100, receivedUTC: 101, canonicalUTC: 100, canonicalSource: .camera, epochID: UUID().uuidString)
        var relative = request(camera, start: -45, end: -15); relative.relativeTo = "live"
        XCTAssertEqual(try relative.resolve(now: 999, live: time).range, .init(start: 55, end: 85))
        relative.timeline = .received
        XCTAssertEqual(try relative.resolve(now: 999, live: time).anchor, 101)
        XCTAssertThrowsError(try relative.resolve(now: 999, live: nil))
        relative.relativeTo = "now"
        XCTAssertEqual(try relative.resolve(now: 200, live: nil).range, .init(start: 155, end: 185))
        for interval in [MediaRange(start: 1, end: 1), .init(start: .nan, end: 5), .init(start: 0, end: 86401)] {
            XCTAssertThrowsError(try request(camera, start: interval.start, end: interval.end).resolve(now: 0, live: nil))
        }
        XCTAssertThrowsError(try request("../file", start: 0, end: 1).resolve(now: 0, live: nil))
        relative.relativeTo = "unknown"; XCTAssertThrowsError(try relative.resolve(now: 0, live: time))
    }
    func testPassthroughBothCodecsNearestKeyframeAndExactPayloads() async throws {
        for codec in [kCMVideoCodecType_H264, kCMVideoCodecType_HEVC] {
            let f = try fixture(codec: codec)
            let manifest = f.folder + "/" + LocalRecordingManifest.filename
            let before = try Data(contentsOf: URL(fileURLWithPath: manifest))
            let result = try response(request(f.camera, start: base + 1.5, end: base + 2.25), provider: f.provider)
            let segment = try XCTUnwrap(result.messages.compactMap(\.segment).first)
            let frames = result.messages.compactMap(\.frame)
            XCTAssertEqual(segment.range.start, base + 1)
            XCTAssertEqual(frames.first?.presentationTicks, 90000)
            XCTAssertEqual(frames.first?.keyFrame, true)
            XCTAssertEqual(frames.filter(\.preroll).count, 8)
            XCTAssertEqual(result.messages.last?.outcome, "complete")
            XCTAssertFalse(result.messages.contains { $0.type == "gap" })
            XCTAssertEqual(result.payloads, Array(f.samples[15..<34].map { $0.frame.payload }))
            XCTAssertEqual(frames.map(\.byteCount), result.payloads.map(\.count))
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: manifest)), before)
            let json = String(decoding: try JSONEncoder().encode(result.messages), as: UTF8.self)
            XCTAssertFalse(json.contains(f.root)); XCTAssertFalse(json.contains(".mp4"))
            // Repackage exactly the received encoded bytes, then decode the whole
            // response to prove the selected preroll and codec header are usable.
            let writer = try MemoryMP4Shard(codec: segment.codec, sets: segment.parameterSets,
                clock: segment.timescale, timestamp: UInt32(frames[0].presentationTicks))
            for (frame, bytes) in zip(frames, result.payloads) {
                try writer.append(.init(payload: bytes, timestamp: UInt32(frame.presentationTicks), keyFrame: frame.keyFrame))
            }
            let url = URL(fileURLWithPath: f.root + "/response.mp4")
            try SecureFiles.atomicWrite(writer.finish(), to: url.path, mode: 0o600)
            let asset = AVURLAsset(url: url), tracks = try await asset.loadTracks(withMediaType: .video)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first), outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(output); XCTAssertTrue(reader.startReading())
            var count = 0; while output.copyNextSampleBuffer() != nil { count += 1 }
            XCTAssertEqual(reader.status, .completed); XCTAssertEqual(count, frames.count)
        }
    }
    func testAllTimelinesAvailabilityGapsAndMissingCameraTime() throws {
        let f = try fixture(shard: "1s")
        for timeline in [MediaTimeline.canonical, .camera, .received] {
            let start = base + (timeline == .received ? 0.4 : 0)
            let result = try response(request(f.camera, start: start - 1, end: start + 4, operation: "availability", timeline: timeline), provider: f.provider)
            XCTAssertEqual(result.messages.filter { $0.type == "available" }.compactMap(\.range), [.init(start: start, end: start + 3)])
            XCTAssertEqual(result.messages.filter { $0.type == "gap" }.compactMap(\.range), [.init(start: start - 1, end: start), .init(start: start + 3, end: start + 4)])
            XCTAssertEqual(result.messages.last?.outcome, "partial")
        }
        let absent = try fixture(cameraClock: false)
        let result = try response(request(absent.camera, start: base, end: base + 5, timeline: .camera), provider: absent.provider)
        XCTAssertEqual(result.messages.last?.outcome, "unavailable"); XCTAssertTrue(result.payloads.isEmpty)
        // Disabled stores remain readable; disabled recording is not deletion.
        var disabled = f.config; disabled.enabled = false
        XCTAssertEqual(try response(request(f.camera, start: base, end: base + 1), provider: LocalMediaProvider(configurations: { [disabled] })).messages.last?.outcome, "complete")
    }
    func testKeyframeFallbackAfterGapAndCrossShardReads() throws {
        let f = try fixture(shard: "1s")
        let files = try FileManager.default.contentsOfDirectory(atPath: f.folder).filter { $0.hasSuffix(".mp4") }.sorted()
        try FileManager.default.removeItem(atPath: f.folder + "/" + files[0])
        let result = try response(request(f.camera, start: base + 0.5, end: base + 2.5), provider: f.provider)
        XCTAssertEqual(result.messages.compactMap(\.segment).first?.range.start, base + 1)
        XCTAssertEqual(result.messages.compactMap(\.segment).count, 2)
        XCTAssertEqual(result.messages.filter { $0.type == "gap" }.compactMap(\.range), [.init(start: base + 0.5, end: base + 1)])
        XCTAssertEqual(result.messages.last?.outcome, "partial")
    }
    func testReadFailsClosedOnReplacedFileAndMissingManifestNeverBackfills() throws {
        let f = try fixture(), query = request(f.camera, start: base, end: base + 3)
        let sources = try f.provider.catalog(camera: f.camera, range: query.range, timeline: .canonical, work: MediaWork())
        let source = try XCTUnwrap(sources.first)
        let file = f.folder + "/" + source.row.filename
        let data = try Data(contentsOf: URL(fileURLWithPath: file))
        try SecureFiles.atomicWrite(data, to: file, mode: 0o600)
        XCTAssertThrowsError(try LocalMediaReader.read(.init(source: source, range: query.range), number: 0, request: query, work: MediaWork(), emit: { _ in }, bytes: { _ in }))
        XCTAssertEqual(try response(query, provider: f.provider).messages.last?.outcome, "unavailable")
        try FileManager.default.removeItem(atPath: f.folder + "/" + LocalRecordingManifest.filename)
        XCTAssertEqual(try response(query, provider: f.provider).messages.last?.outcome, "unavailable")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.folder + "/" + LocalRecordingManifest.filename))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file))
    }
    func testPlanningDeduplicatesStoresButRetainsOverlappingEpochs() throws {
        let f = try fixture(), range = MediaRange(start: base, end: base + 3)
        let sources = try f.provider.catalog(camera: f.camera, range: range, timeline: .canonical, work: MediaWork())
        XCTAssertEqual(try LocalMediaProvider.plan(sources + sources, range: range).count, 1)
        // Distinct camera timing epochs at the same wall time are not duplicates.
        let other = try fixture()
        let otherSources = try other.provider.catalog(camera: other.camera, range: range, timeline: .canonical, work: MediaWork())
        XCTAssertEqual(try LocalMediaProvider.plan(sources + otherSources, range: range).count, 2)
    }
    func testCancellationAndDeadlineAbortBeforeReading() throws {
        let f = try fixture(), query = request(f.camera, start: base, end: base + 1)
        let work = MediaWork(); work.cancellation.stop()
        XCTAssertThrowsError(try MediaResponse.run(query, provider: f.provider, work: work, emit: { _ in XCTFail() }, bytes: { _ in XCTFail() }))
        XCTAssertThrowsError(try MediaResponse.run(query, provider: f.provider, work: MediaWork(deadline: 0), emit: { _ in XCTFail() }, bytes: { _ in XCTFail() }))
    }
    func pair() throws -> [Int32] {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw ServiceError.posix("Test socket pair") }
        try fds.forEach { try SocketIO.configure($0) }; return fds
    }
    func testWireHandlesFragmentationCoalescingAndOversizedRecords() throws {
        let fds = try pair(); defer { fds.forEach { close($0) } }
        let wire = Data([1, 0, 0, 0, 2, 123, 125, 1, 0, 0, 0, 2, 123, 125])
        let done = expectation(description: "fragmented writer")
        DispatchQueue.global().async {
            for byte in wire { var b = byte; _ = send(fds[0], &b, 1, 0) }
            done.fulfill()
        }
        XCTAssertEqual(try MediaWire.read(fd: fds[1], cancellation: Cancellation()), Data("{}".utf8))
        XCTAssertEqual(try MediaWire.read(fd: fds[1], cancellation: Cancellation()), Data("{}".utf8))
        wait(for: [done], timeout: 2)
        _ = Data([1, 0, 1, 0, 1]).withUnsafeBytes { send(fds[0], $0.baseAddress, $0.count, 0) }
        XCTAssertThrowsError(try MediaWire.read(fd: fds[1], cancellation: Cancellation()))
        XCTAssertThrowsError(try MediaWire.write(Data(count: MediaLimits.messageBytes + 1), type: 2, fd: fds[0], work: MediaWork()))
    }
    func testSessionAuthorizationAndVersionAreRequired() throws {
        let fds = try pair(); defer { fds.forEach { close($0) } }
        let provider = LocalMediaProvider(configurations: { XCTFail("Authorization must precede reads"); return [] })
        let sessions = MediaSessions(provider: provider, authorize: { _ in false })
        XCTAssertThrowsError(try sessions.open(fds[0], uid: geteuid(), version: 1, deadline: ProcessInfo.processInfo.systemUptime + 1)) {
            XCTAssertEqual(($0 as? ServiceError)?.code, .permission)
        }
        let allowed = MediaSessions(provider: provider, authorize: { _ in true })
        XCTAssertThrowsError(try allowed.open(fds[0], uid: geteuid(), version: 99, deadline: ProcessInfo.processInfo.systemUptime + 1)) {
            XCTAssertEqual(($0 as? ServiceError)?.code, .incompatible)
        }
    }
    func testKeepaliveIsAuthenticatedAndDoesNotReadRecordings() throws {
        let fds = try pair(), gate = Gate()
        let provider = LocalMediaProvider(configurations: { XCTFail("Keepalive must not inspect stores"); return [] })
        let sessions = MediaSessions(provider: provider, authorize: { _ in gate.check() })
        defer { sessions.stop(); close(fds[1]) }
        try sessions.open(fds[0], uid: geteuid(), version: 1, deadline: ProcessInfo.processInfo.systemUptime + 2)
        let ready = try JSONDecoder().decode(Reply.self, from: SocketIO.read(fd: fds[1], deadline: ProcessInfo.processInfo.systemUptime + 2))
        XCTAssertEqual(ready.mediaSession?.supportsKeepalive, true)
        let heartbeat = MediaKeepalive(requestID: "warm", operation: "keepalive")
        for _ in 0..<2 {
            try MediaWire.write(JSONEncoder().encode(heartbeat), type: 1, fd: fds[1], work: MediaWork())
            let reply = try JSONDecoder().decode(MediaMessage.self, from: MediaWire.read(fd: fds[1], cancellation: Cancellation()))
            XCTAssertEqual(reply.type, "alive"); XCTAssertEqual(reply.requestID, "warm")
        }
        XCTAssertThrowsError(try MediaKeepalive(requestID: "", operation: "keepalive").validate())
        gate.revoke()
        try MediaWire.write(JSONEncoder().encode(heartbeat), type: 1, fd: fds[1], work: MediaWork())
        let denied = try JSONDecoder().decode(MediaMessage.self, from: MediaWire.read(fd: fds[1], cancellation: Cancellation()))
        XCTAssertEqual(denied.code, .permission)
    }
    func testPrivateConfigurationErrorsDoNotEscapeTheProvider() throws {
        let provider = LocalMediaProvider(configurations: { throw ServiceError(.invalidMessage, "private-credential-file.json") })
        XCTAssertThrowsError(try provider.catalog(camera: UUID().uuidString, range: .init(start: 100, end: 110), timeline: .canonical, work: MediaWork())) {
            XCTAssertEqual(($0 as? ServiceError)?.code, .unavailable)
            XCTAssertFalse(String(describing: $0).contains("private-credential-file"))
        }
    }
    func testActualSessionTransfersFramesThenAcceptsAnotherRequest() throws {
        try verifySocketFrames(initialCount: nil)
    }
    func testActualSessionTransfersActiveFramesThenAcceptsAnotherRequest() throws {
        try verifySocketFrames(initialCount: 180)
    }
    func testActualSessionTransfersRAMFramesThenAcceptsAnotherRequest() throws {
        try verifySocketFrames(initialCount: 45, ram: true)
    }
    private func verifySocketFrames(initialCount: Int?, ram: Bool = false) throws {
        let f = try fixture(count: initialCount ?? 45, largeFrames: true, initialCount: initialCount), fds = try pair()
        if initialCount != nil { Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertGreaterThan(f.samples[0].frame.payload.count, 2 * MediaLimits.messageBytes)
        let sessions = MediaSessions(provider: ram ? f.ramProvider : f.provider, authorize: { $0 == geteuid() })
        defer { sessions.stop(); close(fds[1]) }
        try sessions.open(fds[0], uid: geteuid(), version: 1, deadline: ProcessInfo.processInfo.systemUptime + 2)
        let ready = try JSONDecoder().decode(Reply.self, from: SocketIO.read(fd: fds[1], deadline: ProcessInfo.processInfo.systemUptime + 2))
        XCTAssertEqual(ready.mediaSession?.version, 1)
        XCTAssertEqual(ready.mediaSession?.includesActiveDiskFragments, true)
        XCTAssertEqual(ready.mediaSession?.includesResidentLocalFrames, true)
        for operation in ["frames", "availability"] {
            let query = request(f.camera, start: base + 1.5, end: base + 2.25, operation: operation)
            try MediaWire.write(JSONEncoder().encode(query), type: 1, fd: fds[1], work: MediaWork())
            var payloads: [Data] = [], remaining = 0
            while true {
                let deadline = ProcessInfo.processInfo.systemUptime + 5
                let header = try MediaWire.readExactly(5, fd: fds[1], deadline: deadline, cancellation: Cancellation())
                let count = header.dropFirst().reduce(0) { ($0 << 8) | Int($1) }
                XCTAssertGreaterThan(count, 0); XCTAssertLessThanOrEqual(count, MediaLimits.messageBytes)
                let payload = try MediaWire.readExactly(count, fd: fds[1], deadline: deadline, cancellation: Cancellation())
                if header[0] == MediaWire.bytes {
                    XCTAssertGreaterThan(remaining, 0); XCTAssertLessThanOrEqual(count, remaining)
                    payloads[payloads.count - 1].append(payload); remaining -= count
                } else {
                    XCTAssertEqual(remaining, 0)
                    let message = try JSONDecoder().decode(MediaMessage.self, from: payload)
                    XCTAssertEqual(message.requestID, query.requestID)
                    if let frame = message.frame { remaining = frame.byteCount; payloads.append(Data()) }
                    if message.type == "end" { XCTAssertEqual(message.outcome, "complete"); break }
                }
            }
            XCTAssertEqual(payloads, operation == "frames" ? Array(f.samples[15..<34].map { $0.frame.payload }) : [])
        }
    }
    func testPeerClosureAndBackpressureAreBounded() throws {
        let fds = try pair(); defer { close(fds[0]) }
        var size: Int32 = 1024
        XCTAssertEqual(setsockopt(fds[0], SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout.size(ofValue: size))), 0)
        let started = ProcessInfo.processInfo.systemUptime
        let work = MediaWork(deadline: started + 0.1, peer: fds[0])
        XCTAssertThrowsError(try MediaWire.write(Data(count: MediaLimits.messageBytes), type: 2, fd: fds[0], work: work)) {
            XCTAssertEqual(($0 as? ServiceError)?.code, .timeout)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1)
        close(fds[1])
        XCTAssertThrowsError(try MediaWork(peer: fds[0]).check())
    }
    private final class Gate {
        private let lock = NSLock()
        private var allowed = true
        func check() -> Bool { lock.lock(); defer { lock.unlock() }; return allowed }
        func revoke() { lock.lock(); allowed = false; lock.unlock() }
    }
    func testSessionRevalidatesAuthorizationBeforeEveryRequest() throws {
        let fds = try pair(), gate = Gate()
        let provider = LocalMediaProvider(configurations: { XCTFail("Revoked access must not enumerate stores"); return [] })
        let sessions = MediaSessions(provider: provider, authorize: { _ in gate.check() })
        defer { sessions.stop(); close(fds[1]) }
        try sessions.open(fds[0], uid: geteuid(), version: 1, deadline: ProcessInfo.processInfo.systemUptime + 2)
        _ = try SocketIO.read(fd: fds[1], deadline: ProcessInfo.processInfo.systemUptime + 2)
        gate.revoke()
        try MediaWire.write(JSONEncoder().encode(request(UUID().uuidString, start: 100, end: 110)), type: 1, fd: fds[1], work: MediaWork())
        let payload = try MediaWire.read(fd: fds[1], cancellation: Cancellation())
        let reply = try JSONDecoder().decode(MediaMessage.self, from: payload)
        XCTAssertEqual(reply.code, .permission); XCTAssertEqual(reply.outcome, "error")
        XCTAssertThrowsError(try MediaWire.read(fd: fds[1], cancellation: Cancellation(), idleSeconds: 1))
    }
}
