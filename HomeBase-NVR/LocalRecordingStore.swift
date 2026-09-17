import Foundation
import Darwin
@preconcurrency import AVFoundation
import CoreMedia

/// Human-facing paths, with hidden identity metadata to separate names from ownership.
enum LocalRecordingLayout {
    static let markerName = ".hbnvr-camera.json"
    struct Identity: Codable, Equatable {
        var schemaVersion = 1
        let storeID: String
        let cameraID: String
        enum CodingKeys: String, CodingKey {
            case schemaVersion = "SchemaVersion", storeID = "StoreID", cameraID = "CameraID"
        }
    }
    final class Directory {
        let path: String
        let fd: Int32
        init(path: String, fd: Int32) { self.path = path; self.fd = fd }
        deinit { close(fd) }
    }
    static func cameraName(_ name: String) -> String {
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        var safe = String(name.precomposedStringWithCanonicalMapping.unicodeScalars.map {
            forbidden.contains($0) ? "-" : String($0)
        }.joined()).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        // Leave ample room for a collision suffix, including on byte-limited filesystems.
        while safe.utf8.count > 180 { safe.removeLast() }
        return safe.isEmpty ? "Camera" : safe
    }
    static func identity(in fd: Int32) throws -> Identity? {
        let file = openat(fd, markerName, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else {
            if [ENOENT, ELOOP].contains(errno) { return nil }
            throw ServiceError.posix("Read camera directory identity")
        }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o777 == 0o600,
              info.st_size > 0, info.st_size <= 4096 else { return nil }
        let data = try handle.read(upToCount: 4097) ?? Data()
        guard let value = try? JSONDecoder().decode(Identity.self, from: data), value.schemaVersion == 1,
              UUID(uuidString: value.storeID) != nil, UUID(uuidString: value.cameraID) != nil else { return nil }
        return value
    }
    static func cameraDirectory(root: String, fd: Int32, store: String, camera: String, name: String, owner: uid_t) throws -> Directory {
        let identity = Identity(storeID: store, cameraID: camera), base = cameraName(name)
        for index in 1...1000 {
            let leaf = index == 1 ? base : "\(base) (\(index))"
            if mkdirat(fd, leaf, 0o700) == 0 {
                let child = openat(fd, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw ServiceError.posix("Open camera recording directory") }
                let directory = Directory(path: root + "/" + leaf, fd: child)
                try StoreDirectory.restrict(child, owner: owner, daemon: geteuid(), directory: true)
                let file = openat(child, markerName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard file >= 0 else { throw ServiceError.posix("Create camera directory identity") }
                defer { close(file) }
                let handle = FileHandle(fileDescriptor: file, closeOnDealloc: false)
                try handle.write(contentsOf: CameraJSON.encode(identity))
                guard fsync(file) == 0, fsync(child) == 0, fsync(fd) == 0 else { throw ServiceError.posix("Persist camera directory identity") }
                return directory
            }
            guard errno == EEXIST else { throw ServiceError.posix("Create camera recording directory") }
            // A display-name collision is not permission to adopt an unrelated folder.
            var info = stat()
            guard fstatat(fd, leaf, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw ServiceError.posix("Inspect camera recording directory") }
            guard info.st_mode & S_IFMT == S_IFDIR else { continue }
            let child = openat(fd, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw ServiceError.posix("Open existing camera recording directory") }
            let directory = Directory(path: root + "/" + leaf, fd: child)
            guard try Self.identity(in: child) == identity else { continue }
            try StoreDirectory.validate(child, owner: owner, daemon: geteuid())
            return directory
        }
        throw ServiceError("Too many colliding camera directory names; choose a different camera name.")
    }
    static func verify(path: String, fd: Int32, owner: uid_t) throws {
        let current = try StoreDirectory.openDirectory(path); defer { close(current) }
        guard try sameDirectory(fd, current) else {
            throw ServiceError("Recording directory was replaced; stop and reconfigure the store.")
        }
        try StoreDirectory.validate(current, owner: owner, daemon: geteuid())
    }
    static func sameDirectory(_ lhs: Int32, _ rhs: Int32) throws -> Bool {
        var first = stat(), second = stat()
        guard fstat(lhs, &first) == 0, fstat(rhs, &second) == 0 else { throw ServiceError.posix("Inspect recording directory identity") }
        return first.st_dev == second.st_dev && first.st_ino == second.st_ino
    }
    static func shardStem(at date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: date)
    }
    static func availableStem(in fd: Int32, at date: Date = Date(), timeZone: TimeZone = .current) throws -> String {
        let base = shardStem(at: date, timeZone: timeZone)
        for index in 1...10000 {
            let stem = index == 1 ? base : "\(base)-\(index)"
            var occupied = false
            for suffix in [".mp4", ".mp4.recording"] {
                var info = stat()
                if fstatat(fd, stem + suffix, &info, AT_SYMLINK_NOFOLLOW) == 0 { occupied = true }
                else if errno != ENOENT { throw ServiceError.posix("Inspect recording filename") }
            }
            if !occupied { return stem }
        }
        throw ServiceError("Too many recordings with the same timestamp; check the system clock.")
    }
    static func isShard(_ name: String) -> Bool {
        name.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}(?:-[0-9]+)?\.mp4(?:\.recording)?$"#, options: .regularExpression) != nil
    }
}

