import XCTest
import Foundation
import Darwin

final class S3ControlTests: XCTestCase {
    private func root() throws -> String {
        let path = "/private/tmp/hbnvr-controls-" + UUID().uuidString
        try SecureFiles.ensureDirectory(path, owner: geteuid(), mode: 0o700)
        addTeardownBlock { try FileManager.default.removeItem(atPath: path) }; return path
    }
    func testAdvancedEditorCoversEverySettingAndValidatesTogether() throws {
        var seen = Set<String>()
        let settings = try StoreAdvancedOptions.edit(S3Tuning()) { label, value in
            seen.insert(String(label.split(separator: " ")[0]))
            switch label.split(separator: " ")[0] {
            case "ConcurrentUploads": return "2"
            case "ReservedLiveSlots": return "1"
            case "ProbeIntervalSeconds": return "2m"
            case "SpoolDirectory":
                XCTAssertEqual(label, "SpoolDirectory (default to reset)"); XCTAssertEqual(value, "default")
                return "/Volumes/Test/spool"
            case "ForceSpooling": return "yes"
            default: return value
            }
        }
        XCTAssertEqual(seen, Set(S3Tuning.CodingKeys.allCases.map(\.rawValue)))
        XCTAssertEqual(settings.concurrentUploads, 2); XCTAssertEqual(settings.probeInterval, 120)
        XCTAssertTrue(settings.forceSpooling); XCTAssertEqual(settings.spoolDirectory, "/Volumes/Test/spool")
        let reset = try StoreAdvancedOptions.edit(settings) { label, value in label == "SpoolDirectory (default to reset)" ? "default" : value }
        XCTAssertNil(reset.spoolDirectory)
        for (key, bad) in [("ConcurrentUploads", "1"), ("ReservedLiveSlots", "99"), ("SpoolLimitBytes", "0"), ("MinimumFreeBytes", "-1"), ("ProbeIntervalSeconds", "inf"), ("ForceSpooling", "maybe")] {
            XCTAssertThrowsError(try StoreAdvancedOptions.edit(S3Tuning()) { label, value in label.hasPrefix(key + " ") ? bad : value }, key)
        }
    }
    func testLegacyDefaultsSchemaGuardAndOperationalOnlyClassification() throws {
        XCTAssertFalse(try JSONDecoder().decode(S3Tuning.self, from: Data("{}".utf8)).forceSpooling)
        let current = try S3Tests().config().summary
        var changed = current; var tuning = S3Tuning(); tuning.forceSpooling = true
        changed.s3?.tuning = tuning
        XCTAssertThrowsError(try changed.validate()); changed.updateS3ReaderVersion()
        XCTAssertEqual(changed.schemaVersion, 4); try changed.validate()
        XCTAssertTrue(changed.differsOnlyInAdvancedSettings(from: current))
        changed.s3?.tuning?.forceSpooling = false; changed.updateS3ReaderVersion()
        XCTAssertEqual(changed.schemaVersion, 4)
        var bad = changed; bad.enabled.toggle(); XCTAssertFalse(bad.differsOnlyInAdvancedSettings(from: current))
        bad = changed; bad.s3?.credentials = try S3Tests().config().s3?.credentials
        XCTAssertFalse(bad.differsOnlyInAdvancedSettings(from: current))
        bad = changed; bad.s3?.clientEncryption = S3ClientEncryption(password: "test password")
        XCTAssertFalse(bad.differsOnlyInAdvancedSettings(from: current))
        bad = changed; bad.s3?.bucket = "other-bucket"; XCTAssertFalse(bad.differsOnlyInAdvancedSettings(from: current))
    }
    func testForcedSpoolingPersistsWithoutUploadsOrProbesAndRestartDrainsOnRelease() async throws {
        let helper = S3Tests(), path = try root(), network = FakeS3(), clock = S3Tests.Clock()
        var c = try helper.config(); var tuning = S3Tuning(); tuning.forceSpooling = true
        c.s3?.tuning = tuning; c.updateS3ReaderVersion()
        let queue = DispatchQueue(label: "manual-spool-test")
        let spool = try S3Spool(path: path + "/spool", storeID: c.id, settings: tuning)
        let manager = S3UploadManager(configuration: c, spool: spool, queue: queue, factory: { _ in network }, now: { clock.time })
        let shards = (0..<3).map { _ in helper.shard(c) }
        try await helper.on(queue) {
            for (metadata, data) in shards { manager.ready(metadata, data: data) }
            clock.time = 3600; manager.tick()
            let status = manager.snapshot(assemblingBytes: 0)
            XCTAssertTrue(status.spooling); XCTAssertTrue(status.acceptingRecording)
            XCTAssertEqual(status.reasons, ["manual"]); XCTAssertNil(status.nextProbeSeconds)
            XCTAssertEqual(status.spoolCount, 3); XCTAssertEqual(status.residentBytes, 0)
            manager.stopDispatch()
        }
        let attempts = await network.attempts.count; XCTAssertEqual(attempts, 0)
        let recovered = try S3Spool(path: path + "/spool", storeID: c.id, settings: tuning)
        c.enabled = false // Disabling recording must not prevent later backlog replay.
        let restarted = S3UploadManager(configuration: c, spool: recovered, queue: queue, factory: { _ in network }, now: { clock.time })
        try await helper.on(queue) { restarted.tick(); XCTAssertEqual(restarted.snapshot(assemblingBytes: 0).active, 0) }
        await network.configure(automatic: true)
        var released = c; released.s3?.tuning?.forceSpooling = false
        let final = released
        try await helper.on(queue) { restarted.update(final) }
        try await helper.eventually { try await helper.on(queue) { restarted.snapshot(assemblingBytes: 0).confirmedUploads == 3 } }
        try await helper.on(queue) { XCTAssertFalse(restarted.outstanding); restarted.stopDispatch() }
    }
    func testManualHoldDoesNotCancelInflightOrClearAutomaticReasons() async throws {
        let helper = S3Tests(), network = FakeS3(), clock = S3Tests.Clock(), queue = DispatchQueue(label: "manual-recovery-test")
        let c = try helper.config(), spool = try S3Spool(path: root() + "/spool", storeID: c.id, settings: c.s3!.settings)
        let manager = S3UploadManager(configuration: c, spool: spool, queue: queue, factory: { _ in network }, now: { clock.time })
        let (metadata, data) = helper.shard(c)
        try await helper.on(queue) { manager.ready(metadata, data: data) }
        try await helper.eventually { await network.attempts.count == 1 }
        var hold = c; var tuning = S3Tuning(); tuning.forceSpooling = true; hold.s3?.tuning = tuning
        let held = hold
        try await helper.on(queue) { manager.update(held); XCTAssertEqual(manager.snapshot(assemblingBytes: 0).active, 1) }
        await network.resolve(metadata.id, error: .init(kind: .network, message: "offline"))
        try await helper.eventually { try await helper.on(queue) { manager.policy.reasons.contains("upload-error") } }
        try await helper.on(queue) {
            clock.time = 3600; manager.memoryPressure(true); manager.tick()
            XCTAssertNil(manager.snapshot(assemblingBytes: 0).nextProbeSeconds)
            XCTAssertEqual(manager.snapshot(assemblingBytes: 0).active, 0)
        }
        let attempts = await network.attempts.count; XCTAssertEqual(attempts, 1)
        // Release permits a single recovery probe, not a blind reset of errors.
        try await helper.on(queue) {
            manager.update(c)
            XCTAssertTrue(manager.policy.reasons.contains("upload-error"))
            XCTAssertTrue(manager.policy.reasons.contains("pressure"))
        }
        try await helper.eventually { await network.attempts.count == 2 }
        await network.resolve(metadata.id)
        try await helper.eventually { try await helper.on(queue) { manager.snapshot(assemblingBytes: 0).confirmedUploads == 1 } }
        try await helper.on(queue) {
            XCTAssertEqual(manager.policy.reasons, ["pressure"])
            manager.memoryPressure(false); XCTAssertFalse(manager.policy.spooling); manager.stopDispatch()
        }
    }
    func testAdvancedSpoolRelocationRequiresDisabledDrainedAndPreservesOnFailure() throws {
        let path = try root(), helper = S3Tests(), network = FakeS3()
        let manager = RecordingStoreManager(spoolRoot: path + "/default", transportFactory: { _ in network })
        defer { _ = manager.stop() }
        var c = try helper.config(); try manager.install(c)
        let custom = path + "/custom"; try SecureFiles.ensureDirectory(custom, owner: geteuid(), mode: 0o700)
        var moved = c; var tuning = S3Tuning(); tuning.spoolDirectory = custom
        moved.s3?.tuning = tuning; moved.updateS3ReaderVersion()
        XCTAssertThrowsError(try manager.install(moved))
        c.enabled = false; try manager.install(c); try manager.drain()
        moved.enabled = false; try manager.install(moved); try manager.drain()
        XCTAssertEqual(manager.snapshot().first?.s3?.spoolDirectory, custom)
        var missing = moved; missing.s3?.tuning?.spoolDirectory = path + "/missing"
        XCTAssertThrowsError(try manager.install(missing))
        XCTAssertEqual(manager.snapshot().first?.s3?.spoolDirectory, custom)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + "/missing"))
    }
    func testManualHoldAtFullSpoolKeepsVolatileWorkUntilRelease() async throws {
        let helper = S3Tests(), network = FakeS3(), queue = DispatchQueue(label: "manual-full-spool")
        var c = try helper.config(); var tuning = S3Tuning(); tuning.forceSpooling = true
        c.s3?.tuning = tuning; c.updateS3ReaderVersion()
        let spool = try S3Spool(path: root() + "/spool", storeID: c.id, settings: tuning)
        spool.freeSpace = { _ in 0 }
        let manager = S3UploadManager(configuration: c, spool: spool, queue: queue, factory: { _ in network })
        let (metadata, data) = helper.shard(c)
        try await helper.on(queue) {
            manager.ready(metadata, data: data)
            let status = manager.snapshot(assemblingBytes: 0)
            XCTAssertFalse(status.acceptingRecording); XCTAssertEqual(status.volatileShards, 1)
            XCTAssertEqual(status.spoolCount, 0); XCTAssertFalse(manager.safeToExit)
            XCTAssertEqual(status.active, 0); XCTAssertNil(status.nextProbeSeconds)
        }
        let attempts = await network.attempts.count; XCTAssertEqual(attempts, 0)
        await network.configure(automatic: true)
        c.s3?.tuning?.forceSpooling = false; let released = c
        try await helper.on(queue) { manager.update(released) }
        try await helper.eventually { try await helper.on(queue) { manager.snapshot(assemblingBytes: 0).confirmedUploads == 1 } }
        try await helper.on(queue) {
            XCTAssertFalse(manager.snapshot(assemblingBytes: 0).acceptingRecording)
            spool.freeSpace = { _ in Int64.max / 2 }; manager.tick()
            XCTAssertTrue(manager.snapshot(assemblingBytes: 0).acceptingRecording); manager.stopDispatch()
        }
    }
    func testManualControlPreservesCurrentShardAndSpoolsWhenFinalized() async throws {
        let helper = S3Tests(), network = FakeS3(), path = try root(), camera = UUID().uuidString
        var c = try helper.config()
        let store = try S3RecordingStore(configuration: c, spoolRoot: path, factory: { _ in network }, log: { _ in })
        store.accept(.media(camera: camera, name: "Camera", try StoreTests.video(count: 1)[0]))
        XCTAssertTrue(store.flush(timeout: 3)); XCTAssertEqual(store.snapshot().activeRecordings, 1)
        var tuning = S3Tuning(); tuning.forceSpooling = true
        c.s3?.tuning = tuning; c.updateS3ReaderVersion(); try store.update(c)
        XCTAssertTrue(store.flush(timeout: 3)); XCTAssertEqual(store.snapshot().activeRecordings, 1)
        c.enabled = false; try store.update(c)
        XCTAssertTrue(store.flush(timeout: 5))
        XCTAssertEqual(store.snapshot().completedShards, 1); XCTAssertEqual(store.snapshot().s3?.spoolCount, 1)
        let attempts = await network.attempts.count; XCTAssertEqual(attempts, 0)
        XCTAssertTrue(store.finish(timeout: 5))
    }
}
