import XCTest
import Foundation
import Darwin
import SQLite3

final class ActiveLocalTagsTests: XCTestCase {
    private struct Fixture {
        let configuration: RecordingStoreConfiguration
        let store: LocalRecordingStore
        let camera: String
        let frames: [EncodedMedia]
        func append(_ range: Range<Int>) {
            for frame in frames[range] { store.accept(.media(camera: camera, name: "Camera", frame)) }
        }
        func index() throws -> (LocalRecordingLayout.Directory, LocalRecordingManifest) {
            let path = configuration.directory + "/Camera"
            let directory = LocalRecordingLayout.Directory(path: path, fd: try StoreDirectory.openDirectory(path))
            return (directory, try LocalRecordingManifest(directory: directory,
                identity: .init(storeID: configuration.id, cameraID: camera), owner: geteuid(), readOnly: true))
        }
    }
    private func fixture(duration: String = "1m", shortNextInterval: Bool = false,
                         tagEvents: FootageTagEvents? = nil,
                         before: @escaping (LocalRecordingStore.Operation, String?) throws -> Void = { _, _ in }) throws -> Fixture {
        let root = "/private/tmp/hbnvr-active-tags-" + UUID().uuidString
        try SecureFiles.ensureDirectory(root, owner: geteuid(), mode: 0o700)
        var configuration = try StoreTests().config(root + "/local")
        configuration.shardDuration = duration
        var hooks = LocalRecordingStore.Hooks(); hooks.automaticMaintenance = false; hooks.before = before
        let store = try LocalRecordingStore(configuration: configuration, hooks: hooks, tagEvents: tagEvents)
        addTeardownBlock { _ = store.finish(timeout: 30); try? FileManager.default.removeItem(atPath: root) }
        let camera = UUID().uuidString, epoch = UUID().uuidString
        let start = Date().timeIntervalSince1970 - 3600
        let frames = try StoreTests.video(count: 32).enumerated().map { index, input in
            let ticks = input.frame.timestamp - (shortNextInterval && index >= 8 ? 3000 : 0)
            let elapsed = Double(ticks) / 90000, utc = start + elapsed
            var frame = EncodedMedia(codec: input.codec, clockRate: input.clockRate, parameterSets: input.parameterSets,
                frame: .init(payload: input.frame.payload, timestamp: ticks, keyFrame: input.frame.keyFrame),
                receivedAt: Date(timeIntervalSince1970: utc), receivedUptime: 100 + elapsed, ssrc: 42,
                tags: ["other": "preserved", "original": "yes"])
            frame.time = RecordingTime(cameraUTC: nil, receivedUTC: utc, canonicalUTC: utc,
                canonicalSource: .received, epochID: epoch)
            return frame
        }
        return Fixture(configuration: configuration, store: store, camera: camera, frames: frames)
    }

    func testActiveEditsAreVisibleImmediatelyAndDoNotAffectFutureSamples() throws {
        let f = try fixture(shortNextInterval: true)
        f.append(0..<8)
        let snapshot = try XCTUnwrap(f.store.pendingTagSnapshots().first)
        XCTAssertEqual(snapshot.frames, 8)
        XCTAssertEqual(snapshot.endTicks, 42001)
        try f.store.commitPendingTags([.init(snapshot: snapshot, overrides: [
            .init(start: 0, end: snapshot.endTicks, key: "private", value: "true"),
            .init(start: 12000, end: 24000, key: "original", value: nil)
        ])], work: MediaWork())
        let (directory, index) = try f.index()
        let row = try XCTUnwrap(index.recordings().first)
        XCTAssertEqual(row.state, .recording)
        let disk = try XCTUnwrap(index.historicalTags(id: row.id))
        let ram = try XCTUnwrap(RecordingRAMCache.shared.tagSnapshot(row: row))
        XCTAssertEqual(ram.timeline, disk)
        XCTAssertEqual(disk.tags(at: 42000)?["private"], "true")
        XCTAssertNil(disk.tags(at: 12000)?["original"])
        XCTAssertEqual(disk.tags(at: 12000)?["other"], "preserved")
        XCTAssertEqual(disk.tags(at: 24000)?["original"], "yes")
        f.append(8..<12)
        let continued = try XCTUnwrap(f.store.pendingTagSnapshots().first)
        XCTAssertNil(continued.tags.tags(at: 45000)?["private"], "Shorter next sample must not inherit the provisional tail edit")
        XCTAssertEqual(continued.tags.tags(at: 45000)?["original"], "yes")
        f.store.accept(.end(camera: f.camera)); XCTAssertTrue(f.store.flush(timeout: 30))
        let final = try XCTUnwrap(index.recordings().first)
        XCTAssertEqual(final.state, .complete)
        let tags = try XCTUnwrap(VideoTagMP4.read(Data(contentsOf: URL(fileURLWithPath: directory.path + "/" + final.filename))))
        XCTAssertEqual(tags, continued.tags)
        XCTAssertEqual(try index.historicalTags(id: final.id), tags)
        XCTAssertNil(f.store.snapshot().lastError)
    }

