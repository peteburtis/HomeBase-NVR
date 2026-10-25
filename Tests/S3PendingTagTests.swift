import XCTest
import Foundation
import Darwin

final class S3PendingTagTests: XCTestCase {
    private func root() throws -> String {
        let path = "/private/tmp/hbnvr-pending-tags-" + UUID().uuidString
        try SecureFiles.ensureDirectory(path, owner: geteuid(), mode: 0o700)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }
    private func edit(_ snapshot: RecordingTagSnapshot, key: String = "review", value: String? = "hidden") -> RecordingTagEdit {
        .init(snapshot: snapshot, overrides: [.init(start: 0, end: snapshot.endTicks, key: key, value: value)])
    }
    private func timed(_ config: RecordingStoreConfiguration, password: String? = nil) throws -> (S3ShardMetadata, Data) {
        let template = S3PlaybackManifestTests().shard(config, camera: UUID().uuidString, at: 1_790_000_000, duration: 1)
        let data = try password.map { try RecordingEncryption.encrypt(Data([1, 2, 3]), password: $0) } ?? Data([1, 2, 3])
        var metadata = S3ShardMetadata.make(store: config, camera: template.cameraID, name: "Test", capturedAt: template.capturedAt,
            data: data, encrypted: password != nil, id: template.id)
        metadata.timing = template.timing; metadata.endTicks = template.endTicks; metadata.frameTicks = [0, 30_000, 60_000]
        metadata.tagMetadata = try StoredVideoTags.freeze(.init(changes: [.init(ticks: 0, frame: 0, tags: ["original": "yes"])]), password: password)
        return (metadata, data)
    }
    func testActiveAndFinalizedPendingTagsSurviveEncryptedSpoolRestart() throws {
        for encrypted in [false, true] {
            let path = try root(), network = FakeS3(), camera = UUID().uuidString
            var config = try S3Tests().config(), tuning = S3Tuning(); tuning.forceSpooling = true; config.s3?.tuning = tuning
            if encrypted { config.s3?.clientEncryption = .init(password: "test pending password") }
            let store = try S3RecordingStore(configuration: config, spoolRoot: path + "/spool", factory: { _ in network }, log: { _ in })
            let frames = try StoreTests.video(count: 12)
            for frame in frames.prefix(6) { store.accept(.media(camera: camera, name: "Camera", frame)) }
            let active = try XCTUnwrap(store.pendingTagSnapshots().first)
            XCTAssertEqual(active.frames, 6); XCTAssertEqual(active.endTicks, active.frameTicks.last! + 1)
            try store.commitPendingTags([edit(active)], work: MediaWork())
            XCTAssertEqual(try store.pendingTagSnapshots().first?.tags.state(at: active.frameTicks.last!).values["review"], "hidden")
            for frame in frames.dropFirst(6) { store.accept(.media(camera: camera, name: "Camera", frame)) }
            store.accept(.end(camera: camera))
            let pending = try XCTUnwrap(store.pendingTagSnapshots().first)
            XCTAssertEqual(pending.frames, 12)
            XCTAssertEqual(pending.tags.state(at: pending.frameTicks[5]).values["review"], "hidden")
            XCTAssertNil(pending.tags.state(at: pending.frameTicks[6]).values["review"], "An edit of accepted footage must not tag later arriving frames")
            try store.commitPendingTags([edit(pending, key: "pending", value: "corrected")], work: MediaWork())
            XCTAssertTrue(try store.historicalShards().isEmpty, "Pending uploads must not be advertised as playable cloud media")
            XCTAssertTrue(store.finish(timeout: 30))
            let recovered = try S3RecordingStore(configuration: config, spoolRoot: path + "/spool", factory: { _ in network }, log: { _ in })
            let restored = try XCTUnwrap(recovered.pendingTagSnapshots().first)
            XCTAssertEqual(restored.frameTicks, pending.frameTicks)
            XCTAssertEqual(restored.tags.state(at: pending.frameTicks.last!).values["pending"], "corrected")
            XCTAssertTrue(recovered.finish(timeout: 30))
            let spool = try S3Spool.open(storeID: config.id, defaultRoot: path + "/spool", settings: tuning, clientEncrypted: encrypted)
            let entry = try XCTUnwrap(spool.entries[pending.timing.shardID])
            if encrypted {
                XCTAssertNil(entry.metadata.tagMetadata?.timeline)
                let descriptor = try Data(contentsOf: URL(fileURLWithPath: entry.directory + "/metadata.json"))
                XCTAssertFalse(String(decoding: descriptor, as: UTF8.self).contains("corrected"))
            }
            var bytes = try entry.payload.read(offset: 0, count: Int(entry.metadata.size))
            if encrypted { bytes = try RecordingEncryption.decrypt(bytes, password: "test pending password") }
            let embedded = try XCTUnwrap(VideoTagMP4.read(bytes))
            XCTAssertEqual(embedded.state(at: pending.frameTicks[5]).values["review"], "hidden")
            XCTAssertNil(embedded.state(at: pending.frameTicks[6]).values["review"])
            XCTAssertNil(embedded.state(at: 0).values["pending"], "A pending correction changes authoritative metadata without rewriting immutable video bytes")
        }
    }
    func testInflightCompletionAndStaleReplayUseDurableEditedMetadata() async throws {
        let helper = S3Tests(), path = try root(), config = try helper.config(), network = FakeS3(), queue = DispatchQueue(label: "pending-tag-inflight")
        let spool = try S3Spool(path: path + "/spool", storeID: config.id, settings: config.s3!.settings)
        let publisher = S3PlaybackPublisher(configuration: config, path: path + "/playback/" + config.id, queue: queue, factory: { _ in network })
        let manager = S3UploadManager(configuration: config, spool: spool, queue: queue, factory: { _ in network }, playback: publisher)
        let (metadata, bytes) = try timed(config)
        try await helper.on(queue) { manager.ready(metadata, data: bytes) }
        try await helper.eventually { await network.attempts.count == 1 }
        try await helper.on(queue) {
            let snapshot = try XCTUnwrap(manager.pendingTagSnapshots().first)
            XCTAssertTrue(try manager.applyPendingTags(self.edit(snapshot), work: MediaWork()))
            XCTAssertTrue(publisher.entries.isEmpty)
            XCTAssertEqual(try spool.entries[metadata.id]?.metadata.tagMetadata?.thaw(password: nil).state(at: 0).values["review"], "hidden")
            XCTAssertEqual(try spool.entries[metadata.id]?.payload.read(offset: 0, count: bytes.count), bytes)
        }
        let sent = await network.attempts[0]
        XCTAssertEqual(sent.metadata, metadata, "The transport owns its frozen original request while effective tags change")
        let restarted = try S3Spool(path: path + "/spool", storeID: config.id, settings: config.s3!.settings)
        XCTAssertEqual(try restarted.entries[metadata.id]?.metadata.tagMetadata?.thaw(password: nil).state(at: 0).values["review"], "hidden")
        await network.resolve(metadata.id)
        try await helper.eventually { try await helper.on(queue) { !manager.outstanding } }
        try await helper.on(queue) {
            XCTAssertEqual(try publisher.entries[metadata.id]?.shard.tagMetadata?.thaw(password: nil).state(at: 0).values["review"], "hidden")
            try publisher.record(metadata)
            XCTAssertEqual(try publisher.entries[metadata.id]?.shard.tagMetadata?.thaw(password: nil).state(at: 0).values["review"], "hidden")
            manager.completed(metadata.id, token: UUID(), result: .success(()))
            XCTAssertTrue(try manager.pendingTagSnapshots().isEmpty)
            manager.stopDispatch()
        }
        let attempts = await network.attempts.count; XCTAssertEqual(attempts, 1)
    }
    func testCommitFollowsActiveFootageThroughAlreadyConfirmedUpload() async throws {
        let path = try root(), config = try S3Tests().config(), network = FakeS3(), camera = UUID().uuidString
        await network.configure(automatic: true)
        let store = try S3RecordingStore(configuration: config, spoolRoot: path + "/spool", factory: { _ in network }, log: { _ in })
        let frames = try StoreTests.video(count: 6)
        for frame in frames { store.accept(.media(camera: camera, name: "Camera", frame)) }
        let active = try XCTUnwrap(store.pendingTagSnapshots().first)
        store.accept(.end(camera: camera))
        try await S3Tests().eventually { try store.historicalShards().count == 1 }
        XCTAssertTrue(try store.pendingTagSnapshots().isEmpty)
        let original = try XCTUnwrap(store.historicalShards().first)
        var encryptedMetadata = original
        encryptedMetadata.tagMetadata = try StoredVideoTags.freeze(active.tags, password: "metadata password")
        encryptedMetadata.tagRevision = UUID().uuidString
        try store.commitHistorical([.init(expected: original, replacement: encryptedMetadata)], expected: config)
        try store.commitPendingTags([edit(active)], work: MediaWork(), password: "metadata password")
        let confirmed = try XCTUnwrap(store.historicalShards().first)
        XCTAssertNil(confirmed.encryption)
        XCTAssertNil(confirmed.tagMetadata?.timeline, "An already-encrypted metadata envelope stays encrypted even for plaintext media")
        let tags = try XCTUnwrap(confirmed.tagMetadata).thaw(password: "metadata password")
        XCTAssertEqual(tags.state(at: active.frameTicks.last!).values["review"], "hidden")
        XCTAssertNotNil(confirmed.tagRevision)
        XCTAssertTrue(store.finish(timeout: 30))
    }
    func testPendingLegacyPasswordOverrideAndMissingFrameIndex() throws {
        let path = try root(), queue = DispatchQueue(label: "pending-tag-password"), network = FakeS3()
        var config = try S3Tests().config(); config.s3?.clientEncryption = .init(password: "replacement password")
        var (metadata, bytes) = try timed(config, password: "original password")
        metadata.frameTicks = nil
        let spool = try S3Spool(path: path + "/spool", storeID: config.id, settings: config.s3!.settings)
        _ = try spool.publish(metadata, data: bytes)
        let manager = S3UploadManager(configuration: config, spool: spool, queue: queue, factory: { _ in network })
        XCTAssertThrowsError(try manager.pendingTagSnapshots())
        XCTAssertTrue(try manager.pendingTagSnapshots(cameraID: UUID().uuidString).isEmpty,
            "Unrelated encrypted footage must not require its old password")
        XCTAssertTrue(try manager.pendingTagSnapshots(shardID: UUID().uuidString).isEmpty)
        XCTAssertTrue(try manager.pendingTagSnapshots(cameraID: metadata.cameraID, range: .init(start: 100, end: 200)).isEmpty)
        XCTAssertTrue(try manager.pendingTagSnapshots(cameraID: metadata.cameraID, epochID: UUID().uuidString).isEmpty)
        let snapshot = try XCTUnwrap(manager.pendingTagSnapshots(password: "original password").first)
        XCTAssertEqual(snapshot.frames, 0); XCTAssertTrue(snapshot.frameTicks.isEmpty)
        XCTAssertTrue(try manager.applyPendingTags(edit(snapshot), work: MediaWork(), password: "original password"))
        XCTAssertEqual(try spool.entries[metadata.id]?.metadata.tagMetadata?.thaw(password: "original password").state(at: 0).values["review"], "hidden")
        XCTAssertThrowsError(try spool.entries[metadata.id]?.metadata.tagMetadata?.thaw(password: "replacement password"))
        manager.stopDispatch()
    }
    func testPendingPlaintextMediaKeepsEncryptedTagEnvelope() throws {
        let path = try root(), config = try S3Tests().config(), queue = DispatchQueue(label: "pending-tag-envelope"), network = FakeS3()
        var (metadata, bytes) = try timed(config)
        metadata.tagMetadata = try StoredVideoTags.freeze(try metadata.tagMetadata!.thaw(password: nil), password: "metadata password")
        let spool = try S3Spool(path: path + "/spool", storeID: config.id, settings: config.s3!.settings)
        _ = try spool.publish(metadata, data: bytes)
        let manager = S3UploadManager(configuration: config, spool: spool, queue: queue, factory: { _ in network })
        let snapshot = try XCTUnwrap(manager.pendingTagSnapshots(password: "metadata password").first)
        XCTAssertTrue(try manager.applyPendingTags(edit(snapshot), work: MediaWork(), password: "metadata password"))
        let updated = try XCTUnwrap(spool.entries[metadata.id])
        XCTAssertNil(updated.metadata.encryption)
        XCTAssertNil(updated.metadata.tagMetadata?.timeline)
        XCTAssertEqual(try updated.metadata.tagMetadata?.thaw(password: "metadata password").state(at: 0).values["review"], "hidden")
        XCTAssertEqual(try updated.payload.read(offset: 0, count: bytes.count), bytes)
        manager.stopDispatch()
    }
    func testRestartDiscardsOnlyUncommittedMetadataStaging() throws {
        let path = try root(), config = try S3Tests().config(), (metadata, bytes) = try timed(config)
        let spool = try S3Spool(path: path + "/spool", storeID: config.id, settings: config.s3!.settings)
        let entry = try spool.publish(metadata, data: bytes)
        let abandoned = entry.directory + "/.metadata-" + UUID().uuidString
        try SecureFiles.atomicWrite(Data("{unfinished metadata".utf8), to: abandoned, mode: 0o600)
        let restarted = try S3Spool(path: path + "/spool", storeID: config.id, settings: config.s3!.settings)
        XCTAssertEqual(restarted.entries[metadata.id]?.metadata, metadata)
        XCTAssertTrue(restarted.readErrors.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned))
        XCTAssertEqual(try restarted.entries[metadata.id]?.payload.read(offset: 0, count: bytes.count), bytes)
        let unrelated = entry.directory + "/operator-note"
        try SecureFiles.atomicWrite(Data("preserve".utf8), to: unrelated, mode: 0o600)
        let damaged = try S3Spool(path: path + "/spool", storeID: config.id, settings: config.s3!.settings)
        XCTAssertNotNil(damaged.readErrors[metadata.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated))
        try FileManager.default.removeItem(atPath: unrelated)
        let target = path + "/preserve", link = entry.directory + "/.metadata-" + UUID().uuidString
        try SecureFiles.atomicWrite(Data("preserve".utf8), to: target, mode: 0o600)
        XCTAssertEqual(symlink(target, link), 0)
        let unsafe = try S3Spool(path: path + "/spool", storeID: config.id, settings: config.s3!.settings)
        XCTAssertNotNil(unsafe.readErrors[metadata.id])
        XCTAssertNotNil(try SecureFiles.info(link))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: target)), Data("preserve".utf8))
    }
}
