import Foundation
import Darwin

/// Discovery is deliberately separate from exact time coverage and recording intent.
struct PlaybackStore: Codable, Equatable {
    struct S3Destination: Codable, Equatable {
        let bucket: String, region: String, prefix: String
        let expectedOwner: String?
        let clientEncryptionFormat: String?
        var playbackManifestVersion: Int? = nil
    }
    let id: String
    let name: String
    let type: String
    let enabled: Bool
    let frameReading: Bool
    var state: String // checking, available, partial, unavailable, unsupported
    var s3: S3Destination? = nil
}
struct PlaybackMembership: Codable, Equatable {
    let storeID: String
    let recordingEnabled: Bool // routing intent, not proof frames have arrived
    let indexedHistory: Bool // index rows exist, not a promise any requested time is readable
}
struct PlaybackCamera: Codable, Equatable {
    let id: String
    let name: String?
    let homebaseDeviceID: String?
    let identityAmbiguous: Bool
    let configured: Bool
    let enabled: Bool
    let recordingStarted: Bool
    let stores: [PlaybackMembership]
}
struct PlaybackContent: Equatable {
    var ready = false // false until this configuration has been inspected
    var stores: [PlaybackStore] = []
    var cameras: [PlaybackCamera] = []
}
struct PlaybackSnapshot: Codable, Equatable {
    let instanceID: String
    let revision: UInt64
    let ready: Bool
    let stores: [PlaybackStore]
    let cameras: [PlaybackCamera]
}

