import XCTest
import Foundation
import Darwin
import AVFoundation
import SQLite3

final class TagFilteredNeighborTests: XCTestCase {
    let helper = MediaTests()
    let excludedTag = "review.skip"

    func fixture(codec: CMVideoCodecType = kCMVideoCodecType_H264, count: Int = 45,
                 initialCount: Int? = nil, skew: UInt32 = 0, start: Double? = nil,
                 camera: String? = nil, tags: (Int) -> [String: String] = { _ in [:] }) throws -> MediaTests.Fixture {
        let value = try helper.fixture(codec: codec, count: count, initialCount: initialCount,
            timestampSkewPerFrame: skew, startUTC: start, cameraID: camera, tags: tags)
        addTeardownBlock { _ = value.store.finish(timeout: 10); try? FileManager.default.removeItem(atPath: value.root) }
        return value
    }
    func request(_ camera: String, at point: Double, timeline: MediaTimeline = .canonical,
                 excludeTagKeys: [String] = ["review.skip"]) -> MediaRequest {
        .init(requestID: UUID().uuidString, operation: "neighbors", cameraID: camera,
            timeline: timeline, range: .init(start: point, end: point + 0.001), excludeTagKeys: excludeTagKeys)
    }
    func neighbors(_ request: MediaRequest, provider: LocalMediaProvider) throws -> MediaNeighbors {
        var messages: [MediaMessage] = []
        try MediaResponse.run(request, provider: provider, work: MediaWork(), emit: { messages.append($0) }, bytes: { _ in
            XCTFail("Neighbor navigation must not send video or tag-map bytes")
        })
        XCTAssertEqual(messages.map(\.type), ["begin", "neighbors", "end"])
        XCTAssertEqual(messages.last?.outcome, "complete")
        XCTAssertEqual(messages.last?.frames, 0)
        return try XCTUnwrap(messages[1].neighbors)
    }
    func assertRange(_ actual: MediaRange?, start: Double, end: Double,
                     file: StaticString = #filePath, line: UInt = #line) throws {
        let actual = try XCTUnwrap(actual, file: file, line: line)
        XCTAssertEqual(actual.start, start, accuracy: 0.000001, file: file, line: line)
        XCTAssertEqual(actual.end, end, accuracy: 0.000001, file: file, line: line)
    }
    func append(_ fixtures: [MediaTests.Fixture], to first: MediaTests.Fixture) throws {
        let writer = try LocalRecordingStore(configuration: first.config)
        defer { _ = writer.finish(timeout: 10) }
        for fixture in fixtures {
            for sample in fixture.samples { writer.accept(.media(camera: first.camera, name: "Test Camera", sample)) }
        }
        XCTAssertTrue(writer.finish(timeout: 10))
        XCTAssertNil(writer.snapshot().lastError)
    }
    func updateTags(_ fixture: MediaTests.Fixture, _ edit: (inout VideoTagTimeline) throws -> Void) throws {
        let source = try XCTUnwrap(fixture.provider.catalog(camera: fixture.camera,
            range: .init(start: helper.base, end: helper.base + 3), timeline: .canonical, work: MediaWork()).first)
        let identity = LocalRecordingLayout.Identity(storeID: fixture.config.id, cameraID: fixture.camera)
        let index = try LocalRecordingManifest(directory: source.directory, identity: identity,
            owner: geteuid(), recoverInterrupted: false)
        let original = try XCTUnwrap(index.historicalTags(id: source.row.id))
        var replacement = original
        try edit(&replacement)
        let staged = try LocalTagFile.stage(source: source, tags: replacement, jobID: UUID().uuidString, work: MediaWork())
        try index.commitTagEdits([staged], revisions: [source.row.id: HistoricalTags.revision(original)])
    }
    func execute(_ sql: String, fixture: MediaTests.Fixture) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open((fixture.folder + "/" + LocalRecordingManifest.filename), &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
    }

