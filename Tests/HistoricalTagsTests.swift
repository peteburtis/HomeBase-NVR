import XCTest
import Foundation
import Darwin
import SQLite3
import AVFoundation

private actor HistoricalMemoryReader: S3RepairReading {
    let bytes: Data
    var reads = 0
    init(_ bytes: Data) { self.bytes = bytes }
    func list(after: String?) async throws -> S3RepairPage { XCTFail("Tag editing must not list S3"); throw S3RepairFailure.unavailable }
    func read(_ object: S3RepairObject) async throws -> Data { throw S3RepairFailure.unavailable }
    func readIndexed(_ shard: S3PlaybackShard) async throws -> Data { reads += 1; return bytes }
}

final class HistoricalTagsTests: XCTestCase {
    func testFiniteOverridesPreserveOtherKeysRestorePriorValuesAndCoalesce() throws {
        var tags = VideoTagTimeline(changes: [.init(ticks: 0, frame: 0, tags: ["a": "old", "b": "untouched"]),
            .init(ticks: 100, frame: 10, tags: ["a": "later", "b": "untouched"])])
        try tags.apply(.init(start: 50, end: 150, key: "a", value: "new"))
        XCTAssertEqual(tags.tags(at: 49)?["a"], "old")
        XCTAssertEqual(tags.tags(at: 50)?["a"], "new")
        XCTAssertEqual(tags.tags(at: 149)?["a"], "new")
        XCTAssertEqual(tags.tags(at: 150)?["a"], "later")
        try tags.apply(.init(start: 70, end: 120, key: "a", value: nil))
        XCTAssertNil(tags.tags(at: 100)?["a"])
        XCTAssertEqual(tags.tags(at: 100)?["b"], "untouched")
        XCTAssertEqual(tags.tags(at: 120)?["a"], "new")
        let before = tags
        for _ in 0..<100 { try tags.apply(.init(start: 70, end: 120, key: "a", value: nil)) }
        XCTAssertEqual(tags, before)
        XCTAssertEqual(tags.overrides?.count, 3)
        XCTAssertEqual(try VideoTagMP4.read(VideoTagMP4.box(tags)), tags)
    }
    func testUnknownLegacyStateIsNotFabricatedAndRemovalsAreKnown() throws {
        var tags = VideoTagTimeline.unknown
        try tags.apply(.init(start: 10, end: 20, key: "person.alice", value: ""))
        XCTAssertNil(tags.tags(at: 15))
        XCTAssertEqual(tags.state(at: 15).values, ["person.alice": ""])
        XCTAssertFalse(tags.state(at: 15).complete)
        XCTAssertTrue(tags.state(at: 20).values.isEmpty)
        try tags.apply(.init(start: 12, end: 18, key: "person.alice", value: nil))
        XCTAssertEqual(tags.state(at: 15).knownAbsent, ["person.alice"])
        let frozen = try StoredVideoTags.freeze(tags, password: "secret")
        XCTAssertEqual(try frozen.thaw(password: "secret"), tags)
        XCTAssertThrowsError(try frozen.thaw(password: "wrong"))
        XCTAssertThrowsError(try frozen.thaw(password: nil))
    }
    func testJSONDefaultsValidationAndNoOverflowOnBadInput() throws {
        let job = UUID().uuidString, store = UUID().uuidString, camera = UUID().uuidString
        let json = """
        {"jobID":"\(job)","storeIDs":["\(store)"],"edits":[{"selection":{"cameraID":"\(camera)","start":{"timestamp":100},"end":{"timestamp":110}},"key":"test"}]}
        """
        let request = try JSONDecoder().decode(HistoricalTagRequest.self, from: Data(json.utf8))
        try request.validate()
        XCTAssertFalse(request.dryRun); XCTAssertFalse(request.inspect)
        XCTAssertEqual(request.edits[0].selection.timeline, .canonical)
        XCTAssertEqual(request.edits[0].selection.start?.frameOffset, 0)
        XCTAssertNil(request.edits[0].value)
        var bad = request.edits[0].selection; bad.start = .init(timestamp: .infinity)
        XCTAssertThrowsError(try HistoricalTagRequest(jobID: job, storeIDs: [store], edits: [.init(selection: bad, key: "x")]).validate())
        bad = .init(file: "/managed/file.mp4")
        XCTAssertThrowsError(try HistoricalTagRequest(jobID: job, storeIDs: [store], edits: [.init(selection: bad, key: "x")]).validate())
        XCTAssertThrowsError(try HistoricalTags.frameBoundary(Int.max, ticks: [0, 100], end: 200))
        XCTAssertEqual(try HistoricalTags.ticks(1_790_000_000 + 12000.0 / 90000, anchor: 1_790_000_000, timescale: 90000, end: 90000), 12000)
    }