/// AVFoundation readiness is transient backpressure, not an I/O failure. This
/// bounded wait runs only on a store worker; reception and IPC remain independent.
enum MP4WriterWait {
    static let timeout: TimeInterval = 30
    static func untilReady(ready: () -> Bool, failure: () -> ServiceError?, timeoutMessage: String,
                           now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                           pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) throws {
        let deadline = now() + timeout
        while true {
            if let error = failure() { throw error }
            if ready() { return }
            let remaining = deadline - now()
            guard remaining > 0 else { throw ServiceError(.timeout, timeoutMessage) }
            pause(min(0.01, remaining))
        }
    }
    static func errorCodes(_ error: Error?) -> String {
        var current = error as NSError?, codes: [String] = []
        while let value = current, codes.count < 3 {
            codes.append("\(value.domain) \(value.code)")
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        // Never dump NSError userInfo, which may contain paths, URLs or credentials.
        return codes.isEmpty ? "no framework error reported" : codes.joined(separator: "; ")
    }
}

/// Built-in destination. File/container concerns never escape this implementation.
final class LocalRecordingStore: RecordingDestination, @unchecked Sendable {
    let configuration: RecordingStoreConfiguration
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var status: RecordingStoreStatus
    private var accepting = true
    private var finished = false
    private var queuedBytes = 0
    private var queuedEvents = 0
    private let drained = DispatchGroup()
    private let directoryFD: Int32
    private let path: String
    private var instanceLock: InstanceLock?
    private var legacyLock: InstanceLock?
    private let log: (String) -> Void
    private let shardSeconds: Int64
    private let retentionSeconds: Int64
    private var timer: DispatchSourceTimer?
    private var cameras: [String: Track] = [:]
    private var manifests: [String: LocalRecordingManifest] = [:]
    private final class Track {
        var name = ""
        var directory: LocalRecordingLayout.Directory?
        var codec = ""
        var sets: [Int: Data] = [:]
        var writer: MP4Shard?
        var manifest: LocalRecordingManifest?
        var recordingID: String?
        var clock = LocalRecordingClock()
        var lastManifestCheckpoint: TimeInterval = 0
    }