    func testExactTransitionsWithinBothCodecsUseFrameBoundariesAcrossTimelinesAndClockRounding() throws {
        for codec in [kCMVideoCodecType_H264, kCMVideoCodecType_HEVC] {
            let f = try fixture(codec: codec, skew: 3) { i in
                (15..<30).contains(i) ? [self.excludedTag: i < 23 ? "false" : ""] : [:]
            }
            for timeline in [MediaTimeline.canonical, .camera, .received] {
                let offset = timeline == .received ? 0.4 : 0.0, anchor = helper.base + offset
                // The independent frame response supplies the actual MP4 sample
                // coordinates; nominal FPS or original camera ticks can round differently.
                let frames = try helper.response(helper.request(f.camera, start: anchor, end: anchor + 4,
                    timeline: timeline), provider: f.provider).messages.compactMap(\.frame)
                XCTAssertEqual(frames.count, 45)
                let scale = Double(f.samples[0].clockRate)
                let last = try XCTUnwrap(frames.last)
                let result = try neighbors(request(f.camera, at: anchor + 1.5, timeline: timeline), provider: f.provider)
                try assertRange(result.previous, start: anchor,
                    end: anchor + Double(frames[15].presentationTicks) / scale)
                try assertRange(result.next, start: anchor + Double(frames[30].presentationTicks) / scale,
                    end: anchor + Double(last.presentationTicks + last.durationTicks) / scale)
            }
        }
    }

    func testExcludedAndMissingStretchesAcrossMultipleRecordingsFormOneUnavailableRegion() throws {
        let base = helper.base
        let first = try fixture { $0 >= 15 ? [self.excludedTag: "true"] : [:] }
        let middle = try fixture(start: base + 60, camera: first.camera) { _ in [self.excludedTag: "false"] }
        let last = try fixture(start: base + 120, camera: first.camera) { $0 < 30 ? [self.excludedTag: ""] : [:] }
        try append([middle, last], to: first)
        for offset in [1.5, 3, 30, 60, 61.5, 63, 90, 120, 121.5] {
            let result = try neighbors(request(first.camera, at: base + offset), provider: first.provider)
            try assertRange(result.previous, start: base, end: base + 1)
            try assertRange(result.next, start: base + 122, end: base + 123)
        }
    }

    func testOverlappingRecordingsCompareUnexcludedBoundariesInsteadOfStoppingAtFirstFile() throws {
        let base = helper.base
        let first = try fixture { (20..<44).contains($0) ? [self.excludedTag: "true"] : [:] }
        let overlapping = try fixture(start: base + 0.5, camera: first.camera) {
            (5..<23).contains($0) ? [self.excludedTag: "true"] : [:]
        }
        try append([overlapping], to: first)
        let result = try neighbors(request(first.camera, at: base + 1.6), provider: first.provider)
        try assertRange(result.previous, start: base, end: base + 20.0 / 15)
        try assertRange(result.next, start: base + 0.5 + 23.0 / 15, end: base + 3.5)
    }

    func testSameEpochOverlapRespectsTheSourceSelectedByTaggedPlayback() throws {
        let base = helper.base, first = try fixture { _ in [self.excludedTag: "true"] }
        let later = try fixture(start: base + 2, camera: first.camera)
        let epoch = try XCTUnwrap(first.samples.first?.time?.epochID)
        let writer = try LocalRecordingStore(configuration: first.config)
        defer { _ = writer.finish(timeout: 10) }
        for original in later.samples {
            var sample = original
            let time = try XCTUnwrap(sample.time)
            sample.time = RecordingTime(cameraUTC: time.cameraUTC, receivedUTC: time.receivedUTC,
                canonicalUTC: time.canonicalUTC, canonicalSource: time.canonicalSource,
                epochID: epoch, cameraClock: time.cameraClock)
            writer.accept(.media(camera: first.camera, name: "Test Camera", sample))
        }
        XCTAssertTrue(writer.finish(timeout: 10))
        XCTAssertNil(writer.snapshot().lastError)
        let result = try neighbors(request(first.camera, at: base + 1), provider: first.provider)
        XCTAssertNil(result.previous)
        try assertRange(result.next, start: base + 3, end: base + 5)
        let reverse = try neighbors(request(first.camera, at: base + 6), provider: first.provider)
        try assertRange(reverse.previous, start: base + 3, end: base + 5)
        XCTAssertNil(reverse.next)
    }

    func testActiveRAMWinsSameEpochOverlapWithFinalizedRecording() throws {
        let base = helper.base, first = try fixture()
        let later = try fixture(count: 9, start: base + 2, camera: first.camera) { _ in [self.excludedTag: "true"] }
        let epoch = try XCTUnwrap(first.samples.first?.time?.epochID)
        let writer = try LocalRecordingStore(configuration: first.config)
        defer { _ = writer.finish(timeout: 10) }
        for original in later.samples {
            var sample = original
            let time = try XCTUnwrap(sample.time)
            sample.time = RecordingTime(cameraUTC: time.cameraUTC, receivedUTC: time.receivedUTC,
                canonicalUTC: time.canonicalUTC, canonicalSource: time.canonicalSource,
                epochID: epoch, cameraClock: time.cameraClock)
            writer.accept(.media(camera: first.camera, name: "Test Camera", sample))
        }
        XCTAssertTrue(writer.flush(timeout: 10))
        XCTAssertNil(writer.snapshot().lastError)
        let result = try neighbors(request(first.camera, at: base + 2.3), provider: first.ramProvider)
        try assertRange(result.previous, start: base, end: base + 2)
        try assertRange(result.next, start: base + 2.6, end: base + 3)
    }

