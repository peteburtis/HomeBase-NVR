import XCTest
import Foundation
import Darwin
import AVFoundation
import VideoToolbox

final class StoreTests: XCTestCase {
    func testTransientWriterBackpressureAndSlowFinalizationAreNotFailures() throws {
        // Reproduce a stall longer than the old 0.5s input / 2s finalization deadlines
        // without needing a fresh service-account LaunchServices database in tests.
        for delay in [3.1, 15.0] {
            var clock: TimeInterval = 0
            try MP4WriterWait.untilReady(ready: { clock >= delay }, failure: { nil }, timeoutMessage: "unexpected timeout",
                                         now: { clock }, pause: { clock += $0 })
            XCTAssertGreaterThanOrEqual(clock, delay)
            XCTAssertLessThan(clock, MP4WriterWait.timeout)
        }
    }
    func testWriterWaitRemainsBoundedAndReportsActualFailureImmediately() throws {
        var clock: TimeInterval = 0
        XCTAssertThrowsError(try MP4WriterWait.untilReady(ready: { false }, failure: { nil }, timeoutMessage: "timed out",
            now: { clock }, pause: { clock += $0 })) { error in
            XCTAssertEqual((error as? ServiceError)?.code, .timeout)
        }
        XCTAssertEqual(clock, MP4WriterWait.timeout, accuracy: 0.001)
        clock = 0
        XCTAssertThrowsError(try MP4WriterWait.untilReady(ready: { false }, failure: { ServiceError("actual failure") }, timeoutMessage: "timed out",
            now: { clock }, pause: { clock += $0 })) { error in
            XCTAssertEqual((error as? ServiceError)?.message, "actual failure")
        }
        XCTAssertEqual(clock, 0)
    }
    func testCleanupDoesNotHideFirstStoreFailureOrExposeErrorUserInfo() {
        var status = RecordingStoreStatus(id: UUID().uuidString, name: "Test", enabled: true, state: "ready")
        status.recordFailure("original write failure")
        status.recordFailure("subsequent finalize timeout")
        XCTAssertEqual(status.lastError, "original write failure")
        XCTAssertEqual(status.state, "error")
        let underlying = NSError(domain: NSOSStatusErrorDomain, code: -1, userInfo: [NSLocalizedDescriptionKey: "secret-camera-password"])
        let error = NSError(domain: AVFoundationErrorDomain, code: -11800, userInfo: [NSUnderlyingErrorKey: underlying, NSFilePathErrorKey: "/private-camera-url"])
        XCTAssertEqual(MP4WriterWait.errorCodes(error), "AVFoundationErrorDomain -11800; NSOSStatusErrorDomain -1")
    }
    func temporary() throws -> String {
        let path = "/private/tmp/hs-" + UUID().uuidString
        try SecureFiles.ensureDirectory(path, owner: geteuid(), mode: 0o700)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }
    func config(_ path: String) throws -> RecordingStoreConfiguration {
        try StoreDirectory.create(path, owner: geteuid(), daemon: geteuid())
        return RecordingStoreConfiguration(directory: path, ownerUID: geteuid(), ownerUUID: try StoreDirectory.identity(geteuid()))
    }
    func testDurationSyntaxAndCase() throws {
        for (text, seconds) in [("1m", Int64(60)), ("1M", 2678400), ("1y", 31536000), ("12M", 32140800), ("1w2d", 777600), (" 1h 30m ", 5400), ("1y2M", 36892800)] {
            XCTAssertEqual(try IntervalText.seconds(text), seconds)
        }
        for bad in ["", "0s", "-1s", "1.5h", "1", "1H", "1ms", "1h junk", "999999999999999999999y"] {
            XCTAssertThrowsError(try IntervalText.seconds(bad), bad)
        }
    }
    func testReadableLayoutSanitizesNamesAndKeepsCameraIdentitiesSeparate() throws {
        let root = try temporary(), configuration = try config(root + "/output")
        let fd = try StoreDirectory.openDirectory(configuration.directory); defer { close(fd) }
        let first = UUID().uuidString, second = UUID().uuidString
        func directory(_ camera: String, _ name: String) throws -> LocalRecordingLayout.Directory {
            try LocalRecordingLayout.cameraDirectory(root: configuration.directory, fd: fd,
                store: configuration.id, camera: camera, name: name, owner: geteuid())
        }
        let living = try directory(first, "Living Room Camera")
        XCTAssertEqual(living.path, configuration.directory + "/Living Room Camera")
        XCTAssertEqual(try directory(first, "Living Room Camera").path, living.path)
        let duplicate = try directory(second, "Living Room Camera")
        XCTAssertEqual(duplicate.path, configuration.directory + "/Living Room Camera (2)")
        XCTAssertEqual(try directory(second, "Living Room Camera").path, duplicate.path)
        XCTAssertEqual(try LocalRecordingLayout.identity(in: living.fd)?.cameraID, first)
        XCTAssertEqual(try SecureFiles.info(living.path)!.st_mode & 0o777, 0o700)
        XCTAssertEqual(try SecureFiles.info(living.path + "/" + LocalRecordingLayout.markerName)!.st_mode & 0o777, 0o600)
        XCTAssertEqual(LocalRecordingLayout.cameraName("../../Hall:East\\Door\n"), "-..-Hall-East-Door-")
        XCTAssertEqual(LocalRecordingLayout.cameraName(" . .. "), "Camera")
        XCTAssertEqual(LocalRecordingLayout.cameraName(" Entrée 📷 "), "Entrée 📷")
        XCTAssertLessThanOrEqual(LocalRecordingLayout.cameraName(String(repeating: "📷", count: 100)).utf8.count, 180)
        // Case-equivalent names still cannot combine two identities on case-insensitive APFS.
        let lower = try directory(UUID().uuidString, "living room camera")
        XCTAssertNotEqual(try SecureFiles.info(lower.path)?.st_ino, try SecureFiles.info(living.path)?.st_ino)
        let renamed = try directory(first, "Den")
        XCTAssertEqual(renamed.path, configuration.directory + "/Den")
        XCTAssertTrue(FileManager.default.fileExists(atPath: living.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configuration.directory + "/hbnvr-" + configuration.id))
    }
    func testCameraFoldersDoNotAdoptUnmarkedDirectoriesOrFollowSymlinks() throws {
        let root = try temporary(), configuration = try config(root + "/output")
        let fd = try StoreDirectory.openDirectory(configuration.directory); defer { close(fd) }
        let child = try StoreDirectory.child("Camera", parent: fd, owner: geteuid(), daemon: geteuid()); close(child)
        let outside = root + "/outside"
        try SecureFiles.ensureDirectory(outside, owner: geteuid(), mode: 0o700)
        XCTAssertEqual(symlink(outside, configuration.directory + "/Camera (2)"), 0)
        let directory = try LocalRecordingLayout.cameraDirectory(root: configuration.directory, fd: fd,
            store: configuration.id, camera: UUID().uuidString, name: "Camera", owner: geteuid())
        XCTAssertEqual(directory.path, configuration.directory + "/Camera (3)")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside).isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: configuration.directory + "/Camera").isEmpty)
    }
    func testDirectoryIdentityDoesNotDependOnPathSpelling() throws {
        let root = try temporary(), configuration = try config(root + "/output")
        let fd = try StoreDirectory.openDirectory(configuration.directory); defer { close(fd) }
        let directory = try LocalRecordingLayout.cameraDirectory(root: configuration.directory, fd: fd,
            store: configuration.id, camera: UUID().uuidString, name: "Test Camera", owner: geteuid())
        let alternate = try StoreDirectory.openDirectory(configuration.directory + "/./Test Camera"); defer { close(alternate) }
        XCTAssertTrue(try LocalRecordingLayout.sameDirectory(directory.fd, alternate))
        XCTAssertFalse(try LocalRecordingLayout.sameDirectory(directory.fd, fd))
        try FileManager.default.moveItem(atPath: directory.path, toPath: configuration.directory + "/Renamed")
        let renamed = try StoreDirectory.openDirectory(configuration.directory + "/Renamed"); defer { close(renamed) }
        XCTAssertTrue(try LocalRecordingLayout.sameDirectory(directory.fd, renamed))
        XCTAssertThrowsError(try LocalRecordingLayout.verify(path: directory.path, fd: directory.fd, owner: geteuid()))
    }
    func testTimestampIsLocal24HourStartTimeWithSafeCollisionSuffixes() throws {
        let configuration = try config(try temporary() + "/output")
        let fd = try StoreDirectory.openDirectory(configuration.directory); defer { close(fd) }
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-16T23:04:05Z"))
        let zone = try XCTUnwrap(TimeZone(secondsFromGMT: -7 * 3600))
        let base = "2026-09-16_16-04-05"
        XCTAssertEqual(LocalRecordingLayout.shardStem(at: date, timeZone: zone), base)
        XCTAssertEqual(try LocalRecordingLayout.availableStem(in: fd, at: date, timeZone: zone), base)
        try SecureFiles.atomicWrite(Data([1]), to: configuration.directory + "/" + base + ".mp4", mode: 0o600)
        XCTAssertEqual(try LocalRecordingLayout.availableStem(in: fd, at: date, timeZone: zone), base + "-2")
        try SecureFiles.atomicWrite(Data([2]), to: configuration.directory + "/" + base + "-2.mp4.recording", mode: 0o600)
        XCTAssertEqual(try LocalRecordingLayout.availableStem(in: fd, at: date, timeZone: zone), base + "-3")
        for name in [base + ".mp4", base + "-2.mp4.recording"] { XCTAssertTrue(LocalRecordingLayout.isShard(name)) }
        for name in ["holiday.mp4", base + ".mp4.backup", "../" + base + ".mp4"] { XCTAssertFalse(LocalRecordingLayout.isShard(name)) }
    }
    func testReadableLayoutRetentionRequiresMatchingStoreIdentity() throws {
        let root = try temporary()
        var configuration = try config(root + "/output")
        configuration.enabled = false; configuration.shardDuration = "1s"; configuration.retentionPeriod = "1s"
        let fd = try StoreDirectory.openDirectory(configuration.directory); defer { close(fd) }
        let owned = try LocalRecordingLayout.cameraDirectory(root: configuration.directory, fd: fd,
            store: configuration.id, camera: UUID().uuidString, name: "Living Room", owner: geteuid())
        let other = try LocalRecordingLayout.cameraDirectory(root: configuration.directory, fd: fd,
            store: UUID().uuidString, camera: UUID().uuidString, name: "Other Store", owner: geteuid())
        let old = Date(timeIntervalSince1970: 1000), stem = "2026-09-16_16-04-05"
        func file(_ path: String, expired: Bool = true) throws {
            try SecureFiles.atomicWrite(Data([1]), to: path, mode: 0o600)
            if expired { try FileManager.default.setAttributes([.creationDate: old, .modificationDate: old], ofItemAtPath: path) }
        }
        let expired = owned.path + "/" + stem + ".mp4"
        let partial = owned.path + "/" + stem + "-2.mp4.recording"
        let unrelated = owned.path + "/holiday.mp4", foreign = other.path + "/" + stem + ".mp4"
        let fresh = owned.path + "/2000-01-01_00-00-00.mp4" // Retention is not based on the filename's local start time.
        let loose = configuration.directory + "/" + stem + ".mp4"
        for path in [expired, partial, unrelated, foreign, loose] { try file(path) }
        try file(fresh, expired: false)
        let hard = owned.path + "/" + stem + "-3.mp4", symbolic = owned.path + "/" + stem + "-4.mp4"
        XCTAssertEqual(link(foreign, hard), 0); XCTAssertEqual(symlink(foreign, symbolic), 0)
        let store = try LocalRecordingStore(configuration: configuration)
        try waitUntil { !FileManager.default.fileExists(atPath: expired) }
        XCTAssertTrue(store.finish(timeout: 2))
        XCTAssertNil(store.snapshot().lastError)
        XCTAssertNil(try SecureFiles.info(partial))
        XCTAssertNil(try SecureFiles.info(owned.path + "/" + LocalRecordingManifest.filename))
        for path in [unrelated, foreign, fresh, loose, hard, symbolic] { XCTAssertNotNil(try SecureFiles.info(path), path) }
    }
    func testPrivateDirectoryAndRefusalToAdoptPermissions() throws {
        let parent = try temporary(), path = parent + "/recordings"
        _ = try config(path)
        XCTAssertEqual(try SecureFiles.info(path)!.st_mode & 0o777, 0o700)
        let fd = try StoreDirectory.openDirectory(path); defer { close(fd) }
        try StoreDirectory.validate(fd, owner: geteuid(), daemon: geteuid())
        try StoreDirectory.create(path, owner: geteuid(), daemon: geteuid())
        XCTAssertEqual(chmod(path, 0o755), 0)
        XCTAssertThrowsError(try StoreDirectory.create(path, owner: geteuid(), daemon: geteuid()))
        XCTAssertEqual(try SecureFiles.info(path)!.st_mode & 0o777, 0o755)
        let link = parent + "/link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: path)
        XCTAssertThrowsError(try StoreDirectory.expanded(link))
        XCTAssertThrowsError(try StoreDirectory.openDirectory(link))
    }
    func testExplicitSecondIdentityACL() throws {
        guard let user = getpwnam("_hbnvr") else { throw XCTSkip("Service account not installed; elevated acceptance covers cross-account access.") }
        let daemon = user.pointee.pw_uid, path = try temporary() + "/shared"
        try StoreDirectory.create(path, owner: geteuid(), daemon: daemon)
        let fd = try StoreDirectory.openDirectory(path); defer { close(fd) }
        try StoreDirectory.validate(fd, owner: geteuid(), daemon: daemon)
        XCTAssertThrowsError(try StoreDirectory.validate(fd, owner: geteuid(), daemon: geteuid()))
    }
    func testRepositoryOverlapAndRoundTrip() throws {
        let root = try temporary()
        let store = RecordingStoreRepository(directory: root + "/configs")
        var first = try config(root + "/output")
        try store.save(first, replacing: false)
        XCTAssertEqual(try store.list(), [first])
        first.enabled = false; first.retentionPeriod = "1M"
        try store.save(first, replacing: true)
        XCTAssertEqual(try store.list().first?.retentionPeriod, "1M")
        var other = first; other.id = UUID().uuidString; other.directory += "/nested"
        XCTAssertThrowsError(try store.save(other, replacing: false))
        first.shardDuration = "2d"
        XCTAssertThrowsError(try first.validate())
        try store.remove(first.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.directory))
    }
    func testRetentionOnlyDeletesOwnedRecognizedRegularFiles() throws {
        let root = try temporary()
        var configuration = try config(root + "/output")
        configuration.shardDuration = "1s"; configuration.retentionPeriod = "1s"; configuration.enabled = false
        let rootFD = try StoreDirectory.openDirectory(configuration.directory); defer { close(rootFD) }
        let child = try StoreDirectory.child("hbnvr-" + configuration.id, parent: rootFD, owner: geteuid(), daemon: geteuid()); close(child)
        let directory = configuration.directory + "/hbnvr-" + configuration.id
        func oldName() -> String { UUID().uuidString + "_1000_" + UUID().uuidString + ".mp4" }
        let expired = directory + "/" + oldName(), unrelated = directory + "/holiday.mp4", outside = root + "/outside"
        try SecureFiles.atomicWrite(Data([1]), to: expired, mode: 0o600)
        let interrupted = directory + "/" + oldName() + ".recording"
        let legacy = directory + "/" + oldName() + ".partial"
        try SecureFiles.atomicWrite(Data([1]), to: interrupted, mode: 0o600)
        try SecureFiles.atomicWrite(Data([1]), to: legacy, mode: 0o600)
        try SecureFiles.atomicWrite(Data([2]), to: unrelated, mode: 0o600)
        try SecureFiles.atomicWrite(Data([3]), to: outside, mode: 0o600)
        let symbolic = directory + "/" + oldName(), hard = directory + "/" + oldName()
        XCTAssertEqual(symlink(outside, symbolic), 0); XCTAssertEqual(link(outside, hard), 0)
        let store = try LocalRecordingStore(configuration: configuration)
        let deadline = Date().addingTimeInterval(2)
        while FileManager.default.fileExists(atPath: expired), Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: expired))
        XCTAssertFalse(FileManager.default.fileExists(atPath: interrupted))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: unrelated)), Data([2]))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: outside)), Data([3]))
        XCTAssertNotNil(try SecureFiles.info(symbolic)); XCTAssertNotNil(try SecureFiles.info(hard))
        XCTAssertTrue(store.finish(timeout: 2))
    }
    func testRealEncodedFramesProducePlayableRotatedMP4() async throws {
        try await verifyPlayableShards(codec: kCMVideoCodecType_H264)
    }
    func testHEVCFramesProducePlayableRotatedMP4() async throws {
        try await verifyPlayableShards(codec: kCMVideoCodecType_HEVC)
    }
    func testInBandParametersAreNotRevertedByStaleSDP() async throws {
        try await verifyPlayableShards(codec: kCMVideoCodecType_H264, staleSDP: true)
    }
    func testVisibleRecordingGrowsAndDecodesBeforeCommit() async throws {
        let root = try temporary(), configuration = try config(root + "/output")
        let store = try LocalRecordingStore(configuration: configuration)
        defer { _ = store.finish(timeout: 5) }
        let camera = UUID().uuidString, frames = try Self.video(count: 180)
        for media in frames.prefix(45) { store.accept(.media(camera: camera, name: "Test Camera", media)) }
        try waitUntil { store.snapshot().recordedFrames == 45 }
        let directory = configuration.directory + "/Test Camera"
        let recording = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: directory).first { $0.hasSuffix(".mp4.recording") })
        let path = directory + "/" + recording
        try waitUntil { ((try? SecureFiles.info(path)?.st_size) ?? 0) > 100 }
        let first = try XCTUnwrap(SecureFiles.info(path))
        XCTAssertEqual(first.st_mode & 0o777, 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: String(path.dropLast(10))))
        // Snapshot only synthetic media; prove metadata exists without finishWriting.
        let snapshot = root + "/snapshot.mp4"
        try SecureFiles.atomicWrite(Data(contentsOf: URL(fileURLWithPath: path)), to: snapshot, mode: 0o600)
        let checkpointFrames = try await decodedFrames(snapshot)
        XCTAssertGreaterThan(checkpointFrames, 0)
        for media in frames.dropFirst(45) { store.accept(.media(camera: camera, name: "Test Camera", media)) }
        try waitUntil { store.snapshot().recordedFrames == 180 }
        try waitUntil { ((try? SecureFiles.info(path)?.st_size) ?? 0) > first.st_size }
        XCTAssertEqual(store.snapshot().completedShards, 0)
        XCTAssertTrue(store.finish(timeout: 5))
        let finalName = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: directory).first { $0.hasSuffix(".mp4") })
        let finalPath = directory + "/" + finalName
        XCTAssertEqual(finalName, String(recording.dropLast(10)))
        XCTAssertTrue(LocalRecordingLayout.isShard(finalName))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(try SecureFiles.info(finalPath)?.st_ino, first.st_ino) // No copy on commit.
        let finalFrames = try await decodedFrames(finalPath)
        XCTAssertEqual(finalFrames, 180)
    }
    func testCrashLeavesRecoverableRecording() async throws {
        let key = "HBNVR_TEST_CRASH_DIRECTORY"
        if let root = ProcessInfo.processInfo.environment[key] {
            let store = try LocalRecordingStore(configuration: config(root + "/output"))
            for media in try Self.video(count: 180) { store.accept(.media(camera: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", name: "Test Camera", media)) }
            try waitUntil { store.snapshot().recordedFrames == 180 }
            // Deliberate SIGKILL of this isolated test subprocess; no graceful finish.
            withExtendedLifetime(store) { _ = kill(getpid(), SIGKILL) }
            return
        }
        let root = try temporary(), process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xctest", "-XCTest", NSStringFromClass(StoreTests.self) + "/testCrashLeavesRecoverableRecording", Bundle(for: StoreTests.self).bundlePath]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                               "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer", key: root]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { _ = kill(process.processIdentifier, SIGKILL); process.waitUntilExit() } }
        try waitUntil(timeout: 12) { !process.isRunning }
        process.waitUntilExit()
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGKILL)
        let folder = root + "/output/Test Camera"
        let name = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: folder).first { $0.hasSuffix(".mp4.recording") })
        let path = folder + "/" + name
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        // AVFoundation's file-type inference needs a conventional playback suffix.
        // Work on a copy, leaving the interrupted original untouched for recovery.
        let recoveryCopy = root + "/recovered.mp4"
        try SecureFiles.atomicWrite(before, to: recoveryCopy, mode: 0o600)
        let recoveredFrames = try await decodedFrames(recoveryCopy)
        XCTAssertGreaterThan(recoveredFrames, 0)
        var configuration = try config(root + "/output")
        let fd = try StoreDirectory.openDirectory(folder); defer { close(fd) }
        configuration.id = try XCTUnwrap(LocalRecordingLayout.identity(in: fd)).storeID; configuration.enabled = false
        let reopened = try LocalRecordingStore(configuration: configuration)
        XCTAssertTrue(reopened.finish(timeout: 3))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before)
        let manifestDirectory = LocalRecordingLayout.Directory(path: folder, fd: try StoreDirectory.openDirectory(folder))
        let identity = try XCTUnwrap(LocalRecordingLayout.identity(in: manifestDirectory.fd))
        let manifest = try LocalRecordingManifest(directory: manifestDirectory, identity: identity, owner: geteuid())
        XCTAssertEqual(try manifest.recordings().count, 1)
        XCTAssertEqual(try manifest.recordings().first?.state, .interrupted)
        XCTAssertTrue(try manifest.coverage(from: 0, to: Date().timeIntervalSince1970 + 60).available.isEmpty)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before)
    }
    private func waitUntil(timeout: TimeInterval = 4, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw ServiceError("Timed out waiting for test recording progress.") }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }
    private func decodedFrames(_ path: String) async throws -> Int {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); XCTAssertTrue(reader.startReading())
        var count = 0
        while output.copyNextSampleBuffer() != nil { count += 1 }
        XCTAssertEqual(reader.status, .completed, reader.error?.localizedDescription ?? "")
        return count
    }
    func testStoreFailureIsIndependentAndQueueIsBounded() throws {
        let root = try temporary()
        let good = try config(root + "/good")
        var missing = good; missing.id = UUID().uuidString; missing.directory = root + "/missing"
        let manager = RecordingStoreManager()
        manager.load([good, missing])
        XCTAssertTrue(manager.hasWritableStore)
        XCTAssertEqual(manager.snapshot().first { $0.id == missing.id }?.state, "error")
        for media in try Self.video() { manager.accept(.media(camera: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", name: "Test Camera", media)) }
        manager.stop()
        XCTAssertEqual(manager.snapshot().first { $0.id == good.id }?.recordedFrames, 45)
        XCTAssertNil(manager.snapshot().first { $0.id == good.id }?.lastError)

        let store = try LocalRecordingStore(configuration: config(root + "/bounded"))
        let oversized = EncodedMedia(codec: "H264", clockRate: 90000, parameterSets: [], frame: EncodedVideoFrame(payload: Data(count: 33 * 1024 * 1024), timestamp: 0, keyFrame: true))
        store.accept(.media(camera: UUID().uuidString, name: "Test Camera", oversized))
        XCTAssertEqual(store.snapshot().state, "error")
        XCTAssertEqual(store.snapshot().pendingBytes, 0)
        XCTAssertTrue(store.finish(timeout: 2))
    }
    func testStoreLockSurvivesUntilDrainedAndAllowsReplacement() throws {
        let configuration = try config(try temporary() + "/output")
        let original = try LocalRecordingStore(configuration: configuration)
        XCTAssertThrowsError(try LocalRecordingStore(configuration: configuration))
        var sameRoot = configuration; sameRoot.id = UUID().uuidString
        XCTAssertThrowsError(try LocalRecordingStore(configuration: sameRoot))
        XCTAssertTrue(original.finish(timeout: 2))
        // Keep the original object alive: completion itself must release the lock.
        let replacement = try LocalRecordingStore(configuration: configuration)
        XCTAssertTrue(replacement.finish(timeout: 2))
        let manager = RecordingStoreManager()
        for _ in 0..<30 { try manager.install(configuration) }
        manager.stop()
        withExtendedLifetime(original) {}
    }
    func testCameraStopDrainsItsShardWithoutStoppingOtherCameras() async throws {
        let configuration = try config(try temporary() + "/output")
        let manager = RecordingStoreManager(); try manager.install(configuration)
        defer { manager.stop() }
        let first = UUID().uuidString, second = UUID().uuidString, frames = try Self.video(count: 90)
        for frame in frames.prefix(45) {
            manager.accept(.media(camera: first, name: "First", frame))
            manager.accept(.media(camera: second, name: "Second", frame))
        }
        manager.accept(.end(camera: first))
        try manager.drain()
        XCTAssertEqual(manager.snapshot().first?.completedShards, 1)
        XCTAssertEqual(manager.snapshot().first?.activeRecordings, 1)
        let firstPath = configuration.directory + "/First"
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: firstPath).first { $0.hasSuffix(".mp4") })
        let decoded = try await decodedFrames(firstPath + "/" + file)
        XCTAssertEqual(decoded, 45)
        for frame in frames.dropFirst(45) { manager.accept(.media(camera: second, name: "Second", frame)) }
        manager.accept(.end(camera: second)); try manager.drain()
        XCTAssertEqual(manager.snapshot().first?.completedShards, 2)
        XCTAssertEqual(manager.snapshot().first?.activeRecordings, 0)
        XCTAssertNil(manager.snapshot().first?.lastError)
        XCTAssertTrue(manager.hasWritableStore)
    }
    func testUnavailableDisabledStoreCanBeRemoved() throws {
        var configuration = try config(try temporary() + "/output")
        configuration.enabled = false; configuration.directory += "/missing"
        let manager = RecordingStoreManager()
        try manager.install(configuration)
        XCTAssertFalse(manager.hasWritableStore)
        XCTAssertEqual(manager.snapshot().first?.state, "disabled")
        XCTAssertNotNil(manager.snapshot().first?.lastError)
        try manager.remove(configuration.id)
        XCTAssertTrue(manager.snapshot().isEmpty)
    }
    private func verifyPlayableShards(codec: CMVideoCodecType, staleSDP: Bool = false) async throws {
        let root = try temporary()
        var configuration = try config(root + "/output"); configuration.shardDuration = "1s"
        let store = try LocalRecordingStore(configuration: configuration)
        let camera = UUID().uuidString
        let frames = try Self.video(codec: codec)
        XCTAssertEqual(frames.count, 45)
        for (index, media) in frames.enumerated() {
            var payload = Data()
            if staleSDP && index == 0 {
                for set in media.parameterSets {
                    var size = UInt32(set.count).bigEndian
                    withUnsafeBytes(of: &size) { payload.append(contentsOf: $0) }
                    payload.append(set)
                }
            }
            payload.append(media.frame.payload)
            let sets = staleSDP ? [Data([0x67, 0]), Data([0x68, 0])] : media.parameterSets
            // Cross the 32-bit RTP timestamp boundary inside the first shard.
            let timestamp = media.frame.timestamp &+ (UInt32.max - 50000)
            store.accept(.media(camera: camera, name: "Test Camera", EncodedMedia(codec: media.codec, clockRate: media.clockRate, parameterSets: sets,
                frame: EncodedVideoFrame(payload: payload, timestamp: timestamp, keyFrame: media.frame.keyFrame))))
        }
        store.accept(.end(camera: camera))
        XCTAssertTrue(store.finish(timeout: 5))
        XCTAssertNil(store.snapshot().lastError)
        XCTAssertEqual(store.snapshot().recordedFrames, 45)
        let directory = configuration.directory + "/Test Camera"
        let files = try FileManager.default.contentsOfDirectory(atPath: directory).filter { $0.hasSuffix(".mp4") }
        XCTAssertEqual(files.count, 3)
        let manifestDirectory = LocalRecordingLayout.Directory(path: directory, fd: try StoreDirectory.openDirectory(directory))
        let manifest = try LocalRecordingManifest(directory: manifestDirectory,
            identity: .init(storeID: configuration.id, cameraID: camera), owner: geteuid(), readOnly: true)
        let indexed = try manifest.recordings()
        XCTAssertEqual(Set(indexed.map(\.filename)), Set(files))
        XCTAssertEqual(indexed.reduce(Int64(0)) { $0 + $1.frames }, 45)
        XCTAssertTrue(indexed.allSatisfy { $0.state == .complete && $0.endTicks == 90000 })
        var decoded = 0
        for file in files {
            XCTAssertTrue(LocalRecordingLayout.isShard(file), file)
            XCTAssertEqual(try SecureFiles.info(directory + "/" + file)!.st_mode & 0o777, 0o600)
            let asset = AVURLAsset(url: URL(fileURLWithPath: directory + "/" + file))
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(output); XCTAssertTrue(reader.startReading())
            while output.copyNextSampleBuffer() != nil { decoded += 1 }
            XCTAssertEqual(reader.status, .completed, reader.error?.localizedDescription ?? "")
        }
        XCTAssertEqual(decoded, 45)
    }

    private final class Samples { var media: [EncodedMedia] = [] }
    static func video(codec: CMVideoCodecType = kCMVideoCodecType_H264, count: Int = 45) throws -> [EncodedMedia] {
        let samples = Samples()
        var session: VTCompressionSession?
        let result = VTCompressionSessionCreate(allocator: nil, width: 64, height: 64, codecType: codec, encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: { context, _, status, _, sample in
            guard status == noErr, let sample, let context, let block = CMSampleBufferGetDataBuffer(sample), let format = CMSampleBufferGetFormatDescription(sample) else { return }
            let samples = Unmanaged<Samples>.fromOpaque(context).takeUnretainedValue()
            var data = Data(count: CMBlockBufferGetDataLength(block))
            _ = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            var sets: [Data] = []
            let hevc = CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC
            for index in 0..<(hevc ? 3 : 2) {
                var pointer: UnsafePointer<UInt8>?, size = 0
                let result = hevc
                    ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                    : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if result == noErr, let pointer { sets.append(Data(bytes: pointer, count: size)) }
            }
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]]
            let key = !(attachments?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool ?? false)
            let time = CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sample), timescale: 90000, method: .default)
            samples.media.append(EncodedMedia(codec: hevc ? "H265" : "H264", clockRate: 90000, parameterSets: sets, frame: EncodedVideoFrame(payload: data, timestamp: UInt32(time.value), keyFrame: key)))
        }, refcon: Unmanaged.passUnretained(samples).toOpaque(), compressionSessionOut: &session)
        guard result == noErr, let session else { throw ServiceError("Test encoder unavailable: \(result)") }
        defer { VTCompressionSessionInvalidate(session) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 15 as CFNumber)
        for index in 0..<count {
            var pixel: CVPixelBuffer?
            guard CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess, let pixel else { throw ServiceError("Test pixel buffer unavailable") }
            CVPixelBufferLockBaseAddress(pixel, [])
            memset(CVPixelBufferGetBaseAddress(pixel), Int32(index * 5), CVPixelBufferGetDataSize(pixel))
            CVPixelBufferUnlockBaseAddress(pixel, [])
            guard VTCompressionSessionEncodeFrame(session, imageBuffer: pixel, presentationTimeStamp: CMTime(value: Int64(index), timescale: 15), duration: CMTime(value: 1, timescale: 15), frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil) == noErr else { throw ServiceError("Test video encoding failed") }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        return samples.media
    }
}
