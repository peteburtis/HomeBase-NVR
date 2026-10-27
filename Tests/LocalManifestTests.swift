import XCTest
import Foundation
import Darwin
import SQLite3

final class LocalManifestTests: XCTestCase {
    struct Fixture {
        let root: String
        let config: RecordingStoreConfiguration
        let directory: LocalRecordingLayout.Directory
        let identity: LocalRecordingLayout.Identity
        func open(readOnly: Bool = false) throws -> LocalRecordingManifest {
            try LocalRecordingManifest(directory: directory, identity: identity, owner: geteuid(), readOnly: readOnly)
        }
    }
    func fixture() throws -> Fixture {
        let root = "/private/tmp/hbnvr-manifest-test-" + UUID().uuidString
        try SecureFiles.ensureDirectory(root, owner: geteuid(), mode: 0o700)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: root) }
        let path = root + "/recordings"
        try StoreDirectory.create(path, owner: geteuid(), daemon: geteuid())
        let config = RecordingStoreConfiguration(directory: path, ownerUID: geteuid(), ownerUUID: try StoreDirectory.identity(geteuid()))
        let fd = try StoreDirectory.openDirectory(path); defer { close(fd) }
        let camera = UUID().uuidString
        let directory = try LocalRecordingLayout.cameraDirectory(root: path, fd: fd,
            store: config.id, camera: camera, name: "Test Camera", owner: geteuid())
        return Fixture(root: root, config: config, directory: directory,
                       identity: .init(storeID: config.id, cameraID: camera))
    }
    @discardableResult
    func recorded(_ fixture: Fixture, _ db: LocalRecordingManifest, number: Int = 1,
                  start: Double = 100, duration: Int64 = 10, complete: Bool = true,
                  metadata: LocalRecordingManifest.CameraMetadata? = nil) throws -> (id: String, file: String) {
        let id = UUID().uuidString, file = "2026-09-17_12-00-00-\(number).mp4"
        try db.begin(id: id, temporaryName: file + ".recording", finalName: file,
                     start: Date(timeIntervalSince1970: start), timescale: 90000, sourceTimestamp: UInt32.max - 10,
                     timing: timing(fixture, id: id, start: start), cameraMetadata: metadata)
        try db.progress(id: id, endTicks: duration * 90000, frames: duration * 15)
        if complete {
            // Metadata unit tests stand in for the already-verified MP4 writer.
            // The real-store test below checks this path with encoded video.
            try SecureFiles.atomicWrite(Data([1, 2, 3]), to: fixture.directory.path + "/" + file, mode: 0o600)
            try db.complete(id: id, filename: file, endTicks: duration * 90000, frames: duration * 15)
        }
        return (id, file)
    }
    func testCoverageKeepsRealGapsAndMergesOverlapsWithHalfOpenBounds() throws {
        let f = try fixture(), db = try f.open()
        try recorded(f, db)
        try recorded(f, db, number: 2, start: 120, duration: 5)
        try recorded(f, db, number: 3, start: 124, duration: 6)
        let result = try db.coverage(from: 95, to: 140)
        XCTAssertEqual(result.recordings.count, 3)
        XCTAssertEqual(result.available, [.init(start: 100, end: 110), .init(start: 120, end: 130)])
        XCTAssertEqual(result.gaps, [.init(start: 95, end: 100), .init(start: 110, end: 120), .init(start: 130, end: 140)])
        XCTAssertTrue(try db.coverage(from: 110, to: 120).recordings.isEmpty)
        XCTAssertEqual(try db.coverage(from: 102, to: 105).available, [.init(start: 102, end: 105)])
        XCTAssertThrowsError(try db.coverage(from: 100, to: 100))
        XCTAssertThrowsError(try db.coverage(from: .nan, to: 100))
        let path = f.directory.path + "/" + LocalRecordingManifest.filename
        XCTAssertEqual(try SecureFiles.info(path)!.st_mode & 0o777, 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + "-journal"))
    }
    func testCameraMetadataIsAtomicValidatedAndDoesNotChurnWhenUnchanged() throws {
        let f = try fixture(), db = try f.open()
        let first = LocalRecordingManifest.CameraMetadata(name: "Kitchen", homebaseDeviceID: "camera-one", updatedAt: 1)
        try recorded(f, db, metadata: first)
        XCTAssertEqual(try db.cameraMetadata(), first)
        try recorded(f, db, number: 2, metadata: .init(name: "Kitchen", homebaseDeviceID: "camera-one", updatedAt: 2))
        XCTAssertEqual(try db.cameraMetadata(), first)
        XCTAssertThrowsError(try recorded(f, db, number: 3, metadata: .init(name: "Invalid", homebaseDeviceID: "not-a-camera", updatedAt: 3)))
        XCTAssertEqual(try db.recordings().count, 2)
        XCTAssertEqual(try db.cameraMetadata(), first)
        let renamed = LocalRecordingManifest.CameraMetadata(name: "Pantry", homebaseDeviceID: "camera-one", updatedAt: 4)
        try recorded(f, db, number: 3, metadata: renamed)
        XCTAssertEqual(try f.open(readOnly: true).cameraMetadata(), renamed)
    }
    func testAcceptedProgressIsNotAvailableAndRestartOnlyMarksInterrupted() throws {
        let f = try fixture()
        var db: LocalRecordingManifest? = try f.open()
        let row = try recorded(f, db!, complete: false)
        XCTAssertEqual(try db!.recordings().first?.frames, 150)
        XCTAssertTrue(try db!.coverage(from: 90, to: 120).available.isEmpty)
        // Merely seeing a final-named file must NEVER promote an incomplete row.
        try SecureFiles.atomicWrite(Data([1]), to: f.directory.path + "/" + row.file, mode: 0o600)
        let reader = try f.open(readOnly: true)
        XCTAssertEqual(try reader.recordings().first?.state, .recording)
        db = nil
        db = try f.open()
        XCTAssertEqual(try db!.recordings().first?.state, .interrupted)
        XCTAssertTrue(try db!.coverage(from: 90, to: 120).available.isEmpty)
        XCTAssertThrowsError(try db!.complete(id: row.id, filename: row.file, endTicks: 900000, frames: 150))
        XCTAssertThrowsError(try reader.remove(filename: row.file))
    }
    func testClientTagSnapshotsUseCheckpointMetadataWithoutInspectingMediaFiles() throws {
        let f = try fixture(), writer = try f.open()
        let active = try recorded(f, writer, complete: false)
        let tags = VideoTagTimeline(changes: [.init(ticks: 0, frame: 0, tags: ["private": "true"])])
        try writer.progress(id: active.id, endTicks: 450000, frames: 150, tags: tags)
        let reader = try f.open(readOnly: true)
        let snapshots = try reader.localTagSnapshots(range: .init(start: 99, end: 111))
        let value = try XCTUnwrap(snapshots.first)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(value.timing.shardID, active.id)
        XCTAssertEqual(value.endTicks, 450000)
        XCTAssertEqual(value.tags, tags)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.path + "/" + active.file))
        XCTAssertTrue(try reader.localTagSnapshots(range: .init(start: 105, end: 110)).isEmpty)
        try writer.interrupt(id: active.id)
        XCTAssertTrue(try reader.localTagSnapshots(range: .init(start: 99, end: 111)).isEmpty)

        let finalized = try recorded(f, writer, number: 2, start: 120)
        try FileManager.default.removeItem(atPath: f.directory.path + "/" + finalized.file)
        let legacy = try XCTUnwrap(reader.localTagSnapshots(range: .init(start: 120, end: 130)).first)
        XCTAssertEqual(legacy.timing.shardID, finalized.id)
        XCTAssertNil(legacy.tags, "Missing legacy tags must remain unknown metadata")
        XCTAssertThrowsError(try reader.localTagSnapshots(range: .init(start: 130, end: 120)))
    }
    func testManifestLossNeverScansOrBackfillsOldFootage() throws {
        let f = try fixture(), databasePath = f.directory.path + "/" + LocalRecordingManifest.filename
        var db: LocalRecordingManifest? = try f.open()
        let old = try recorded(f, db!)
        db = nil
        try FileManager.default.removeItem(atPath: databasePath)
        db = try f.open()
        XCTAssertTrue(try db!.recordings().isEmpty)
        XCTAssertTrue(try db!.coverage(from: 0, to: 1000).available.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.directory.path + "/" + old.file))
        try recorded(f, db!, number: 2, start: 200)
        XCTAssertEqual(try db!.recordings().count, 1)
    }
    private func completion(_ f: Fixture, timing: ShardTimingMetadata, filename: String,
                            name: String = "Old name", updatedAt: Double = 100) throws -> LocalRecordingManifest.Completion {
        let path = f.directory.path + "/" + filename
        try SecureFiles.atomicWrite(Data([1, 2, 3]), to: path, mode: 0o600)
        var info = stat(); XCTAssertEqual(lstat(path, &info), 0)
        return .init(seed: .init(temporaryName: filename + ".recording", finalName: filename, timing: timing,
                                camera: .init(name: name, homebaseDeviceID: "camera-one", updatedAt: updatedAt)),
                     endTicks: 900000, frames: 150, file: .init(info))
    }
    func testRetainedCompletionInsertsMissingRowAndIsIdempotentWithoutRevertingCameraMetadata() throws {
        let f = try fixture(), db = try f.open(), id = UUID().uuidString
        var value = try completion(f, timing: timing(f, id: id, start: 100), filename: "2026-09-17_12-00-01.mp4")
        value.tags = try VideoTagsTests().timeline()
        try recorded(f, db, number: 2, start: 200, metadata: .init(name: "New name", homebaseDeviceID: "camera-two", updatedAt: 200))
        try db.completeRetained(value); try db.completeRetained(value)
        var conflict = value
        conflict.tags?.changes[0] = .init(ticks: 0, frame: 0, tags: ["changed": "must-not-overwrite"])
        XCTAssertThrowsError(try db.completeRetained(conflict))
        let rows = try db.recordings()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first?.id, id); XCTAssertEqual(rows.first?.state, .complete)
        XCTAssertEqual(rows.first?.frames, 150)
        XCTAssertEqual(try db.cameraMetadata()?.name, "New name")
        XCTAssertEqual(try db.cameraMetadata()?.homebaseDeviceID, "camera-two")
    }
    func testRetainedCompletionRecoversProvisionalRowsWithoutInterruptingActiveRecording() throws {
        for interrupted in [false, true] {
            let f = try fixture(), db = try f.open()
            let old = try recorded(f, db, complete: false)
            let row = try XCTUnwrap(db.recordings().first)
            if interrupted { try db.interrupt(id: old.id) }
            let active = try recorded(f, db, number: 2, start: 200, complete: false)
            let value = try completion(f, timing: row.timing, filename: old.file)
            let retry = try LocalRecordingManifest(directory: f.directory, identity: f.identity, owner: geteuid(), recoverInterrupted: false)
            try retry.completeRetained(value); try retry.completeRetained(value)
            let rows = try db.recordings()
            XCTAssertEqual(rows.first { $0.id == old.id }?.state, .complete)
            XCTAssertEqual(rows.first { $0.id == active.id }?.state, .recording)
            try db.progress(id: active.id, endTicks: 1000000, frames: 160)
        }
    }
    func testRetainedCompletionRefusesConflictsAndChangedMedia() throws {
        let f = try fixture(), db = try f.open(), old = try recorded(f, db, complete: false)
        let row = try XCTUnwrap(db.recordings().first)
        let value = try completion(f, timing: row.timing, filename: old.file)
        let conflict = LocalRecordingManifest.Completion(seed: .init(temporaryName: old.file + ".recording", finalName: old.file,
            timing: try timing(f, id: old.id, start: 200), camera: value.seed.camera), endTicks: 900000, frames: 150, file: value.file)
        XCTAssertThrowsError(try db.completeRetained(conflict))
        let wrong = LocalRecordingManifest.Completion(seed: value.seed, endTicks: 900001, frames: 150, file: value.file)
        try db.completeRetained(value)
        XCTAssertThrowsError(try db.completeRetained(wrong))
        try SecureFiles.atomicWrite(Data([4, 5, 6]), to: f.directory.path + "/" + old.file, mode: 0o600)
        XCTAssertThrowsError(try db.completeRetained(value)) // Same size, different inode.
        XCTAssertEqual(try db.recordings().first?.endTicks, 900000)
    }
    func testInitialSchemaRequiresTimingAndRoundTripsWithoutCameraClock() throws {
        let f = try fixture(), path = f.directory.path + "/" + LocalRecordingManifest.filename
        var db: LocalRecordingManifest? = try f.open()
        let row = try recorded(f, db!)
        db = nil
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &raw), SQLITE_OK)
        defer { sqlite3_close(raw) }
        var version: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(raw, "PRAGMA user_version", -1, &version, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(version), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int64(version, 0), LocalRecordingManifest.schemaVersion)
        sqlite3_finalize(version)
        for column in ["received_utc", "canonical_source", "timing_json"] {
            XCTAssertEqual(sqlite3_exec(raw, "UPDATE recordings SET \(column)=NULL", nil, nil, nil), SQLITE_CONSTRAINT, column)
        }
        XCTAssertEqual(sqlite3_exec(raw, "UPDATE recordings SET canonical_source='unknown'", nil, nil, nil), SQLITE_CONSTRAINT)
        let reader = try f.open(readOnly: true), stored = try XCTUnwrap(reader.recordings().first)
        XCTAssertEqual(stored.id, row.id); XCTAssertEqual(stored.start, 100)
        XCTAssertNil(stored.timing.time.cameraUTC)
        XCTAssertEqual(stored.timing.time.receivedUTC, 100)
        XCTAssertEqual(stored.timing.time.canonicalSource, .received)
        XCTAssertEqual(try reader.coverage(from: 95, to: 115).available, [.init(start: 100, end: 110)])
    }
    func testTimingIdentityMismatchRejectedBeforeInsertion() throws {
        let f = try fixture(), db = try f.open(), sample = media(timestamp: 0, time: 1000, uptime: 50)
        var timeline = RecordingTimeline()
        let timing = ShardTimingMetadata(storeID: f.identity.storeID, cameraID: f.identity.cameraID,
            media: sample, time: try timeline.observe(sample))
        XCTAssertThrowsError(try db.begin(id: UUID().uuidString, temporaryName: "test.mp4.recording", finalName: "test.mp4",
            start: sample.receivedAt, timescale: 90000, sourceTimestamp: 0, timing: timing))
        XCTAssertTrue(try db.recordings().isEmpty)
    }
    func testMissingOrReplacedOrTruncatedFilesAreNotCoverage() throws {
        let f = try fixture(), db = try f.open()
        let first = try recorded(f, db), second = try recorded(f, db, number: 2, start: 120)
        let third = try recorded(f, db, number: 3, start: 140)
        try FileManager.default.removeItem(atPath: f.directory.path + "/" + first.file)
        try SecureFiles.atomicWrite(Data([9, 8, 7]), to: f.directory.path + "/" + second.file, mode: 0o600)
        let fd = open(f.directory.path + "/" + third.file, O_WRONLY | O_TRUNC); XCTAssertGreaterThanOrEqual(fd, 0); close(fd)
        XCTAssertTrue(try db.coverage(from: 0, to: 1000).available.isEmpty)
        XCTAssertEqual(try db.recordings().count, 3) // no silent reconstruction or row promotion
        try db.remove(filename: first.file)
        XCTAssertEqual(try db.recordings().count, 2)
    }
    func testDatesAndNamesAreNotUsedToInferCaptureTime() throws {
        let f = try fixture(), db = try f.open()
        let record = try recorded(f, db, start: 1234)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1), .modificationDate: Date()],
                                             ofItemAtPath: f.directory.path + "/" + record.file)
        XCTAssertEqual(try db.coverage(from: 1234, to: 1244).available, [.init(start: 1234, end: 1244)])
    }
    func testUnsafeDatabaseAndJournalFilesAreRefusedWithoutFollowingLinks() throws {
        for suffix in ["", "-journal", "-wal", "-shm"] {
            let f = try fixture(), path = f.directory.path + "/" + LocalRecordingManifest.filename
            do { _ = try f.open() }
            if suffix.isEmpty { try FileManager.default.removeItem(atPath: path) }
            let outside = f.root + "/untouched"
            try SecureFiles.atomicWrite(Data([4, 5, 6]), to: outside, mode: 0o600)
            XCTAssertEqual(symlink(outside, path + suffix), 0)
            XCTAssertThrowsError(try f.open(), suffix)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: outside)), Data([4, 5, 6]))
        }
    }
    func testCorruptAndForeignManifestArePreservedNotReset() throws {
        let f = try fixture(), path = f.directory.path + "/" + LocalRecordingManifest.filename
        let damaged = Data("not SQLite".utf8)
        try SecureFiles.atomicWrite(damaged, to: path, mode: 0o600)
        XCTAssertThrowsError(try f.open())
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), damaged)
        try FileManager.default.removeItem(atPath: path)
        do { _ = try f.open() }
        XCTAssertThrowsError(try LocalRecordingManifest(directory: f.directory,
            identity: .init(storeID: UUID().uuidString, cameraID: f.identity.cameraID), owner: geteuid()))
        XCTAssertTrue(try f.open().recordings().isEmpty)
    }
    func testUnknownSchemaAndWriteFailureDoNotEraseHistory() throws {
        let f = try fixture(), path = f.directory.path + "/" + LocalRecordingManifest.filename
        var db: LocalRecordingManifest? = try f.open()
        try recorded(f, db!)
        // Simulate an independent inspector holding a write transaction.
        var other: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &other), SQLITE_OK)
        defer { sqlite3_close(other) }
        XCTAssertEqual(sqlite3_exec(other, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try recorded(f, db!, number: 2)) { error in
            let message = (error as? ServiceError)?.message ?? ""
            XCTAssertTrue(message.contains("SQLite 5, extended 5"))
            XCTAssertTrue(message.contains("begin failed"))
        }
        XCTAssertEqual(sqlite3_exec(other, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(try db!.recordings().count, 1)
        db = nil
        XCTAssertEqual(sqlite3_exec(other, "PRAGMA user_version=999", nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try f.open())
    }
    func testDeletedOpenDatabaseFailsExplicitlyInsteadOfWritingAnInvisibleIndex() throws {
        let f = try fixture(), db = try f.open()
        try FileManager.default.removeItem(atPath: f.directory.path + "/" + LocalRecordingManifest.filename)
        XCTAssertThrowsError(try recorded(f, db))
        XCTAssertThrowsError(try db.recordings())
    }
    func testInvalidNamesAndRegressingProgressAreRejected() throws {
        let f = try fixture(), db = try f.open(), id = UUID().uuidString
        XCTAssertThrowsError(try db.begin(id: id, temporaryName: "../bad.mp4.recording", finalName: "../bad.mp4",
            start: Date(timeIntervalSince1970: 100), timescale: 90000, sourceTimestamp: UInt32.max - 10,
            timing: timing(f, id: id, start: 100)))
        let row = try recorded(f, db, complete: false)
        XCTAssertThrowsError(try db.progress(id: row.id, endTicks: 1, frames: 1))
        XCTAssertEqual(try db.recordings().first?.frames, 150)
    }

    func testClockUnwrapsRTPAndUsesSourceTimingNotWriterQueueTime() throws {
        var clock = LocalRecordingClock()
        let first = try clock.observe(media(timestamp: UInt32.max - 10, time: 1000, uptime: 50))
        let second = try clock.observe(media(timestamp: 9, time: 1000.1, uptime: 50.1))
        XCTAssertEqual(first.time.timeIntervalSince1970, 1000)
        XCTAssertEqual(second.time.timeIntervalSince1970, 1000 + 20.0 / 90000, accuracy: 0.000001)
        XCTAssertFalse(second.discontinuity)
        XCTAssertThrowsError(try clock.observe(media(timestamp: 9, time: 1000.2, uptime: 50.2)))
    }
    func testClockMarksSourceGapsAndWallClockStepsAsDiscontinuities() throws {
        var clock = LocalRecordingClock()
        _ = try clock.observe(media(timestamp: 0, time: 1000, uptime: 50))
        let gap = try clock.observe(media(timestamp: 900000, time: 1010, uptime: 60))
        XCTAssertTrue(gap.discontinuity)
        XCTAssertEqual(gap.time.timeIntervalSince1970, 1010)
        let step = try clock.observe(media(timestamp: 906000, time: 1310, uptime: 60.066))
        XCTAssertTrue(step.discontinuity)
        XCTAssertEqual(step.time.timeIntervalSince1970, 1310)
    }
    private func timing(_ fixture: Fixture, id: String, start: Double) throws -> ShardTimingMetadata {
        let sample = media(timestamp: UInt32.max - 10, time: start, uptime: 50)
        var timeline = RecordingTimeline()
        return ShardTimingMetadata(storeID: fixture.identity.storeID, cameraID: fixture.identity.cameraID,
            shardID: id, media: sample, time: try timeline.observe(sample))
    }
    private func media(timestamp: UInt32, time: Double, uptime: Double) -> EncodedMedia {
        EncodedMedia(codec: "H264", clockRate: 90000, parameterSets: [],
                     frame: .init(payload: Data(), timestamp: timestamp, keyFrame: true),
                     receivedAt: Date(timeIntervalSince1970: time), receivedUptime: uptime)
    }
    func testRealShardsAreIndexedProspectivelyWithExactMediaMappingAndStopGap() throws {
        let f = try fixture()
        var config = f.config; config.shardDuration = "1s"
        let store = try LocalRecordingStore(configuration: config)
        let frames = try StoreTests.video(count: 45), base: Double = 1_800_000_000
        for (index, frame) in frames.enumerated() {
            let offset = Double(index) / 15
            let anchored = EncodedMedia(codec: frame.codec, clockRate: frame.clockRate, parameterSets: frame.parameterSets,
                frame: frame.frame, receivedAt: Date(timeIntervalSince1970: base + offset), receivedUptime: 100 + offset)
            store.accept(.media(camera: f.identity.cameraID, name: "Test Camera", anchored))
        }
        store.accept(.end(camera: f.identity.cameraID))
        for (index, frame) in frames.prefix(15).enumerated() {
            let offset = Double(index) / 15
            let anchored = EncodedMedia(codec: frame.codec, clockRate: frame.clockRate, parameterSets: frame.parameterSets,
                frame: frame.frame, receivedAt: Date(timeIntervalSince1970: base + 10 + offset), receivedUptime: 110 + offset)
            store.accept(.media(camera: f.identity.cameraID, name: "Test Camera", anchored))
        }
        XCTAssertTrue(store.finish(timeout: 10))
        XCTAssertNil(store.snapshot().lastError)
        let db = try f.open(readOnly: true), rows = try db.recordings()
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.map(\.start), [base, base + 1, base + 2, base + 10])
        XCTAssertEqual(rows.map(\.endTicks), [90000, 90000, 90000, 90000])
        XCTAssertTrue(rows.allSatisfy { $0.state == .complete && $0.frames == 15 && $0.timescale == 90000 })
        XCTAssertEqual(try db.coverage(from: base, to: base + 11).gaps, [.init(start: base + 3, end: base + 10)])
    }
    func testRetentionDeletesKnownRowsWithoutCreatingManifestForLegacyFiles() throws {
        let f = try fixture()
        var db: LocalRecordingManifest? = try f.open()
        let row = try recorded(f, db!)
        db = nil
        let path = f.directory.path + "/" + row.file
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: path)
        var config = f.config; config.enabled = false; config.shardDuration = "1s"; config.retentionPeriod = "1s"
        let store = try LocalRecordingStore(configuration: config)
        let deadline = Date().addingTimeInterval(3)
        while FileManager.default.fileExists(atPath: path), Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertTrue(store.finish(timeout: 5))
        XCTAssertNil(store.snapshot().lastError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(try f.open(readOnly: true).recordings().isEmpty)
    }
}