    init(configuration: RecordingStoreConfiguration, log: @escaping (String) -> Void = { _ in }) throws {
        try configuration.validate()
        self.configuration = configuration
        self.log = log
        shardSeconds = try IntervalText.seconds(configuration.shardDuration)
        retentionSeconds = try IntervalText.seconds(configuration.retentionPeriod)
        queue = DispatchQueue(label: "hbnvr.local-store.\(configuration.id)")
        status = RecordingStoreStatus(id: configuration.id, name: configuration.name, enabled: configuration.enabled, state: configuration.enabled ? "ready" : "disabled")
        let root = try StoreDirectory.openDirectory(configuration.directory)
        directoryFD = root
        path = configuration.directory
        do {
            try StoreDirectory.validate(root, owner: configuration.ownerUID, daemon: geteuid())
            instanceLock = try InstanceLock(path: path + "/.hbnvr.lock")
            // Also exclude a pre-0.5.3 writer when upgrading a previously used root.
            let legacyPath = path + "/hbnvr-" + configuration.id
            if try SecureFiles.info(legacyPath) != nil {
                let legacy = try StoreDirectory.openDirectory(legacyPath); defer { close(legacy) }
                try StoreDirectory.validate(legacy, owner: configuration.ownerUID, daemon: geteuid())
                legacyLock = try InstanceLock(path: legacyPath + "/.store.lock")
            }
            // Real write/unlink probe in the daemon identity, before reporting usable.
            let name = ".probe-" + UUID().uuidString
            let probe = openat(directoryFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard probe >= 0 else { throw ServiceError.posix("Daemon cannot write to recording destination") }
            close(probe)
            guard unlinkat(directoryFD, name, 0) == 0 else { throw ServiceError.posix("Daemon cannot clean up recording destination") }
        } catch { close(directoryFD); throw error }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 30)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock(); let stopping = self.finished; self.lock.unlock()
            guard !stopping else { return }
            do { try self.expire() } catch { self.fail(error); self.finishTracks() }
        }
        self.timer = timer; timer.resume()
    }
    deinit { timer?.cancel(); close(directoryFD) }