enum PlaybackDiscovery {
    struct HistoricalCamera {
        let id: String
        var metadata: LocalRecordingManifest.CameraMetadata?
        var identityAmbiguous = false
    }
    struct Scan {
        var state: String
        var cameras: [String: HistoricalCamera] = [:]
    }
    /// No sample reads, filename inference, video probing, or manifest writes.
    static func scan(_ config: RecordingStoreConfiguration, work: MediaWork) -> Scan {
        guard config.type == "Local" else { return Scan(state: "unsupported") }
        var result = Scan(state: "unavailable")
        do {
            try work.check()
            let root = try StoreDirectory.openDirectory(config.directory); defer { close(root) }
            try StoreDirectory.validate(root, owner: config.ownerUID, daemon: geteuid())
            let copy = dup(root)
            guard copy >= 0 else { throw ServiceError.posix("Inspect playback root") }
            guard let iterator = fdopendir(copy) else { close(copy); throw ServiceError.posix("Inspect playback root") }
            defer { closedir(iterator) }
            result.state = "available"
            var count = 0
            while true {
                try work.check()
                errno = 0
                guard let entry = readdir(iterator) else {
                    guard errno == 0 else { throw ServiceError.posix("Read playback root") }
                    break
                }
                let leaf = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
                }
                if leaf == "." || leaf == ".." { continue }
                count += 1
                guard count <= MediaLimits.directories else { throw ServiceError("Playback directory limit reached.") }
                do {
                    var info = stat()
                    guard fstatat(root, leaf, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                        if errno == ENOENT { continue }; throw ServiceError.posix("Inspect playback directory")
                    }
                    guard info.st_mode & S_IFMT == S_IFDIR else { continue }
                    let child = openat(root, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw ServiceError.posix("Open playback directory") }
                    let directory = LocalRecordingLayout.Directory(path: config.directory + "/" + leaf, fd: child)
                    guard let identity = try LocalRecordingLayout.identity(in: child) else {
                        // An ordinary unrelated folder is ignorable. A damaged
                        // identity marker is uncertainty, not proof of no history.
                        if fstatat(child, LocalRecordingLayout.markerName, &info, AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT {
                            result.state = "partial"
                        }
                        continue
                    }
                    guard identity.storeID == config.id else { continue }
                    if fstatat(child, LocalRecordingManifest.filename, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                        if errno == ENOENT { continue }; throw ServiceError.posix("Inspect playback manifest")
                    }
                    let manifest = try LocalRecordingManifest(directory: directory, identity: identity, owner: config.ownerUID, readOnly: true)
                    guard try manifest.hasIndexedRecordings() else { continue }
                    merge(HistoricalCamera(id: identity.cameraID, metadata: try manifest.cameraMetadata()), into: &result.cameras)
                } catch { result.state = "partial" }
            }
        } catch {
            if result.state != "unavailable" { result.state = "partial" }
        }
        return result
    }
    static func merge(_ value: HistoricalCamera, into cameras: inout [String: HistoricalCamera]) {
        guard let old = cameras[value.id] else { cameras[value.id] = value; return }
        let conflict = old.identityAmbiguous || value.identityAmbiguous ||
            (old.metadata?.homebaseDeviceID != nil && value.metadata?.homebaseDeviceID != nil &&
             old.metadata?.homebaseDeviceID != value.metadata?.homebaseDeviceID)
        var latest = (value.metadata?.updatedAt ?? -.infinity) > (old.metadata?.updatedAt ?? -.infinity) ? value : old
        latest.identityAmbiguous = conflict; cameras[value.id] = latest
    }
    static func content(stores: [RecordingStoreConfiguration], cameras: [(String, CameraConfiguration)],
                        scans: [String: Scan], ready: Bool) -> PlaybackContent {
        var history: [String: HistoricalCamera] = [:]
        for store in stores.sorted(by: { $0.id < $1.id }) {
            for camera in (scans[store.id]?.cameras ?? [:]).values { merge(camera, into: &history) }
        }
        let configured = Dictionary(uniqueKeysWithValues: cameras)
        let cameraIDs = Set(configured.keys).union(history.keys)
        let summaries = stores.sorted { $0.id < $1.id }.map {
            PlaybackStore(id: $0.id, name: $0.name, type: $0.type, enabled: $0.enabled,
                          frameReading: $0.type == "Local", state: scans[$0.id]?.state ?? ($0.type == "Local" ? "checking" : "unsupported"),
                          s3: $0.type == "S3" ? $0.s3.map { .init(bucket: $0.bucket, region: $0.region, prefix: $0.prefix,
                              expectedOwner: $0.expectedOwner,
                              clientEncryptionFormat: $0.clientEncryption?.enabled == true ? RecordingEncryption.format : nil,
                              playbackManifestVersion: 1) } : nil)
        }
        return PlaybackContent(ready: ready, stores: summaries, cameras: cameraIDs.sorted().map { id in
            let current = configured[id], old = history[id], ambiguous = current == nil && old?.identityAmbiguous == true
            return PlaybackCamera(id: id, name: current?.name ?? old?.metadata?.name,
                homebaseDeviceID: current != nil ? current?.homebaseDeviceID : ambiguous ? nil : old?.metadata?.homebaseDeviceID,
                identityAmbiguous: ambiguous, configured: current != nil, enabled: current?.enabled ?? false,
                recordingStarted: current?.recordingStarted ?? false,
                stores: stores.sorted { $0.id < $1.id }.compactMap { store in
                    let indexed = scans[store.id]?.cameras[id] != nil
                    guard current != nil || indexed else { return nil }
                    return PlaybackMembership(storeID: store.id,
                        recordingEnabled: store.enabled && current?.enabled == true && current?.recordingStarted == true,
                        indexedHistory: indexed)
                })
        })
    }
}