    struct Fixture {
        let root: String, camera: String
        let configs: [RecordingStoreConfiguration]
        let manager: RecordingStoreManager
        let samples: [EncodedMedia]
        func engine() -> HistoricalTagEngine {
            .init(configs: configs, manager: manager, factory: { _, _ in throw ServiceError("Unexpected network read") },
                  credentials: nil, password: nil, cancellation: Cancellation())
        }
        func index(_ number: Int = 0) throws -> (LocalRecordingLayout.Directory, LocalRecordingManifest) {
            let config = configs[number], path = config.directory + "/Camera"
            let directory = LocalRecordingLayout.Directory(path: path, fd: try StoreDirectory.openDirectory(path))
            return (directory, try LocalRecordingManifest(directory: directory, identity: .init(storeID: config.id, cameraID: camera), owner: geteuid(), readOnly: true))
        }
    }
    func fixture(stores: Int = 1, codec: CMVideoCodecType = kCMVideoCodecType_H264) throws -> Fixture {
        let root = "/private/tmp/hbnvr-history-tags-" + UUID().uuidString
        try SecureFiles.ensureDirectory(root, owner: geteuid(), mode: 0o700)
        let configs = try (0..<stores).map { try StoreTests().config(root + "/store\($0)") }
        let manager = RecordingStoreManager(spoolRoot: root + "/spool")
        for config in configs { try manager.install(config) }
        let camera = UUID().uuidString, start = Date().timeIntervalSince1970 - 3600
        var timeline = RecordingTimeline(), samples: [EncodedMedia] = []
        for original in try StoreTests.video(codec: codec) {
            let elapsed = Double(original.frame.timestamp) / Double(original.clockRate)
            var sample = EncodedMedia(codec: original.codec, clockRate: original.clockRate, parameterSets: original.parameterSets, frame: original.frame,
                receivedAt: Date(timeIntervalSince1970: start + elapsed), receivedUptime: 100 + elapsed,
                cameraUTC: start - 1 + elapsed, ssrc: 42, tags: ["original": "yes"])
            sample.time = try timeline.observe(sample); samples.append(sample)
            manager.accept(.media(camera: camera, name: "Camera", sample))
        }
        manager.accept(.end(camera: camera)); try manager.drain(timeout: 30)
        addTeardownBlock { _ = manager.stop(); try? FileManager.default.removeItem(atPath: root) }
        return Fixture(root: root, camera: camera, configs: configs, manager: manager, samples: samples)
    }
    func testRealLocalFileFrameEditRewritesOnlyFooterAndIndexAndIsIdempotent() async throws {
        for codec in [kCMVideoCodecType_H264, kCMVideoCodecType_HEVC] {
            let f = try fixture(codec: codec), (dir, db) = try f.index(), row = try XCTUnwrap(db.recordings().first)
            let path = dir.path + "/" + row.filename, old = try Data(contentsOf: URL(fileURLWithPath: path))
            let oldTags = try XCTUnwrap(db.historicalTags(id: row.id)), prefix = old.dropLast(try VideoTagMP4.box(oldTags).count)
            let selection = HistoricalTagRequest.Selection(file: path, startFrame: 3, endFrame: 9)
            let request = HistoricalTagRequest(jobID: UUID().uuidString, storeIDs: [f.configs[0].id], edits: [.init(selection: selection, key: "recognized", value: "alice")])
            let (result, _) = try await f.engine().run(request) { _ in }
            XCTAssertEqual(result.state, "completed"); XCTAssertEqual(result.results.first?.publication, "local-complete")
            let new = try Data(contentsOf: URL(fileURLWithPath: path)), tags = try XCTUnwrap(VideoTagMP4.read(new))
            XCTAssertEqual(new.dropLast(try VideoTagMP4.box(tags).count), prefix)
            XCTAssertEqual(tags.tags(at: 18000)?["recognized"], "alice")
            XCTAssertNil(tags.tags(at: 12000)?["recognized"])
            XCTAssertNil(tags.tags(at: 54000)?["recognized"])
            XCTAssertEqual(try db.historicalTags(id: row.id), tags)
            let replaced = try XCTUnwrap(db.recordings().first)
            XCTAssertNotEqual(replaced.inode, row.inode)
            let (again, _) = try await f.engine().run(request) { _ in }
            XCTAssertEqual(again.results.first?.changed, false)
            XCTAssertEqual(try db.recordings().first?.inode, replaced.inode)
            let source = LocalMediaProvider.Source(directory: dir, owner: geteuid(), row: replaced, range: .init(start: replaced.start, end: replaced.end))
            XCTAssertEqual(try LocalMediaReader.frameTicks(source, work: MediaWork()).count, f.samples.count)
        }
    }
    func testTimestampFrameOffsetsAllTimeBasesAndExplicitCrossStoreMapping() async throws {
        let f = try fixture(stores: 2), (dir, db) = try f.index(), row = try XCTUnwrap(db.recordings().first)
        let (_, other) = try f.index(1), otherRow = try XCTUnwrap(other.recordings().first)
        XCTAssertNotEqual(row.id, otherRow.id)
        for basis in [MediaTimeline.canonical, .camera, .received] {
            let start = try XCTUnwrap(basis.anchor(row.timing.time))
            let selection = HistoricalTagRequest.Selection(cameraID: f.camera, timeline: basis,
                start: .init(timestamp: start, frameOffset: 2), end: .init(timestamp: start, frameOffset: 5))
            let request = HistoricalTagRequest(jobID: UUID().uuidString, storeIDs: f.configs.map(\.id),
                edits: [.init(selection: selection, key: basis.rawValue, value: "set")])
            let (result, _) = try await f.engine().run(request) { _ in }
            XCTAssertEqual(result.results.count, 2)
            for index in [db, other] {
                let r = try XCTUnwrap(index.recordings().first), tags = try XCTUnwrap(index.historicalTags(id: r.id))
                XCTAssertNil(tags.tags(at: 6000)?[basis.rawValue])
                XCTAssertEqual(tags.tags(at: 12000)?[basis.rawValue], "set")
                XCTAssertNil(tags.tags(at: 30000)?[basis.rawValue])
            }
        }
        let selection = HistoricalTagRequest.Selection(file: dir.path + "/" + row.filename, startFrame: 10, endFrame: 15)
        let request = HistoricalTagRequest(jobID: UUID().uuidString, storeIDs: [f.configs[1].id], edits: [.init(selection: selection, key: "cross", value: "yes")])
        _ = try await f.engine().run(request) { _ in }
        XCTAssertNil(try db.historicalTags(id: row.id)?.tags(at: 60000)?["cross"])
        XCTAssertEqual(try other.historicalTags(id: otherRow.id)?.tags(at: 60000)?["cross"], "yes")
    }
    func testDryRunRevisionConflictAndInvalidBatchNeverChangeFile() async throws {
        let f = try fixture(), (dir, db) = try f.index(), row = try XCTUnwrap(db.recordings().first)
        let path = dir.path + "/" + row.filename, bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let selection = HistoricalTagRequest.Selection(file: path, allFrames: true)
        var request = HistoricalTagRequest(jobID: UUID().uuidString, storeIDs: [f.configs[0].id], edits: [.init(selection: selection, key: "x", value: "y")], dryRun: true)
        let (preview, _) = try await f.engine().run(request) { _ in }
        XCTAssertEqual(preview.results.first?.changed, true)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes)
        request.dryRun = false; request.expectedRevisions = [f.configs[0].id + "/" + row.id: "stale"]
        do { _ = try await f.engine().run(request) { _ in }; XCTFail("Expected conflict") } catch {}
        let bad = HistoricalTagRequest.Selection(file: path, startFrame: 0, endFrame: 1_000_000)
        let batch = HistoricalTagRequest(jobID: UUID().uuidString, storeIDs: [f.configs[0].id], edits: request.edits + [.init(selection: bad, key: "x", value: "z")])
        do { _ = try await f.engine().run(batch) { _ in }; XCTFail("Expected invalid frame") } catch {}
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes)
        XCTAssertEqual(try db.recordings().first?.inode, row.inode)
    }
    func testFrameLookaheadDoesNotRejectAnUnrelatedActiveShard() async throws {
        let f = try fixture(), (_, db) = try f.index(), row = try XCTUnwrap(db.recordings().first)
        let first = f.samples[0], time = row.timing.time
        let later = RecordingTime(cameraUTC: time.cameraUTC.map { $0 + 10 }, receivedUTC: time.receivedUTC + 10,
            canonicalUTC: time.canonicalUTC + 10, canonicalSource: time.canonicalSource, epochID: time.epochID)
        let active = EncodedMedia(codec: first.codec, clockRate: first.clockRate, parameterSets: first.parameterSets,
            frame: .init(payload: first.frame.payload, timestamp: first.frame.timestamp + 900000, keyFrame: true),
            receivedAt: Date(timeIntervalSince1970: later.receivedUTC), receivedUptime: first.receivedUptime + 10,
            cameraUTC: later.cameraUTC, ssrc: first.ssrc, time: later)
        f.manager.accept(.media(camera: f.camera, name: "Camera", active)); try f.manager.drain(timeout: 10)
        XCTAssertTrue(try db.recordings().contains { $0.state == .recording })
        let selection = HistoricalTagRequest.Selection(cameraID: f.camera,
            start: .init(timestamp: row.start, frameOffset: 2), end: .init(timestamp: row.start, frameOffset: 5))
        let request = HistoricalTagRequest(jobID: UUID().uuidString, storeIDs: [f.configs[0].id], edits: [.init(selection: selection, key: "x", value: "y")])
        let (result, _) = try await f.engine().run(request) { _ in }
        XCTAssertEqual(result.state, "completed")
        XCTAssertTrue(try db.recordings().contains { $0.state == .recording })
        let bad = HistoricalTagRequest.Selection(cameraID: f.camera, start: .init(timestamp: later.canonicalUTC), end: .init(timestamp: later.canonicalUTC + 1))
        do {
            _ = try await f.engine().run(.init(jobID: UUID().uuidString, storeIDs: [f.configs[0].id], edits: [.init(selection: bad, key: "bad", value: "y")])) { _ in }
            XCTFail("Active media was editable")
        } catch {}
    }
    func testLocalRecoveryOnBothSidesOfRename() throws {
        for alreadyRenamed in [false, true] {
            let f = try fixture(), (dir, reader) = try f.index(), row = try XCTUnwrap(reader.recordings().first)
            var tags = try XCTUnwrap(reader.historicalTags(id: row.id)); try tags.apply(.init(start: 0, end: row.endTicks, key: "recovered", value: "yes"))
            let source = LocalMediaProvider.Source(directory: dir, owner: geteuid(), row: row, range: .init(start: row.start, end: row.end))
            let pending = try LocalTagFile.stage(source: source, tags: tags, jobID: UUID().uuidString, work: MediaWork())
            // Inject the exact durable intent to simulate a process crash.
            var sql: OpaquePointer?, statement: OpaquePointer?
            XCTAssertEqual(sqlite3_open((dir.path + "/" + LocalRecordingManifest.filename), &sql), SQLITE_OK)
            defer { sqlite3_close(sql) }
            XCTAssertEqual(sqlite3_prepare_v2(sql, "INSERT INTO tag_edits VALUES (?,?)", -1, &statement, nil), SQLITE_OK)
            let json = String(decoding: try JSONEncoder().encode(pending), as: UTF8.self)
            row.id.withCString { _ = sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            json.withCString { _ = sqlite3_bind_text(statement, 2, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE); sqlite3_finalize(statement)
            if alreadyRenamed { XCTAssertEqual(renameat(dir.fd, pending.stagedName, dir.fd, pending.filename), 0) }
            let writer = try LocalRecordingManifest(directory: dir, identity: .init(storeID: f.configs[0].id, cameraID: f.camera), owner: geteuid(), recoverInterrupted: false)
            XCTAssertEqual(try writer.historicalTags(id: row.id), tags)
            XCTAssertEqual(try writer.recordings().first?.inode, pending.newFile.inode)
            XCTAssertEqual(try VideoTagMP4.read(Data(contentsOf: URL(fileURLWithPath: dir.path + "/" + row.filename))), tags)
            try writer.recoverTagEdits()
        }
    }
    func testS3ManifestOnlyEditSurvivesReplayRepairAndRestartWithoutMediaUpload() async throws {
        let helper = S3PlaybackManifestTests(), config = try helper.config(), camera = UUID().uuidString, root = try helper.root()
        let queue = DispatchQueue(label: "history-s3"), network = ManifestTransport()
        let publisher = S3PlaybackPublisher(configuration: config, path: root + "/index", queue: queue, factory: { _ in network })
        var metadata = helper.shard(config, camera: camera, at: Date().timeIntervalSince1970 - 86400)
        metadata.encryption = RecordingEncryption.format
        var tags = VideoTagTimeline(changes: [.init(ticks: 0, frame: 0, tags: ["admin": "false"])])
        metadata.tagMetadata = try .freeze(tags, password: "secret")
        try publisher.record(metadata)
        let original = try XCTUnwrap(publisher.entries[metadata.id]?.shard)
        try tags.apply(.init(start: 90000, end: 180000, key: "admin", value: "true"))
        var next = original; next.tagMetadata = try .freeze(tags, password: "secret"); next.tagRevision = UUID().uuidString
        try publisher.editTags([.init(expected: original, replacement: next)])
        XCTAssertEqual(next.key, original.key); XCTAssertEqual(next.sha256, original.sha256); XCTAssertEqual(next.size, original.size)
        try publisher.record(metadata) // late original completion must not revert edits
        XCTAssertEqual(publisher.entries[metadata.id]?.shard, next)
        XCTAssertThrowsError(try publisher.editTags([.init(expected: original, replacement: next)]))
        let journal = try Data(contentsOf: URL(fileURLWithPath: root + "/index/" + metadata.id + ".json"))
        XCTAssertFalse(String(decoding: journal, as: UTF8.self).contains("admin"))
        let restarted = S3PlaybackPublisher(configuration: config, path: root + "/index", queue: queue, factory: { _ in network })
        XCTAssertEqual(restarted.entries[metadata.id]?.shard, next)
        let day = S3PlaybackPublisher.day(next.start)
        XCTAssertEqual(restarted.document(.init(camera: camera, period: day), at: Date()).shards?.first?.tagRevision, next.tagRevision)
        XCTAssertEqual(restarted.document(.init(camera: camera, period: String(day.prefix(7))), at: Date()).shards?.first?.tagRevision, next.tagRevision)
    }
    func testS3TimestampOnlyEngineDoesNotReadObjects() async throws {
        let root = "/private/tmp/hbnvr-history-s3-" + UUID().uuidString
        try SecureFiles.ensureDirectory(root, owner: geteuid(), mode: 0o700)
        let config = try S3Tests().config(), camera = UUID().uuidString, network = FakeS3()
        let manager = RecordingStoreManager(spoolRoot: root + "/spool", transportFactory: { _ in network })
        defer { _ = manager.stop(); try? FileManager.default.removeItem(atPath: root) }
        try manager.install(config)
        let sink = try manager.repairSink(config: config, cameras: [camera], cameraStillExists: { _ in true })
        let metadata = S3PlaybackManifestTests().shard(config, camera: camera, at: Date().timeIntervalSince1970 - 120)
        _ = try await sink.merge(metadata, Cancellation())
        let start = metadata.timing!.time.canonicalUTC
        let request = HistoricalTagRequest(jobID: UUID().uuidString, storeIDs: [config.id], edits: [.init(selection: .init(cameraID: camera,
            start: .init(timestamp: start + 5), end: .init(timestamp: start + 10)), key: "person", value: "yes")])
        let engine = HistoricalTagEngine(configs: [config], manager: manager, factory: { _, _ in XCTFail("Unexpected media read"); throw ServiceError("Unexpected read") }, credentials: nil, password: nil, cancellation: Cancellation())
        let (result, _) = try await engine.run(request) { _ in }
        XCTAssertEqual(result.results.first?.publication, "s3-queued")
        let shard = try XCTUnwrap(manager.historicalS3(config.id).historicalShards().first)
        XCTAssertEqual(shard.tagMetadata?.timeline?.state(at: 450000).values["person"], "yes")
        XCTAssertFalse(shard.tagMetadata!.timeline!.state(at: 450000).complete)
        _ = try await sink.merge(metadata, Cancellation())
        XCTAssertEqual(try manager.historicalS3(config.id).historicalShards().first, shard)
    }
    func testS3RecoveryJournalRollsForwardAPartiallyWrittenBatch() throws {
        let helper = S3PlaybackManifestTests(), config = try helper.config(), root = try helper.root()
        let network = ManifestTransport(), queue = DispatchQueue(label: "history-recovery")
        let publisher = S3PlaybackPublisher(configuration: config, path: root + "/index", queue: queue, factory: { _ in network })
        let a = helper.shard(config, camera: UUID().uuidString, at: 1000), b = helper.shard(config, camera: UUID().uuidString, at: 1100)
        try publisher.record(a); try publisher.record(b)
        var tags = VideoTagTimeline.unknown; try tags.apply(.init(start: 0, end: 90000, key: "recovery", value: "yes"))
        let replacements = try [a, b].map { metadata -> S3PlaybackPublisher.TagReplacement in
            let old = try XCTUnwrap(publisher.entries[metadata.id]?.shard)
            var next = old; next.tagMetadata = try .freeze(tags, password: nil); next.tagRevision = UUID().uuidString
            return .init(expected: old, replacement: next)
        }
        publisher.checkpoint = { if $0 == "tag-record" { throw ServiceError("Injected crash after first record") } }
        XCTAssertThrowsError(try publisher.editTags(replacements))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/index/.tag-edit"))
        let restarted = S3PlaybackPublisher(configuration: config, path: root + "/index", queue: queue, factory: { _ in network })
        for replacement in replacements { XCTAssertEqual(restarted.entries[replacement.expected.id]?.shard, replacement.replacement) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/index/.tag-edit"))
    }
    func testMissingPathAndOversizedEditDoNotChangeManagedFootage() async throws {
        let f = try fixture(), (_, db) = try f.index(), row = try XCTUnwrap(db.recordings().first)
        let selection = HistoricalTagRequest.Selection(file: "/etc/passwd", allFrames: true)
        let request = HistoricalTagRequest(jobID: UUID().uuidString, storeIDs: [f.configs[0].id], edits: [.init(selection: selection, key: "x", value: "y")])
        do { _ = try await f.engine().run(request) { _ in }; XCTFail("Arbitrary path accepted") } catch {}
        var tags = VideoTagTimeline(changes: [.init(ticks: 0, frame: 0, tags: [:])])
        for i in 0..<32 { try tags.apply(.init(start: 0, end: 100, key: "k\(i)", value: "v")) }
        let original = tags
        XCTAssertThrowsError(try tags.apply(.init(start: 0, end: 100, key: "overflow", value: "v")))
        XCTAssertEqual(tags, original)
        XCTAssertEqual(try db.recordings().first?.inode, row.inode)
    }
    func testEncryptedS3OnlyFrameEditingReadsInRAMAndOnlyChangesMetadata() async throws {
        let root = "/private/tmp/hbnvr-history-remote-" + UUID().uuidString
        try SecureFiles.ensureDirectory(root, owner: geteuid(), mode: 0o700)
        var config = try S3Tests().config(); config.schemaVersion = 2
        config.s3?.clientEncryption = .init(enabled: true, password: "history-secret")
        let camera = UUID().uuidString, samples = try S3ThumbnailTests().fixture(config, camera: camera), first = samples[0]
        let timing = ShardTimingMetadata(storeID: config.id, cameraID: camera, media: first, time: first.time!)
        let writer = try MemoryMP4Shard(codec: first.codec, sets: first.parameterSets, clock: first.clockRate, timestamp: first.frame.timestamp, timing: timing)
        for sample in samples { try writer.append(sample.frame, tags: ["original": "yes"]) }
        let plain = try writer.finish(), bytes = try RecordingEncryption.encrypt(plain, password: "history-secret")
        var metadata = S3ObjectMetadata.make(store: config, camera: camera, name: "Camera", capturedAt: first.receivedAt,
            data: bytes, encrypted: true, id: timing.shardID)
        metadata.timing = timing; metadata.endTicks = writer.endTicks
        metadata.tagMetadata = try .freeze(writer.tagTimeline, password: "history-secret")
        let network = FakeS3(), reader = HistoricalMemoryReader(bytes)
        let manager = RecordingStoreManager(spoolRoot: root + "/spool", transportFactory: { _ in network })
        defer { _ = manager.stop(); try? FileManager.default.removeItem(atPath: root) }
        try manager.install(config)
        let sink = try manager.repairSink(config: config, cameras: [camera], cameraStillExists: { _ in true })
        _ = try await sink.merge(metadata, Cancellation())
        let selection = HistoricalTagRequest.Selection(shardID: timing.shardID, sourceStoreID: config.id, startFrame: 2, endFrame: 5)
        let request = HistoricalTagRequest(jobID: UUID().uuidString, storeIDs: [config.id], edits: [.init(selection: selection, key: "person", value: "alice")])
        let engine = HistoricalTagEngine(configs: [config], manager: manager, factory: { _, _ in reader }, credentials: nil, password: nil, cancellation: Cancellation())
        _ = try await engine.run(request) { _ in }
        let shard = try XCTUnwrap(manager.historicalS3(config.id).historicalShards().first)
        XCTAssertEqual(shard.key, metadata.key); XCTAssertEqual(shard.sha256, metadata.sha256)
        let tags = try XCTUnwrap(shard.tagMetadata).thaw(password: "history-secret")
        XCTAssertNil(tags.tags(at: 6000)?["person"])
        XCTAssertEqual(tags.tags(at: 12000)?["person"], "alice")
        XCTAssertNil(tags.tags(at: 30000)?["person"])
        let reads = await reader.reads; XCTAssertEqual(reads, 1)
        let uploads = await network.attempts; XCTAssertTrue(uploads.isEmpty)
        XCTAssertFalse(try FileManager.default.subpathsOfDirectory(atPath: root).contains { $0.hasSuffix(".mp4") })
        let json = try Data(contentsOf: URL(fileURLWithPath: root + "/playback/" + config.id + "/" + timing.shardID + ".json"))
        XCTAssertFalse(String(decoding: json, as: UTF8.self).contains("alice"))
    }
}
