import XCTest
import Foundation
import Darwin

final class S3RetryTests: XCTestCase {
    private func root() throws -> String {
        let path = "/private/tmp/hbnvr-retry-" + UUID().uuidString
        try SecureFiles.ensureDirectory(path, owner: geteuid(), mode: 0o700)
        addTeardownBlock { try FileManager.default.removeItem(atPath: path) }; return path
    }
    func testLegacyQuarantineRetriesWithoutDeletingBeforeAcknowledgment() async throws {
        let helper = S3Tests(), c = try helper.config(), path = try root() + "/spool", network = FakeS3()
        let original = try S3Spool(path: path, storeID: c.id, settings: c.s3!.settings)
        let data = try RecordingEncryption.encrypt(Data("test footage".utf8), password: "test password")
        let m = S3ShardMetadata.make(store: c, camera: UUID().uuidString, name: "Test", capturedAt: Date(), data: data, encrypted: true)
        let entry = try original.publish(m, data: data)
        let marker = entry.directory + "/quarantined"
        try SecureFiles.atomicWrite(Data("Shard rejected; manual inspection required.\n".utf8), to: marker, mode: 0o600)
        let recovered = try S3Spool(path: path, storeID: c.id, settings: c.s3!.settings)
        XCTAssertEqual(recovered.entries.count, 1); XCTAssertTrue(recovered.readErrors.isEmpty)
        let queue = DispatchQueue(label: "legacy-retry"), manager = S3UploadManager(configuration: c, spool: recovered, queue: queue, factory: { _ in network })
        try await helper.on(queue) { manager.tick() }
        try await helper.eventually { await network.attempts.count == 1 }
        let sent = await network.attempts[0]
        XCTAssertEqual(sent.metadata, m); XCTAssertEqual(try sent.payload.read(offset: 0, count: data.count), data)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker))
        await network.resolve(m.id)
        try await helper.eventually { try await helper.on(queue) { !manager.outstanding } }
        XCTAssertFalse(FileManager.default.fileExists(atPath: entry.directory))
        try await helper.on(queue) { manager.stopDispatch() }
    }
    func testRepeatedRejectionsRetryFairlyAndUnrelatedSuccessKeepsError() async throws {
        let helper = S3Tests(), c = try helper.config(), network = FakeS3(), clock = S3Tests.Clock(), queue = DispatchQueue(label: "fair-retry")
        let spool = try S3Spool(path: root() + "/spool", storeID: c.id, settings: c.s3!.settings)
        let manager = S3UploadManager(configuration: c, spool: spool, queue: queue, factory: { _ in network }, now: { clock.time }, jitter: { 1 })
        let (bad, data) = helper.shard(c, at: Date(timeIntervalSince1970: 100)), (good, bytes) = helper.shard(c, at: Date(timeIntervalSince1970: 200))
        try await helper.on(queue) { manager.ready(bad, data: data) }
        for (attempt, time) in [(1, 1.0), (2, 3.0), (3, 63.0)] {
            try await helper.eventually { await network.attempts.count == attempt }
            await network.resolve(bad.id, error: .init(kind: .transient, message: "BadDigest, HTTP 400; will retry"))
            try await helper.eventually { try await helper.on(queue) { manager.snapshot(assemblingBytes: 0).active == 0 } }
            if attempt == 3 { try await helper.on(queue) { manager.ready(good, data: bytes) } }
            try await helper.on(queue) { clock.time = time; manager.tick() }
        }
        try await helper.eventually { await network.attempts.count == 4 }
        let firstProbe = await network.attempts[3]; XCTAssertEqual(firstProbe.metadata.id, bad.id)
        await network.resolve(bad.id, error: .init(kind: .transient, message: "BadDigest, HTTP 400; will retry"))
        try await helper.eventually { try await helper.on(queue) { manager.snapshot(assemblingBytes: 0).active == 0 } }
        try await helper.on(queue) { clock.time = 123; manager.tick() }
        try await helper.eventually { await network.attempts.count == 5 }
        let probe = await network.attempts[4]; XCTAssertEqual(probe.metadata.id, good.id)
        await network.resolve(good.id)
        try await helper.eventually { await network.attempts.count == 6 }
        try await helper.on(queue) {
            XCTAssertTrue(manager.lastError?.contains("BadDigest") == true)
            XCTAssertEqual(manager.snapshot(assemblingBytes: 0).unreadableSpoolCount, 0)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: spool.path + "/" + bad.id + "/quarantined"))
        let retry = await network.attempts[5]; XCTAssertEqual(retry.metadata, bad)
        XCTAssertEqual(try retry.payload.read(offset: 0, count: data.count), data)
        await network.resolve(bad.id)
        try await helper.eventually { try await helper.on(queue) { !manager.outstanding } }
        try await helper.on(queue) { XCTAssertNil(manager.lastError); manager.stopDispatch() }
    }
    func testUnreadableAndInvalidEntriesAreRecheckedAndRepairNeedsNoRestart() async throws {
        for damage in ["permissions", "hash", "metadata"] {
            let helper = S3Tests(), c = try helper.config(), path = try root() + "/spool", network = FakeS3(), clock = S3Tests.Clock()
            let original = try S3Spool(path: path, storeID: c.id, settings: c.s3!.settings)
            let (m, data) = helper.shard(c), entry = try original.publish(m, data: data)
            let payload = entry.directory + "/video.mp4", manifest = entry.directory + "/metadata.json"
            switch damage {
            case "permissions": XCTAssertEqual(chmod(payload, 0), 0)
            case "hash": try SecureFiles.atomicWrite(Data(repeating: 1, count: data.count), to: payload, mode: 0o600)
            default: try SecureFiles.atomicWrite(Data("{".utf8), to: manifest, mode: 0o600)
            }
            let recovered = try S3Spool(path: path, storeID: c.id, settings: c.s3!.settings)
            XCTAssertEqual(recovered.damaged, [m.id]); XCTAssertTrue(FileManager.default.fileExists(atPath: payload))
            let queue = DispatchQueue(label: "read-retry"), manager = S3UploadManager(configuration: c, spool: recovered, queue: queue, factory: { _ in network }, now: { clock.time })
            try await helper.on(queue) {
                manager.tick(); clock.time = 60; manager.tick()
                XCTAssertEqual(manager.snapshot(assemblingBytes: 0).unreadableSpoolCount, 1)
                XCTAssertEqual(manager.snapshot(assemblingBytes: 0).nextReadRetrySeconds, 60)
                XCTAssertNotNil(manager.lastError)
            }
            let attempts = await network.attempts.count; XCTAssertEqual(attempts, 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: payload))
            // Atomic replacement exercises refresh of the pinned file identity.
            XCTAssertEqual(chmod(payload, 0o600), 0)
            try SecureFiles.atomicWrite(data, to: payload, mode: 0o600)
            try SecureFiles.atomicWrite(JSONEncoder().encode(m), to: manifest, mode: 0o600)
            try await helper.on(queue) { clock.time = 120; manager.tick() }
            try await helper.eventually { await network.attempts.count == 1 }
            XCTAssertTrue(FileManager.default.fileExists(atPath: payload))
            await network.resolve(m.id)
            try await helper.eventually { try await helper.on(queue) { !manager.outstanding } }
            try await helper.on(queue) { XCTAssertNil(manager.lastError); manager.stopDispatch() }
        }
    }
    func testReadFailureAfterStartupRetriesRepairedFileWithSameMetadata() async throws {
        let helper = S3Tests(), c = try helper.config(), network = FakeS3(), clock = S3Tests.Clock(), queue = DispatchQueue(label: "runtime-read-retry")
        let spool = try S3Spool(path: root() + "/spool", storeID: c.id, settings: c.s3!.settings)
        let (m, data) = helper.shard(c), entry = try spool.publish(m, data: data)
        let manager = S3UploadManager(configuration: c, spool: spool, queue: queue, factory: { _ in network }, now: { clock.time })
        try await helper.on(queue) { manager.tick() }
        try await helper.eventually { await network.attempts.count == 1 }
        await network.resolve(m.id, error: .init(kind: .localRead, message: "Injected read failure"))
        try await helper.eventually { try await helper.on(queue) { spool.readErrors[m.id] != nil } }
        try SecureFiles.atomicWrite(Data([1]), to: entry.directory + "/video.mp4", mode: 0o600)
        try await helper.on(queue) { clock.time = 60; manager.tick() }
        let attempts = await network.attempts.count; XCTAssertEqual(attempts, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: entry.directory + "/video.mp4"))
        try SecureFiles.atomicWrite(data, to: entry.directory + "/video.mp4", mode: 0o600)
        try await helper.on(queue) { clock.time = 120; manager.tick() }
        try await helper.eventually { await network.attempts.count == 2 }
        let retry = await network.attempts[1]
        XCTAssertEqual(retry.metadata, m); XCTAssertEqual(try retry.payload.read(offset: 0, count: data.count), data)
        await network.resolve(m.id)
        try await helper.eventually { try await helper.on(queue) { !manager.outstanding } }
        try await helper.on(queue) { manager.stopDispatch() }
    }
    func testConfirmedCleanupFailureRetriesWithoutUploadingAgain() async throws {
        let helper = S3Tests(), c = try helper.config(), network = FakeS3(), clock = S3Tests.Clock(), queue = DispatchQueue(label: "cleanup-retry")
        let spool = try S3Spool(path: root() + "/spool", storeID: c.id, settings: c.s3!.settings)
        let (m, data) = helper.shard(c), entry = try spool.publish(m, data: data)
        spool.checkpoint = { if $0 == "deleted-video.mp4" { throw ServiceError("Injected partial deletion failure") } }
        let manager = S3UploadManager(configuration: c, spool: spool, queue: queue, factory: { _ in network }, now: { clock.time })
        try await helper.on(queue) { manager.tick() }
        try await helper.eventually { await network.attempts.count == 1 }; await network.resolve(m.id)
        try await helper.eventually { try await helper.on(queue) { manager.snapshot(assemblingBytes: 0).confirmedUploads == 1 } }
        try await helper.on(queue) {
            XCTAssertTrue(manager.outstanding); XCTAssertTrue(manager.lastError?.contains("cleanup will retry") == true)
            XCTAssertTrue(FileManager.default.fileExists(atPath: entry.directory + "/metadata.json"))
            try spool.scan() // Another shard's publication/recovery cannot erase cleanup progress.
            clock.time = 59; manager.tick(); XCTAssertTrue(manager.outstanding)
            spool.checkpoint = { _ in }; clock.time = 60; manager.tick()
            XCTAssertFalse(manager.outstanding); XCTAssertNil(manager.lastError); manager.stopDispatch()
        }
        let attempts = await network.attempts.count; XCTAssertEqual(attempts, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: entry.directory))
    }
    func testRelocationExplainsUnreadableWorkInsteadOfSayingNotDisabled() throws {
        let helper = S3Tests(), path = try root(), network = FakeS3()
        var c = try helper.config(); c.enabled = false
        let spool = try S3Spool(path: path + "/" + c.id, storeID: c.id, settings: c.s3!.settings)
        let (m, data) = helper.shard(c), entry = try spool.publish(m, data: data)
        try SecureFiles.atomicWrite(Data([1]), to: entry.directory + "/video.mp4", mode: 0o600)
        let store = try S3RecordingStore(configuration: c, spoolRoot: path, factory: { _ in network }, log: { _ in })
        XCTAssertTrue(store.flush(timeout: 3))
        let message = try XCTUnwrap(store.drainBlocker())
        XCTAssertTrue(message.contains("Store is disabled")); XCTAssertTrue(message.contains("1 unreadable entries"), message)
        XCTAssertTrue(FileManager.default.fileExists(atPath: entry.directory + "/video.mp4")); XCTAssertTrue(store.finish(timeout: 3))
    }
    func testConfirmedButUnreadableFileIsPreservedUntilRepair() async throws {
        let helper = S3Tests(), c = try helper.config(), network = FakeS3(), clock = S3Tests.Clock(), queue = DispatchQueue(label: "cleanup-read-repair")
        let spool = try S3Spool(path: root() + "/spool", storeID: c.id, settings: c.s3!.settings)
        let (m, data) = helper.shard(c), entry = try spool.publish(m, data: data)
        let payload = entry.directory + "/video.mp4"
        let manager = S3UploadManager(configuration: c, spool: spool, queue: queue, factory: { _ in network }, now: { clock.time })
        try await helper.on(queue) { manager.tick() }
        try await helper.eventually { await network.attempts.count == 1 }
        XCTAssertEqual(chmod(payload, 0), 0)
        await network.resolve(m.id)
        try await helper.eventually { try await helper.on(queue) { manager.snapshot(assemblingBytes: 0).confirmedUploads == 1 } }
        try await helper.on(queue) {
            clock.time = 60; manager.tick()
            XCTAssertTrue(manager.outstanding); XCTAssertTrue(FileManager.default.fileExists(atPath: payload))
        }
        XCTAssertEqual(chmod(payload, 0o600), 0)
        try SecureFiles.atomicWrite(data, to: payload, mode: 0o600)
        try await helper.on(queue) { clock.time = 120; manager.tick(); XCTAssertFalse(manager.outstanding); manager.stopDispatch() }
        let attempts = await network.attempts.count; XCTAssertEqual(attempts, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: entry.directory))
    }
}