/// Cached, bounded discovery. Disk I/O never runs on the command or recording
/// queues. One coalescing worker, not a new scan per request/subscriber/timer tick.
final class PlaybackCatalog: @unchecked Sendable {
    typealias Scanner = (RecordingStoreConfiguration, MediaWork) -> PlaybackDiscovery.Scan
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "hbnvr.playback.discovery", qos: .utility)
    private let cancellation = Cancellation()
    private let scan: Scanner
    private let instanceID: String
    private var stores: [RecordingStoreConfiguration] = []
    private var cameras: [(String, CameraConfiguration)] = []
    private var scans: [String: PlaybackDiscovery.Scan] = [:]
    private var generation: UInt64 = 0
    private var running = false
    private var stopped = false
    private var timer: DispatchSourceTimer?
    private var revision: UInt64 = 0
    private var content = PlaybackContent()
    private var failure: ServiceError?
    private var subscribers: [UUID: SnapshotSubscriber] = [:]
    init(instanceID: String, scan: @escaping Scanner = PlaybackDiscovery.scan) {
        self.instanceID = instanceID; self.scan = scan
    }
    deinit { stop() }
    func start() {
        lock.lock(); defer { lock.unlock() }
        guard timer == nil, !stopped else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.refresh() }
        self.timer = timer; timer.resume()
    }
    func replace(stores: [RecordingStoreConfiguration], cameras: [(String, CameraConfiguration)]) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        let stores = stores.sorted { $0.id < $1.id }, cameras = cameras.sorted { $0.0 < $1.0 }
        guard stores != self.stores || cameras.map(\.0) != self.cameras.map(\.0) || cameras.map(\.1) != self.cameras.map(\.1) || generation == 0 else { return }
        self.stores = stores; self.cameras = cameras; generation &+= 1
        scans = scans.filter { entry in stores.contains { $0.id == entry.key } }
        // Old history remains explicitly checking until the new scan finishes.
        for key in Array(scans.keys) where scans[key]?.state != "unsupported" { scans[key]?.state = "checking" }
        publish(PlaybackDiscovery.content(stores: stores, cameras: cameras, scans: scans, ready: false))
        schedule()
    }
    func refresh() {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }; schedule()
    }
    private func schedule() { // lock held
        guard !running else { return }
        running = true
        queue.async { [weak self] in self?.inspect() }
    }
    private func inspect() {
        lock.lock()
        if stopped { running = false; lock.unlock(); return }
        let stores = self.stores, cameras = self.cameras, generation = self.generation, previous = scans
        lock.unlock()
        var next: [String: PlaybackDiscovery.Scan] = [:]
        for config in stores {
            if cancellation.isStopped { break }
            let work = MediaWork(cancellation: cancellation, deadline: ProcessInfo.processInfo.systemUptime + 5)
            var result = scan(config, work)
            // A failed inspection is not evidence that known history disappeared.
            if result.state == "unavailable" || result.state == "partial" {
                for camera in (previous[config.id]?.cameras ?? [:]).values {
                    PlaybackDiscovery.merge(camera, into: &result.cameras)
                }
            }
            next[config.id] = result
        }
        lock.lock(); defer { lock.unlock() }
        running = false
        guard !stopped else { return }
        guard generation == self.generation else { schedule(); return }
        scans = next
        publish(PlaybackDiscovery.content(stores: stores, cameras: cameras, scans: scans, ready: true))
    }
    private func snapshotLocked(_ value: PlaybackContent, revision: UInt64) -> PlaybackSnapshot {
        PlaybackSnapshot(instanceID: instanceID, revision: revision, ready: value.ready, stores: value.stores, cameras: value.cameras)
    }
    func snapshot() throws -> PlaybackSnapshot {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw failure }
        return snapshotLocked(content, revision: revision)
    }
    private static func encode(_ snapshot: PlaybackSnapshot) throws -> Data {
        var reply = Reply(protocolVersion: 1, status: nil, error: nil, code: nil); reply.playbackSnapshot = snapshot
        let data = try JSONEncoder().encode(reply)
        guard data.count <= SocketIO.limit else { throw ServiceError(.invalidMessage, "Playback catalog exceeds 64 KiB; discovery is unavailable, not empty.") }
        return data
    }
    private func publish(_ value: PlaybackContent) { // lock held; no I/O
        guard value != content || failure != nil else { return }
        do {
            let data = try Self.encode(snapshotLocked(value, revision: revision + 1))
            revision &+= 1; content = value; failure = nil
            for subscriber in subscribers.values { subscriber.offer(data) }
        } catch {
            let error = ServiceError(.invalidMessage, "Playback catalog exceeds 64 KiB; discovery is unavailable, not empty.")
            failure = error
            if let data = try? JSONEncoder().encode(Reply.failure(error)) {
                for subscriber in subscribers.values { subscriber.offer(data) }
            }
        }
    }
    func subscribe(_ fd: Int32, authorize: @escaping () -> Bool) throws {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, subscribers.count < 8 else { throw ServiceError(.unavailable, "Playback subscription limit reached or agent is stopping.") }
        if let failure { throw failure }
        let id = UUID(), data = try Self.encode(snapshotLocked(content, revision: revision))
        let subscriber = SnapshotSubscriber(fd: fd, initial: data, authorize: authorize) { [weak self] in
            guard let self else { return }; self.lock.lock(); self.subscribers[id] = nil; self.lock.unlock()
        }
        subscribers[id] = subscriber; subscriber.start()
    }
    func stop() {
        lock.lock(); stopped = true; cancellation.stop(); timer?.cancel(); timer = nil
        let values = Array(subscribers.values); subscribers.removeAll(); lock.unlock()
        values.forEach { $0.stop() }
    }
}
