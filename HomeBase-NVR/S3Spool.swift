import Foundation
import Darwin
import CryptoKit

struct S3SpoolVolume: Equatable {
    let uuid: String
    let mountPoint: String
    let capacity: Int64
    let available: Int64
    let fileSystem: String
    let flags: UInt32
    static func read(_ path: String) throws -> Self {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { throw ServiceError.posix("Inspect spool volume") }
        guard let uuid = try URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString else {
            throw ServiceError("Cannot identify the spool volume; refusing a possible disk fallback.")
        }
        func bytes(_ blocks: UInt64) -> Int64 {
            let (result, overflow) = blocks.multipliedReportingOverflow(by: UInt64(fs.f_bsize))
            return overflow ? Int64.max : Int64(clamping: result)
        }
        let mount = withUnsafeBytes(of: fs.f_mntonname) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
        let type = withUnsafeBytes(of: fs.f_fstypename) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
        return Self(uuid: uuid, mountPoint: mount, capacity: bytes(fs.f_blocks), available: bytes(fs.f_bavail), fileSystem: type, flags: fs.f_flags)
    }
    var ignoresOwnership: Bool { flags & UInt32(MNT_IGNORE_OWNERSHIP) != 0 }
    func validate(path: String? = nil, clientEncrypted: Bool = false) throws {
        guard ["apfs", "hfs"].contains(fileSystem), flags & UInt32(MNT_LOCAL) != 0,
              flags & UInt32(MNT_RDONLY) == 0 else {
            throw ServiceError("Spooling requires a writable local APFS or HFS+ volume; exFAT, network, and read-only volumes are not supported. Ignore-ownership volumes additionally require client-side encryption.")
        }
        guard !ignoresOwnership || clientEncrypted else {
            throw ServiceError("Ownership is disabled on spool volume \(mountPoint). Enable client-side encryption to spool here without enforcing ownership, or enable ownership for private plaintext spooling. Enabling ownership is a volume-wide change; it is not changed automatically.")
        }
        if let path, path.hasPrefix("/Volumes/") {
            let expectedMount = "/Volumes/" + String(path.split(separator: "/")[1])
            guard mountPoint == expectedMount else { throw ServiceError("The external spool volume is not mounted at \(expectedMount); refusing an internal-disk fallback.") }
        }
    }
}

/// Only encrypted footage may use an ignore-ownership volume. This relaxes
/// confidentiality-related UID/mode checks, not filesystem or identity checks.
enum S3SpoolAccess: Sendable {
    case privateFiles, encryptedSharedVolume
    func validateDirectory(_ path: String) throws {
        if self == .privateFiles { try SecureFiles.validateDirectory(path, owner: geteuid(), mode: 0o700); return }
        guard let info = try SecureFiles.info(path), info.st_mode & S_IFMT == S_IFDIR else {
            throw ServiceError(.permission, "Encrypted spool requires a real directory (not a symbolic link) at \(path).")
        }
        guard Darwin.access(path, R_OK | W_OK | X_OK) == 0 else { throw ServiceError.posix("Access encrypted spool directory \(path)") }
    }
    func acceptsFile(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1 &&
        (self == .encryptedSharedVolume || (info.st_uid == geteuid() && info.st_mode & 0o777 == 0o600))
    }
}

struct S3SpoolLocation: Codable, Equatable {
    var schemaVersion = 1
    let storeID: String
    let path: String
    let volumeUUID: String
}

struct S3SpoolFileIdentity: Sendable {
    let device: dev_t
    let inode: ino_t
    let access: S3SpoolAccess
    init(_ info: stat, access: S3SpoolAccess = .privateFiles) { device = info.st_dev; inode = info.st_ino; self.access = access }
    func matches(_ info: stat) -> Bool { device == info.st_dev && inode == info.st_ino }
}