    func testOneSidedAllExcludedAndEmptyArchivesAreCompleteResults() throws {
        let base = helper.base
        let f = try fixture { (15..<30).contains($0) ? [self.excludedTag: "true"] : [:] }
        let before = try neighbors(request(f.camera, at: base - 10), provider: f.provider)
        XCTAssertNil(before.previous)
        try assertRange(before.next, start: base, end: base + 1)
        let after = try neighbors(request(f.camera, at: base + 10), provider: f.provider)
        try assertRange(after.previous, start: base + 2, end: base + 3)
        XCTAssertNil(after.next)
        let allExcluded = try fixture { _ in [self.excludedTag: ""] }
        XCTAssertEqual(try neighbors(request(allExcluded.camera, at: base + 1.5), provider: allExcluded.provider), MediaNeighbors())
        XCTAssertEqual(try neighbors(request(UUID().uuidString, at: base), provider: f.provider), MediaNeighbors())
        let empty = LocalMediaProvider(configurations: { [] }, ram: nil)
        XCTAssertEqual(try neighbors(request(f.camera, at: base), provider: empty), MediaNeighbors())
    }

    func testHistoricalOverridesAndRemovalChangeDestinationsWithoutFallingBackToOriginalTags() throws {
        let base = helper.base, f = try fixture { _ in [self.excludedTag: "false"] }
        XCTAssertEqual(try neighbors(request(f.camera, at: base + 1), provider: f.provider), MediaNeighbors())
        try updateTags(f) { tags in
            try tags.apply(.init(start: 60000, end: 120000, key: excludedTag, value: nil))
            try tags.apply(.init(start: 84000, end: 96000, key: excludedTag, value: ""))
        }
        let result = try neighbors(request(f.camera, at: base + 1), provider: f.provider)
        try assertRange(result.previous, start: base + 10.0 / 15, end: base + 14.0 / 15)
        try assertRange(result.next, start: base + 16.0 / 15, end: base + 20.0 / 15)
        try updateTags(f) { try $0.apply(.init(start: 0, end: 270000, key: excludedTag, value: nil)) }
        let removed = try neighbors(request(f.camera, at: base - 1), provider: f.provider)
        try assertRange(removed.next, start: base, end: base + 3)
    }

    func testHistoricalBoundariesBetweenSamplesUseFirstSampleAtOrAfterEachBoundary() throws {
        let base = helper.base, f = try fixture()
        try updateTags(f) {
            try $0.apply(.init(start: 60001, end: 119999, key: excludedTag, value: "false"))
        }
        let result = try neighbors(request(f.camera, at: base + 1), provider: f.provider)
        try assertRange(result.previous, start: base, end: base + 11.0 / 15)
        try assertRange(result.next, start: base + 20.0 / 15, end: base + 3)
        try updateTags(f) {
            try $0.apply(.init(start: 72001, end: 95999, key: excludedTag, value: nil))
        }
        let removed = try neighbors(request(f.camera, at: base + 1.2), provider: f.provider)
        try assertRange(removed.previous, start: base + 13.0 / 15, end: base + 16.0 / 15)
        try assertRange(removed.next, start: base + 20.0 / 15, end: base + 3)
    }

    func testExactExcludedBoundariesAndRelativeAnchorKeepHalfOpenSemantics() throws {
        let base = helper.base
        let f = try fixture { (15..<30).contains($0) ? [self.excludedTag: "true"] : [:] }
        let atStart = try neighbors(request(f.camera, at: base + 1), provider: f.provider)
        try assertRange(atStart.previous, start: base, end: base + 1)
        try assertRange(atStart.next, start: base + 2, end: base + 3)
        let provider = LocalMediaProvider(configurations: { [f.config] }, now: { base + 2 }, ram: nil)
        let query = MediaRequest(requestID: "relative-boundary", operation: "neighbors", cameraID: f.camera,
            range: .init(start: -0.001, end: 0), relativeTo: "now", excludeTagKeys: [excludedTag])
        let atEnd = try neighbors(query, provider: provider)
        try assertRange(atEnd.previous, start: base, end: base + 1)
        try assertRange(atEnd.next, start: base + 2, end: base + 3)
    }

