import XCTest
import Foundation
import Darwin
import SQLite3

final class PlaybackCatalogTests: XCTestCase {
    func configuration() throws -> RecordingStoreConfiguration {
        let root = "/private/tmp/hbnvr-discovery-" + UUID().uuidString
        try StoreDirectory.create(root, owner: geteuid(), daemon: geteuid())
        addTeardownBlock { try? FileManager.default.removeItem(atPath: root) }
        return RecordingStoreConfiguration(directory: root, ownerUID: geteuid(), ownerUUID: try StoreDirectory.identity(geteuid()))
    }
    func camera(_ name: String = "Kitchen") -> CameraConfiguration {
        var value = CameraConfiguration(name: name, ipAddress: "192.0.2.1",
            credentials: CameraCredentials(username: "secret-user", password: "secret-password"))
        value.homebaseDeviceID = "camera-hardware-serial"
        return value
    }
    func record(_ config: RecordingStoreConfiguration, id: String, name: String = "Kitchen", hardware: String? = "camera-hardware-serial") throws {
        let store = try LocalRecordingStore(configuration: config)
        for sample in try StoreTests.video(count: 10) {
            store.accept(.media(camera: id, name: name, sample, homebaseDeviceID: hardware))
        }
        XCTAssertTrue(store.finish(timeout: 10))
        XCTAssertNil(store.snapshot().lastError)
    }
    func awaitSnapshot(_ catalog: PlaybackCatalog, matching: (PlaybackSnapshot) -> Bool) throws -> PlaybackSnapshot {
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            let value = try catalog.snapshot()
            if matching(value) { return value }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTFail("Playback discovery did not finish")
        return try catalog.snapshot()
    }
    func testManifestIdentitySurvivesRemovalRestartAndDisabledStore() throws {
        var config = try configuration()
        let id = UUID().uuidString
        try record(config, id: id)
        config.enabled = false
        let scan = PlaybackDiscovery.scan(config, work: MediaWork())
        XCTAssertEqual(scan.state, "available")
        XCTAssertEqual(scan.cameras[id]?.metadata?.name, "Kitchen")
        XCTAssertEqual(scan.cameras[id]?.metadata?.homebaseDeviceID, "camera-hardware-serial")
        // No camera configurations at all: discovery must come from SQLite.
        let catalog = PlaybackCatalog(instanceID: "test")
        defer { catalog.stop() }
        catalog.replace(stores: [config], cameras: [])
        let snapshot = try awaitSnapshot(catalog) { $0.ready }
        let retained = try XCTUnwrap(snapshot.cameras.first)
        XCTAssertEqual(retained.id, id)
        XCTAssertEqual(retained.name, "Kitchen")
        XCTAssertEqual(retained.homebaseDeviceID, "camera-hardware-serial")
        XCTAssertFalse(retained.configured)
        XCTAssertFalse(retained.recordingStarted)
        XCTAssertEqual(retained.stores, [.init(storeID: config.id, recordingEnabled: false, indexedHistory: true)])
        XCTAssertTrue(snapshot.stores[0].frameReading)
        XCTAssertFalse(snapshot.stores[0].enabled)
        XCTAssertEqual(snapshot.stores[0].state, "available")
        let provider = LocalMediaProvider(configurations: { [config] })
        XCTAssertFalse(try provider.catalog(camera: id, range: .init(start: 0, end: Date().timeIntervalSince1970 + 60), timeline: .canonical, work: MediaWork()).isEmpty)
    }
    func testConfiguredIntentIsNotHistoryAndNoPrivateFieldsLeak() throws {
        var local = try configuration(), remote = local
        local.enabled = false; remote.id = UUID().uuidString; remote.type = "S3"
        remote.s3 = S3Configuration(bucket: "test-recordings", region: "us-west-2", prefix: "nvr/",
            credentials: .init(accessKeyID: "private-access-id", secretAccessKey: "private-secret-key"),
            clientEncryption: .init(enabled: true, password: "private-passphrase"))
        let id = UUID().uuidString, configured = camera()
        let value = PlaybackDiscovery.content(stores: [local, remote], cameras: [(id, configured)], scans: [:], ready: false)
        XCTAssertEqual(value.cameras.count, 1)
        XCTAssertFalse(value.cameras[0].stores.first { $0.storeID == local.id }!.recordingEnabled)
        XCTAssertTrue(value.cameras[0].stores.first { $0.storeID == remote.id }!.recordingEnabled)
        XCTAssertTrue(value.cameras[0].stores.allSatisfy { !$0.indexedHistory })
        let s3 = try XCTUnwrap(value.stores.first { $0.id == remote.id })
        XCTAssertFalse(s3.frameReading); XCTAssertEqual(s3.state, "unsupported")
        XCTAssertEqual(s3.s3?.bucket, "test-recordings")
        XCTAssertEqual(s3.s3?.clientEncryptionFormat, "hbnvr-pbe-v1")
        XCTAssertEqual(s3.s3?.playbackManifestVersion, 1)
        let snapshot = PlaybackSnapshot(instanceID: "test", revision: 1, ready: value.ready, stores: value.stores, cameras: value.cameras)
        let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        for secret in ["192.0.2.1", "secret-user", "secret-password", local.directory, "ownerUID", "rtspURL",
                       "private-access-id", "private-secret-key", "private-passphrase", "Credentials", "Password"] {
            XCTAssertFalse(encoded.contains(secret), secret)
        }
    }
    func testMediaReadsOnlyFirstDiscoveredLocalStore() throws {
        var first = try configuration(), second = try configuration()
        first.id = "00000000-0000-0000-0000-000000000001"
        second.id = "00000000-0000-0000-0000-000000000002"
        let id = UUID().uuidString
        try record(second, id: id)
        let range = MediaRange(start: 0, end: Date().timeIntervalSince1970 + 60)
        let provider = LocalMediaProvider(configurations: { [second, first] })
        XCTAssertTrue(try provider.catalog(camera: id, range: range, timeline: .canonical, work: MediaWork()).isEmpty)
        let neighbors = try provider.neighbors(camera: id, range: .init(start: range.end, end: range.end + 1),
            timeline: .canonical, work: MediaWork())
        XCTAssertNil(neighbors.previous)
        XCTAssertNil(neighbors.next)
        XCTAssertFalse(try LocalMediaProvider(configurations: { [second] }).catalog(camera: id,
            range: range, timeline: .canonical, work: MediaWork()).isEmpty)
    }
    func testMetadataRenameMergingAndConflictingHardwareDoesNotGuess() throws {
        let config = try configuration(), id = UUID().uuidString
        var history: [String: PlaybackDiscovery.HistoricalCamera] = [:]
        PlaybackDiscovery.merge(.init(id: id, metadata: .init(name: "Old", homebaseDeviceID: "camera-one", updatedAt: 1)), into: &history)
        PlaybackDiscovery.merge(.init(id: id, metadata: .init(name: "New", homebaseDeviceID: "camera-one", updatedAt: 2)), into: &history)
        XCTAssertEqual(history[id]?.metadata?.name, "New")
        XCTAssertFalse(history[id]!.identityAmbiguous)
        PlaybackDiscovery.merge(.init(id: id, metadata: .init(name: "Conflict", homebaseDeviceID: "camera-two", updatedAt: 3)), into: &history)
        let scans = [config.id: PlaybackDiscovery.Scan(state: "available", cameras: history)]
        let retired = PlaybackDiscovery.content(stores: [config], cameras: [], scans: scans, ready: true).cameras[0]
        XCTAssertTrue(retired.identityAmbiguous); XCTAssertNil(retired.homebaseDeviceID)
        let current = PlaybackDiscovery.content(stores: [config], cameras: [(id, camera("Current"))], scans: scans, ready: true).cameras[0]
        XCTAssertFalse(current.identityAmbiguous); XCTAssertEqual(current.name, "Current")
        XCTAssertEqual(current.homebaseDeviceID, "camera-hardware-serial")
    }
    func testCorruptManifestIsPartialAndDoesNotHideAnotherCamera() throws {
        let config = try configuration(), a = UUID().uuidString, b = UUID().uuidString
        try record(config, id: a, name: "Good")
        try record(config, id: b, name: "Broken")
        let path = config.directory + "/Broken/" + LocalRecordingManifest.filename
        try Data("not sqlite".utf8).write(to: URL(fileURLWithPath: path))
        let scan = PlaybackDiscovery.scan(config, work: MediaWork())
        XCTAssertEqual(scan.state, "partial")
        XCTAssertNotNil(scan.cameras[a]); XCTAssertNil(scan.cameras[b])
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "not sqlite")
        // A corrupt directory identity must not turn lost discovery into an
        // authoritative empty/available catalog either.
        try Data("broken marker".utf8).write(to: URL(fileURLWithPath: config.directory + "/Good/" + LocalRecordingLayout.markerName))
        XCTAssertEqual(PlaybackDiscovery.scan(config, work: MediaWork()).state, "partial")
    }
    func testRefreshKeepsOfflineHistoryThenRemovesItAfterSuccessfulEmptyScan() throws {
        let config = try configuration(), id = UUID().uuidString
        try record(config, id: id)
        let catalog = PlaybackCatalog(instanceID: "test"); defer { catalog.stop() }
        catalog.replace(stores: [config], cameras: [])
        let first = try awaitSnapshot(catalog) { $0.ready }
        let offline = config.directory + "-offline"
        try FileManager.default.moveItem(atPath: config.directory, toPath: offline)
        defer { try? FileManager.default.moveItem(atPath: offline, toPath: config.directory) }
        catalog.refresh()
        let missing = try awaitSnapshot(catalog) { $0.stores.first?.state == "unavailable" }
        XCTAssertEqual(missing.cameras, first.cameras)
        try FileManager.default.moveItem(atPath: offline, toPath: config.directory)
        let path = config.directory + "/Kitchen/" + LocalRecordingManifest.filename
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "DELETE FROM recordings", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        catalog.refresh()
        let empty = try awaitSnapshot(catalog) { $0.stores.first?.state == "available" && $0.cameras.isEmpty }
        XCTAssertGreaterThan(empty.revision, missing.revision)
    }
    func testSlowScanDoesNotBlockSnapshotAndStaleGenerationCannotPublish() throws {
        let config = try configuration(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let catalog = PlaybackCatalog(instanceID: "test", scan: { _, _ in
            entered.signal(); _ = release.wait(timeout: .now() + 4)
            return .init(state: "available")
        })
        defer { release.signal(); catalog.stop() }
        catalog.replace(stores: [config], cameras: [])
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        XCTAssertFalse(try catalog.snapshot().ready)
        catalog.replace(stores: [], cameras: [])
        XCTAssertTrue(try catalog.snapshot().stores.isEmpty)
        release.signal()
        let value = try awaitSnapshot(catalog) { $0.ready }
        XCTAssertTrue(value.stores.isEmpty)
        let revision = value.revision
        catalog.refresh()
        Thread.sleep(forTimeInterval: 0.03)
        XCTAssertEqual(try catalog.snapshot().revision, revision)
    }
    func testVersionOneMetadataAbsenceIsNotInferredAndWriterUpgradePreservesRows() throws {
        let config = try configuration(), id = UUID().uuidString
        try record(config, id: id)
        let path = config.directory + "/Kitchen/" + LocalRecordingManifest.filename
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &raw), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(raw, "DROP TABLE camera_metadata; PRAGMA user_version=1", nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)
        let scan = PlaybackDiscovery.scan(config, work: MediaWork())
        XCTAssertEqual(scan.state, "available")
        XCTAssertNotNil(scan.cameras[id]); XCTAssertNil(scan.cameras[id]?.metadata)
        let child = try StoreDirectory.openDirectory(config.directory + "/Kitchen")
        let directory = LocalRecordingLayout.Directory(path: config.directory + "/Kitchen", fd: child)
        let writer = try LocalRecordingManifest(directory: directory, identity: .init(storeID: config.id, cameraID: id), owner: geteuid())
        XCTAssertNil(try writer.cameraMetadata())
        XCTAssertTrue(try writer.hasIndexedRecordings())
        XCTAssertEqual(try writer.recordings().count, 1)
    }
    func testOversizeCatalogFailsExplicitlyAndRecoversWithoutTruncation() throws {
        let catalog = PlaybackCatalog(instanceID: "test"); defer { catalog.stop() }
        var oversized = camera()
        oversized.name = String(repeating: "x", count: SocketIO.limit + 1)
        catalog.replace(stores: [], cameras: [(UUID().uuidString, oversized)])
        XCTAssertThrowsError(try catalog.snapshot())
        catalog.replace(stores: [], cameras: [])
        let value = try awaitSnapshot(catalog) { $0.ready }
        XCTAssertTrue(value.cameras.isEmpty)
    }
}
