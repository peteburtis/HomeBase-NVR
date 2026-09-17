import XCTest
import Foundation
import Darwin

final class S3SpoolLocationTests: XCTestCase {
    private var roots: [String] = []
    override func tearDownWithError() throws { for path in roots { try FileManager.default.removeItem(atPath: path) }; roots.removeAll() }
    private func root() throws -> String {
        let path = "/private/tmp/hbnvr-spool-location-" + UUID().uuidString
        try SecureFiles.ensureDirectory(path, owner: geteuid(), mode: 0o700); roots.append(path); return path
    }
    private func custom(_ root: String) throws -> S3Tuning {
        var settings = S3Tuning(); settings.spoolDirectory = root + "/external-spool"
        try SecureFiles.ensureDirectory(settings.spoolDirectory!, owner: geteuid(), mode: 0o700)
        return settings
    }
    func testJSONDefaultsPathValidationAndReaderVersion() throws {
        XCTAssertNil(try JSONDecoder().decode(S3Tuning.self, from: Data("{}".utf8)).spoolDirectory)
        let settings = try JSONDecoder().decode(S3Tuning.self, from: Data("{\"SpoolDirectory\":\"/Volumes/NVR/Spool\"}".utf8))
        XCTAssertEqual(settings.spoolLimitBytes, 10 * 1024 * 1024 * 1024); try settings.validate()
        XCTAssertEqual(try JSONDecoder().decode(S3Tuning.self, from: JSONEncoder().encode(settings)), settings)
        for path in ["", "/", "~/NVR", "relative", "/a//b", "/a/../b", "/a/./b", "/a/", "/a/\0b"] {
            var invalid = settings; invalid.spoolDirectory = path; XCTAssertThrowsError(try invalid.validate(), path)
        }
        var c = try S3Tests().config(); c.s3?.tuning = settings
        XCTAssertThrowsError(try c.validate()); c.schemaVersion = 3; XCTAssertNoThrow(try c.validate())
        var other = try S3Tests().config(); other.schemaVersion = 3; other.s3?.prefix = "other/"; other.s3?.tuning = settings
        XCTAssertTrue(RecordingStoreRepository.overlap(c, other))
        other.s3?.tuning?.spoolDirectory = settings.spoolDirectory! + "/nested"
        XCTAssertTrue(RecordingStoreRepository.overlap(c, other))
        XCTAssertEqual(c.summary.s3?.settings.spoolDirectory, settings.spoolDirectory)
    }
    func testCustomDirectoryIsExactPrivateLockedAndNotCreatedImplicitly() throws {
        let path = try root(), c = try S3Tests().config(), settings = try custom(path)
        var spool: S3Spool? = try S3Spool.open(storeID: c.id, defaultRoot: path + "/default", settings: settings)
        XCTAssertEqual(spool?.path, settings.spoolDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: settings.spoolDirectory! + "/" + c.id))
        XCTAssertEqual(try SecureFiles.info(settings.spoolDirectory!)!.st_mode & 0o777, 0o700)
        XCTAssertEqual(try SecureFiles.info(settings.spoolDirectory! + "/.hbnvr-store.json")!.st_mode & 0o777, 0o600)
        XCTAssertThrowsError(try S3Spool.open(storeID: c.id, defaultRoot: path + "/default", settings: settings))
        spool = nil
        XCTAssertNoThrow(try S3Spool.open(storeID: c.id, defaultRoot: path + "/default", settings: settings))
        XCTAssertThrowsError(try S3Spool.open(storeID: UUID().uuidString, defaultRoot: path + "/other-default", settings: settings))
        var missing = settings; missing.spoolDirectory = path + "/missing-drive/spool"
        XCTAssertThrowsError(try S3Spool.open(storeID: UUID().uuidString, defaultRoot: path + "/default", settings: missing))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + "/missing-drive"))
    }
    func testRejectsInsecureOwnershipModesAndUnsupportedVolumes() throws {
        let path = try root(), c = try S3Tests().config(), settings = try custom(path)
        XCTAssertEqual(chmod(settings.spoolDirectory!, 0o755), 0)
        XCTAssertThrowsError(try S3Spool.open(storeID: c.id, defaultRoot: path + "/default", settings: settings))
        XCTAssertEqual(chmod(settings.spoolDirectory!, 0o700), 0)
        let actual = try S3SpoolVolume.read(settings.spoolDirectory!)
        XCTAssertThrowsError(try actual.validate(path: "/Volumes/Not-Mounted/HBNVR-spool"))
        for (type, flags) in [("exfat", actual.flags), ("apfs", actual.flags | UInt32(MNT_RDONLY)), ("apfs", actual.flags | UInt32(MNT_IGNORE_OWNERSHIP))] {
            let volume = S3SpoolVolume(uuid: actual.uuid, mountPoint: actual.mountPoint, capacity: actual.capacity, available: actual.available, fileSystem: type, flags: flags)
            XCTAssertThrowsError(try S3Spool.open(storeID: c.id, defaultRoot: path + "/default", settings: settings, volumeReader: { _ in volume }))
        }
        let ignored = S3SpoolVolume(uuid: actual.uuid, mountPoint: "/Volumes/Test", capacity: actual.capacity, available: actual.available, fileSystem: "apfs", flags: UInt32(MNT_LOCAL | MNT_IGNORE_OWNERSHIP))
        XCTAssertThrowsError(try ignored.validate()) { error in
            let message = (error as? ServiceError)?.message ?? ""
            XCTAssertTrue(message.contains("Ownership is disabled on spool volume /Volumes/Test"))
            XCTAssertTrue(message.contains("volume-wide change"))
        }
    }
    func testVolumeAccountingUsesActualTargetAndDetectsReplacement() throws {
        let path = try root(), c = try S3Tests().config(), settings = try custom(path)
        let target = settings.spoolDirectory!, actual = try S3SpoolVolume.read(target)
        var available: Int64 = 5 * 1024 * 1024 * 1024, uuid = actual.uuid
        var inspected: [String] = []
        let reader: (String) throws -> S3SpoolVolume = { location in
            inspected.append(location)
            return S3SpoolVolume(uuid: uuid, mountPoint: actual.mountPoint, capacity: 8 * 1024 * 1024 * 1024,
                available: available, fileSystem: actual.fileSystem, flags: actual.flags)
        }
        let spool = try S3Spool.open(storeID: c.id, defaultRoot: path + "/default", settings: settings, volumeReader: reader)
        XCTAssertTrue(spool.hasCapacity(for: 1024)); XCTAssertEqual(spool.volumeSnapshot()?.available, available)
        XCTAssertTrue(inspected.allSatisfy { $0 == target })
        available = settings.minimumFreeBytes + 65535
        XCTAssertFalse(spool.hasCapacity(for: 1))
        uuid = UUID().uuidString
        XCTAssertThrowsError(try spool.validateLocation()); XCTAssertFalse(spool.hasCapacity()); XCTAssertNil(spool.volumeSnapshot())
    }
    private func sharedVolume(_ path: String) throws -> S3SpoolVolume {
        let actual = try S3SpoolVolume.read(path)
        return S3SpoolVolume(uuid: actual.uuid, mountPoint: actual.mountPoint, capacity: actual.capacity,
            available: actual.available, fileSystem: actual.fileSystem, flags: actual.flags | UInt32(MNT_IGNORE_OWNERSHIP))
    }
    func testEncryptedSharedVolumePublishesRecoversReadsAndCleansUpWithoutPrivateModes() throws {
        let path = try root(), c = try S3Tests().config(), settings = try custom(path), target = settings.spoolDirectory!
        let volume = try sharedVolume(target), defaultRoot = path + "/default"
        XCTAssertEqual(chmod(target, 0o755), 0)
        XCTAssertThrowsError(try S3Spool.open(storeID: c.id, defaultRoot: defaultRoot, settings: settings, volumeReader: { _ in volume }))
        var spool: S3Spool? = try S3Spool.open(storeID: c.id, defaultRoot: defaultRoot, settings: settings, clientEncrypted: true, volumeReader: { _ in volume })
        XCTAssertTrue(spool!.requiresEncryption)
        let plaintext = Data("test video bytes".utf8), data = try RecordingEncryption.encrypt(plaintext, password: "test password")
        let metadata = S3ShardMetadata.make(store: c, camera: UUID().uuidString, name: "Camera", capturedAt: Date(), data: data, encrypted: true)
        let entry = try spool!.publish(metadata, data: data)
        XCTAssertEqual(try entry.payload.read(offset: 0, count: data.count), data)
        XCTAssertThrowsError(try S3Spool.open(storeID: c.id, defaultRoot: defaultRoot, settings: settings, clientEncrypted: true, volumeReader: { _ in volume }))
        spool = nil
        // These modes must not be required on an ownership-ignored volume.
        XCTAssertEqual(chmod(entry.directory, 0o755), 0)
        for file in [entry.directory + "/metadata.json", entry.directory + "/video.mp4.hbnvr", target + "/.hbnvr-store.json", target + "/.hbnvr-spool.lock"] {
            XCTAssertEqual(chmod(file, 0o644), 0)
        }
        // A complete interrupted staging publication follows the same policy.
        try FileManager.default.moveItem(atPath: entry.directory, toPath: entry.directory + ".staging")
        spool = try S3Spool.open(storeID: c.id, defaultRoot: defaultRoot, settings: settings, clientEncrypted: true, volumeReader: { _ in volume })
        let recovered = try XCTUnwrap(spool?.entries[metadata.id])
        let replay = try recovered.payload.read(offset: 0, count: data.count)
        XCTAssertEqual(try RecordingEncryption.decrypt(replay, password: "test password"), plaintext)
        XCTAssertEqual(spool?.damaged, [])
        XCTAssertEqual(try SecureFiles.info(defaultRoot + "/locations/" + c.id + ".json")!.st_mode & 0o777, 0o600)
        try spool!.delivered(metadata.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: entry.directory))
        XCTAssertEqual(try SecureFiles.info(target)!.st_mode & 0o777, 0o755) // No chmod of the user's directory.
    }
    func testEncryptedSharedVolumeNeverPublishesPlaintextAndRetainsUnexpectedPlaintext() throws {
        let path = try root(), c = try S3Tests().config(), settings = try custom(path), target = settings.spoolDirectory!
        let volume = try sharedVolume(target), defaultRoot = path + "/default"
        // Existing plaintext from before a mount-policy change is preserved.
        var old: S3Spool? = try S3Spool.open(storeID: c.id, defaultRoot: defaultRoot, settings: settings)
        let (metadata, data) = S3Tests().shard(c)
        let entry = try old!.publish(metadata, data: data); old = nil
        let spool = try S3Spool.open(storeID: c.id, defaultRoot: defaultRoot, settings: settings, clientEncrypted: true, volumeReader: { _ in volume })
        XCTAssertNil(spool.entries[metadata.id]); XCTAssertNotNil(spool.readErrors[metadata.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: entry.directory + "/video.mp4"))
        let (next, bytes) = S3Tests().shard(c)
        XCTAssertThrowsError(try spool.publish(next, data: bytes))
        var mislabeled = next; mislabeled.encryption = RecordingEncryption.format
        XCTAssertThrowsError(try spool.publish(mislabeled, data: bytes))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target + "/" + next.id + ".staging"))
    }
    func testEncryptionDoesNotRelaxFilesystemDurabilityOrPrivateVolumePermissions() throws {
        let path = try root(), c = try S3Tests().config(), settings = try custom(path), actual = try S3SpoolVolume.read(settings.spoolDirectory!)
        XCTAssertEqual(chmod(settings.spoolDirectory!, 0o755), 0)
        XCTAssertThrowsError(try S3Spool.open(storeID: c.id, defaultRoot: path + "/default", settings: settings, clientEncrypted: true))
        XCTAssertEqual(chmod(settings.spoolDirectory!, 0o700), 0)
        for (type, flags) in [("exfat", actual.flags), ("apfs", actual.flags | UInt32(MNT_RDONLY)), ("apfs", actual.flags & ~UInt32(MNT_LOCAL))] {
            let volume = S3SpoolVolume(uuid: actual.uuid, mountPoint: actual.mountPoint, capacity: actual.capacity, available: actual.available, fileSystem: type, flags: flags)
            XCTAssertThrowsError(try S3Spool.open(storeID: c.id, defaultRoot: path + "/default", settings: settings, clientEncrypted: true, volumeReader: { _ in volume }))
        }
    }
    func testSharedAccessStillRejectsLinksAndReplacedFiles() throws {
        let path = try root(), file = path + "/encrypted"
        try SecureFiles.atomicWrite(Data("ciphertext".utf8), to: file, mode: 0o644)
        var info = try XCTUnwrap(SecureFiles.info(file))
        info.st_uid = geteuid() + 1
        XCTAssertFalse(S3SpoolAccess.privateFiles.acceptsFile(info))
        XCTAssertTrue(S3SpoolAccess.encryptedSharedVolume.acceptsFile(info))
        let identity = S3SpoolFileIdentity(info, access: .encryptedSharedVolume)
        let fd = try S3Spool.openFile(file, expectedIdentity: identity); close(fd)
        try FileManager.default.createSymbolicLink(atPath: path + "/link", withDestinationPath: file)
        XCTAssertThrowsError(try S3Spool.openFile(path + "/link", access: .encryptedSharedVolume))
        XCTAssertThrowsError(try S3SpoolAccess.encryptedSharedVolume.validateDirectory(path + "/link"))
        XCTAssertEqual(link(file, path + "/hardlink"), 0)
        XCTAssertThrowsError(try S3Spool.openFile(file, access: .encryptedSharedVolume))
        try FileManager.default.removeItem(atPath: path + "/hardlink")
        try FileManager.default.moveItem(atPath: file, toPath: file + ".original")
        try SecureFiles.atomicWrite(Data("replacement".utf8), to: file, mode: 0o644)
        XCTAssertThrowsError(try S3Spool.openFile(file, expectedIdentity: identity))
    }
    func testCannotDisableEncryptionOnSharedSpoolOrSilentlyChangeMountPolicy() throws {
        let path = try root(), settings = try custom(path), volume = try sharedVolume(settings.spoolDirectory!)
        var c = try S3Tests().config(); c.enabled = false; c.schemaVersion = 3
        c.s3?.tuning = settings; c.s3?.clientEncryption = S3ClientEncryption(password: "test password")
        let network = FakeS3()
        let store = try S3RecordingStore(configuration: c, spoolRoot: path + "/default", factory: { _ in network }, volumeReader: { _ in volume }, log: { _ in })
        var changed = c; changed.s3?.clientEncryption = S3ClientEncryption(enabled: false)
        XCTAssertThrowsError(try store.update(changed)); XCTAssertEqual(store.configuration, c)
        changed = c; changed.s3?.clientEncryption = S3ClientEncryption(password: "replacement password")
        XCTAssertNoThrow(try store.update(changed))
        XCTAssertTrue(store.finish(timeout: 5))
        let other = path + "/other"; try SecureFiles.ensureDirectory(other, owner: geteuid(), mode: 0o700)
        var ignored = false
        let spool = try S3Spool(path: other, storeID: UUID().uuidString, settings: S3Tuning(), create: false, clientEncrypted: true, volumeReader: { _ in
            S3SpoolVolume(uuid: volume.uuid, mountPoint: volume.mountPoint, capacity: volume.capacity, available: volume.available,
                fileSystem: volume.fileSystem, flags: ignored ? volume.flags : volume.flags & ~UInt32(MNT_IGNORE_OWNERSHIP))
        })
        ignored = true
        XCTAssertThrowsError(try spool.validateLocation()); XCTAssertFalse(spool.hasCapacity())
    }
    func testSharedSpoolDoesNotFollowReplacedStagingDirectory() throws {
        let path = try root(), c = try S3Tests().config(), settings = try custom(path), target = settings.spoolDirectory!
        let volume = try sharedVolume(target), outside = path + "/outside"
        try SecureFiles.ensureDirectory(outside, owner: geteuid(), mode: 0o700)
        let spool = try S3Spool.open(storeID: c.id, defaultRoot: path + "/default", settings: settings, clientEncrypted: true, volumeReader: { _ in volume })
        let data = try RecordingEncryption.encrypt(Data("video".utf8), password: "test password")
        let metadata = S3ShardMetadata.make(store: c, camera: UUID().uuidString, name: "Camera", capturedAt: Date(), data: data, encrypted: true)
        spool.checkpoint = { point in
            if point == "reserved" {
                let stage = target + "/" + metadata.id + ".staging"
                try FileManager.default.moveItem(atPath: stage, toPath: stage + ".original")
                try FileManager.default.createSymbolicLink(atPath: stage, withDestinationPath: outside)
            }
        }
        XCTAssertThrowsError(try spool.publish(metadata, data: data))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside).isEmpty)
    }
    func testDirectoryReadDenialExplainsPrivacyWithoutMisclassifyingOtherFailures() throws {
        let denied = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError, userInfo: [NSUnderlyingErrorKey: denied])
        for error in [denied, wrapped] {
            XCTAssertThrowsError(try S3Spool.directoryContents("/Volumes/Test/Spool", read: { _ in throw error })) { result in
                let failure = result as? ServiceError, message = failure?.message ?? ""
                XCTAssertEqual(failure?.code, .permission)
                XCTAssertTrue(message.contains("Operation not permitted"))
                XCTAssertTrue(message.contains("/Volumes/Test/Spool"))
                XCTAssertTrue(message.contains("/usr/local/bin/hbnvr"))
                XCTAssertTrue(message.contains("Full Disk Access is broader than this folder"))
            }
        }
        let io = NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        XCTAssertThrowsError(try S3Spool.directoryContents("/unused", read: { _ in throw io })) { error in
            XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
            XCTAssertEqual((error as NSError).code, Int(EIO))
        }
        XCTAssertEqual(try S3Spool.directoryContents("/unused", read: { _ in ["a", "b"] }), ["a", "b"])
    }
    func testRelocationRefusesPendingWorkThenAllowsDrainedRestart() throws {
        let path = try root(), c = try S3Tests().config(), settings = try custom(path), defaultRoot = path + "/default"
        var old: S3Spool? = try S3Spool.open(storeID: c.id, defaultRoot: defaultRoot, settings: S3Tuning())
        let (metadata, data) = S3Tests().shard(c)
        _ = try old!.publish(metadata, data: data)
        old = nil
        XCTAssertThrowsError(try S3Spool.open(storeID: c.id, defaultRoot: defaultRoot, settings: settings))
        old = try S3Spool.open(storeID: c.id, defaultRoot: defaultRoot, settings: S3Tuning())
        XCTAssertEqual(old?.entries.count, 1); try old!.delivered(metadata.id); old = nil
        var relocated: S3Spool? = try S3Spool.open(storeID: c.id, defaultRoot: defaultRoot, settings: settings)
        XCTAssertEqual(relocated?.path, settings.spoolDirectory)
        relocated = nil
        // The durable registry also prevents abandoning a custom location later.
        try FileManager.default.moveItem(atPath: settings.spoolDirectory!, toPath: settings.spoolDirectory! + ".detached")
        XCTAssertThrowsError(try S3Spool.open(storeID: c.id, defaultRoot: defaultRoot, settings: S3Tuning()))
    }
    func testUnavailableOrReplacedDirectoryNeverReceivesWritesAndPayloadPinsInode() throws {
        let path = try root(), c = try S3Tests().config(), settings = try custom(path), target = settings.spoolDirectory!
        let spool = try S3Spool.open(storeID: c.id, defaultRoot: path + "/default", settings: settings)
        let (metadata, data) = S3Tests().shard(c)
        let entry = try spool.publish(metadata, data: data)
        try FileManager.default.moveItem(atPath: target, toPath: target + ".detached")
        try SecureFiles.ensureDirectory(target, owner: geteuid(), mode: 0o700)
        let (next, bytes) = S3Tests().shard(c)
        XCTAssertThrowsError(try spool.publish(next, data: bytes)); XCTAssertFalse(spool.hasCapacity())
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target).isEmpty)
        try FileManager.default.removeItem(atPath: target)
        try FileManager.default.moveItem(atPath: target + ".detached", toPath: target)
        try spool.validateLocation()
        let payloadPath = entry.directory + "/" + metadata.payloadFileName
        try FileManager.default.moveItem(atPath: payloadPath, toPath: payloadPath + ".original")
        try SecureFiles.atomicWrite(data, to: payloadPath, mode: 0o600)
        XCTAssertThrowsError(try entry.payload.read(offset: 0, count: data.count))
        XCTAssertThrowsError(try spool.delivered(metadata.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: payloadPath + ".original"))
    }
    func testMissingDriveSuspendsStoreWithoutQuarantiningAndResumesReplay() async throws {
        let helper = S3Tests(), path = try root(), settings = try custom(path)
        var c = try helper.config(); c.schemaVersion = 3; c.s3?.tuning = settings
        let actual = try S3SpoolVolume.read(settings.spoolDirectory!)
        var uuid = actual.uuid
        let spool = try S3Spool.open(storeID: c.id, defaultRoot: path + "/default", settings: settings, volumeReader: { _ in
            S3SpoolVolume(uuid: uuid, mountPoint: actual.mountPoint, capacity: actual.capacity, available: actual.available, fileSystem: actual.fileSystem, flags: actual.flags)
        })
        let (metadata, data) = helper.shard(c); _ = try spool.publish(metadata, data: data)
        let queue = DispatchQueue(label: "s3-detached-test"), network = FakeS3(); await network.configure(automatic: true)
        let manager = S3UploadManager(configuration: c, spool: spool, queue: queue, factory: { _ in network })
        try await helper.on(queue) {
            uuid = UUID().uuidString; manager.tick()
            let status = manager.snapshot(assemblingBytes: 0)
            XCTAssertFalse(status.acceptingRecording); XCTAssertNil(status.spoolVolumeAvailableBytes)
            XCTAssertEqual(status.spoolDirectory, settings.spoolDirectory); XCTAssertEqual(status.unreadableSpoolCount, 0)
            XCTAssertEqual(status.spoolLimitBytes, settings.spoolLimitBytes)
        }
        let attempts = await network.attempts.count; XCTAssertEqual(attempts, 0)
        try await helper.on(queue) { uuid = actual.uuid; manager.tick() }
        try await helper.eventually { try await helper.on(queue) { manager.snapshot(assemblingBytes: 0).confirmedUploads == 1 } }
        try await helper.on(queue) {
            XCTAssertTrue(manager.snapshot(assemblingBytes: 0).acceptingRecording)
            XCTAssertEqual(manager.snapshot(assemblingBytes: 0).spoolCount, 0)
            XCTAssertNil(manager.lastError); manager.stopDispatch()
        }
    }
    func testLiveRelocationRejectedWithoutChangingConfiguration() throws {
        let path = try root(), c = try S3Tests().config(), network = FakeS3()
        let store = try S3RecordingStore(configuration: c, spoolRoot: path + "/default", factory: { _ in network }, log: { _ in })
        var changed = c; changed.schemaVersion = 3; changed.s3?.tuning = try custom(path)
        XCTAssertThrowsError(try store.update(changed)); XCTAssertEqual(store.configuration, c)
        XCTAssertTrue(store.finish(timeout: 5))
    }
    func testPathReplacementBetweenCapacityCheckAndWriteCannotCreateFallbackFiles() throws {
        let path = try root(), c = try S3Tests().config(), settings = try custom(path), target = settings.spoolDirectory!
        let spool = try S3Spool.open(storeID: c.id, defaultRoot: path + "/default", settings: settings)
        spool.checkpoint = { point in
            if point == "before-stage" {
                try FileManager.default.moveItem(atPath: target, toPath: target + ".detached")
                try SecureFiles.ensureDirectory(target, owner: geteuid(), mode: 0o700)
            }
        }
        let (metadata, data) = S3Tests().shard(c)
        XCTAssertThrowsError(try spool.publish(metadata, data: data))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target + ".detached/" + metadata.id + ".staging"))
    }
}