    func snapshot() -> RecordingStoreStatus {
        lock.lock(); defer { lock.unlock() }
        var value = status; value.pendingBytes = queuedBytes; return value
    }
    func accept(_ event: RecordingEvent) {
        lock.lock()
        guard accepting, configuration.enabled else { lock.unlock(); return }
        guard queuedBytes + event.bytes <= 32 * 1024 * 1024, queuedEvents < 2048 else {
            accepting = false
            status.recordFailure("Local store queue limit reached; reception continues. Disable/enable this store to retry.")
            lock.unlock()
            log("Store \(configuration.id): queue limit reached; recording stopped, reception continues.")
            queue.async { [self] in finishTracks() }
            return
        }
        queuedBytes += event.bytes; queuedEvents += 1
        lock.unlock()
        queue.async { [self] in
            defer { lock.lock(); queuedBytes -= event.bytes; queuedEvents -= 1; lock.unlock() }
            do {
                switch event {
                case .end(let camera):
                    if let track = cameras.removeValue(forKey: camera) { try finish(track) }
                case .media(let camera, let name, let media): try consume(camera: camera, name: name, media: media)
                }
            } catch { fail(error); finishTracks() }
        }
    }
    func finish(timeout: TimeInterval) -> Bool {
        lock.lock()
        if !finished {
            finished = true; accepting = false
            if status.state != "error" { status.state = "stopping" }
            drained.enter()
            queue.async { [self] in
                timer?.cancel(); timer = nil
                finishTracks()
                manifests.removeAll()
                // Release before notifying a replacing instance, not at eventual deinit.
                instanceLock = nil
                legacyLock = nil
                drained.leave()
            }
        }
        lock.unlock()
        return drained.wait(timeout: .now() + timeout) == .success
    }
    func flush(timeout: TimeInterval) -> Bool {
        let barrier = DispatchGroup(); barrier.enter()
        queue.async { barrier.leave() }
        return barrier.wait(timeout: .now() + timeout) == .success
    }
    private func fail(_ error: Error) {
        let message = (error as? ServiceError)?.message ?? "Local recording failed; check destination access and free space."
        lock.lock(); accepting = false
        status.recordFailure(message)
        lock.unlock()
        log("Store \(configuration.id): \(message)")
    }
    private func finishTracks() {
        for track in cameras.values {
            do { try finish(track) } catch { fail(error) }
        }
        cameras.removeAll()
    }
    private func finish(_ track: Track) throws {
        guard let writer = track.writer else { return }
        track.writer = nil
        let recordingID = track.recordingID; track.recordingID = nil
        defer { lock.lock(); status.activeRecordings -= 1; lock.unlock() }
        do {
            try writer.finish()
            if let recordingID, let manifest = track.manifest {
                try manifest.complete(id: recordingID, filename: writer.finalName,
                                      endTicks: writer.endTicks, frames: writer.sampleCount)
            }
        } catch {
            if let recordingID { try? track.manifest?.interrupt(id: recordingID) }
            throw error
        }
        lock.lock(); status.completedShards &+= 1; lock.unlock()
    }
    private func manifest(for directory: LocalRecordingLayout.Directory,
                          identity: LocalRecordingLayout.Identity, create: Bool) throws -> LocalRecordingManifest? {
        if let existing = manifests[directory.path] { return existing }
        if !create {
            var info = stat()
            if fstatat(directory.fd, LocalRecordingManifest.filename, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT { return nil }
                throw ServiceError.posix("Inspect local manifest")
            }
        }
        let value = try LocalRecordingManifest(directory: directory, identity: identity, owner: configuration.ownerUID)
        manifests[directory.path] = value
        return value
    }
    private func consume(camera: String, name: String, media: EncodedMedia) throws {
        guard UUID(uuidString: camera) != nil else { throw ServiceError("Invalid recording camera ID.") }
        lock.lock(); let failed = status.state == "error"; lock.unlock()
        if failed { return }
        let track = cameras[camera] ?? Track(); cameras[camera] = track
        if track.name != name { try finish(track); track.name = name; track.directory = nil; track.manifest = nil }
        if track.codec != media.codec { try finish(track); track.codec = media.codec; track.sets.removeAll(); track.clock = LocalRecordingClock() }
        let nals = try Self.nals(media.frame.payload)
        var changed = false
        // SDP initializes missing parameters; newer in-band parameters take precedence.
        // Reapplying stale SDP on every frame would undo a camera's codec update.
        for (source, overwrite) in [(media.parameterSets, false), (nals, true)] {
            for nal in source where !nal.isEmpty {
                let type = media.codec == "H264" ? Int(nal[0] & 31) : Int((nal[0] >> 1) & 63)
                if (media.codec == "H264" ? [7, 8] : [32, 33, 34]).contains(type),
                   (overwrite || track.sets[type] == nil), track.sets[type] != nal {
                    changed = true; track.sets[type] = nal
                }
            }
        }
        if changed { try finish(track) }
        let required = media.codec == "H264" ? [7, 8] : [32, 33, 34]
        guard required.allSatisfy({ track.sets[$0] != nil }), nals.contains(where: {
            media.codec == "H264" ? (1...5).contains(Int($0[0] & 31)) : ($0[0] >> 1) & 63 < 32
        }) else { return }
        let observed = try track.clock.observe(media)
        if observed.discontinuity { try finish(track) }
        if let writer = track.writer, media.frame.keyFrame, writer.elapsed(media.frame.timestamp) >= Double(shardSeconds) {
            try finish(track)
        }
        if track.writer == nil {
            guard media.frame.keyFrame else { return }
            // Detect replacement of a path before letting AVFoundation use it.
            try LocalRecordingLayout.verify(path: path, fd: directoryFD, owner: configuration.ownerUID)
            if track.directory == nil {
                track.directory = try LocalRecordingLayout.cameraDirectory(root: path, fd: directoryFD,
                    store: configuration.id, camera: camera, name: name, owner: configuration.ownerUID)
            }
            let directory = track.directory!
            try LocalRecordingLayout.verify(path: directory.path, fd: directory.fd, owner: configuration.ownerUID)
            track.manifest = try manifest(for: directory,
                identity: .init(storeID: configuration.id, cameraID: camera), create: true)
            let timing = ShardTimingMetadata(storeID: configuration.id, cameraID: camera, media: media, time: observed.timing)
            track.writer = try MP4Shard(directory: directory,
                                        codec: media.codec, sets: required.map { track.sets[$0]! }, clock: media.clockRate,
                                        firstTimestamp: media.frame.timestamp, capturedAt: observed.time, timing: timing)
            lock.lock(); status.activeRecordings += 1; lock.unlock()
            let id = timing.shardID
            try track.manifest!.begin(id: id, temporaryName: track.writer!.temporaryName, finalName: track.writer!.finalName,
                                      start: observed.time, timescale: media.clockRate, sourceTimestamp: media.frame.timestamp, timing: timing)
            track.recordingID = id
            track.lastManifestCheckpoint = ProcessInfo.processInfo.systemUptime
        }
        try track.writer!.append(media.frame)
        let now = ProcessInfo.processInfo.systemUptime
        if now - track.lastManifestCheckpoint >= 5, let id = track.recordingID, let writer = track.writer {
            try track.manifest!.progress(id: id, endTicks: writer.endTicks, frames: writer.sampleCount)
            track.lastManifestCheckpoint = now
        }
        lock.lock(); status.recordedFrames &+= 1; lock.unlock()
    }
    static func nals(_ data: Data) throws -> [Data] {
        var offset = 0, result: [Data] = []
        while offset < data.count {
            guard offset + 4 <= data.count, result.count < 4096 else { throw ServiceError("Invalid encoded NAL length or count.") }
            let length = data[offset..<offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }; offset += 4
            guard length > 0, Int(length) <= data.count - offset else { throw ServiceError("Invalid encoded NAL payload.") }
            result.append(Data(data[offset..<offset + Int(length)])); offset += Int(length)
        }
        return result
    }
    static func expirationDate(_ name: String) -> Date? {
        let stem: String
        if name.hasSuffix(".mp4.recording") { stem = String(name.dropLast(14)) }
        else if name.hasSuffix(".mp4.partial") { stem = String(name.dropLast(12)) } // Legacy unfinished files.
        else if name.hasSuffix(".mp4") { stem = String(name.dropLast(4)) }
        else { return nil }
        let fields = stem.components(separatedBy: "_")
        guard fields.count == 3, UUID(uuidString: fields[0]) != nil, UUID(uuidString: fields[2]) != nil,
              let milliseconds = Int64(fields[1]), milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }
    private func expire() throws {
        try LocalRecordingLayout.verify(path: path, fd: directoryFD, owner: configuration.ownerUID)
        let cutoff = Date().addingTimeInterval(-Double(retentionSeconds))
        for leaf in try FileManager.default.contentsOfDirectory(atPath: path) {
            var info = stat()
            guard fstatat(directoryFD, leaf, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { continue }; throw ServiceError.posix("Inspect retained recording directory")
            }
            guard info.st_mode & S_IFMT == S_IFDIR else { continue }
            let child = openat(directoryFD, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw ServiceError.posix("Open retained recording directory") }
            let directory = LocalRecordingLayout.Directory(path: path + "/" + leaf, fd: child)
            let legacy = leaf == "hbnvr-" + configuration.id
            let identity = try LocalRecordingLayout.identity(in: child)
            guard legacy || identity?.storeID == configuration.id else { continue }
            try StoreDirectory.validate(child, owner: configuration.ownerUID, daemon: geteuid())
            let index = try identity.flatMap { try manifest(for: directory, identity: $0, create: false) }
            try expire(in: child, path: directory.path, legacy: legacy, cutoff: cutoff, manifest: index)
            withExtendedLifetime(directory) {}
        }
    }
    private func expire(in fd: Int32, path: String, legacy: Bool, cutoff: Date, manifest: LocalRecordingManifest?) throws {
        var active = Set<String>()
        // Compare pinned filesystem identity, not spelling: APFS may resolve a
        // case-only camera rename to an existing folder with different casing.
        for track in cameras.values {
            if let writer = track.writer, let directory = track.directory,
               try LocalRecordingLayout.sameDirectory(fd, directory.fd) {
                active.insert(writer.temporaryName)
            }
        }
        for name in try FileManager.default.contentsOfDirectory(atPath: path) {
            guard !active.contains(name), legacy ? Self.expirationDate(name) != nil : LocalRecordingLayout.isShard(name) else { continue }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { continue }; throw ServiceError.posix("Inspect retained recording")
            }
            guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_uid == geteuid() else { continue }
            // Keep readable start-time filenames stable on commit. Filesystem times
            // avoid local-time/DST ambiguity and preserve completion-based retention.
            let timestamp = name.hasSuffix(".recording") ? info.st_birthtimespec : info.st_mtimespec
            let date = legacy ? Self.expirationDate(name)! : Date(timeIntervalSince1970: Double(timestamp.tv_sec) + Double(timestamp.tv_nsec) / 1e9)
            guard date < cutoff else { continue }
            guard unlinkat(fd, name, 0) == 0 else { throw ServiceError.posix("Expire retained recording") }
            try manifest?.remove(filename: name)
        }
    }
}