    func testLegacyMissingAndUnknownTagsMatchTaggedFrameValuePresence() throws {
        let base = helper.base, f = try fixture { _ in [self.excludedTag: "embedded-value"] }
        try execute("UPDATE recordings SET tags_json=NULL", fixture: f)
        try assertRange(try neighbors(request(f.camera, at: base - 1), provider: f.provider).next,
            start: base, end: base + 3)
        let unknown = try fixture { _ in [self.excludedTag: "embedded-value"] }
        try updateTags(unknown) { tags in
            tags = .unknown
            try tags.apply(.init(start: 90000, end: 180000, key: excludedTag, value: "false"))
        }
        let result = try neighbors(request(unknown.camera, at: base + 1.5), provider: unknown.provider)
        try assertRange(result.previous, start: base, end: base + 1)
        try assertRange(result.next, start: base + 2, end: base + 3)
        try updateTags(unknown) { try $0.apply(.init(start: 120000, end: 150000, key: excludedTag, value: nil)) }
        let beforeRemoval = try neighbors(request(unknown.camera, at: base + 1.2), provider: unknown.provider)
        try assertRange(beforeRemoval.previous, start: base, end: base + 1)
        try assertRange(beforeRemoval.next, start: base + 20.0 / 15, end: base + 25.0 / 15)
        let afterRemoval = try neighbors(request(unknown.camera, at: base + 1.8), provider: unknown.provider)
        try assertRange(afterRemoval.previous, start: base + 20.0 / 15, end: base + 25.0 / 15)
        try assertRange(afterRemoval.next, start: base + 2, end: base + 3)
    }

    func testAbsentAndEmptyFilterPreserveOrdinaryNavigationThroughTaggedFootage() throws {
        let base = helper.base, f = try fixture { _ in [self.excludedTag: "true"] }
        let legacy = helper.request(f.camera, start: base + 1, end: base + 1.001, operation: "neighbors")
        let disabled = request(f.camera, at: base + 1, excludeTagKeys: [])
        let old = try neighbors(legacy, provider: f.provider)
        XCTAssertEqual(try neighbors(disabled, provider: f.provider), old)
        try assertRange(old.previous, start: base, end: base + 1)
        try assertRange(old.next, start: base + 1.001, end: base + 3)
        XCTAssertEqual(try neighbors(request(f.camera, at: base + 1), provider: f.provider), MediaNeighbors())
    }