    func testSnapshotCanBeCommittedAfterRolloverWithoutChangingTheNewRecording() throws {
        let f = try fixture(duration: "1s")
        f.append(0..<14)
        let snapshot = try XCTUnwrap(f.store.pendingTagSnapshots().first)
        f.append(14..<18)
        let next = try XCTUnwrap(f.store.pendingTagSnapshots().first)
        XCTAssertNotEqual(next.timing.shardID, snapshot.timing.shardID)
        let (directory, index) = try f.index()
        let before = try XCTUnwrap(index.recordings().first { $0.id == snapshot.timing.shardID })
        let oldBytes = try Data(contentsOf: URL(fileURLWithPath: directory.path + "/" + before.filename))
        let oldTags = try XCTUnwrap(VideoTagMP4.read(oldBytes))
        try f.store.commitPendingTags([.init(snapshot: snapshot, overrides: [
            .init(start: 12000, end: snapshot.endTicks, key: "private", value: "true")
        ])], work: MediaWork())
        let old = try XCTUnwrap(index.recordings().first { $0.id == snapshot.timing.shardID })
        XCTAssertEqual(old.state, .complete)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: directory.path + "/" + old.filename))
        let tags = try XCTUnwrap(VideoTagMP4.read(bytes))
        XCTAssertEqual(bytes.dropLast(try VideoTagMP4.box(tags).count), oldBytes.dropLast(try VideoTagMP4.box(oldTags).count))
        XCTAssertEqual(tags.tags(at: 12000)?["private"], "true")
        XCTAssertNil(tags.tags(at: 6000)?["private"])
        XCTAssertNil(tags.tags(at: 84000)?["private"], "Sample appended after the snapshot stays unedited")
        XCTAssertEqual(try index.historicalTags(id: old.id), tags)
        XCTAssertEqual(try f.store.pendingTagSnapshots().first?.tags, next.tags)
        XCTAssertNil(f.store.snapshot().lastError)
    }

    func testInvalidActiveEditDoesNotChangeWriterOrManifest() throws {
        let f = try fixture()
        f.append(0..<8)
        let snapshot = try XCTUnwrap(f.store.pendingTagSnapshots().first)
        let edits = [VideoTagTimeline.Override(start: 0, end: snapshot.endTicks, key: "okay", value: "yes"),
                     .init(start: 0, end: snapshot.endTicks, key: "oversized", value: String(repeating: "x", count: 2049))]
        XCTAssertThrowsError(try f.store.commitPendingTags([.init(snapshot: snapshot, overrides: edits)], work: MediaWork()))
        XCTAssertEqual(try f.store.pendingTagSnapshots().first?.tags, snapshot.tags)
        let (_, index) = try f.index()
        XCTAssertNil(try index.historicalTags(id: snapshot.timing.shardID)?.tags(at: 0)?["okay"])
        f.append(8..<12)
        XCTAssertEqual(try f.store.pendingTagSnapshots().first?.frames, 12)
        XCTAssertNil(f.store.snapshot().lastError)
    }

    func testActiveTagEditServesManifestCheckpointUntilWriterPublishes() throws {
        let events = FootageTagEvents(instanceID: UUID().uuidString)
        var expected: LocalTagReadSnapshot?, observed = false
        let f = try fixture(tagEvents: events) { operation, _ in
            guard case .editTags = operation else { return }
            let previous = try XCTUnwrap(expected)
            let (token, captured) = try events.readLocalSnapshot(storeID: previous.timing.storeID, work: MediaWork()) {
                try XCTUnwrap($0[previous.timing.shardID])
            }
            XCTAssertEqual(token.revision, 0)
            XCTAssertEqual(captured.endTicks, previous.endTicks)
            XCTAssertEqual(captured.tags, previous.tags)
            observed = true
        }
        f.append(0..<8)
        let pending = try XCTUnwrap(f.store.pendingTagSnapshots().first)
        let (_, reader) = try f.index(), row = try XCTUnwrap(reader.recordings().first)
        expected = .init(timing: row.timing, endTicks: row.endTicks, tags: try reader.historicalTags(id: row.id))
        try f.store.commitPendingTags([.init(snapshot: pending, overrides: [
            .init(start: 0, end: pending.endTicks, key: "private", value: "true")
        ])], work: MediaWork())
        XCTAssertTrue(observed)
        let (token, empty) = try events.readLocalSnapshot(storeID: f.configuration.id, work: MediaWork()) { $0.isEmpty }
        XCTAssertTrue(empty)
        XCTAssertEqual(token.revision, 1)
        XCTAssertEqual(try reader.historicalTags(id: row.id)?.tags(at: 0)?["private"], "true")
        XCTAssertEqual(try f.store.pendingTagSnapshots().first?.tags.tags(at: 0)?["private"], "true")
    }

    func testFailedActiveTagEditReleasesUnchangedCheckpoint() throws {
        let events = FootageTagEvents(instanceID: UUID().uuidString)
        let f = try fixture(tagEvents: events)
        f.append(0..<8)
        let pending = try XCTUnwrap(f.store.pendingTagSnapshots().first)
        let (directory, reader) = try f.index()
        let checkpoint = try XCTUnwrap(reader.recordings().first)
        let original = try reader.historicalTags(id: pending.timing.shardID)
        var sql: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.path + "/" + LocalRecordingManifest.filename, &sql), SQLITE_OK)
        defer { sqlite3_close(sql) }
        XCTAssertEqual(sqlite3_exec(sql, """
            CREATE TRIGGER fail_active_tags BEFORE UPDATE OF tags_json ON recordings
            BEGIN SELECT RAISE(ABORT, 'injected active tag failure'); END
            """, nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try f.store.commitPendingTags([.init(snapshot: pending, overrides: [
            .init(start: 0, end: pending.endTicks, key: "private", value: "true")
        ])], work: MediaWork()))
        let (_, empty) = try events.readLocalSnapshot(storeID: f.configuration.id, work: MediaWork()) { $0.isEmpty }
        XCTAssertTrue(empty)
        XCTAssertEqual(try reader.recordings().first?.endTicks, checkpoint.endTicks)
        XCTAssertEqual(try reader.historicalTags(id: pending.timing.shardID), original)
        XCTAssertEqual(try f.store.pendingTagSnapshots().first?.tags, pending.tags)
        XCTAssertEqual(sqlite3_exec(sql, "DROP TRIGGER fail_active_tags", nil, nil, nil), SQLITE_OK)
        f.append(8..<12)
        XCTAssertEqual(try f.store.pendingTagSnapshots().first?.frames, 12)
    }

    func testAccumulatorRejectsCombinedTagLimitWithoutLosingPreviousChanges() throws {
        var accumulator = VideoTagAccumulator()
        let full = Dictionary(uniqueKeysWithValues: (0..<32).map { ("key\($0)", "value") })
        try accumulator.append(full, ticks: 0, frame: 0)
        let before = accumulator.timeline
        XCTAssertThrowsError(try accumulator.apply(overrides: [.init(start: 0, end: 1, key: "extra", value: "no")]))
        XCTAssertEqual(accumulator.timeline, before)
        try accumulator.apply(overrides: [.init(start: 0, end: 1, key: "key0", value: nil)])
        try accumulator.append(["future": "yes"], ticks: 2, frame: 1)
        XCTAssertNil(accumulator.timeline.tags(at: 0)?["key0"])
        XCTAssertEqual(accumulator.timeline.tags(at: 2), ["future": "yes"])
        try accumulator.timeline.validate()
    }
}