final class MP4Shard {
    // Only retains/releases the writer across its completion callback; no cross-queue mutation.
    private struct WriterLifetime: @unchecked Sendable { let writer: AVAssetWriter }
    let temporaryName: String
    let finalName: String
    private let directory: LocalRecordingLayout.Directory
    private let directoryFD: Int32
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let format: CMFormatDescription
    private let clock: Int32
    private var last: UInt32
    private var ticks: Int64 = 0
    private var samples = 0
    private var lastDuration: Int64 = 6000
    private var syncFD: Int32 = -1
    private var lastSync: TimeInterval = 0
    private var finalization: DispatchGroup?
    var endTicks: Int64 { samples == 0 ? 0 : ticks + lastDuration }
    var sampleCount: Int64 { Int64(samples) }
    init(directory: LocalRecordingLayout.Directory, codec: String, sets: [Data], clock: UInt32, firstTimestamp: UInt32, capturedAt: Date = Date(), timing: ShardTimingMetadata? = nil) throws {
        guard clock > 0, clock <= Int32.max else { throw ServiceError("Unsupported video clock rate.") }
        self.clock = Int32(clock); last = firstTimestamp; directoryFD = directory.fd; self.directory = directory
        lastDuration = Int64(clock) / 15
        format = try Self.format(codec: codec, sets: sets)
        finalName = try LocalRecordingLayout.availableStem(in: directory.fd, at: capturedAt) + ".mp4"
        temporaryName = finalName + ".recording"
        writer = try AVAssetWriter(outputURL: URL(fileURLWithPath: directory.path + "/" + temporaryName), fileType: .mp4)
        writer.metadata = try timing?.assetMetadata() ?? []
        // Stream into a visible file, with recoverable metadata throughout the shard.
        // This is independent of shard duration; never retain a whole shard in RAM.
        writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)
        writer.initialMovieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        writer.shouldOptimizeForNetworkUse = false
        input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw ServiceError("Camera codec is not supported by the MP4 writer.") }
        writer.add(input)
        guard writer.startWriting() else { throw ServiceError("Could not start MP4 recording; check free space and permissions.") }
        writer.startSession(atSourceTime: .zero)
    }
    deinit {
        // cancelWriting deletes its output. Even on an error/timeout, leave the
        // visible recording intact and let an already-started finalization finish.
        if writer.status == .writing, finalization == nil { _ = beginFinalization() }
        if syncFD >= 0 { close(syncFD) }
    }
    static func format(codec: String, sets: [Data]) throws -> CMFormatDescription {
        let buffers = sets.map { data -> UnsafeMutablePointer<UInt8> in
            let memory = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
            data.copyBytes(to: memory, count: data.count); return memory
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers = buffers.map { UnsafePointer($0) }, sizes = sets.map(\.count)
        var format: CMFormatDescription?
        let result = codec == "H264"
            ? CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers, parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            : CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers, parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
        guard result == noErr, let format else { throw ServiceError("Invalid camera codec initialization (\(result)).") }
        return format
    }
    func elapsed(_ timestamp: UInt32) -> Double { Double(ticks + Int64(Int32(bitPattern: timestamp &- last))) / Double(clock) }
    func append(_ frame: EncodedVideoFrame) throws {
        let delta = Int64(Int32(bitPattern: frame.timestamp &- last))
        guard samples == 0 || delta > 0 else { throw ServiceError("This stream reorders presentation timestamps; recording requires a no-B-frame camera profile in this increment.") }
        if samples > 0 { ticks += delta; lastDuration = delta }; last = frame.timestamp
        try MP4WriterWait.untilReady(
            ready: { self.input.isReadyForMoreMediaData },
            failure: { self.writer.status == .writing ? nil : self.writerFailure("accept video") },
            timeoutMessage: "Local MP4 writer remained backpressured for 30 seconds; reception continues. The bounded store queue may contain unrecorded video. Check status and retry this store.")
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: frame.payload.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: frame.payload.count, flags: 0, blockBufferOut: &block) == noErr, let block else { throw ServiceError("Could not allocate encoded sample.") }
        let copied = frame.payload.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: $0.count) }
        var timing = CMSampleTimingInfo(duration: CMTime(value: lastDuration, timescale: clock), presentationTimeStamp: CMTime(value: ticks, timescale: clock), decodeTimeStamp: .invalid)
        var size = frame.payload.count, sample: CMSampleBuffer?
        guard copied == noErr, CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { throw ServiceError("Could not create encoded sample.") }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(), Unmanaged.passUnretained(frame.keyFrame ? kCFBooleanFalse : kCFBooleanTrue).toOpaque())
        }
        guard input.append(sample) else { throw writerFailure("append video") }
        samples += 1
        try checkpoint()
    }
    private func checkpoint() throws {
        let now = ProcessInfo.processInfo.systemUptime
        if syncFD < 0 {
            syncFD = openat(directoryFD, temporaryName, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            if syncFD < 0, errno == ENOENT { return } // AVFoundation may create asynchronously.
            guard syncFD >= 0 else { throw ServiceError.posix("Open in-progress recording") }
            var info = stat()
            guard fstat(syncFD, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == geteuid(), info.st_nlink == 1,
                  fchmod(syncFD, 0o600) == 0 else { throw ServiceError("Unsafe in-progress recording file.") }
            guard fsync(directoryFD) == 0 else { throw ServiceError.posix("Persist recording directory entry") }
        }
        guard now - lastSync >= 5 else { return }
        // Batch flushes on this store's worker, never on reception or every frame.
        // fsync cannot flush AVFoundation buffers or promise hardware power-loss safety.
        guard fsync(syncFD) == 0 else { throw ServiceError.posix("Flush in-progress recording") }
        lastSync = now
    }
    private func beginFinalization() -> DispatchGroup {
        if let finalization { return finalization }
        let done = DispatchGroup(); done.enter(); finalization = done
        input.markAsFinished()
        // Keep the writer alive if the caller's bounded wait expires. Never cancel
        // it or publish success in that case; the file retains its recording suffix.
        let pendingWriter = WriterLifetime(writer: writer)
        writer.finishWriting { [pendingWriter] in
            withExtendedLifetime(pendingWriter) { done.leave() }
        }
        return done
    }
    func finish() throws {
        let done = beginFinalization()
        try MP4WriterWait.untilReady(
            ready: { done.wait(timeout: .now()) == .success },
            failure: { [.failed, .cancelled].contains(self.writer.status) ? self.writerFailure("finalize") : nil },
            timeoutMessage: "MP4 finalization timed out after 30 seconds. The .mp4.recording file was left for recovery; it may still be finishing.")
        guard writer.status == .completed else { throw writerFailure("finalize") }
        let fd = openat(directoryFD, temporaryName, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ServiceError.posix("Open completed recording") }
        defer { close(fd) }
        // Inherited requester/daemon ACLs are retained; no group/other POSIX access.
        guard fchmod(fd, 0o600) == 0, futimens(fd, nil) == 0, fsync(fd) == 0 else { throw ServiceError.posix("Secure completed recording") }
        guard renameatx_np(directoryFD, temporaryName, directoryFD, finalName, UInt32(RENAME_EXCL)) == 0 else { throw ServiceError.posix("Publish completed recording") }
        guard fsync(directoryFD) == 0 else { throw ServiceError.posix("Persist completed recording name") }
    }
    private func writerFailure(_ operation: String) -> ServiceError {
        ServiceError("MP4 writer could not \(operation) (state \(writer.status.rawValue); \(MP4WriterWait.errorCodes(writer.error))). The .mp4.recording file was left for recovery.")
    }
}
