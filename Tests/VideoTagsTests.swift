import XCTest
import Foundation
import SQLite3

final class VideoTagsTests: XCTestCase {
    func timeline() throws -> VideoTagTimeline {
        var value = VideoTagAccumulator()
        try value.append(["opaque": "", "another": "value"], ticks: 0, frame: 0)
        try value.append(["opaque": "", "another": "value"], ticks: 6000, frame: 1)
        try value.append(["opaque": "new"], ticks: 12000, frame: 2)
        try value.append([:], ticks: 18000, frame: 3)
        return value.timeline
    }
    func testOpaqueValuesBoundsAndEmptyValueDiffersFromAbsence() throws {
        try VideoTags.validate(["namespaced.anything": "", "unicode 🐈": "\n\u{0}value"])
        XCTAssertThrowsError(try VideoTags.validate(["": "value"]))
        XCTAssertThrowsError(try VideoTags.validate([String(repeating: "x", count: 257): "value"]))
        XCTAssertThrowsError(try VideoTags.validate(["x": String(repeating: "🐈", count: 513)]))
        XCTAssertThrowsError(try VideoTags.validate(Dictionary(uniqueKeysWithValues: (0..<33).map { (String($0), "") })))
        XCTAssertThrowsError(try VideoTags.validate(Dictionary(uniqueKeysWithValues: (0..<8).map { (String($0), String(repeating: "x", count: 2048)) })))
        let value = try timeline()
        XCTAssertEqual(value.changes.count, 3)
        XCTAssertEqual(value.tags(at: 11999)?["opaque"], "")
        XCTAssertEqual(value.tags(at: 12000), ["opaque": "new"])
        XCTAssertEqual(value.tags(at: 18000), [:])
        XCTAssertNil(value.tags(at: -1))
    }
    func testBoundedMetadataChurnMarksUnknownInsteadOfInventingEmptyTags() throws {
        var value = VideoTagAccumulator(), overflows = 0
        for index in 0..<5000 {
            if try value.append(["key": String(index)], ticks: Int64(index), frame: Int64(index)) { overflows += 1 }
        }
        XCTAssertEqual(overflows, 1)
        let boundary = try XCTUnwrap(value.timeline.unknownFromTicks)
        XCTAssertNotNil(value.timeline.tags(at: boundary - 1))
        XCTAssertNil(value.timeline.tags(at: boundary))
        try value.timeline.validate()
    }
    func testPrivateMP4BoxRoundTripSkipsOtherBoxesAndRejectsMalformedMetadata() throws {
        let value = try timeline(), box = try VideoTagMP4.box(value)
        let prefix = Data([0,0,0,12]) + Data("free".utf8) + Data([1,2,3,4])
        XCTAssertEqual(try VideoTagMP4.read(prefix + box), value)
        XCTAssertEqual(try VideoTagMP4.read((Data([0]) + box).dropFirst()), value)
        XCTAssertNil(try VideoTagMP4.read(prefix))
        XCTAssertThrowsError(try VideoTagMP4.read(box + box))
        XCTAssertThrowsError(try VideoTagMP4.read(box.dropLast()))
        var bad = value; bad.changes.append(.init(ticks: 1, frame: 0, tags: [:]))
        XCTAssertThrowsError(try bad.validate())
    }
    func testFrozenEncryptedTagsRemainSecretInSidecarsAndRoundTrip() throws {
        let value = try timeline(), stored = try StoredVideoTags.freeze(value, password: "tag-test-password")
        try stored.validate()
        let data = try JSONEncoder().encode(stored)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("opaque"))
        let reloaded = try JSONDecoder().decode(StoredVideoTags.self, from: data)
        XCTAssertEqual(reloaded, stored)
        let decrypted = try RecordingEncryption.decrypt(XCTUnwrap(reloaded.encrypted), password: "tag-test-password")
        XCTAssertEqual(try JSONDecoder().decode(VideoTagTimeline.self, from: decrypted), value)
        XCTAssertThrowsError(try RecordingEncryption.decrypt(XCTUnwrap(reloaded.encrypted), password: "wrong"))
    }
    func testLocalManifestCheckpointsAndCompletionKeepTags() throws {
        let helper = LocalManifestTests(), f = try helper.fixture(), db = try f.open()
        defer { try? FileManager.default.removeItem(atPath: f.root) }
        let row = try helper.recorded(f, db, complete: false), tags = try timeline()
        try db.progress(id: row.id, endTicks: 900000, frames: 150, tags: tags)
        try SecureFiles.atomicWrite(Data([1, 2, 3]), to: f.directory.path + "/" + row.file, mode: 0o600)
        try db.complete(id: row.id, filename: row.file, endTicks: 900000, frames: 150, tags: tags)
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(f.directory.path + "/" + LocalRecordingManifest.filename, &raw, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(raw) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(raw, "SELECT tags_json FROM recordings", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        let json = String(cString: sqlite3_column_text(statement, 0))
        XCTAssertEqual(try JSONDecoder().decode(VideoTagTimeline.self, from: Data(json.utf8)), tags)
    }
    func testMissingOldCameraTagsDecodeAsEmptyAndRoundTripPersistedState() throws {
        var camera = CameraConfiguration(name: "Test", ipAddress: "127.0.0.1", credentials: nil)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: CameraJSON.encode(camera)) as? [String: Any])
        object.removeValue(forKey: "Tags")
        XCTAssertEqual(try JSONDecoder().decode(CameraConfiguration.self, from: JSONSerialization.data(withJSONObject: object)).tags, [:])
        camera.tags = ["anything": ""]
        XCTAssertEqual(try JSONDecoder().decode(CameraConfiguration.self, from: CameraJSON.encode(camera)), camera)
    }
    func testVersionTwoManifestUpgradePreservesOldRowsAsUnknown() throws {
        let helper = LocalManifestTests(), f = try helper.fixture()
        defer { try? FileManager.default.removeItem(atPath: f.root) }
        do { let db = try f.open(); try helper.recorded(f, db) }
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(f.directory.path + "/" + LocalRecordingManifest.filename, &raw), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(raw, "ALTER TABLE recordings DROP COLUMN tags_json; PRAGMA user_version=2", nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)
        do { let db = try f.open(); XCTAssertEqual(try db.recordings().count, 1) }
        XCTAssertEqual(sqlite3_open(f.directory.path + "/" + LocalRecordingManifest.filename, &raw), SQLITE_OK)
        defer { sqlite3_close(raw) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(raw, "SELECT tags_json FROM recordings", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_type(statement, 0), SQLITE_NULL)
    }
    func testLargeTagEnvelopeSurvivesSpoolAndManifestRestartWithoutPlaintextLeak() throws {
        let helper = S3PlaybackManifestTests(), root = try helper.root()
        defer { try? FileManager.default.removeItem(atPath: root) }
        var config = try helper.config(); config.s3?.clientEncryption = .init(password: "tag-secret")
        let camera = UUID().uuidString, at = 1_789_732_800.0
        var accumulator = VideoTagAccumulator()
        for index in 0..<180 {
            try accumulator.append(["private": "marker-" + String(index) + String(repeating: "x", count: 1000)],
                ticks: Int64(index * 6000), frame: Int64(index))
        }
        let bytes = try RecordingEncryption.encrypt(Data([1,2,3]), password: "tag-secret")
        let original = helper.shard(config, camera: camera, at: at)
        var metadata = S3ObjectMetadata.make(store: config, camera: camera, name: "Test", capturedAt: Date(timeIntervalSince1970: at),
            data: bytes, encrypted: true, id: original.id)
        metadata.timing = original.timing; metadata.endTicks = original.endTicks
        metadata.tagMetadata = try StoredVideoTags.freeze(accumulator.timeline, password: "tag-secret")
        let spoolPath = root + "/spool"
        let spool = try S3Spool(path: spoolPath, storeID: config.id, settings: config.s3!.settings)
        let entry = try spool.publish(metadata, data: bytes)
        let json = try Data(contentsOf: URL(fileURLWithPath: entry.directory + "/metadata.json"))
        XCTAssertGreaterThan(json.count, 65536)
        XCTAssertFalse(String(decoding: json, as: UTF8.self).contains("marker-"))
        let reopened = try S3Spool(path: spoolPath, storeID: config.id, settings: config.s3!.settings)
        XCTAssertEqual(reopened.entries[metadata.id]?.metadata, metadata)
        let queue = DispatchQueue(label: "tag-manifest-test"), transport = ManifestTransport()
        let publisher = S3PlaybackPublisher(configuration: config, path: root + "/index", queue: queue, factory: { _ in transport })
        try publisher.record(metadata); try publisher.record(metadata)
        let restored = S3PlaybackPublisher(configuration: config, path: root + "/index", queue: queue, factory: { _ in transport })
        XCTAssertEqual(restored.entries[metadata.id]?.shard.tagMetadata, metadata.tagMetadata)
        let day = S3PlaybackPublisher.day(at)
        XCTAssertEqual(restored.document(.init(camera: camera, period: day), at: Date()).shards?.first?.tagMetadata, metadata.tagMetadata)
    }
    func testRepairPreservesEmbeddedTagsAndLeavesLegacyUnknown() async throws {
        let helper = S3ThumbnailTests(), config = try S3Tests().config(), camera = UUID().uuidString
        let samples = try helper.fixture(config, camera: camera), first = samples[0]
        let timing = ShardTimingMetadata(storeID: config.id, cameraID: camera, media: first, time: first.time!)
        let writer = try MemoryMP4Shard(codec: first.codec, sets: first.parameterSets, clock: first.clockRate,
            timestamp: first.frame.timestamp, timing: timing)
        for (index, sample) in samples.enumerated() { try writer.append(sample.frame, tags: index < 10 ? ["annotation": "first"] : [:]) }
        let data = try writer.finish(), tagBox = try VideoTagMP4.box(writer.tagTimeline)
        for encrypted in [false, true] {
            let bytes = try encrypted ? RecordingEncryption.encrypt(data, password: "old-tag-password") : data
            let object = S3ObjectMetadata.make(store: config, camera: camera, name: "Test", capturedAt: first.receivedAt,
                data: bytes, encrypted: encrypted, id: timing.shardID)
            let candidate = try XCTUnwrap(S3RepairCandidate.parse(.init(key: object.key, size: object.size, etag: "test"), prefix: config.s3!.prefix, cameras: [camera]))
            let repaired = try await S3RepairMedia.inspect(bytes, candidate: candidate, store: config, passwords: ["old-tag-password"])
            let restored: VideoTagTimeline?
            if encrypted {
                let decoded = try RecordingEncryption.decrypt(XCTUnwrap(repaired.tagMetadata?.encrypted), password: "old-tag-password")
                restored = try JSONDecoder().decode(VideoTagTimeline.self, from: decoded)
                XCTAssertNil(repaired.tagMetadata?.timeline)
            } else { restored = repaired.tagMetadata?.timeline }
            XCTAssertEqual(restored, writer.tagTimeline)
        }
        let legacy = Data(data.dropLast(tagBox.count))
        let object = S3ObjectMetadata.make(store: config, camera: camera, name: "Test", capturedAt: first.receivedAt,
            data: legacy, id: timing.shardID)
        let candidate = try XCTUnwrap(S3RepairCandidate.parse(.init(key: object.key, size: object.size, etag: "test"), prefix: config.s3!.prefix, cameras: [camera]))
        let repaired = try await S3RepairMedia.inspect(legacy, candidate: candidate, store: config, passwords: [])
        XCTAssertNil(repaired.tagMetadata)
    }
}
