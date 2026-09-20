import XCTest
import AVFoundation
import ImageIO

final class S3ThumbnailTests: XCTestCase {
    let slot = 1_789_733_400.0
    func fixture(_ c: RecordingStoreConfiguration, camera: String, count: Int = 45, codec: CMVideoCodecType = kCMVideoCodecType_H264) throws -> [EncodedMedia] {
        var timeline = RecordingTimeline()
        return try StoreTests.video(codec: codec, count: count).map { original in
            let offset = Double(original.frame.timestamp) / Double(original.clockRate)
            var media = EncodedMedia(codec: original.codec, clockRate: original.clockRate, parameterSets: original.parameterSets,
                frame: original.frame, receivedAt: Date(timeIntervalSince1970: slot - 1 + offset), receivedUptime: 100 + offset,
                cameraUTC: slot - 1 + offset, ssrc: 42)
            media.time = try timeline.observe(media); return media
        }
    }
    func testMidpointGridAndKnownNamesAreStableAcrossRenames() throws {
        XCTAssertEqual(S3Thumbnail.slots(start: 0, end: 3600), [600, 1800, 3000])
        XCTAssertEqual(S3Thumbnail.slots(start: 600, end: 1800), [600])
        XCTAssertEqual(S3Thumbnail.slots(start: 601, end: 1799), [])
        let camera = UUID().uuidString, store = UUID().uuidString
        let key = S3Thumbnail.key(prefix: "test/", camera: camera, slot: slot, encrypted: true)
        XCTAssertTrue(key.hasSuffix("/2026-09-18/12-10.jpg.hbnvr"), key)
        XCTAssertTrue(S3Thumbnail.listed(key, prefix: "test/", cameras: [camera]))
        XCTAssertFalse(S3Thumbnail.listed(key + ".tmp", prefix: "test/", cameras: [camera]))
        XCTAssertFalse(S3Thumbnail.listed(key, prefix: "test/", cameras: [UUID().uuidString]))
        XCTAssertEqual(S3Thumbnail.id(store: store, camera: camera, slot: slot), S3Thumbnail.id(store: store.lowercased(), camera: camera.lowercased(), slot: slot))
    }
    func testLiveSelectorUsesPrecedingKeyframeAndResetsAtDiscontinuity() throws {
        let c = try S3Tests().config(), camera = UUID().uuidString
        var selector = S3ThumbnailSelection(), selected: [(S3ThumbnailSelection.Frame, Double)] = []
        for media in try fixture(c, camera: camera) {
            if let item = selector.observe(media, sets: media.parameterSets, time: media.time!) { selected.append(item) }
        }
        XCTAssertEqual(selected.count, 1); XCTAssertEqual(selected.first?.1, slot)
        XCTAssertLessThanOrEqual(selected.first!.0.time.canonicalUTC, slot)
        var fresh = S3ThumbnailSelection()
        let late = try XCTUnwrap(fixture(c, camera: camera).last)
        XCTAssertNil(fresh.observe(late, sets: late.parameterSets, time: late.time!))
        var reset = S3ThumbnailSelection()
        let frames = try fixture(c, camera: camera), first = frames[0]
        XCTAssertNil(reset.observe(first, sets: first.parameterSets, time: first.time!))
        let discontinuous = RecordingTime(cameraUTC: slot, receivedUTC: slot, canonicalUTC: slot,
            canonicalSource: .camera, epochID: UUID().uuidString)
        XCTAssertNil(reset.observe(frames[1], sets: first.parameterSets, time: discontinuous), "Never reuse an old epoch's keyframe")
    }
    func testJPEGDimensionsEncryptionDescriptionAndSpoolRoundTrip() throws {
        let helper = S3Tests(), root = try helper.root()
        defer { try? FileManager.default.removeItem(atPath: root) }
        var c = try helper.config(); c.s3?.clientEncryption = .init(password: "thumbnail-test-password")
        let camera = UUID().uuidString, media = try fixture(c, camera: camera).first!
        let info = S3ThumbnailInfo(storeID: c.id, cameraID: camera, slot: slot, timestamp: media.time!.canonicalUTC)
        let sample = try S3Thumbnail.sample(media, sets: media.parameterSets)
        let (object, bytes) = try S3Thumbnail.render(sample, info: info, store: c)
        XCTAssertEqual(object.schemaVersion, 2); XCTAssertNil(object.timing); XCTAssertEqual(object.contentType, "application/octet-stream")
        XCTAssertTrue(bytes.starts(with: RecordingEncryption.magic))
        let jpeg = try RecordingEncryption.decrypt(bytes, password: "thumbnail-test-password")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 64)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 64) // No upscaling, no letterbox.
        let iptc = try XCTUnwrap(properties[kCGImagePropertyIPTCDictionary] as? [String: Any])
        let description = try XCTUnwrap(iptc[kCGImagePropertyIPTCCaptionAbstract as String] as? String)
        XCTAssertEqual(try JSONDecoder().decode(S3ThumbnailInfo.self, from: Data(description.utf8)), info)
        let spool = try S3Spool(path: root + "/" + c.id, storeID: c.id, settings: c.s3!.settings)
        let entry = try spool.publish(object, data: bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: entry.directory + "/thumbnail.jpg.hbnvr"))
        let reloaded = try S3Spool(path: root + "/" + c.id, storeID: c.id, settings: c.s3!.settings)
        XCTAssertEqual(reloaded.entries[object.id]?.metadata, object); XCTAssertTrue(reloaded.damaged.isEmpty)
        XCTAssertEqual(try reloaded.entries[object.id]?.payload.read(offset: 0, count: bytes.count), bytes)
    }
    func testSharedPoolOfflineRetryStableBytesAndShutdownReplay() async throws {
        let helper = S3Tests(), root = try helper.root()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let c = try helper.config(), camera = UUID().uuidString, media = try fixture(c, camera: camera).first!
        let (object, bytes) = try S3Thumbnail.render(S3Thumbnail.sample(media, sets: media.parameterSets),
            info: .init(storeID: c.id, cameraID: camera, slot: slot, timestamp: media.time!.canonicalUTC), store: c)
        let queue = DispatchQueue(label: "thumbnail-pool-test"), network = FakeS3()
        let path = root + "/" + c.id, spool = try S3Spool(path: path, storeID: c.id, settings: c.s3!.settings)
        let pool = S3UploadManager(configuration: c, spool: spool, queue: queue, factory: { _ in network })
        try await helper.on(queue) { pool.ready(object, data: bytes); pool.ready(object, data: bytes) }
        try await helper.eventually { await network.attempts.count == 1 }
        await network.resolve(object.id, error: .init(kind: .network, message: "offline"))
        try await helper.eventually { try await helper.on(queue) { spool.entries.count == 1 } }
        try await helper.on(queue) { XCTAssertTrue(pool.policy.spooling); pool.stopDispatch(); XCTAssertTrue(pool.safeToExit) }
        let replaySpool = try S3Spool(path: path, storeID: c.id, settings: c.s3!.settings)
        let replay = S3UploadManager(configuration: c, spool: replaySpool, queue: queue, factory: { _ in network })
        try await helper.on(queue) { replay.tick() }
        try await helper.eventually { await network.attempts.count == 2 }
        let attempts = await network.attempts
        XCTAssertEqual(attempts.count, 2); XCTAssertEqual(attempts[0].metadata, attempts[1].metadata)
        XCTAssertEqual(try attempts[1].payload.read(offset: 0, count: bytes.count), bytes)
        await network.resolve(object.id)
        try await helper.eventually { try await helper.on(queue) { !replay.outstanding } }
        try await helper.on(queue) { replay.stopDispatch() }
    }
    func testLiveThumbnailEntersPoolBeforeItsShardCloses() async throws {
        let helper = S3Tests(), root = try helper.root()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let c = try helper.config(), camera = UUID().uuidString, network = FakeS3()
        await network.configure(automatic: true)
        let store = try S3RecordingStore(configuration: c, spoolRoot: root + "/spool", factory: { _ in network }, log: { _ in })
        for media in try fixture(c, camera: camera) { store.accept(.media(camera: camera, name: "Camera", media)) }
        try await helper.eventually { await network.attempts.contains { $0.metadata.thumbnail != nil } }
        XCTAssertEqual(store.snapshot().completedShards, 0); XCTAssertEqual(store.snapshot().activeRecordings, 1)
        let attempts = await network.attempts; XCTAssertEqual(attempts.count, 1)
        XCTAssertTrue(store.finish(timeout: 10))
    }
    func testVideoAndThumbnailsShareSlotsRetryLaneAndLiveReservation() async throws {
        let helper = S3Tests(), root = try helper.root()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let c = try helper.config(), camera = UUID().uuidString, media = try fixture(c, camera: camera).first!
        let (thumbnail, bytes) = try S3Thumbnail.render(S3Thumbnail.sample(media, sets: media.parameterSets),
            info: .init(storeID: c.id, cameraID: camera, slot: slot, timestamp: media.time!.canonicalUTC), store: c)
        var thumbnails: [S3ObjectMetadata] = []
        for offset in 0..<6 {
            let point = slot + Double(offset) * 1200
            var m = S3ObjectMetadata(id: S3Thumbnail.id(store: c.id, camera: camera, slot: point), storeID: c.id,
                cameraID: camera, bucket: c.s3!.bucket, region: c.s3!.region, expectedOwner: nil, prefix: c.s3!.prefix,
                key: S3Thumbnail.key(prefix: c.s3!.prefix, camera: camera, slot: point, encrypted: false),
                capturedAt: Date(timeIntervalSince1970: point), size: thumbnail.size, sha256: thumbnail.sha256)
            m.schemaVersion = 2; m.thumbnail = .init(storeID: c.id, cameraID: camera, slot: point, timestamp: point)
            thumbnails.append(m)
        }
        let objects = thumbnails, network = FakeS3(), queue = DispatchQueue(label: "thumbnail-mixed-pool")
        let spool = try S3Spool(path: root + "/" + c.id, storeID: c.id, settings: c.s3!.settings)
        let pool = S3UploadManager(configuration: c, spool: spool, queue: queue, factory: { _ in network }, jitter: { 0 })
        try await helper.on(queue) { for object in objects { pool.ready(object, data: bytes, background: true) } }
        try await helper.eventually { await network.attempts.count == 4 }
        let (video, footage) = helper.shard(c)
        try await helper.on(queue) { pool.ready(video, data: footage) }
        try await helper.eventually { await network.attempts.count == 5 }
        let before = await network.attempts
        XCTAssertEqual(before[4].metadata.id, video.id)
        let first = before[0]
        await network.resolve(first.metadata.id, error: .init(kind: .transient, message: "try later"))
        try await helper.eventually { await network.attempts.count == 6 }
        let retried = await network.attempts[5]
        XCTAssertEqual(retried.metadata, first.metadata)
        XCTAssertEqual(try retried.payload.read(offset: 0, count: bytes.count), bytes)
        try await helper.on(queue) {
            let status = pool.snapshot(assemblingBytes: 0)
            XCTAssertEqual(status.active, 5); XCTAssertEqual(status.retrying, 1)
            pool.stopDispatch(); XCTAssertTrue(pool.safeToExit)
            XCTAssertEqual(spool.entries.count, 7) // Same spool holds six previews plus the video.
        }
        await network.resolveAll()
    }
    func testThumbnailUsesTheSameQuotaWithoutEvictingVideo() async throws {
        let helper = S3Tests(), root = try helper.root()
        defer { try? FileManager.default.removeItem(atPath: root) }
        var config = try helper.config(); var tuning = S3Tuning(); tuning.forceSpooling = true; config.s3?.tuning = tuning
        let c = config, camera = UUID().uuidString, media = try fixture(c, camera: camera).first!
        let (object, bytes) = try S3Thumbnail.render(S3Thumbnail.sample(media, sets: media.parameterSets),
            info: .init(storeID: c.id, cameraID: camera, slot: slot, timestamp: media.time!.canonicalUTC), store: c)
        let spool = try S3Spool(path: root + "/" + c.id, storeID: c.id, settings: c.s3!.settings)
        let (video, footage) = helper.shard(c)
        _ = try spool.publish(video, data: footage)
        spool.settings.spoolLimitBytes = spool.bytes
        let network = FakeS3(), queue = DispatchQueue(label: "thumbnail-quota")
        let pool = S3UploadManager(configuration: c, spool: spool, queue: queue, factory: { _ in network })
        try await helper.on(queue) {
            pool.ready(object, data: bytes)
            XCTAssertTrue(pool.suspended); XCTAssertFalse(pool.safeToExit)
            XCTAssertEqual(pool.snapshot(assemblingBytes: 0).volatileShards, 1)
            XCTAssertEqual(spool.entries.count, 1); XCTAssertNotNil(spool.entries[video.id])
            spool.settings.spoolLimitBytes = c.s3!.settings.spoolLimitBytes
            pool.tick(); XCTAssertFalse(pool.suspended); XCTAssertTrue(pool.safeToExit)
            XCTAssertEqual(spool.entries.count, 2); pool.stopDispatch()
        }
        let attempts = await network.attempts; XCTAssertTrue(attempts.isEmpty)
    }
    func testSDKUploadsJPEGAndCiphertextThroughSharedTransportFromRAMAndDisk() async throws {
        let helper = S3Tests(), root = try helper.root()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let engine = S3HTTPFixture()
        for encrypted in [false, true] {
            var c = try helper.config()
            if encrypted { c.s3?.clientEncryption = .init(password: "test-encryption") }
            let camera = UUID().uuidString, media = try fixture(c, camera: camera).first!
            let (object, bytes) = try S3Thumbnail.render(S3Thumbnail.sample(media, sets: media.parameterSets),
                info: .init(storeID: c.id, cameraID: camera, slot: slot, timestamp: media.time!.canonicalUTC), store: c)
            let spool = try S3Spool(path: root + "/" + c.id, storeID: c.id, settings: c.s3!.settings)
            let entry = try spool.publish(object, data: bytes)
            let transport = try await AWSS3Transport(configuration: c.s3!, httpClient: engine)
            try await transport.upload(object, payload: .memory(bytes))
            try await transport.upload(object, payload: entry.payload)
            let bodies = await engine.objectBodies, types = await engine.objectTypes, paths = await engine.objectPaths
            XCTAssertEqual(Array(bodies.suffix(2)), [bytes, bytes])
            XCTAssertEqual(Array(types.suffix(2)), [object.contentType, object.contentType])
            XCTAssertEqual(paths.suffix(2).first, paths.last) // Stable key with SDK SHA-256 framing checked by fixture.
        }
    }
}
