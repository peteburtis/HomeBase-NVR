import XCTest
import Foundation
import Darwin

actor ManifestTransport: S3Transport {
    struct Put: Sendable { let key: String; let data: Data }
    var puts: [Put] = []
    var hold = false
    var pending: CheckedContinuation<Void, Error>?
    func setHold(_ value: Bool) { hold = value }
    func validate(_ configuration: S3Configuration) async throws {}
    func upload(_ metadata: S3ShardMetadata, payload: S3Payload) async throws {}
    func reconcile(_ configuration: RecordingStoreConfiguration) async throws {}
    func publishManifest(key: String, data: Data, storeID: String, cameraID: String) async throws {
        puts.append(Put(key: key, data: data))
        if hold { try await withCheckedThrowingContinuation { pending = $0 } }
    }
    func release(error: Error? = nil) {
        let value = pending; pending = nil
        if let error { value?.resume(throwing: error) } else { value?.resume() }
    }
}

final class S3PlaybackManifestTests: XCTestCase {
    final class Clock { var date = Date(timeIntervalSince1970: 1_789_732_800) } // 2026-09-18 UTC
    func root() throws -> String {
        let value = "/private/tmp/hbnvr-playback-manifest-" + UUID().uuidString
        try SecureFiles.ensureDirectory(value, owner: geteuid(), mode: 0o700)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: value) }
        return value
    }
    func config() throws -> RecordingStoreConfiguration {
        var value = RecordingStoreConfiguration(ownerUID: geteuid(), ownerUUID: try StoreDirectory.identity(geteuid()))
        value.type = "S3"; value.s3 = .init(bucket: "test-recordings", region: "us-west-2", prefix: "test/", lifecycle: "External")
        return value
    }
    func shard(_ config: RecordingStoreConfiguration, camera: String, at: Double, duration: Double = 60) -> S3ShardMetadata {
        let media = EncodedMedia(codec: "H264", clockRate: 90_000, parameterSets: [],
            frame: .init(payload: Data(), timestamp: 100, keyFrame: true), receivedAt: Date(timeIntervalSince1970: at),
            receivedUptime: 100, cameraUTC: at, ssrc: 42)
        let timing = ShardTimingMetadata(storeID: config.id, cameraID: camera, media: media,
            time: .init(cameraUTC: at, receivedUTC: at, canonicalUTC: at, canonicalSource: .camera, epochID: UUID().uuidString))
        var metadata = S3ShardMetadata.make(store: config, camera: camera, name: "Camera", capturedAt: media.receivedAt,
            data: Data([1, 2, 3]), id: timing.shardID)
        metadata.timing = timing; metadata.endTicks = Int64(duration * 90_000)
        return metadata
    }
    func eventually(_ body: () async throws -> Bool) async throws {
        for _ in 0..<250 { if try await body() { return }; try await Task.sleep(for: .milliseconds(20)) }
        throw ServiceError("Manifest test deadline exceeded")
    }
    func testDailyMonthlyBoundaryAndRestartPreserveConfirmedEntries() throws {
        let c = try config(), camera = UUID().uuidString, root = try root(), clock = Clock()
        let queue = DispatchQueue(label: "index-test"), transport = ManifestTransport()
        let publisher = S3PlaybackPublisher(configuration: c, path: root + "/index", queue: queue, factory: { _ in transport }, now: { clock.date })
        let midnight = floor(clock.date.timeIntervalSince1970 / 86400) * 86400
        let old = shard(c, camera: camera, at: midnight - 30), recent = shard(c, camera: camera, at: midnight + 120)
        try publisher.record(recent); try publisher.record(old); try publisher.record(recent)
        XCTAssertEqual(publisher.entries.count, 2)
        let today = S3PlaybackPublisher.day(midnight), yesterday = S3PlaybackPublisher.day(midnight - 1)
        let catalog = publisher.document(.init(camera: camera, period: nil), at: clock.date)
        XCTAssertEqual(catalog.days?.map(\.day), [yesterday, today])
        XCTAssertEqual(catalog.days?.first?.end, midnight)
        XCTAssertEqual(publisher.document(.init(camera: camera, period: today), at: clock.date).shards?.count, 2)
        let monthly = publisher.document(.init(camera: camera, period: String(today.prefix(7))), at: clock.date)
        XCTAssertEqual(monthly.shards?.map(\.id), [old.id])
        let restarted = S3PlaybackPublisher(configuration: c, path: root + "/index", queue: queue, factory: { _ in transport }, now: { clock.date })
        XCTAssertEqual(restarted.entries.count, 2)
        XCTAssertGreaterThan(restarted.pendingPublications, 0)
        XCTAssertEqual(try SecureFiles.info(root + "/index")!.st_mode & 0o777, 0o700)
        XCTAssertEqual(try SecureFiles.info(root + "/index/" + old.id + ".json")!.st_mode & 0o777, 0o600)
    }
    func testJournalAndManifestKeepRawKeysAndThumbnailPrefixes() throws {
        var c = try config(); c.s3?.prefix = "Entrée + %20 &/"
        let camera = UUID().uuidString, root = try root(), clock = Clock(), queue = DispatchQueue(label: "raw-key-journal")
        let transport = ManifestTransport(), at = clock.date.timeIntervalSince1970 + 10
        let timed = shard(c, camera: camera, at: at)
        var m = S3ShardMetadata.make(store: c, camera: camera, name: "Room + %2B", capturedAt: Date(timeIntervalSince1970: at),
                                     data: Data([1, 2, 3]), id: timed.id)
        m.timing = timed.timing; m.endTicks = timed.endTicks
        let publisher = S3PlaybackPublisher(configuration: c, path: root + "/index", queue: queue, factory: { _ in transport }, now: { clock.date })
        try publisher.record(m)
        let restored = S3PlaybackPublisher(configuration: c, path: root + "/index", queue: queue, factory: { _ in transport }, now: { clock.date })
        let doc = restored.document(.init(camera: camera, period: S3PlaybackPublisher.day(at)), at: clock.date)
        let decoded = try JSONDecoder().decode(S3PlaybackDocument.self, from: JSONEncoder().encode(doc))
        XCTAssertEqual(decoded.shards?.first?.key, m.key)
        XCTAssertTrue(m.key.contains("Room + %2B"))
        XCTAssertNotNil(S3RepairCandidate.parse(.init(key: m.key, size: 3, etag: "example"), prefix: c.s3!.prefix, cameras: [camera]))
        let thumbnailKey = S3Thumbnail.key(prefix: c.s3!.prefix, camera: camera, slot: S3Thumbnail.firstSlot(atOrAfter: at), encrypted: true)
        XCTAssertTrue(thumbnailKey.hasPrefix(c.s3!.prefix))
        XCTAssertTrue(S3Thumbnail.listed(thumbnailKey, prefix: c.s3!.prefix, cameras: [camera]))
    }
    func testConcurrentCompletionKeepsNewerRevisionAndPublishesCatalogLast() async throws {
        let c = try config(), camera = UUID().uuidString, root = try root(), clock = Clock()
        let queue = DispatchQueue(label: "index-order"), transport = ManifestTransport()
        await transport.setHold(true)
        let publisher = S3PlaybackPublisher(configuration: c, path: root + "/index", queue: queue, factory: { _ in transport }, now: { clock.date })
        let start = clock.date.timeIntervalSince1970 + 100
        try queue.sync { try publisher.record(shard(c, camera: camera, at: start)); publisher.tick() }
        try await eventually { await transport.puts.count == 1 }
        try queue.sync { try publisher.record(shard(c, camera: camera, at: start + 120)) }
        await transport.setHold(false); await transport.release()
        try await eventually { queue.sync { publisher.pendingPublications == 0 } }
        let puts = await transport.puts
        XCTAssertEqual(puts.count, 4)
        XCTAssertTrue(puts[1].key.hasSuffix("catalog.json"), "New shards cannot starve the prior snapshot's catalog")
        XCTAssertTrue(puts.last!.key.hasSuffix("catalog.json"))
        let day = try JSONDecoder().decode(S3PlaybackDocument.self, from: puts[2].data)
        XCTAssertEqual(day.shards?.count, 2)
        XCTAssertEqual(Set(day.shards!.map(\.id)).count, 2)
    }
    func testMidnightPublishesClosedMonthWithoutAnotherShard() async throws {
        let c = try config(), camera = UUID().uuidString, root = try root(), clock = Clock()
        let queue = DispatchQueue(label: "midnight-index"), transport = ManifestTransport()
        let publisher = S3PlaybackPublisher(configuration: c, path: root + "/index", queue: queue, factory: { _ in transport }, now: { clock.date })
        try queue.sync { try publisher.record(shard(c, camera: camera, at: clock.date.timeIntervalSince1970 + 10)); publisher.tick() }
        try await eventually { queue.sync { publisher.pendingPublications == 0 } }
        let initialPuts = await transport.puts
        XCTAssertFalse(initialPuts.contains { $0.key.contains("/months/") })
        queue.sync { clock.date = clock.date.addingTimeInterval(86400); publisher.tick() }
        try await eventually { queue.sync { publisher.pendingPublications == 0 } }
        let monthly = await transport.puts.filter { $0.key.contains("/months/") }
        XCTAssertEqual(monthly.count, 1)
        XCTAssertEqual(try JSONDecoder().decode(S3PlaybackDocument.self, from: monthly[0].data).shards?.count, 1)
    }
    func testJournalFailureRetainsConfirmedFootageAndRetriesWithoutUpload() async throws {
        let c = try config(), camera = UUID().uuidString, root = try root(), clock = Clock()
        let queue = DispatchQueue(label: "journal-failure"), network = FakeS3()
        let spool = try S3Spool(path: root + "/spool", storeID: c.id, settings: c.s3!.settings)
        let publisher = S3PlaybackPublisher(configuration: c, path: root + "/index", queue: queue, factory: { _ in network }, now: { clock.date })
        publisher.checkpoint = { _ in throw ServiceError("Injected journal write failure") }
        let manager = S3UploadManager(configuration: c, spool: spool, queue: queue, factory: { _ in network }, playback: publisher,
            now: { clock.date.timeIntervalSince1970 }, date: { clock.date })
        let metadata = shard(c, camera: camera, at: clock.date.timeIntervalSince1970)
        queue.sync { manager.ready(metadata, data: Data([1, 2, 3])) }
        try await eventually { await network.attempts.count == 1 }
        await network.resolve(metadata.id)
        try await eventually { queue.sync { spool.entries.count == 1 } }
        XCTAssertTrue(queue.sync { manager.outstanding })
        XCTAssertNotNil(queue.sync { manager.snapshot(assemblingBytes: 0).playbackWarning })
        queue.sync { publisher.checkpoint = { _ in }; clock.date = clock.date.addingTimeInterval(61); manager.tick() }
        XCTAssertFalse(queue.sync { manager.outstanding })
        let attempts = await network.attempts.count
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(queue.sync { publisher.entries.count }, 1)
        queue.sync { manager.stopDispatch() }
    }
    func testEncryptedManifestsAndPasswordReplacement() async throws {
        var c = try config(); c.s3?.clientEncryption = .init(enabled: true, password: "original password")
        let camera = UUID().uuidString, root = try root(), clock = Clock()
        let queue = DispatchQueue(label: "encrypted-index"), transport = ManifestTransport()
        let publisher = S3PlaybackPublisher(configuration: c, path: root + "/index", queue: queue, factory: { _ in transport }, now: { clock.date })
        try queue.sync { try publisher.record(shard(c, camera: camera, at: clock.date.timeIntervalSince1970)); publisher.tick() }
        try await eventually { queue.sync { publisher.pendingPublications == 0 } }
        let old = await transport.puts
        XCTAssertTrue(old.allSatisfy { $0.data.starts(with: RecordingEncryption.magic) })
        let document = try JSONDecoder().decode(S3PlaybackDocument.self, from: RecordingEncryption.decrypt(old.last!.data, password: "original password"))
        XCTAssertEqual(document.cameraID, camera)
        c.s3?.clientEncryption?.password = "replacement password"
        queue.sync { publisher.update(c); publisher.tick() }
        try await eventually { queue.sync { publisher.pendingPublications == 0 } }
        let latest = await transport.puts.last!
        XCTAssertNoThrow(try RecordingEncryption.decrypt(latest.data, password: "replacement password"))
        XCTAssertThrowsError(try RecordingEncryption.decrypt(latest.data, password: "original password"))
    }
    func testUnreadableJournalNeverRewritesPartialCloudIndex() throws {
        let c = try config(), camera = UUID().uuidString, root = try root(), clock = Clock()
        let queue = DispatchQueue(label: "broken-index"), transport = ManifestTransport()
        let publisher = S3PlaybackPublisher(configuration: c, path: root + "/index", queue: queue, factory: { _ in transport }, now: { clock.date })
        let metadata = shard(c, camera: camera, at: clock.date.timeIntervalSince1970)
        try publisher.record(metadata)
        try SecureFiles.atomicWrite(Data("{".utf8), to: root + "/index/" + metadata.id + ".json", mode: 0o600)
        let broken = S3PlaybackPublisher(configuration: c, path: root + "/index", queue: queue, factory: { _ in transport }, now: { clock.date })
        XCTAssertNotNil(broken.warning)
        XCTAssertEqual(broken.pendingPublications, 0)
        XCTAssertThrowsError(try broken.record(shard(c, camera: camera, at: clock.date.timeIntervalSince1970 + 60)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/index/" + metadata.id + ".json"))
    }
    func testLateReplayUpdatesOnlyItsDayMonthAndCatalog() async throws {
        let c = try config(), camera = UUID().uuidString, root = try root(), clock = Clock()
        let queue = DispatchQueue(label: "late-replay-index"), transport = ManifestTransport()
        let publisher = S3PlaybackPublisher(configuration: c, path: root + "/index", queue: queue, factory: { _ in transport }, now: { clock.date })
        try queue.sync { try publisher.record(shard(c, camera: camera, at: clock.date.timeIntervalSince1970)); publisher.tick() }
        try await eventually { queue.sync { publisher.pendingPublications == 0 } }
        let initial = await transport.puts.count
        let past = clock.date.timeIntervalSince1970 - 5 * 86400 + 100
        try queue.sync { try publisher.record(shard(c, camera: camera, at: past)); publisher.tick() }
        try await eventually { queue.sync { publisher.pendingPublications == 0 } }
        let changed = await Array(transport.puts.dropFirst(initial)).map(\.key)
        XCTAssertEqual(changed.count, 3)
        XCTAssertTrue(changed.contains { $0.hasSuffix("days/" + S3PlaybackPublisher.day(past) + ".json") })
        XCTAssertEqual(changed.filter { $0.contains("/months/") }.count, 1)
        XCTAssertTrue(changed.last!.hasSuffix("catalog.json"))
    }
    func testJournalSyncFailureDoesNotAcknowledgeAndCanRecover() throws {
        let c = try config(), camera = UUID().uuidString, root = try root(), clock = Clock()
        let queue = DispatchQueue(label: "sync-failure-index"), transport = ManifestTransport()
        let publisher = S3PlaybackPublisher(configuration: c, path: root + "/index", queue: queue, factory: { _ in transport }, now: { clock.date })
        let metadata = shard(c, camera: camera, at: clock.date.timeIntervalSince1970)
        publisher.checkpoint = { if $0 == "sync" { throw ServiceError("Injected directory sync failure") } }
        XCTAssertThrowsError(try publisher.record(metadata))
        XCTAssertTrue(publisher.entries.isEmpty)
        XCTAssertEqual(publisher.pendingPublications, 0)
        publisher.checkpoint = { _ in }
        XCTAssertNoThrow(try publisher.record(metadata))
        XCTAssertEqual(publisher.entries.count, 1)
        XCTAssertEqual(publisher.pendingPublications, 2)
    }
    func testDirectoryAncestrySyncFailuresRetainConfirmedFootageUntilRetry() async throws {
        for phase in ["leaf", "parent", "ancestor"] {
            let c = try config(), camera = UUID().uuidString, root = try root(), clock = Clock()
            let queue = DispatchQueue(label: "journal-ancestry-" + phase), network = FakeS3()
            let spool = try S3Spool(path: root + "/spool", storeID: c.id, settings: c.s3!.settings)
            let publisher = S3PlaybackPublisher(configuration: c, path: root + "/playback/" + c.id,
                queue: queue, factory: { _ in network }, now: { clock.date }, checkpoint: {
                    if $0 == "sync-ancestry-" + phase { throw ServiceError("Injected directory ancestry sync failure") }
                })
            XCTAssertNotNil(publisher.warning, phase)
            XCTAssertTrue(publisher.entries.isEmpty, phase)
            let manager = S3UploadManager(configuration: c, spool: spool, queue: queue, factory: { _ in network },
                playback: publisher, now: { clock.date.timeIntervalSince1970 }, date: { clock.date })
            let metadata = shard(c, camera: camera, at: clock.date.timeIntervalSince1970)
            queue.sync { manager.ready(metadata, data: Data([1, 2, 3])) }
            try await eventually { await network.attempts.count == 1 }
            await network.resolve(metadata.id)
            try await eventually { queue.sync { spool.entries.count == 1 } }
            XCTAssertTrue(queue.sync { manager.outstanding }, phase)
            XCTAssertTrue(queue.sync { publisher.entries.isEmpty }, phase)
            XCTAssertNotNil(queue.sync { manager.snapshot(assemblingBytes: 0).playbackWarning }, phase)

            var retriedPhases: [String] = []
            queue.sync {
                publisher.checkpoint = { retriedPhases.append($0) }
                clock.date = clock.date.addingTimeInterval(61)
                manager.tick()
            }
            XCTAssertEqual(Array(retriedPhases.prefix(3)),
                ["sync-ancestry-leaf", "sync-ancestry-parent", "sync-ancestry-ancestor"], phase)
            XCTAssertFalse(queue.sync { manager.outstanding }, phase)
            XCTAssertEqual(queue.sync { publisher.entries.count }, 1, phase)
            let attempts = await network.attempts.count
            XCTAssertEqual(attempts, 1, "Confirmed video must not be uploaded again after a journal sync failure")
            queue.sync { manager.stopDispatch() }
        }
    }
    func testAncestryBarrierRunsOnceAndAgainAfterEmptyDirectoryRecreation() throws {
        let c = try config(), camera = UUID().uuidString, root = try root(), clock = Clock()
        let queue = DispatchQueue(label: "journal-ancestry-once"), transport = ManifestTransport()
        var phases: [String] = []
        let path = root + "/playback/" + c.id
        let publisher = S3PlaybackPublisher(configuration: c, path: path, queue: queue,
            factory: { _ in transport }, now: { clock.date }, checkpoint: { phases.append($0) })
        let barrier = ["sync-ancestry-leaf", "sync-ancestry-parent", "sync-ancestry-ancestor"]
        XCTAssertEqual(phases, barrier)
        // These are empty directories created by this fixture. Recreating a
        // lost path must re-publish both directory entries durably.
        try FileManager.default.removeItem(atPath: path)
        try FileManager.default.removeItem(atPath: root + "/playback")
        phases.removeAll()
        try publisher.record(shard(c, camera: camera, at: clock.date.timeIntervalSince1970))
        XCTAssertEqual(Array(phases.prefix(3)), barrier)
        phases.removeAll()
        try publisher.record(shard(c, camera: camera, at: clock.date.timeIntervalSince1970 + 120))
        XCTAssertEqual(phases, ["write", "sync"], "Ordinary shards need only their record/directory sync, not ancestor fsyncs")
    }
    func testManifestFailureKeepsDurableJournalAndRetriesAfterMinute() async throws {
        let c = try config(), camera = UUID().uuidString, root = try root(), clock = Clock()
        let queue = DispatchQueue(label: "manifest-cloud-failure"), transport = ManifestTransport()
        await transport.setHold(true)
        let publisher = S3PlaybackPublisher(configuration: c, path: root + "/index", queue: queue, factory: { _ in transport }, now: { clock.date })
        try queue.sync { try publisher.record(shard(c, camera: camera, at: clock.date.timeIntervalSince1970)); publisher.tick() }
        try await eventually { await transport.puts.count == 1 }
        await transport.release(error: S3Failure(kind: .network, message: "Offline"))
        try await eventually { queue.sync { publisher.warning != nil } }
        XCTAssertEqual(queue.sync { publisher.entries.count }, 1)
        queue.sync { clock.date = clock.date.addingTimeInterval(59); publisher.tick() }
        let beforeRetry = await transport.puts.count
        XCTAssertEqual(beforeRetry, 1)
        await transport.setHold(false)
        queue.sync { clock.date = clock.date.addingTimeInterval(2); publisher.tick() }
        try await eventually { queue.sync { publisher.pendingPublications == 0 } }
        let puts = await transport.puts
        XCTAssertEqual(puts[0].key, puts[1].key)
        XCTAssertEqual(puts[0].data, puts[1].data)
        XCTAssertNil(queue.sync { publisher.warning })
    }
    func testManualSpoolingHoldsManifestsUntilReleased() async throws {
        var c = try config(); var tuning = S3Tuning(); tuning.forceSpooling = true; c.s3?.tuning = tuning
        let camera = UUID().uuidString, root = try root(), clock = Clock()
        let queue = DispatchQueue(label: "manifest-manual-hold"), transport = ManifestTransport()
        let publisher = S3PlaybackPublisher(configuration: c, path: root + "/index", queue: queue, factory: { _ in transport }, now: { clock.date })
        try queue.sync { try publisher.record(shard(c, camera: camera, at: clock.date.timeIntervalSince1970)); publisher.tick() }
        let held = await transport.puts.count
        XCTAssertEqual(held, 0)
        XCTAssertEqual(queue.sync { publisher.pendingPublications }, 2)
        tuning.forceSpooling = false; c.s3?.tuning = tuning
        queue.sync { publisher.update(c); publisher.tick() }
        try await eventually { queue.sync { publisher.pendingPublications == 0 } }
        let delivered = await transport.puts.count
        XCTAssertEqual(delivered, 2)
    }
}
