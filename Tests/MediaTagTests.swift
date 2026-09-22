import XCTest
import Foundation
import Darwin
import AVFoundation
import SQLite3

final class MediaTagTests: XCTestCase {
    typealias Span = MediaTagRanges.Span
    final class Capture {
        var messages: [MediaMessage] = [], payloads: [Data] = []
        var maps: [Int: MediaTagRanges.Map] = [:]
        var segment: Int?, remaining = 0, data = Data()
        func emit(_ message: MediaMessage) throws {
            XCTAssertEqual(remaining, 0)
            XCTAssertLessThanOrEqual(try JSONEncoder().encode(message).count, MediaLimits.messageBytes)
            messages.append(message)
            if let value = message.segment, let count = value.tagByteCount {
                XCTAssertEqual(value.tagRangesVersion, 1)
                XCTAssertGreaterThan(count, 0)
                segment = value.number; remaining = count; data = Data()
            } else if let frame = message.frame {
                // Tag maps must have been fully delivered before the first frame.
                if messages.contains(where: { $0.segment?.number == frame.segment && $0.segment?.tagByteCount != nil }) {
                    XCTAssertNotNil(maps[frame.segment])
                }
                segment = nil; remaining = frame.byteCount; payloads.append(Data())
            }
        }
        func bytes(_ bytes: Data) throws {
            XCTAssertLessThanOrEqual(bytes.count, MediaLimits.messageBytes)
            XCTAssertLessThanOrEqual(bytes.count, remaining)
            remaining -= bytes.count
            if let segment {
                data.append(bytes)
                if remaining == 0 { maps[segment] = try JSONDecoder().decode(MediaTagRanges.Map.self, from: data) }
            } else { payloads[payloads.count - 1].append(bytes) }
        }
        func verify(_ expected: [[String: String]]) throws {
            XCTAssertEqual(remaining, 0)
            let frames = messages.compactMap(\.frame)
            XCTAssertEqual(frames.count, expected.count)
            var ordinals: [Int: Int] = [:]
            for (frame, values) in zip(frames, expected) {
                let ordinal = ordinals[frame.segment, default: 0]
                let map = try XCTUnwrap(maps[frame.segment])
                var actual: [String: String] = [:]
                for (key, spans) in map {
                    let matching = spans.filter { $0.startFrame <= ordinal && ordinal < $0.endFrame }
                    XCTAssertLessThanOrEqual(matching.count, 1)
                    actual[key] = matching.first?.value
                }
                XCTAssertEqual(actual, values, "segment \(frame.segment), frame \(ordinal)")
                ordinals[frame.segment] = ordinal + 1
            }
            for segment in messages.compactMap(\.segment) {
                XCTAssertEqual(segment.tagFrameCount, ordinals[segment.number])
                for spans in maps[segment.number]?.values ?? Dictionary<String, [Span]>().values {
                    for span in spans {
                        XCTAssertGreaterThanOrEqual(span.startFrame, 0)
                        XCTAssertGreaterThan(span.endFrame, span.startFrame)
                        XCTAssertLessThanOrEqual(span.endFrame, segment.tagFrameCount!)
                    }
                    for pair in zip(spans, spans.dropFirst()) {
                        XCTAssertLessThanOrEqual(pair.0.endFrame, pair.1.startFrame)
                        XCTAssertFalse(pair.0.endFrame == pair.1.startFrame && pair.0.value == pair.1.value)
                    }
                }
            }
        }
    }
    func capture(_ request: MediaRequest, provider: LocalMediaProvider) throws -> Capture {
        let result = Capture()
        try MediaResponse.run(request, provider: provider, work: MediaWork(), emit: result.emit, bytes: result.bytes)
        return result
    }
    func query(_ camera: String, _ start: Double, _ end: Double, timeline: MediaTimeline = .canonical) -> MediaRequest {
        .init(requestID: UUID().uuidString, operation: "frames", cameraID: camera, timeline: timeline,
              range: .init(start: start, end: end), includeTags: true)
    }
    static func values(_ i: Int) -> [String: String] {
        var tags = ["constant": "yes"]
        if i % 11 < 5 { tags["person"] = "alice" }
        if i % 7 == 0 { tags["empty"] = "" }
        return tags
    }
    func testProjectionCoalescesPerKeyResolvesOverridesAndOmitsUnknownAndAbsent() throws {
        var timeline = VideoTagTimeline(changes: [
            .init(ticks: 0, frame: 0, tags: ["a": "yes"]),
            .init(ticks: 100, frame: 10, tags: ["a": "yes", "b": "other"]),
            .init(ticks: 200, frame: 20, tags: ["a": "yes"])
        ], unknownFromTicks: 300, unknownFromFrame: 30)
        try timeline.apply(.init(start: 50, end: 90, key: "a", value: "yes"))
        try timeline.apply(.init(start: 90, end: 160, key: "a", value: "yes"))
        try timeline.apply(.init(start: 120, end: 180, key: "b", value: nil))
        try timeline.apply(.init(start: 310, end: 350, key: "a", value: ""))
        let points = (0..<40).map { MediaTagRanges.Point(ticks: Int64($0 * 10), frame: Int64($0)) }
        let map = try MediaTagRanges.build(timeline, points: points, work: MediaWork())
        XCTAssertEqual(map["a"], [Span(startFrame: 0, endFrame: 30, value: "yes"), Span(startFrame: 31, endFrame: 35, value: "")])
        XCTAssertEqual(map["b"], [Span(startFrame: 10, endFrame: 12, value: "other"), Span(startFrame: 18, endFrame: 20, value: "other")])
        XCTAssertEqual(try MediaTagRanges.build(nil, points: points, work: MediaWork()), [:])
        XCTAssertEqual(try MediaTagRanges.build(.unknown, points: points, work: MediaWork()), [:])
        XCTAssertEqual(try MediaTagRanges.build(VideoTagTimeline(changes: [.init(ticks: 0, frame: 0, tags: [:])]), points: points, work: MediaWork()), [:])
        let cancellation = Cancellation(); cancellation.stop()
        XCTAssertThrowsError(try MediaTagRanges.build(timeline, points: points, work: MediaWork(cancellation: cancellation)))
    }
    func testFinalizedBothCodecsPrerollAndAllTimeBasesUseSegmentRelativeFrames() throws {
        let helper = MediaTests()
        for codec in [kCMVideoCodecType_H264, kCMVideoCodecType_HEVC] {
            let f = try helper.fixture(codec: codec, tags: Self.values)
            defer { try? FileManager.default.removeItem(atPath: f.root) }
            for timeline in [MediaTimeline.canonical, .camera, .received] {
                let offset = timeline == .received ? 0.4 : 0.0
                let result = try capture(query(f.camera, helper.base + offset + 1.5, helper.base + offset + 2.25, timeline: timeline), provider: f.provider)
                XCTAssertEqual(result.payloads, f.samples[15..<34].map { $0.frame.payload })
                XCTAssertEqual(result.messages.compactMap(\.frame).filter(\.preroll).count, 8)
                try result.verify((15..<34).map(Self.values))
            }
        }
    }
    func testProspectiveFrameBoundariesSurviveMP4ClockRounding() throws {
        let helper = MediaTests(), f = try helper.fixture(timestampSkewPerFrame: 3, tags: Self.values)
        defer { try? FileManager.default.removeItem(atPath: f.root) }
        let result = try capture(query(f.camera, helper.base, helper.base + 4), provider: f.provider)
        XCTAssertEqual(result.payloads, f.samples.map { $0.frame.payload })
        try result.verify((0..<45).map(Self.values))
    }
    func testRAMBeforeCheckpointAndFrozenSnapshotDoesNotAcquireLaterTags() throws {
        let helper = MediaTests(), f = try helper.fixture(count: 12, initialCount: 9, tags: Self.values)
        defer { _ = f.store.finish(timeout: 10); try? FileManager.default.removeItem(atPath: f.root) }
        let request = query(f.camera, helper.base, helper.base + 2)
        let sources = try f.ramProvider.catalog(camera: f.camera, range: request.range, timeline: .canonical, work: MediaWork(), includeTags: true)
        let memory = try XCTUnwrap(sources.first(where: { $0.memory != nil }))
        XCTAssertEqual(memory.row.endTicks, 0) // No SQLite progress checkpoint.
        let before = Capture()
        for piece in try LocalMediaProvider.plan([memory], range: request.range) {
            _ = try LocalMediaReader.read(piece, number: 0, request: request, work: MediaWork(), emit: before.emit, bytes: before.bytes)
        }
        try before.verify((0..<9).map(Self.values))
        for sample in f.samples.dropFirst(9) { f.store.accept(.media(camera: f.camera, name: "Test Camera", sample)) }
        XCTAssertTrue(f.store.flush(timeout: 10))
        let frozen = Capture()
        for piece in try LocalMediaProvider.plan([memory], range: request.range) {
            _ = try LocalMediaReader.read(piece, number: 0, request: request, work: MediaWork(), emit: frozen.emit, bytes: frozen.bytes)
        }
        XCTAssertEqual(frozen.maps, before.maps)
        XCTAssertEqual(frozen.payloads, before.payloads)
        let fresh = try capture(request, provider: f.ramProvider)
        try fresh.verify((0..<12).map(Self.values))
        XCTAssertTrue(f.store.finish(timeout: 10))
        XCTAssertTrue(memory.memory!.frames.allSatisfy { $0.sample == nil })
        let finalized = try capture(request, provider: f.provider)
        XCTAssertEqual(finalized.maps, fresh.maps)
        XCTAssertEqual(finalized.payloads, fresh.payloads)
    }
    func testActiveDiskTagsSurviveRAMPressureWithoutWaitingForSQLite() throws {
        let helper = MediaTests(), f = try helper.fixture(count: 180, initialCount: 180, tags: Self.values)
        defer { _ = f.store.finish(timeout: 10); try? FileManager.default.removeItem(atPath: f.root) }
        RecordingRAMCache.shared.memoryPressure(true)
        defer { RecordingRAMCache.shared.memoryPressure(false) }
        let request = query(f.camera, helper.base, helper.base + 12)
        var result = try capture(request, provider: f.provider)
        let deadline = Date().addingTimeInterval(3)
        while result.payloads.isEmpty, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02); result = try capture(request, provider: f.provider)
        }
        XCTAssertGreaterThan(result.payloads.count, 0)
        XCTAssertLessThan(result.payloads.count, 180)
        let row = try XCTUnwrap(f.provider.catalog(camera: f.camera, range: request.range, timeline: .canonical, work: MediaWork()).first?.row)
        XCTAssertEqual(row.endTicks, 0)
        XCTAssertEqual(f.store.snapshot().playbackRAMBytes, 0)
        try result.verify((0..<result.payloads.count).map(Self.values))
        XCTAssertEqual(result.payloads, f.samples.prefix(result.payloads.count).map { $0.frame.payload })
    }
    func testOneRequestSpansFinalizedGrowingAndRAMWithIdenticalTagInterpretation() throws {
        let helper = MediaTests(), f = try helper.fixture(shard: "3s", count: 210, initialCount: 210, tags: Self.values)
        defer { _ = f.store.finish(timeout: 10); try? FileManager.default.removeItem(atPath: f.root) }
        let result = try capture(query(f.camera, helper.base + 11.5, helper.base + 14), provider: f.ramProvider)
        XCTAssertEqual(result.messages.compactMap(\.segment).count, 3)
        XCTAssertEqual(result.payloads, f.samples[165..<210].map { $0.frame.payload })
        try result.verify((165..<210).map(Self.values))
    }
    func testRetroactiveEditDuringServingKeepsOldSnapshotThenNewRequestSeesNewTags() throws {
        let helper = MediaTests(), f = try helper.fixture(tags: { _ in ["test": "old"] })
        defer { try? FileManager.default.removeItem(atPath: f.root) }
        let request = query(f.camera, helper.base, helper.base + 3)
        let source = try XCTUnwrap(f.provider.catalog(camera: f.camera, range: request.range, timeline: .canonical, work: MediaWork()).first)
        let identity = LocalRecordingLayout.Identity(storeID: f.config.id, cameraID: f.camera)
        let db = try LocalRecordingManifest(directory: source.directory, identity: identity, owner: geteuid(), recoverInterrupted: false)
        let original = try XCTUnwrap(db.historicalTags(id: source.row.id))
        var replacement = original
        try replacement.apply(.init(start: 0, end: source.row.endTicks, key: "test", value: nil))
        try replacement.apply(.init(start: 60000, end: 120000, key: "new", value: "value"))
        let staged = try LocalTagFile.stage(source: source, tags: replacement, jobID: UUID().uuidString, work: MediaWork())
        let first = Capture()
        var edited = false
        try MediaResponse.run(request, provider: f.provider, work: MediaWork(), emit: { message in
            try first.emit(message)
            if message.segment != nil, !edited {
                try db.commitTagEdits([staged], revisions: [source.row.id: HistoricalTags.revision(original)])
                edited = true
            }
        }, bytes: first.bytes)
        XCTAssertTrue(edited)
        try first.verify(Array(repeating: ["test": "old"], count: 45))
        XCTAssertThrowsError(try db.playbackTags(matching: source.row))
        let second = try capture(request, provider: f.provider)
        try second.verify((0..<45).map { (10..<20).contains($0) ? ["new": "value"] : [:] })
        XCTAssertEqual(first.payloads, second.payloads)
    }
    func testActualSocketDeliversLargeTagMapInChunksAndThenLegacyRequest() throws {
        let helper = MediaTests()
        let f = try helper.fixture(tags: { ["long": String(repeating: "x", count: 1800) + String($0)] })
        defer { try? FileManager.default.removeItem(atPath: f.root) }
        var sockets: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        let sessions = MediaSessions(provider: f.provider, authorize: { $0 == geteuid() })
        defer { sessions.stop(); close(sockets[1]) }
        try sessions.open(sockets[0], uid: geteuid(), version: 1, deadline: ProcessInfo.processInfo.systemUptime + 2)
        let reply = try JSONDecoder().decode(Reply.self, from: SocketIO.read(fd: sockets[1], deadline: ProcessInfo.processInfo.systemUptime + 2))
        XCTAssertEqual(reply.mediaSession?.segmentTagsVersion, 1)
        for tagged in [true, false] {
            var request = query(f.camera, helper.base, helper.base + 3); request.includeTags = tagged
            try MediaWire.write(JSONEncoder().encode(request), type: MediaWire.json, fd: sockets[1], work: MediaWork())
            let result = Capture()
            while true {
                let deadline = ProcessInfo.processInfo.systemUptime + 5
                let header = try MediaWire.readExactly(5, fd: sockets[1], deadline: deadline, cancellation: Cancellation())
                let count = header.dropFirst().reduce(0) { $0 << 8 | Int($1) }
                XCTAssertLessThanOrEqual(count, MediaLimits.messageBytes)
                let payload = try MediaWire.readExactly(count, fd: sockets[1], deadline: deadline, cancellation: Cancellation())
                if header[0] == MediaWire.bytes { try result.bytes(payload) }
                else {
                    let message = try JSONDecoder().decode(MediaMessage.self, from: payload)
                    try result.emit(message)
                    if message.type == "end" { XCTAssertEqual(message.outcome, "complete"); break }
                }
            }
            XCTAssertEqual(result.payloads, f.samples.map { $0.frame.payload })
            if tagged {
                XCTAssertGreaterThan(try XCTUnwrap(result.messages.compactMap(\.segment).first?.tagByteCount), MediaLimits.messageBytes)
                try result.verify(f.samples.map(\.tags))
            } else {
                XCTAssertTrue(result.maps.isEmpty)
                XCTAssertTrue(result.messages.compactMap(\.segment).allSatisfy { $0.tagByteCount == nil && $0.tagFrameCount == nil })
            }
        }
    }
    func testMissingManifestTagsAreEmptyRatherThanFallingBackToEmbeddedValues() throws {
        let helper = MediaTests(), f = try helper.fixture(tags: { _ in ["embedded": "old"] })
        defer { try? FileManager.default.removeItem(atPath: f.root) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open((f.folder + "/" + LocalRecordingManifest.filename), &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "UPDATE recordings SET tags_json=NULL", nil, nil, nil), SQLITE_OK)
        let result = try capture(query(f.camera, helper.base, helper.base + 3), provider: f.provider)
        try result.verify(Array(repeating: [:], count: 45))
        XCTAssertEqual(result.messages.compactMap(\.segment).first?.tagByteCount, 2)
    }
    func testActiveDiskSnapshotDoesNotGrowAfterNewFramesArrive() throws {
        let helper = MediaTests(), f = try helper.fixture(count: 180, initialCount: 45, tags: Self.values)
        defer { _ = f.store.finish(timeout: 10); try? FileManager.default.removeItem(atPath: f.root) }
        let request = query(f.camera, helper.base, helper.base + 12)
        var sources = try f.provider.catalog(camera: f.camera, range: request.range, timeline: .canonical, work: MediaWork(), includeTags: true)
        let deadline = Date().addingTimeInterval(3)
        while sources.isEmpty, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
            sources = try f.provider.catalog(camera: f.camera, range: request.range, timeline: .canonical, work: MediaWork(), includeTags: true)
        }
        XCTAssertFalse(sources.isEmpty)
        func readFrozen() throws -> Capture {
            let result = Capture()
            for (i, piece) in try LocalMediaProvider.plan(sources, range: request.range).enumerated() {
                _ = try LocalMediaReader.read(piece, number: i, request: request, work: MediaWork(), emit: result.emit, bytes: result.bytes)
            }
            return result
        }
        let before = try readFrozen()
        for sample in f.samples.dropFirst(45) { f.store.accept(.media(camera: f.camera, name: "Test Camera", sample)) }
        XCTAssertTrue(f.store.flush(timeout: 10))
        let after = try readFrozen()
        XCTAssertEqual(before.maps, after.maps)
        XCTAssertEqual(before.payloads, after.payloads)
        try after.verify((0..<after.payloads.count).map(Self.values))
        let fresh = try capture(request, provider: f.ramProvider)
        XCTAssertEqual(fresh.payloads.count, 180)
        try fresh.verify((0..<180).map(Self.values))
    }
    func testTagRequestDefaultsAndMisuseValidation() throws {
        let camera = UUID().uuidString
        let old = try JSONDecoder().decode(MediaRequest.self, from: Data("{\"requestID\":\"a\",\"operation\":\"frames\",\"cameraID\":\"\(camera)\",\"range\":{\"start\":1,\"end\":2}}".utf8))
        XCTAssertFalse(old.includeTags)
        let wrong = MediaRequest(requestID: "bad", operation: "availability", cameraID: camera, range: .init(start: 1, end: 2), includeTags: true)
        XCTAssertThrowsError(try wrong.resolve(now: 2, live: nil))
    }
}