    func testActiveResidentAndGrowingDiskNeighborsUseCurrentTags() throws {
        let base = helper.base
        let f = try fixture(count: 180, initialCount: 180) { (15..<90).contains($0) ? [self.excludedTag: "true"] : [:] }
        let query = request(f.camera, at: base + 3)
        let memory = try neighbors(query, provider: f.ramProvider)
        try assertRange(memory.previous, start: base, end: base + 1)
        XCTAssertEqual(try XCTUnwrap(memory.next).start, base + 6, accuracy: 0.000001)
        // Disk-only navigation also has authoritative tag metadata before the
        // periodic SQLite checkpoint and cannot depend on retained video payloads.
        RecordingRAMCache.shared.memoryPressure(true)
        defer { RecordingRAMCache.shared.memoryPressure(false) }
        var disk = try neighbors(query, provider: f.provider)
        let deadline = Date().addingTimeInterval(3)
        while disk.next == nil, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
            disk = try neighbors(query, provider: f.provider)
        }
        try assertRange(disk.previous, start: base, end: base + 1)
        XCTAssertEqual(try XCTUnwrap(disk.next).start, base + 6, accuracy: 0.000001)
        XCTAssertEqual(f.store.snapshot().playbackRAMBytes, 0)
        XCTAssertEqual(f.store.snapshot().completedShards, 0)
    }

    func testCancellationDeadlineAndUnavailableStoreCannotBecomeConfirmedAbsence() throws {
        let f = try fixture { _ in [self.excludedTag: "true"] }
        let query = request(f.camera, at: helper.base + 1)
        let cancellation = Cancellation(); cancellation.stop()
        for work in [MediaWork(cancellation: cancellation), MediaWork(deadline: ProcessInfo.processInfo.systemUptime - 1)] {
            XCTAssertThrowsError(try f.provider.neighbors(camera: f.camera, range: query.range,
                timeline: .canonical, work: work, excludeTagKeys: [excludedTag]))
        }
        try FileManager.default.removeItem(atPath: f.config.directory)
        XCTAssertThrowsError(try neighbors(query, provider: f.provider))
    }

    func testUnreadableIndexedFileIsAnErrorButDeletedFileIsConfirmedAbsent() throws {
        let f = try fixture { _ in [self.excludedTag: "true"] }
        let source = try XCTUnwrap(f.provider.catalog(camera: f.camera,
            range: .init(start: helper.base, end: helper.base + 3), timeline: .canonical, work: MediaWork()).first)
        let path = source.directory.path + "/" + source.row.filename
        XCTAssertEqual(chmod(path, 0o000), 0)
        let query = request(f.camera, at: helper.base + 1)
        XCTAssertThrowsError(try neighbors(query, provider: f.provider))
        XCTAssertEqual(try neighbors(request(f.camera, at: helper.base + 1, excludeTagKeys: []), provider: f.provider), MediaNeighbors())
        XCTAssertEqual(chmod(path, 0o600), 0)
        try FileManager.default.removeItem(atPath: path)
        XCTAssertEqual(try neighbors(query, provider: f.provider), MediaNeighbors())
    }

    func testMalformedTagMetadataFailsWithoutEmittingNeighborsOrSuccess() throws {
        let f = try fixture { _ in [self.excludedTag: "true"] }
        try execute("UPDATE recordings SET tags_json='{invalid-json}'", fixture: f)
        var messages: [MediaMessage] = []
        XCTAssertThrowsError(try MediaResponse.run(request(f.camera, at: helper.base + 1), provider: f.provider,
            work: MediaWork(), emit: { messages.append($0) }, bytes: { _ in XCTFail("Unexpected media payload") }))
        XCTAssertEqual(messages.map(\.type), ["begin"])
        // The existing operation does not inspect tags and remains usable.
        XCTAssertNotNil(try neighbors(request(f.camera, at: helper.base + 1, excludeTagKeys: []), provider: f.provider).previous)
    }

    func testMultipleArbitraryTagKeysExcludeTheirUnion() throws {
        let base = helper.base
        let f = try fixture { index in
            if (10..<20).contains(index) { return [self.excludedTag: "false"] }
            if (20..<30).contains(index) { return ["workflow.private": ""] }
            return [:]
        }
        let result = try neighbors(request(f.camera, at: base + 1,
            excludeTagKeys: [excludedTag, "workflow.private"]), provider: f.provider)
        try assertRange(result.previous, start: base, end: base + 10.0 / 15)
        try assertRange(result.next, start: base + 2, end: base + 3)
        let onlyFirst = try neighbors(request(f.camera, at: base + 1), provider: f.provider)
        try assertRange(onlyFirst.previous, start: base, end: base + 10.0 / 15)
        try assertRange(onlyFirst.next, start: base + 20.0 / 15, end: base + 3)
    }

    func testHomebaseHiddenTagHasNoEffectUnlessExplicitlyRequested() throws {
        let base = helper.base, f = try fixture { _ in ["homebase.hidden": "true"] }
        let ordinary = try neighbors(request(f.camera, at: base + 1, excludeTagKeys: []), provider: f.provider)
        let unrelatedFilter = try neighbors(request(f.camera, at: base + 1), provider: f.provider)
        XCTAssertEqual(unrelatedFilter, ordinary)
        try assertRange(unrelatedFilter.previous, start: base, end: base + 1)
        try assertRange(unrelatedFilter.next, start: base + 1.001, end: base + 3)
        XCTAssertEqual(try neighbors(request(f.camera, at: base + 1,
            excludeTagKeys: ["homebase.hidden"]), provider: f.provider), MediaNeighbors())
    }

    func testFilterDefaultsValidationAndWireCapability() throws {
        let camera = UUID().uuidString
        let old = Data("{\"requestID\":\"old\",\"operation\":\"neighbors\",\"cameraID\":\"\(camera)\",\"range\":{\"start\":1,\"end\":2}}".utf8)
        XCTAssertEqual(try JSONDecoder().decode(MediaRequest.self, from: old).excludeTagKeys, [])
        let enabled = request(camera, at: 1)
        XCTAssertEqual(try JSONDecoder().decode(MediaRequest.self, from: JSONEncoder().encode(enabled)).excludeTagKeys, [excludedTag])
        XCTAssertNoThrow(try enabled.resolve(now: 2, live: nil))
        for operation in ["frames", "availability"] {
            let wrong = MediaRequest(requestID: "wrong", operation: operation, cameraID: camera,
                range: .init(start: 1, end: 2), excludeTagKeys: [excludedTag])
            XCTAssertThrowsError(try wrong.resolve(now: 2, live: nil))
            let empty = MediaRequest(requestID: "empty", operation: operation, cameraID: camera,
                range: .init(start: 1, end: 2), excludeTagKeys: [])
            XCTAssertNoThrow(try empty.resolve(now: 2, live: nil))
        }
        var wrong = enabled; wrong.includeTags = true
        XCTAssertThrowsError(try wrong.resolve(now: 2, live: nil))
        let info = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(MediaSessionInfo())) as? [String: Any])
        XCTAssertEqual(info["supportsNeighbors"] as? Bool, true)
        XCTAssertEqual(info["supportsTagFilteredNeighbors"] as? Bool, true)
        XCTAssertNil(info["supportsHiddenNeighbors"])
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(enabled)) as? [String: Any])
        XCTAssertNil(encoded["excludeHidden"])
    }

    func testFilterKeyValidationLimitsAndJSONTypes() throws {
        let camera = UUID().uuidString
        for keys in [[], [String(repeating: "a", count: 256)], [String(repeating: "é", count: 128)],
                     (0..<32).map { "tag.\($0)" }] {
            XCTAssertNoThrow(try request(camera, at: 1, excludeTagKeys: keys).resolve(now: 2, live: nil))
        }
        for keys in [[""], [excludedTag, excludedTag], [String(repeating: "a", count: 257)],
                     [String(repeating: "é", count: 129)], (0..<33).map { "tag.\($0)" }] {
            XCTAssertThrowsError(try request(camera, at: 1, excludeTagKeys: keys).resolve(now: 2, live: nil))
        }
        for invalid in ["true", "\"review.skip\"", "[1]", "[null]", "{}"] {
            let json = Data("{\"requestID\":\"invalid\",\"operation\":\"neighbors\",\"cameraID\":\"\(camera)\",\"range\":{\"start\":1,\"end\":2},\"excludeTagKeys\":\(invalid)}".utf8)
            XCTAssertThrowsError(try JSONDecoder().decode(MediaRequest.self, from: json))
        }
    }

    func testSocketNegotiatesCapabilityAndReportsTagFailureAsTerminalError() throws {
        let f = try fixture { _ in [self.excludedTag: "true"] }
        var sockets: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        let sessions = MediaSessions(provider: f.provider, authorize: { $0 == geteuid() })
        defer { sessions.stop(); close(sockets[1]) }
        try sessions.open(sockets[0], uid: geteuid(), version: 1, deadline: ProcessInfo.processInfo.systemUptime + 2)
        let reply = try JSONDecoder().decode(Reply.self,
            from: SocketIO.read(fd: sockets[1], deadline: ProcessInfo.processInfo.systemUptime + 2))
        XCTAssertEqual(reply.mediaSession?.supportsTagFilteredNeighbors, true)
        try execute("UPDATE recordings SET tags_json='{invalid-json}'", fixture: f)
        for filtered in [true, false] {
            let query = request(f.camera, at: helper.base + 1, excludeTagKeys: filtered ? [excludedTag] : [])
            try MediaWire.write(JSONEncoder().encode(query), type: MediaWire.json, fd: sockets[1], work: MediaWork())
            var messages: [MediaMessage] = []
            while messages.last?.type != "end" {
                let deadline = ProcessInfo.processInfo.systemUptime + 5
                let header = try MediaWire.readExactly(5, fd: sockets[1], deadline: deadline, cancellation: Cancellation())
                XCTAssertEqual(header[0], MediaWire.json)
                let count = header.dropFirst().reduce(0) { $0 << 8 | Int($1) }
                let data = try MediaWire.readExactly(count, fd: sockets[1], deadline: deadline, cancellation: Cancellation())
                messages.append(try JSONDecoder().decode(MediaMessage.self, from: data))
            }
            XCTAssertEqual(messages.map(\.type), filtered ? ["begin", "end"] : ["begin", "neighbors", "end"])
            XCTAssertEqual(messages.last?.outcome, filtered ? "error" : "complete")
            if filtered { XCTAssertEqual(messages.last?.code, .unavailable) }
        }
    }
}
