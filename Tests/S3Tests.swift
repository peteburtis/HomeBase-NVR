import XCTest
import Foundation
import Darwin
import AVFoundation

actor FakeS3: S3Transport {
    struct Attempt: Sendable { let metadata: S3ShardMetadata; let payload: S3Payload }
    var attempts: [Attempt] = []
    var pending: [String: CheckedContinuation<Void, Error>] = [:]
    var automatic = false
    var validationFailure: S3Failure?
    var lifecycleCalls = 0
    var lifecycleFailure: S3Failure?
    func failLifecycle(_ failure: S3Failure) { lifecycleFailure = failure }
    func configure(automatic: Bool = false, failure: S3Failure? = nil) { self.automatic = automatic; validationFailure = failure }
    func validate(_ configuration: S3Configuration) async throws { if let validationFailure { throw validationFailure } }
    func upload(_ metadata: S3ShardMetadata, payload: S3Payload) async throws {
        attempts.append(.init(metadata: metadata, payload: payload))
        if automatic { return }
        try await withCheckedThrowingContinuation { pending[metadata.id] = $0 }
    }
    func reconcile(_ configuration: RecordingStoreConfiguration) async throws { lifecycleCalls += 1; if let lifecycleFailure { throw lifecycleFailure } }
    func resolve(_ id: String, error: S3Failure? = nil) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
    func resolveAll() { let values = pending.values; pending.removeAll(); for value in values { value.resume() } }
}