struct S3ShardMetadata: Codable, Equatable, Sendable {
    var schemaVersion = 1
    let id: String
    let storeID: String
    let cameraID: String
    let bucket: String
    let region: String
    let expectedOwner: String?
    let prefix: String
    let key: String
    let capturedAt: Date
    let size: Int64
    let sha256: String
    var encryption: String?
    var payloadFileName: String { encryption == nil ? "video.mp4" : "video.mp4.hbnvr" }
    var contentType: String { encryption != nil ? "application/octet-stream" : (key.hasSuffix(".mp4") ? "video/mp4" : "text/plain") }
    static func make(store: RecordingStoreConfiguration, camera: String, name: String, capturedAt: Date, data: Data, encrypted: Bool = false, id: String = UUID().uuidString) -> Self {
        let s3 = store.s3!
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss.SSS'Z'"
        let folder = LocalRecordingLayout.cameraName(name) + "--" + camera.lowercased()
        return Self(id: id, storeID: store.id, cameraID: camera, bucket: s3.bucket, region: s3.region, expectedOwner: s3.expectedOwner, prefix: s3.prefix,
                    key: s3.prefix + folder + "/" + formatter.string(from: capturedAt) + "_" + id.lowercased() + (encrypted ? ".mp4.hbnvr" : ".mp4"),
                    capturedAt: capturedAt, size: Int64(data.count), sha256: hash(data), encryption: encrypted ? RecordingEncryption.format : nil)
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

enum S3Payload: Sendable {
    case memory(Data)
    case file(String, Int64, identity: S3SpoolFileIdentity? = nil)
    var size: Int64 { switch self { case .memory(let data): return Int64(data.count); case .file(_, let size, _): return size } }
    func read(offset: Int64, count: Int) throws -> Data {
        guard offset >= 0, offset <= size, count >= 0, Int64(count) <= size - offset else { throw ServiceError("Invalid upload body range.") }
        switch self {
        case .memory(let data): return data.subdata(in: Int(offset)..<(Int(offset) + count))
        case .file(let path, _, let identity):
            let fd = try S3Spool.openFile(path, expectedIdentity: identity); defer { close(fd) }
            var data = Data(count: count)
            try data.withUnsafeMutableBytes { bytes in
                var done = 0
                while done < count {
                    let n = pread(fd, bytes.baseAddress!.advanced(by: done), count - done, off_t(offset) + off_t(done))
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { throw ServiceError.posix("Read spooled shard") }; done += n
                }
            }
            return data
        }
    }
}

struct S3SpoolEntry: Sendable {
    let metadata: S3ShardMetadata
    let directory: String
    let fileIdentity: S3SpoolFileIdentity
    var payload: S3Payload { .file(directory + "/" + metadata.payloadFileName, metadata.size, identity: fileIdentity) }
}

/// Called on a store's serial worker. Complete publications are the ownership
/// handoff; staging and damaged directories continue to consume quota.
final class S3Spool {
    static func directoryContents(_ path: String, read: (String) throws -> [String] = { try FileManager.default.contentsOfDirectory(atPath: $0) }) throws -> [String] {
        do { return try read(path) }
        catch {
            // Foundation wraps opendir's EPERM in NSCocoaErrorDomain 257.
            // It may be TCC, a sandbox, or another policy; don't call it corruption
            // or automatically broaden permissions to try to make it disappear.
            var cause = error as NSError
            for _ in 0..<8 {
                if cause.domain == NSPOSIXErrorDomain, cause.code == Int(EPERM) {
                    throw ServiceError(.permission, "macOS denied access to spool directory \(path) (Operation not permitted). If ownership and permissions are correct, check macOS privacy/removable-volume access. A background daemon cannot approve a privacy prompt. For the installed daemon, check System Settings > Privacy & Security > Full Disk Access for /usr/local/bin/hbnvr, then restart it. Full Disk Access is broader than this folder; no privacy settings or permissions were changed automatically.")
                }
                guard let underlying = cause.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
                cause = underlying
            }
            throw error
        }
    }
    private static let reservationLock = NSLock()
    private static var reservations: [dev_t: Int64] = [:]
    private static let controlFiles: Set<String> = [".hbnvr-spool.lock", ".hbnvr-store.json"]
    let path: String
    let storeID: String
    let mountedVolume: S3SpoolVolume
    let access: S3SpoolAccess
    var requiresEncryption: Bool { access == .encryptedSharedVolume }
    private let identity: S3SpoolFileIdentity
    private let volumeReader: (String) throws -> S3SpoolVolume
    private var directoryFD: Int32 = -1
    private var lockFD: Int32 = -1
    var settings: S3Tuning
    private(set) var entries: [String: S3SpoolEntry] = [:]
    private(set) var readErrors: [String: String] = [:]
    var damaged: [String] { readErrors.keys.sorted() }
    // In-process deletion progress follows an explicit upload acknowledgment.
    // A restart with incomplete metadata retains it for inspection/rechecking.
    private var removedFiles: [String: Set<String>] = [:]
    private(set) var bytes: Int64 = 0
    // Test seams include every durability boundary, including post-rename failure.
    var checkpoint: (String) throws -> Void = { _ in }
    var freeSpace: (String) throws -> Int64
    init(path: String, storeID: String, settings: S3Tuning, create: Bool = true, clientEncrypted: Bool = false,
         volumeReader: @escaping (String) throws -> S3SpoolVolume = S3SpoolVolume.read) throws {
        self.path = path; self.storeID = storeID; self.settings = settings; self.volumeReader = volumeReader
        freeSpace = { try volumeReader($0).available }
        if create {
            try SecureFiles.ensureDirectory(URL(fileURLWithPath: path).deletingLastPathComponent().path, owner: geteuid(), mode: 0o700)
            try SecureFiles.ensureDirectory(path, owner: geteuid(), mode: 0o700)
        }
        mountedVolume = try volumeReader(path); try mountedVolume.validate(path: path, clientEncrypted: clientEncrypted)
        access = mountedVolume.ignoresOwnership ? .encryptedSharedVolume : .privateFiles
        try access.validateDirectory(path)
        guard let info = try SecureFiles.info(path) else { throw ServiceError("Spool directory disappeared.") }
        identity = S3SpoolFileIdentity(info)
        directoryFD = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw ServiceError.posix("Open spool directory") }
        // Persist the newly created spool directory names as well as later entries.
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        if create { try syncDirectory(parent.path); try syncDirectory(parent.deletingLastPathComponent().path) }
        if create { try scan() } // Custom directories are locked/claimed before scanning.
    }
    deinit { if lockFD >= 0 { close(lockFD) }; if directoryFD >= 0 { close(directoryFD) } }
    @discardableResult func validateLocation() throws -> S3SpoolVolume {
        var held = stat()
        guard fstat(directoryFD, &held) == 0, identity.matches(held), let current = try SecureFiles.info(path), identity.matches(current) else {
            throw ServiceError("Spool directory or volume is unavailable or was replaced; no fallback disk will be used. Restore the drive and restart the agent if necessary.")
        }
        let volume = try volumeReader(path); try volume.validate(path: path, clientEncrypted: requiresEncryption)
        guard volume.ignoresOwnership == mountedVolume.ignoresOwnership else { throw ServiceError("Spool volume ownership policy changed; restart the agent to revalidate its permissions.") }
        try access.validateDirectory(path)
        guard volume.uuid == mountedVolume.uuid else { throw ServiceError("Spool volume identity changed; refusing to use a different drive.") }
        return volume
    }
    func volumeSnapshot() -> S3SpoolVolume? { try? validateLocation() }

    /// The registry lives in daemon-private state, not on the removable drive.
    /// Changing location is deliberately offline/drained, never implicit migration.
    private static func canonicalPath(_ path: String) throws -> String {
        // Foundation rewrites /private/tmp to /tmp only once a path exists. POSIX
        // realpath plus missing suffixes gives a stable spelling before/after mkdir.
        var candidate = path, suffix: [String] = []
        while true {
            if let resolved = realpath(candidate, nil) {
                defer { free(resolved) }
                let base = String(cString: resolved)
                return suffix.isEmpty ? base : base + (base == "/" ? "" : "/") + suffix.reversed().joined(separator: "/")
            }
            guard errno == ENOENT, candidate != "/", !candidate.isEmpty else { throw ServiceError.posix("Resolve spool path") }
            suffix.append((candidate as NSString).lastPathComponent)
            candidate = (candidate as NSString).deletingLastPathComponent
            if candidate.isEmpty { candidate = "." }
        }
    }
    static func open(storeID: String, defaultRoot: String, settings: S3Tuning, clientEncrypted: Bool = false,
                     volumeReader: @escaping (String) throws -> S3SpoolVolume = S3SpoolVolume.read) throws -> S3Spool {
        try settings.validate()
        guard UUID(uuidString: storeID) != nil else { throw ServiceError("Invalid spool store identity.") }
        let locations = defaultRoot + "/locations", registry = locations + "/" + storeID + ".json"
        let defaultPath = defaultRoot + "/" + storeID
        let requested = settings.spoolDirectory ?? defaultPath
        // Resolve aliases only for comparison, never create a custom path or mount point.
        let path = try canonicalPath(requested)
        try SecureFiles.ensureDirectory(defaultRoot, owner: geteuid(), mode: 0o700)
        try SecureFiles.ensureDirectory(locations, owner: geteuid(), mode: 0o700)
        let previous: S3SpoolLocation?
        if try SecureFiles.info(registry) != nil {
            previous = try JSONDecoder().decode(S3SpoolLocation.self, from: CameraJSON.read(registry, privateFile: true))
            guard previous?.schemaVersion == 1, previous?.storeID == storeID else { throw ServiceError("Invalid spool-location registry; preserved for inspection.") }
        } else { previous = nil }
        let previousPath = try canonicalPath(previous?.path ?? defaultPath)
        func locationAccess(_ path: String) throws -> S3SpoolAccess {
            let volume = try volumeReader(path)
            try volume.validate(path: path, clientEncrypted: clientEncrypted)
            return volume.ignoresOwnership ? .encryptedSharedVolume : .privateFiles
        }
        if previousPath != path {
            let exists = try SecureFiles.info(previousPath) != nil
            if previous != nil || exists {
                let oldAccess = try locationAccess(previousPath)
                try oldAccess.validateDirectory(previousPath)
                if let previous, try volumeReader(previousPath).uuid != previous.volumeUUID { throw ServiceError("Previous spool drive is unavailable or was replaced; mount it and drain before changing SpoolDirectory.") }
                let names = Set(try Self.directoryContents(previousPath))
                for name in names.intersection(controlFiles) { let fd = try openFile(previousPath + "/" + name, access: oldAccess); close(fd) }
                guard names.subtracting(controlFiles).isEmpty else {
                    throw ServiceError("Previous spool still contains pending or damaged work at \(previousPath). Restore the old setting, drain it, then stop the agent before changing SpoolDirectory.")
                }
            }
            // Relocation never adopts an uninspected backlog or blocks IPC on
            // a full-media scan. Both locations must be drained first.
            if try SecureFiles.info(path) != nil {
                try locationAccess(path).validateDirectory(path)
                guard Set(try Self.directoryContents(path)).subtracting(controlFiles).isEmpty else {
                    throw ServiceError("New spool location must be empty of footage, staging, and damaged work; no backlog was moved.")
                }
            }
        }
        if settings.spoolDirectory != nil { try locationAccess(path).validateDirectory(path) }
        if settings.spoolDirectory != nil, requested.hasPrefix("/Volumes/") {
            let expectedMount = "/Volumes/" + String(requested.split(separator: "/")[1])
            guard try volumeReader(path).mountPoint == expectedMount else {
                throw ServiceError("The external spool volume is not mounted at \(expectedMount); refusing an internal-disk fallback.")
            }
        }
        if let previous, previousPath == path {
            guard try volumeReader(path).uuid == previous.volumeUUID else { throw ServiceError("Configured spool path is on a different volume; no fallback disk will be used.") }
        }
        let spool = try S3Spool(path: path, storeID: storeID, settings: settings, create: settings.spoolDirectory == nil, clientEncrypted: clientEncrypted, volumeReader: volumeReader)
        if settings.spoolDirectory != nil { try spool.claimCustomDirectory() }
        let location = S3SpoolLocation(storeID: storeID, path: path, volumeUUID: spool.mountedVolume.uuid)
        if previous != location {
            try SecureFiles.atomicWrite(CameraJSON.encode(location), to: registry, mode: 0o600)
            try spool.syncDirectory(locations)
            try spool.syncDirectory(defaultRoot)
            try spool.syncDirectory(URL(fileURLWithPath: defaultRoot).deletingLastPathComponent().path)
        }
        return spool
    }
    private func claimCustomDirectory() throws {
        try validateLocation()
        lockFD = openat(directoryFD, ".hbnvr-spool.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw ServiceError.posix("Lock custom spool") }
        var info = stat()
        guard fstat(lockFD, &info) == 0, access.acceptsFile(info), flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw ServiceError("Custom spool is unsafe or already in use by another instance.") }
        let marker = path + "/.hbnvr-store.json"
        if try SecureFiles.info(marker) != nil {
            let fd = try Self.openFile(marker, access: access); defer { close(fd) }
            let bytes = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 65537) ?? Data()
            guard bytes.count <= 65536 else { throw ServiceError("Oversized spool-location marker.") }
            let owner = try JSONDecoder().decode(S3SpoolLocation.self, from: bytes)
            guard owner.schemaVersion == 1, owner.storeID == storeID, owner.volumeUUID == mountedVolume.uuid else { throw ServiceError("Custom spool belongs to another store or volume; refusing to reuse it.") }
        } else {
            guard Set(try Self.directoryContents(path)).subtracting(Self.controlFiles).isEmpty else { throw ServiceError("A new custom spool must be an empty, dedicated directory.") }
            try SecureFiles.atomicWrite(CameraJSON.encode(S3SpoolLocation(storeID: storeID, path: path, volumeUUID: mountedVolume.uuid)), to: marker, mode: 0o600)
            try syncDirectory(path)
        }
        try scan()
    }
    static func openFile(_ path: String, flags: Int32 = O_RDONLY, expectedIdentity: S3SpoolFileIdentity? = nil, access: S3SpoolAccess? = nil) throws -> Int32 {
        let url = URL(fileURLWithPath: path)
        let parent = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw ServiceError.posix("Open spool file directory") }; defer { close(parent) }
        let fd = openat(parent, url.lastPathComponent, flags | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ServiceError.posix("Open spool file") }
        var info = stat()
        let policy = access ?? expectedIdentity?.access ?? .privateFiles
        guard fstat(fd, &info) == 0, policy.acceptsFile(info), expectedIdentity?.matches(info) ?? true else { close(fd); throw ServiceError("Unsafe or replaced spool file; preserved for inspection.") }
        return fd
    }
    private func syncDirectory(_ path: String) throws {
        if path == self.path {
            guard fsync(directoryFD) == 0 else { throw ServiceError.posix("Sync spool directory") }; return
        }
        let fd = path.hasPrefix(self.path + "/")
            ? openat(directoryFD, String(path.dropFirst(self.path.count + 1)), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            : Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ServiceError.posix("Open spool directory") }; defer { close(fd) }
        guard fsync(fd) == 0 else { throw ServiceError.posix("Sync spool directory") }
    }
    private func usage(_ path: String) throws -> Int64 {
        guard let info = try SecureFiles.info(path) else { return 0 }
        guard info.st_mode & S_IFMT == S_IFDIR else { return max(0, info.st_size) }
        return try Self.directoryContents(path).reduce(Int64(max(0, info.st_size))) { try $0 + usage(path + "/" + $1) }
    }
    func refreshUsage() throws {
        try validateLocation()
        bytes = try Self.directoryContents(path).reduce(0) { try $0 + usage(path + "/" + $1) }
    }
    func hasCapacity(for size: Int64 = 1) -> Bool {
        guard size >= 0, (try? validateLocation()) != nil, let free = try? freeSpace(path) else { return false }
        guard settings.spoolLimitBytes >= bytes, settings.spoolLimitBytes - bytes >= 65536,
              free >= settings.minimumFreeBytes, free - settings.minimumFreeBytes >= 65536 else { return false }
        return size <= settings.spoolLimitBytes - bytes - 65536 && size <= free - settings.minimumFreeBytes - 65536
    }
    func noteReadFailure(_ id: String, _ message: String) { readErrors[id] = message }
    func scan(retryOnly: Bool = false, excluding: Set<String> = []) throws {
        try validateLocation()
        let previous = entries
        let leaves = Set(try Self.directoryContents(path)).union(readErrors.keys)
        if !retryOnly {
            // A rescan caused by another publication must not forget confirmed
            // delivery/partial-cleanup ownership for existing entries.
            entries = entries.filter { removedFiles[$0.key] != nil }
            readErrors = readErrors.filter { removedFiles[$0.key] != nil }
        }
        for leaf in leaves.sorted() {
            if Self.controlFiles.contains(leaf) { let fd = try Self.openFile(path + "/" + leaf, access: access); close(fd); continue }
            let directory = path + "/" + leaf
            let staging = leaf.hasSuffix(".staging")
            let id = staging ? String(leaf.dropLast(8)) : leaf
            if excluding.contains(id) { continue }
            if let removed = removedFiles[id], !removed.isEmpty { continue }
            if retryOnly, readErrors[leaf] == nil, previous[id] != nil { continue }
            do {
                guard UUID(uuidString: id) != nil else { throw ServiceError("Unrecognized spool entry.") }
                try access.validateDirectory(directory)
                let manifestFD = try Self.openFile(directory + "/metadata.json", access: access); defer { close(manifestFD) }
                var manifestInfo = stat()
                guard fstat(manifestFD, &manifestInfo) == 0, manifestInfo.st_size <= 65536 else { throw ServiceError("Invalid spool metadata size.") }
                let manifest = try FileHandle(fileDescriptor: manifestFD, closeOnDealloc: false).read(upToCount: 65537) ?? Data()
                guard manifest.count <= 65536 else { throw ServiceError("Oversized spool metadata.") }
                let metadata = try JSONDecoder().decode(S3ShardMetadata.self, from: manifest)
                try S3Configuration(bucket: metadata.bucket, region: metadata.region, prefix: metadata.prefix, expectedOwner: metadata.expectedOwner).validate()
                guard metadata.schemaVersion == 1, metadata.storeID == storeID, metadata.id == id,
                      metadata.encryption == nil || metadata.encryption == RecordingEncryption.format,
                      UUID(uuidString: metadata.cameraID) != nil, metadata.size > 0,
                      metadata.key.hasPrefix(metadata.prefix), metadata.key.utf8.count <= 1024, metadata.sha256.count == 64,
                      (0...253402300799).contains(metadata.capturedAt.timeIntervalSince1970) else { throw ServiceError("Invalid spool manifest.") }
                guard previous[id] == nil || previous[id]?.metadata == metadata else { throw ServiceError("Spool metadata changed; restore the frozen destination, key, and hash before retrying.") }
                guard !requiresEncryption || metadata.encryption == RecordingEncryption.format else { throw ServiceError("Plaintext entry on an ignore-ownership volume; preserved but not replayed. Restore private ownership before retrying.") }
                // 0.7.0–0.7.2 quarantine markers are inert. Keep them until a
                // confirmed upload permits cleanup of the complete entry.
                let names = Set(try Self.directoryContents(directory))
                guard names.subtracting(["quarantined"]) == ["metadata.json", metadata.payloadFileName] else { throw ServiceError("Invalid spool entry files.") }
                let fd = try Self.openFile(directory + "/" + metadata.payloadFileName, access: access); defer { close(fd) }
                var info = stat(); guard fstat(fd, &info) == 0, info.st_size == metadata.size else { throw ServiceError("Spool size mismatch.") }
                if requiresEncryption {
                    var header = Data(count: RecordingEncryption.headerSize)
                    let count = header.withUnsafeMutableBytes { pread(fd, $0.baseAddress!, $0.count, 0) }
                    guard count == header.count else { throw ServiceError("Cannot read encrypted spool header.") }
                    try RecordingEncryption.validateEnvelopeHeader(header, size: metadata.size)
                }
                var hash = SHA256(), buffer = [UInt8](repeating: 0, count: 1024 * 1024)
                while true {
                    let n = Darwin.read(fd, &buffer, buffer.count)
                    if n < 0 && errno == EINTR { continue }
                    guard n >= 0 else { throw ServiceError.posix("Verify spool content") }
                    if n == 0 { break }; hash.update(data: Data(buffer.prefix(n)))
                }
                guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == metadata.sha256 else { throw ServiceError("Spool content hash mismatch.") }
                let final = path + "/" + id
                if staging {
                    guard fsync(fd) == 0 else { throw ServiceError.posix("Sync recovered video") }
                    let mf = try Self.openFile(directory + "/metadata.json", access: access); defer { close(mf) }
                    guard fsync(mf) == 0 else { throw ServiceError.posix("Sync recovered metadata") }
                    try syncDirectory(directory)
                    guard renameatx_np(directoryFD, leaf, directoryFD, id, UInt32(RENAME_EXCL)) == 0 else { throw ServiceError.posix("Publish recovered spool entry") }
                    try syncDirectory(path)
                }
                entries[id] = S3SpoolEntry(metadata: metadata, directory: final, fileIdentity: S3SpoolFileIdentity(info, access: access))
                readErrors[leaf] = nil
            } catch {
                readErrors[leaf] = (error as? ServiceError)?.message ?? "Cannot read or validate spool metadata; entry retained for retry."
            } // Never salvage, evict, or silently erase unreadable work.
        }
        try refreshUsage()
    }
    func publish(_ metadata: S3ShardMetadata, data: Data) throws -> S3SpoolEntry {
        try validateLocation()
        if requiresEncryption {
            guard metadata.encryption == RecordingEncryption.format else { throw ServiceError("Refusing to spool plaintext on an ignore-ownership volume; completed shard retained in RAM.") }
            try RecordingEncryption.validateEnvelopeHeader(Data(data.prefix(RecordingEncryption.headerSize)), size: Int64(data.count))
        }
        if let entry = entries[metadata.id] {
            guard entry.metadata == metadata, readErrors[metadata.id] == nil else { throw ServiceError("Conflicting or unreadable spool entry; RAM retained until durable publication succeeds.") }; return entry
        }
        guard metadata.storeID == storeID, UUID(uuidString: metadata.id) != nil, metadata.size == data.count,
              metadata.sha256 == S3ShardMetadata.hash(data) else { throw ServiceError("Invalid completed shard.") }
        let stage = path + "/" + metadata.id + ".staging", final = path + "/" + metadata.id
        if try SecureFiles.info(stage) != nil || SecureFiles.info(final) != nil {
            try scan()
            if let recovered = entries[metadata.id], recovered.metadata == metadata {
                try syncDirectory(recovered.directory); try syncDirectory(path); return recovered
            }
            guard try SecureFiles.info(final) == nil else { throw ServiceError("Conflicting or damaged completed spool entry; preserved for inspection.") }
            // Only retry our own incomplete publication while its exact complete
            // bytes are still retained in RAM. Restart never takes this path.
            try access.validateDirectory(stage)
            let names = try Self.directoryContents(stage)
            guard Set(names).isSubset(of: [metadata.payloadFileName, "metadata.json"]) else { throw ServiceError("Unexpected staging content was preserved.") }
            for name in names { try removeSpoolFile(metadata.id + ".staging/" + name) }
            guard unlinkat(directoryFD, metadata.id + ".staging", AT_REMOVEDIR) == 0 else { throw ServiceError.posix("Retry spool publication") }
            readErrors[metadata.id + ".staging"] = nil; try syncDirectory(path)
        }
        try refreshUsage()
        guard hasCapacity(for: metadata.size) else { throw ServiceError("S3 spool quota or free-space reserve exhausted; new recording to this store is suspended.") }
        // Reserve the volume headroom across concurrent stores in this process.
        // Unrelated processes can still consume free space; write failures remain
        // explicit and retain the RAM owner.
        let volume = try Self.reserve(path: path, bytes: metadata.size + 65536, free: freeSpace, minimum: settings.minimumFreeBytes)
        defer { Self.release(volume: volume, bytes: metadata.size + 65536) }
        try checkpoint("before-stage")
        // Anchor mutations to the opened directory, even if a mount/path changes
        // between its validation and the syscall. Never follow a fallback path.
        guard mkdirat(directoryFD, metadata.id + ".staging", 0o700) == 0 else { throw ServiceError.posix("Reserve shard staging directory") }
        // On any failure retain staging; the next startup verifies and recovers it.
        defer {
            try? refreshUsage()
            if entries[metadata.id] == nil {
                let leaf = (try? SecureFiles.info(final)) != nil ? metadata.id : metadata.id + ".staging"
                readErrors[leaf] = "Incomplete spool publication; retained for retry."
            }
        }
        try checkpoint("reserved")
        try write(data, to: stage + "/" + metadata.payloadFileName)
        try checkpoint("payload")
        try write(JSONEncoder().encode(metadata), to: stage + "/metadata.json")
        try checkpoint("metadata")
        try syncDirectory(stage)
        try checkpoint("staged")
        guard renameatx_np(directoryFD, metadata.id + ".staging", directoryFD, metadata.id, UInt32(RENAME_EXCL)) == 0 else { throw ServiceError.posix("Publish spooled shard") }
        try checkpoint("renamed")
        try syncDirectory(path)
        try validateLocation()
        guard let info = try SecureFiles.info(final + "/" + metadata.payloadFileName) else { throw ServiceError("Published spool file disappeared.") }
        let entry = S3SpoolEntry(metadata: metadata, directory: final, fileIdentity: S3SpoolFileIdentity(info, access: access)); entries[metadata.id] = entry
        return entry
    }
    private static func reserve(path: String, bytes: Int64, free: (String) throws -> Int64, minimum: Int64) throws -> dev_t {
        reservationLock.lock(); defer { reservationLock.unlock() }
        guard let info = try SecureFiles.info(path) else { throw ServiceError("Spool directory disappeared.") }
        let reserved = reservations[info.st_dev, default: 0]
        let available = try free(path)
        guard available >= minimum, available - minimum >= reserved,
              bytes <= available - minimum - reserved else { throw ServiceError("S3 spool volume reserve is exhausted; recording is suspended.") }
        reservations[info.st_dev] = reserved + bytes; return info.st_dev
    }
    private static func release(volume: dev_t, bytes: Int64) {
        reservationLock.lock(); defer { reservationLock.unlock() }
        reservations[volume, default: 0] -= bytes
    }
    private func write(_ data: Data, to path: String) throws {
        try validateLocation()
        guard path.hasPrefix(self.path + "/") else { throw ServiceError("Write escaped the spool directory.") }
        let relative = String(path.dropFirst(self.path.count + 1))
        let parent = try openEntryDirectory((relative as NSString).deletingLastPathComponent); defer { close(parent) }
        let fd = openat(parent, (relative as NSString).lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ServiceError.posix("Create spool file") }; defer { close(fd) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw ServiceError.posix("Write spool file") }; offset += n
            }
        }
        guard fsync(fd) == 0 else { throw ServiceError.posix("Persist spool file") }
    }
    private func openEntryDirectory(_ name: String) throws -> Int32 {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { throw ServiceError("Invalid spool entry directory.") }
        let fd = openat(directoryFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ServiceError.posix("Open spool entry directory") }
        return fd
    }
    private func removeSpoolFile(_ relative: String) throws {
        let parent = try openEntryDirectory((relative as NSString).deletingLastPathComponent); defer { close(parent) }
        let name = (relative as NSString).lastPathComponent
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ServiceError.posix("Open delivered spool file") }; defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, access.acceptsFile(info) else { throw ServiceError("Unsafe spool file; preserved for inspection.") }
        guard unlinkat(parent, name, 0) == 0 else { throw ServiceError.posix("Remove delivered spool file") }
    }
    /// Caller must have a confirmed successful PUT/completion, not an existence check.
    func delivered(_ id: String) throws {
        guard entries[id] != nil else { return }
        if removedFiles[id] == nil { removedFiles[id] = [] }
        try validateLocation()
        // Before any deletion, allow a repaired/replaced file to be revalidated
        // against the original manifest. Partial cleanup instead resumes from
        // its acknowledged in-process progress, even across unrelated rescans.
        if readErrors[id] != nil, removedFiles[id]?.isEmpty == true {
            try scan(retryOnly: true, excluding: Set(entries.keys).subtracting([id]))
            if let error = readErrors[id] { throw ServiceError(error) }
        }
        guard let entry = entries[id] else { throw ServiceError("Delivered spool entry cannot be read; retained for cleanup retry.") }
        if removedFiles[id]?.contains("directory") != true {
            try access.validateDirectory(entry.directory)
            let names = try Self.directoryContents(entry.directory)
            let files = [entry.metadata.payloadFileName, "metadata.json"] + (names.contains("quarantined") ? ["quarantined"] : [])
            guard Set(names).isSubset(of: Set(files)) else { throw ServiceError("Unexpected spool files were preserved; cleanup will retry.") }
            // Check all remaining files before deleting any of them. A failed
            // read/check is never permission to discard an entry.
            for name in files where removedFiles[id]?.contains(name) != true {
                let fd = try Self.openFile(entry.directory + "/" + name, expectedIdentity: name == entry.metadata.payloadFileName ? entry.fileIdentity : nil, access: access)
                close(fd)
            }
            try checkpoint("delete")
            for name in files where removedFiles[id]?.contains(name) != true {
                try removeSpoolFile(id + "/" + name)
                removedFiles[id, default: []].insert(name)
                try checkpoint("deleted-" + name)
            }
            guard unlinkat(directoryFD, id, AT_REMOVEDIR) == 0 else { throw ServiceError.posix("Remove delivered spool entry") }
            removedFiles[id, default: []].insert("directory")
        }
        try syncDirectory(path)
        try refreshUsage()
        entries[id] = nil; readErrors[id] = nil; removedFiles[id] = nil
    }
}