final class S3Tests: XCTestCase {
    final class Clock { var time = 0.0 }
    var roots: [String] = []
    override func tearDownWithError() throws { for path in roots { try? FileManager.default.removeItem(atPath: path) }; roots.removeAll() }
    func root() throws -> String {
        let path = "/private/tmp/hbs3-" + UUID().uuidString
        try SecureFiles.ensureDirectory(path, owner: geteuid(), mode: 0o700); roots.append(path); return path
    }
    func config() throws -> RecordingStoreConfiguration {
        var result = RecordingStoreConfiguration(ownerUID: geteuid(), ownerUUID: try StoreDirectory.identity(geteuid()))
        result.type = "S3"; result.name = "S3 test"
        result.s3 = S3Configuration(bucket: "hbnvr-unit-test", region: "us-west-2", prefix: "test/", lifecycle: "External",
                                    credentials: .init(accessKeyID: "AKIAUNITTEST000000000", secretAccessKey: String(repeating: "a", count: 40)))
        return result
    }
    func shard(_ config: RecordingStoreConfiguration, data: Data = Data(repeating: 42, count: 100), at: Date = Date()) -> (S3ShardMetadata, Data) {
        (.make(store: config, camera: UUID().uuidString, name: "Living Room", capturedAt: at, data: data), data)
    }
    func on<T>(_ queue: DispatchQueue, _ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in queue.async { continuation.resume(with: Result { try body() }) } }
    }
    func eventually(_ condition: @escaping () async throws -> Bool) async throws {
        for _ in 0..<250 { if try await condition() { return }; try await Task.sleep(for: .milliseconds(20)) }
        XCTFail("Condition did not become true"); throw ServiceError("Test deadline exceeded.")
    }
    func testConfigurationCompatibilityAndCredentialRedaction() throws {
        var c = try config(); try c.validate()
        let privateJSON = try CameraJSON.encode(c), publicJSON = try CameraJSON.encode(c.summary)
        XCTAssertTrue(String(decoding: privateJSON, as: UTF8.self).contains("SecretAccessKey"))
        XCTAssertFalse(String(decoding: publicJSON, as: UTF8.self).contains("AccessKey"))
        XCTAssertEqual(try JSONDecoder().decode(RecordingStoreConfiguration.self, from: privateJSON), c)
        var other = c; other.s3?.prefix = "test/nested/"; XCTAssertTrue(RecordingStoreRepository.overlap(c, other))
        other.s3?.prefix = "test-other/"; XCTAssertFalse(RecordingStoreRepository.overlap(c, other))
        c.retentionPeriod = "1h"; XCTAssertThrowsError(try c.validate())
        c.retentionPeriod = "1d1s"; XCTAssertThrowsError(try c.validate())
        c.retentionPeriod = "1w"; c.s3?.prefix = "*/"; XCTAssertThrowsError(try c.validate())
    }
    func testIAMIsWriteOnlyAndLifecycleIsOptional() throws {
        var c = try config().s3!
        let external = try c.iamPolicy()
        for forbidden in ["GetObject", "DeleteObject", "ListBucket", "CreateBucket", "LifecycleConfiguration"] { XCTAssertFalse(external.contains(forbidden)) }
        XCTAssertTrue(external.contains("arn:aws:s3:::hbnvr-unit-test/test/*"))
        XCTAssertTrue(external.contains("s3:AbortMultipartUpload"))
        c.lifecycle = "Managed"
        let managed = try c.iamPolicy(); XCTAssertTrue(managed.contains("s3:PutLifecycleConfiguration"))
        XCTAssertTrue(try c.lifecycleJSON(id: UUID().uuidString, days: 7).contains("DaysAfterInitiation"))
        c.region = "cn-north-1"; try c.validate(); XCTAssertTrue(try c.iamPolicy().contains("arn:aws-cn:s3:::"))
        c.region = "us-gov-west-1"; try c.validate(); XCTAssertTrue(try c.iamPolicy().contains("arn:aws-us-gov:s3:::"))
    }
    func testPolicyFailuresPressureAndIndependentRecoveryReasons() {
        var policy = S3UploadPolicy(settings: S3Tuning())
        policy.failed(.transient, now: 0, jitter: 1); policy.failed(.transient, now: 1, jitter: 1)
        XCTAssertFalse(policy.spooling)
        policy.succeeded(probe: false); policy.failed(.transient, now: 2, jitter: 1)
        XCTAssertFalse(policy.spooling)
        policy.failed(.transient, now: 40, jitter: 1); policy.failed(.transient, now: 41, jitter: 1)
        XCTAssertFalse(policy.spooling)
        policy.failed(.transient, now: 42, jitter: 1); XCTAssertTrue(policy.spooling)
        policy.pressure(count: 11, cameras: 2, oldestAge: 0, duration: 60)
        policy.succeeded(probe: true); XCTAssertEqual(policy.reasons, ["pressure"])
        policy.pressure(count: 5, cameras: 2, oldestAge: 0, duration: 60); XCTAssertTrue(policy.spooling)
        policy.pressure(count: 4, cameras: 2, oldestAge: 0, duration: 60); XCTAssertFalse(policy.spooling)
        policy.failed(.network, now: 50, jitter: 0); XCTAssertTrue(policy.spooling)
        policy.reasons.insert("shutdown"); policy.succeeded(probe: true); XCTAssertEqual(policy.reasons, ["shutdown"])
    }
    func testLifecycleRejectsUnsupportedXMLBeforeRewrite() throws {
        let xml = "<LifecycleConfiguration xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Rule><ID>unrelated</ID><Status>Enabled</Status><Filter><And><Prefix>elsewhere/</Prefix><Tag><Key>a</Key><Value>b</Value></Tag></And></Filter><Transition><Days>30</Days><StorageClass>STANDARD_IA</StorageClass></Transition></Rule></LifecycleConfiguration>"
        XCTAssertNoThrow(try S3LifecycleXML.validate(Data(xml.utf8)))
        XCTAssertThrowsError(try S3LifecycleXML.validate(Data(xml.replacingOccurrences(of: "<Days>30</Days>", with: "<NewUnsupportedSetting>true</NewUnsupportedSetting>").utf8)))
        XCTAssertThrowsError(try S3LifecycleXML.validate(Data("<!DOCTYPE x><LifecycleConfiguration/>".utf8)))
    }
    func testSpoolPublicationRecoveryPermissionsAndCorruption() throws {
        let c = try config(), path = try root() + "/spool/" + c.id
        let spool = try S3Spool(path: path, storeID: c.id, settings: c.s3!.settings)
        let (m, data) = shard(c)
        spool.checkpoint = { if $0 == "staged" { throw ServiceError("Injected crash") } }
        XCTAssertThrowsError(try spool.publish(m, data: data))
        let recovered = try S3Spool(path: path, storeID: c.id, settings: c.s3!.settings)
        let entry = try XCTUnwrap(recovered.entries[m.id])
        XCTAssertEqual(try entry.payload.read(offset: 0, count: data.count), data)
        XCTAssertEqual(try XCTUnwrap(SecureFiles.info(entry.directory)).st_mode & 0o777, 0o700)
        XCTAssertEqual(try XCTUnwrap(SecureFiles.info(entry.directory + "/video.mp4")).st_mode & 0o777, 0o600)
        try SecureFiles.atomicWrite(Data([1]), to: entry.directory + "/video.mp4", mode: 0o600)
        let damaged = try S3Spool(path: path, storeID: c.id, settings: c.s3!.settings)
        XCTAssertEqual(damaged.entries.count, 0); XCTAssertEqual(damaged.damaged, [m.id]); XCTAssertGreaterThan(damaged.bytes, 0)
    }
    func testSpoolQuotaDoesNotEvictAndRetryUsesRetainedBytes() throws {
        let c = try config(), spool = try S3Spool(path: try root() + "/" + c.id, storeID: c.id, settings: c.s3!.settings)
        let (m, data) = shard(c)
        spool.freeSpace = { _ in 0 }; XCTAssertThrowsError(try spool.publish(m, data: data)); XCTAssertTrue(spool.entries.isEmpty)
        spool.freeSpace = { _ in Int64.max / 2 }
        spool.checkpoint = { if $0 == "payload" { throw ServiceError("Injected write failure") } }
        XCTAssertThrowsError(try spool.publish(m, data: data))
        spool.checkpoint = { _ in }
        XCTAssertEqual(try spool.publish(m, data: data).metadata, m)
        spool.settings.spoolLimitBytes = spool.bytes
        let (next, bytes) = shard(c); XCTAssertThrowsError(try spool.publish(next, data: bytes))
        XCTAssertEqual(spool.entries.count, 1)
        try spool.delivered(m.id); XCTAssertTrue(spool.entries.isEmpty)
    }
    func testMultipartSizing() {
        XCTAssertEqual(AWSS3Transport.partSize(64 * 1024 * 1024), 16 * 1024 * 1024)
        let size: Int64 = 5 * 1024 * 1024 * 1024 * 1024
        XCTAssertLessThanOrEqual((size + Int64(AWSS3Transport.partSize(size)) - 1) / Int64(AWSS3Transport.partSize(size)), 10000)
    }
    func testRAMMP4H264FullAndShort() async throws { try await playable(codec: kCMVideoCodecType_H264) }
    func testRAMMP4HEVCFullAndShort() async throws { try await playable(codec: kCMVideoCodecType_HEVC) }
    private func playable(codec: CMVideoCodecType) async throws {
        let path = try root(), frames = try StoreTests.video(codec: codec)
        for count in [1, 10, 45] {
            let first = frames[0]
            let writer = try MemoryMP4Shard(codec: first.codec, sets: first.parameterSets, clock: first.clockRate, timestamp: first.frame.timestamp)
            for media in frames.prefix(count) { try writer.append(media.frame) }
            let bytes = try writer.finish()
            XCTAssertGreaterThan(bytes.count, 0)
            // Persist the result only as a test playback fixture, never by the writer.
            let file = path + "/\(count).mp4"; try SecureFiles.atomicWrite(bytes, to: file, mode: 0o600)
            let asset = AVURLAsset(url: URL(fileURLWithPath: file)), tracks = try await asset.loadTracks(withMediaType: .video)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first), outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(output); XCTAssertTrue(reader.startReading())
            var decoded = 0; while output.copyNextSampleBuffer() != nil { decoded += 1 }
            XCTAssertEqual(decoded, count); XCTAssertEqual(reader.status, .completed)
        }
    }
    func testUploadSlotsRetrySerializationAndStableBytes() async throws {
        let c = try config(), network = FakeS3(), queue = DispatchQueue(label: "s3-test")
        let spool = try S3Spool(path: try root() + "/" + c.id, storeID: c.id, settings: c.s3!.settings)
        let manager = S3UploadManager(configuration: c, spool: spool, queue: queue, factory: { _ in network }, jitter: { 0 })
        let shards = (0..<6).map { _ in shard(c) }
        try await on(queue) { for (m, bytes) in shards { manager.ready(m, data: bytes) } }
        try await eventually { await network.attempts.count == 5 }
        let first = await network.attempts[0]
        await network.resolve(first.metadata.id, error: .init(kind: .transient, message: "500"))
        try await eventually { await network.attempts.count == 6 }
        // The queued live shard beats the retry; once one slot opens the serial retry can run.
        let second = await network.attempts[1]; await network.resolve(second.metadata.id)
        try await eventually { await network.attempts.count == 7 }
        let attempts = await network.attempts
        XCTAssertEqual(attempts[6].metadata, first.metadata)
        XCTAssertEqual(try attempts[6].payload.read(offset: 0, count: 100), try first.payload.read(offset: 0, count: 100))
        let status = try await on(queue) { manager.snapshot(assemblingBytes: 0) }
        XCTAssertLessThanOrEqual(status.active, 5); XCTAssertEqual(status.retrying, 1)
        XCTAssertTrue(spool.entries.isEmpty)
        await network.configure(automatic: true); await network.resolveAll()
        try await eventually { try await self.on(queue) { !manager.outstanding } }
        try await on(queue) { manager.stopDispatch() }
    }
    func testOfflineSpoolsAndShutdownIsDurableWithoutWaitingForNetwork() async throws {
        let c = try config(), network = FakeS3(), queue = DispatchQueue(label: "s3-offline")
        let path = try root() + "/" + c.id
        let spool = try S3Spool(path: path, storeID: c.id, settings: c.s3!.settings)
        let manager = S3UploadManager(configuration: c, spool: spool, queue: queue, factory: { _ in network })
        let (m, bytes) = shard(c)
        try await on(queue) { manager.ready(m, data: bytes) }
        try await eventually { await network.attempts.count == 1 }
        await network.resolve(m.id, error: .init(kind: .network, message: "offline"))
        try await eventually { try await self.on(queue) { manager.snapshot(assemblingBytes: 0).spoolCount == 1 } }
        let status = try await on(queue) { manager.snapshot(assemblingBytes: 0) }
        XCTAssertTrue(status.spooling); XCTAssertTrue(status.acceptingRecording); XCTAssertEqual(status.volatileShards, 0)
        try await on(queue) { manager.stopDispatch(); XCTAssertTrue(manager.safeToExit) }
        XCTAssertEqual(try S3Spool(path: path, storeID: c.id, settings: c.s3!.settings).entries.count, 1)
    }
    func testSetupFailedSaveDisabledAndCancellation() async throws {
        let c = try config(), network = FakeS3()
        await network.configure(failure: .init(kind: .destination, message: "denied"))
        let jobs = S3SetupJobs(factory: { _ in network })
        let job = try jobs.start(draft: c, original: nil, uid: geteuid())
        try await eventually { try jobs.poll(job.id, uid: geteuid()).state == "failed" }
        XCTAssertThrowsError(try jobs.prepared(job.id, uid: geteuid(), saveDisabled: false, current: nil))
        XCTAssertFalse(try jobs.prepared(job.id, uid: geteuid(), saveDisabled: true, current: nil).enabled)
        XCTAssertThrowsError(try jobs.poll(job.id, uid: geteuid() + 1))
        _ = try jobs.cancel(job.id, uid: geteuid())
        XCTAssertThrowsError(try jobs.prepared(job.id, uid: geteuid(), saveDisabled: true, current: nil))
        jobs.stop()
    }
    func testS3StoreRotatesShortShardsAndDoesNotWriteMediaOnSuccess() async throws {
        var c = try config(); c.shardDuration = "1s"
        let network = FakeS3(); await network.configure(automatic: true)
        let path = try root(), store = try S3RecordingStore(configuration: c, spoolRoot: path, factory: { _ in network }, log: { _ in })
        for media in try StoreTests.video() { store.accept(.media(camera: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", name: "Living Room", media)) }
        store.accept(.end(camera: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        try await eventually { store.snapshot().s3?.confirmedUploads == 3 }
        XCTAssertEqual(store.snapshot().recordedFrames, 45); XCTAssertNil(store.snapshot().lastError)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: path + "/" + c.id).isEmpty)
        let attempts = await network.attempts
        XCTAssertEqual(attempts.count, 3)
        XCTAssertTrue(attempts.allSatisfy { $0.metadata.key.hasPrefix("test/Living Room--aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/") })
        XCTAssertTrue(store.finish(timeout: 5))
    }
    func testEncryptedH264AndHEVCShardsDecryptToPlayableMP4WithoutNormalDiskWrites() async throws {
        for codec in [kCMVideoCodecType_H264, kCMVideoCodecType_HEVC] {
            var c = try config(); c.shardDuration = "1s"
            c.s3?.clientEncryption = S3ClientEncryption(password: "test encryption passphrase")
            c.schemaVersion = 2
            let network = FakeS3(); await network.configure(automatic: true)
            let path = try root(), store = try S3RecordingStore(configuration: c, spoolRoot: path, factory: { _ in network }, log: { _ in })
            let camera = UUID().uuidString
            for media in try StoreTests.video(codec: codec, count: 20) { store.accept(.media(camera: camera, name: "Encrypted camera", media)) }
            store.accept(.end(camera: camera))
            try await eventually { store.snapshot().s3?.confirmedUploads == 2 }
            XCTAssertTrue(store.snapshot().s3?.clientEncrypted == true)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: path + "/" + c.id).isEmpty)
            var total = 0
            for attempt in await network.attempts {
                XCTAssertEqual(attempt.metadata.encryption, RecordingEncryption.format)
                let bytes = try attempt.payload.read(offset: 0, count: Int(attempt.metadata.size))
                XCTAssertEqual(attempt.metadata.sha256, S3ShardMetadata.hash(bytes))
                let mp4 = try RecordingEncryption.decrypt(bytes, password: "test encryption passphrase")
                let file = path + "/" + attempt.metadata.id + ".mp4"
                try SecureFiles.atomicWrite(mp4, to: file, mode: 0o600) // Test-only playback fixture.
                let asset = AVURLAsset(url: URL(fileURLWithPath: file)), tracks = try await asset.loadTracks(withMediaType: .video)
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first), outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                reader.add(output); XCTAssertTrue(reader.startReading())
                while output.copyNextSampleBuffer() != nil { total += 1 }
                XCTAssertEqual(reader.status, .completed)
            }
            XCTAssertEqual(total, 20); XCTAssertTrue(store.finish(timeout: 5))
        }
    }
    func testEncryptionChangeDoesNotReencryptPendingBacklog() async throws {
        var c = try config(); c.s3?.clientEncryption = S3ClientEncryption(password: "original passphrase")
        c.schemaVersion = 2
        let path = try root(), camera = UUID().uuidString, network = FakeS3()
        let store = try S3RecordingStore(configuration: c, spoolRoot: path, factory: { _ in network }, log: { _ in })
        let frames = try StoreTests.video(count: 1)
        store.accept(.media(camera: camera, name: "Camera", frames[0]))
        c.s3?.clientEncryption = S3ClientEncryption(password: "replacement passphrase")
        try store.update(c) // Finalizes the already-open short shard with the original password.
        try await eventually { await network.attempts.count == 1 }
        store.accept(.media(camera: camera, name: "Camera", frames[0])); store.accept(.end(camera: camera))
        try await eventually { await network.attempts.count == 2 }
        XCTAssertTrue(store.finish(timeout: 5)) // All unconfirmed ciphertext is durably spooled.
        let before = await network.attempts
        let spool = try S3Spool(path: path + "/" + c.id, storeID: c.id, settings: c.s3!.settings)
        XCTAssertEqual(spool.entries.count, 2)
        for (i, attempt) in before.enumerated() {
            let bytes = try attempt.payload.read(offset: 0, count: Int(attempt.metadata.size))
            XCTAssertEqual(try spool.entries[attempt.metadata.id]?.payload.read(offset: 0, count: bytes.count), bytes)
            XCTAssertNoThrow(try RecordingEncryption.decrypt(bytes, password: i == 0 ? "original passphrase" : "replacement passphrase"))
        }
        await network.resolveAll()
        await network.configure(automatic: true)
        c.s3?.clientEncryption = S3ClientEncryption(enabled: false)
        c.enabled = false
        let restarted = try S3RecordingStore(configuration: c, spoolRoot: path, factory: { _ in network }, log: { _ in })
        try await eventually { restarted.snapshot().s3?.confirmedUploads == 2 }
        let replay = Array(await network.attempts.dropFirst(2))
        for attempt in replay {
            let original = try XCTUnwrap(before.first { $0.metadata.id == attempt.metadata.id })
            XCTAssertEqual(attempt.metadata, original.metadata)
            // Disk entries are removed on success, so the frozen manifest hash verifies identical payload identity.
            XCTAssertEqual(attempt.metadata.sha256, original.metadata.sha256)
        }
        XCTAssertTrue(restarted.finish(timeout: 5))
    }
    func testRecoveryProbeIsPacedNonoverlappingAndLiveSlotIsReserved() async throws {
        let c = try config(), network = FakeS3(), clock = Clock(), queue = DispatchQueue(label: "s3-recovery")
        let spool = try S3Spool(path: try root() + "/" + c.id, storeID: c.id, settings: c.s3!.settings)
        var old: [S3ShardMetadata] = []
        for index in 0..<6 {
            let (m, data) = shard(c, at: Date(timeIntervalSince1970: Double(index + 1)))
            _ = try spool.publish(m, data: data); old.append(m)
        }
        let manager = S3UploadManager(configuration: c, spool: spool, queue: queue, factory: { _ in network }, now: { clock.time }, jitter: { 0 })
        try await on(queue) { manager.tick() }
        try await eventually { await network.attempts.count == 4 }
        let (live, bytes) = shard(c)
        try await on(queue) { manager.ready(live, data: bytes) }
        try await eventually { await network.attempts.count == 5 }
        await network.resolve(old[0].id, error: .init(kind: .network, message: "offline"))
        try await eventually { try await self.on(queue) { manager.snapshot(assemblingBytes: 0).spooling } }
        try await on(queue) { clock.time = 59; manager.tick() }
        var count = await network.attempts.count; XCTAssertEqual(count, 5)
        try await on(queue) { clock.time = 60; manager.tick() }
        try await eventually { await network.attempts.count == 6 }
        let probe = await network.attempts[5]; XCTAssertEqual(probe.metadata.id, old[0].id)
        try await on(queue) { clock.time = 200; manager.tick(); manager.tick() }
        count = await network.attempts.count; XCTAssertEqual(count, 6)
        await network.resolve(probe.metadata.id)
        try await eventually { try await self.on(queue) { !manager.snapshot(assemblingBytes: 0).spooling } }
        await network.configure(automatic: true); await network.resolveAll()
        try await eventually { try await self.on(queue) { !manager.outstanding } }
        try await on(queue) { manager.stopDispatch() }
    }
    func testSpoolFailureSuspendsAndRAMProbeBreaksRecoveryDeadlock() async throws {
        let c = try config(), network = FakeS3(), clock = Clock(), queue = DispatchQueue(label: "s3-full")
        let spool = try S3Spool(path: try root() + "/" + c.id, storeID: c.id, settings: c.s3!.settings)
        spool.freeSpace = { _ in 0 }
        let manager = S3UploadManager(configuration: c, spool: spool, queue: queue, factory: { _ in network }, now: { clock.time })
        let (m, bytes) = shard(c)
        try await on(queue) { manager.ready(m, data: bytes) }
        try await eventually { await network.attempts.count == 1 }
        await network.resolve(m.id, error: .init(kind: .network, message: "offline"))
        try await eventually { try await self.on(queue) { manager.suspended } }
        var status = try await on(queue) { manager.snapshot(assemblingBytes: 0) }
        XCTAssertFalse(status.acceptingRecording); XCTAssertEqual(status.volatileShards, 1); XCTAssertEqual(status.spoolCount, 0)
        try await on(queue) { clock.time = 60; manager.tick() }
        try await eventually { await network.attempts.count == 2 }
        await network.resolve(m.id)
        try await eventually { try await self.on(queue) { !manager.outstanding } }
        try await on(queue) { spool.freeSpace = { _ in Int64.max / 2 }; manager.tick() }
        status = try await on(queue) { manager.snapshot(assemblingBytes: 0) }
        XCTAssertTrue(status.acceptingRecording); XCTAssertFalse(status.spooling)
        try await on(queue) { manager.stopDispatch() }
    }
    func testDisabledStoreFinishesButDrainsAndBlocksRemoval() async throws {
        var c = try config(); c.shardDuration = "1m"
        let network = FakeS3(), path = try root(), store = try S3RecordingStore(configuration: c, spoolRoot: path, factory: { _ in network }, log: { _ in })
        for media in try StoreTests.video(count: 10) { store.accept(.media(camera: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", name: "Test", media)) }
        c.enabled = false; try store.update(c)
        XCTAssertFalse(store.removable())
        try await eventually { await network.attempts.count == 1 }
        XCTAssertFalse(store.removable()); XCTAssertEqual(store.snapshot().activeRecordings, 0)
        let id = await network.attempts[0].metadata.id; await network.resolve(id)
        try await eventually { store.removable() }
        XCTAssertTrue(store.finish(timeout: 3))
    }
    func testActiveUploadIsSpooledAtShutdownWithoutNetworkWait() async throws {
        let c = try config(), network = FakeS3(), queue = DispatchQueue(label: "s3-shutdown")
        let path = try root() + "/" + c.id, spool = try S3Spool(path: path, storeID: c.id, settings: c.s3!.settings)
        let manager = S3UploadManager(configuration: c, spool: spool, queue: queue, factory: { _ in network })
        let (m, bytes) = shard(c)
        try await on(queue) { manager.ready(m, data: bytes) }
        try await eventually { await network.attempts.count == 1 }
        try await on(queue) { manager.stopDispatch(); XCTAssertTrue(manager.safeToExit) }
        XCTAssertEqual(try S3Spool(path: path, storeID: c.id, settings: c.s3!.settings).entries.count, 1)
        await network.resolveAll()
        try await on(queue) { XCTAssertEqual(spool.entries.count, 1) } // Late acknowledgment doesn't race restart ownership.
    }
    func testSetupExpirationAndRevisionChecks() async throws {
        let c = try config(), network = FakeS3(), clock = Clock()
        await network.configure(automatic: true)
        let jobs = S3SetupJobs(factory: { _ in network }, now: { clock.time })
        let job = try jobs.start(draft: c, original: nil, uid: geteuid())
        try await eventually { try jobs.poll(job.id, uid: geteuid()).state == "validated" }
        XCTAssertThrowsError(try jobs.prepared(job.id, uid: geteuid(), saveDisabled: false, current: c))
        XCTAssertEqual(try jobs.prepared(job.id, uid: geteuid(), saveDisabled: false, current: nil), c)
        clock.time = 901; XCTAssertThrowsError(try jobs.poll(job.id, uid: geteuid()))
        jobs.stop()
    }
    func testIPCRemainsResponsiveWhileAWSUploadIsBlocked() async throws {
        let path = try root(), c = try config(), network = FakeS3()
        let server = AgentServer(directory: path, authorization: .local(geteuid()), system: false, transportFactory: { _ in network })
        func exchange(_ request: Request) throws -> Reply {
            var pair = [Int32](repeating: -1, count: 2)
            XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
            defer { close(pair[0]); close(pair[1]) }
            try SocketIO.configure(pair[0]); try SocketIO.configure(pair[1])
            try SocketIO.write(JSONEncoder().encode(request), fd: pair[0], deadline: ProcessInfo.processInfo.systemUptime + 1)
            server.handle(pair[1], started: ProcessInfo.processInfo.systemUptime)
            return try JSONDecoder().decode(Reply.self, from: SocketIO.read(fd: pair[0], deadline: ProcessInfo.processInfo.systemUptime + 1))
        }
        let job = try XCTUnwrap(exchange(Request(protocolVersion: 1, operation: S3SetupJobs.startOperation, store: c)).setup)
        try await eventually { await network.attempts.count == 1 }
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<10 { XCTAssertTrue(try exchange(Request(protocolVersion: 1, operation: "status")).status?.ready == true) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        let cancelled = try exchange(Request(protocolVersion: 1, operation: "stores.setup.cancel", setupID: job.id))
        XCTAssertEqual(cancelled.setup?.state, "cancelled")
        await network.resolveAll()
        XCTAssertTrue(try server.stores.list().isEmpty)
    }
    func testEveryPublicationBoundaryRetainsRecoverableOrReportedWork() throws {
        let c = try config()
        for boundary in ["reserved", "payload", "metadata", "staged", "renamed"] {
            let path = try root() + "/" + c.id, spool = try S3Spool(path: path, storeID: c.id, settings: c.s3!.settings)
            let (m, data) = shard(c)
            spool.checkpoint = { if $0 == boundary { throw ServiceError("Injected failure") } }
            XCTAssertThrowsError(try spool.publish(m, data: data))
            let after = try S3Spool(path: path, storeID: c.id, settings: c.s3!.settings)
            XCTAssertEqual(after.entries.count + after.damaged.count, 1)
            XCTAssertGreaterThan(after.bytes, 0)
            spool.checkpoint = { _ in }
            _ = try spool.publish(m, data: data)
            XCTAssertEqual(try spool.entries[m.id]?.payload.read(offset: 0, count: 100), data)
            spool.checkpoint = { if $0 == "delete" { throw ServiceError("Injected deletion failure") } }
            XCTAssertThrowsError(try spool.delivered(m.id)); XCTAssertEqual(spool.entries.count, 1)
        }
    }
    func testManifestHardlinksAndSymlinksAreRetainedForReadRetry() throws {
        let c = try config(), path = try root(), spool = try S3Spool(path: path + "/spool/" + c.id, storeID: c.id, settings: c.s3!.settings)
        let (m, bytes) = shard(c), entry = try spool.publish(m, data: bytes)
        XCTAssertEqual(link(entry.directory + "/metadata.json", path + "/linked.json"), 0)
        try spool.scan(); XCTAssertTrue(spool.entries.isEmpty); XCTAssertEqual(spool.damaged.count, 1)
        let id = UUID().uuidString
        XCTAssertEqual(symlink(path, spool.path + "/" + id), 0)
        try spool.scan(); XCTAssertEqual(spool.damaged.count, 2)
    }
    func testCredentialReplacementWithBacklogAndDestinationChangeRefusal() async throws {
        var c = try config(); c.shardDuration = "1s"
        let network = FakeS3(), store = try S3RecordingStore(configuration: c, spoolRoot: try root(), factory: { _ in network }, log: { _ in })
        for media in try StoreTests.video(count: 15) { store.accept(.media(camera: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", name: "Original name", media)) }
        store.accept(.end(camera: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        try await eventually { await network.attempts.count == 1 }
        let original = await network.attempts[0].metadata
        await network.resolve(original.id, error: .init(kind: .destination, message: "expired credential"))
        try await eventually { store.snapshot().s3?.spoolCount == 1 }
        var moved = c; moved.s3?.prefix = "moved/"; XCTAssertThrowsError(try store.update(moved))
        c.name = "Repaired"; c.s3?.credentials?.secretAccessKey = String(repeating: "b", count: 40)
        try store.update(c)
        try await eventually { await network.attempts.count == 2 }
        let replayed = await network.attempts[1].metadata; XCTAssertEqual(replayed, original)
        await network.resolve(original.id)
        try await eventually { store.snapshot().s3?.confirmedUploads == 1 }
        XCTAssertTrue(store.finish(timeout: 3))
    }
    func testLifecycleDenialWarnsWithoutBlockingVideoUploads() async throws {
        var c = try config(); c.s3?.lifecycle = "Managed"
        let network = FakeS3(); await network.configure(automatic: true)
        await network.failLifecycle(.init(kind: .destination, message: "AccessDenied"))
        let store = try S3RecordingStore(configuration: c, spoolRoot: try root(), factory: { _ in network }, log: { _ in })
        let camera = UUID().uuidString
        for frame in try StoreTests.video(count: 1) { store.accept(.media(camera: camera, name: "Test", frame)) }
        store.accept(.end(camera: camera))
        try await eventually { store.snapshot().s3?.confirmedUploads == 1 && store.snapshot().s3?.lifecycleWarning != nil }
        XCTAssertTrue(store.snapshot().s3?.acceptingRecording == true); XCTAssertFalse(store.snapshot().s3?.spooling == true)
        XCTAssertNil(store.snapshot().s3?.appliedRetentionDays); XCTAssertTrue(store.finish(timeout: 3))
    }
}
