import Foundation

final class S3RecordingStore: RecordingDestination, @unchecked Sendable {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var config: RecordingStoreConfiguration
    var configuration: RecordingStoreConfiguration { lock.lock(); defer { lock.unlock() }; return config }
    private var status: RecordingStoreStatus
    private var queuedBytes = 0
    private var shuttingDown = false
    private var receptionBlocked = false
    private var done = DispatchGroup()
    private var shutdownSafe = true
    private var mediaError: String?
    private var timer: DispatchSourceTimer?
    private var pressure: DispatchSourceMemoryPressure?
    private var upload: S3UploadManager!
    private let log: (String) -> Void
    private var tracks: [String: Track] = [:]
    private var mediaConfiguration: RecordingStoreConfiguration
    private final class Track {
        var name = "", codec = ""
        var sets: [Int: Data] = [:]
        var writer: MemoryMP4Shard?
        var config: RecordingStoreConfiguration?
        var failed = false
    }
    init(configuration: RecordingStoreConfiguration, spoolRoot: String, factory: @escaping S3TransportFactory = AWSS3Transport.make,
         volumeReader: @escaping (String) throws -> S3SpoolVolume = S3SpoolVolume.read, log: @escaping (String) -> Void) throws {
        try configuration.s3?.clientEncryption?.validate(requirePassword: true)
        config = configuration; mediaConfiguration = configuration; self.log = log
        queue = DispatchQueue(label: "hbnvr.s3." + configuration.id, qos: .utility)
        status = RecordingStoreStatus(id: configuration.id, name: configuration.name, enabled: configuration.enabled, state: configuration.enabled ? "recording" : "disabled")
        let spool = try S3Spool.open(storeID: configuration.id, defaultRoot: spoolRoot, settings: configuration.s3!.settings,
                                     clientEncrypted: configuration.s3?.clientEncryption?.enabled == true, volumeReader: volumeReader)
        upload = S3UploadManager(configuration: configuration, spool: spool, queue: queue, factory: factory, changed: { [weak self] in self?.publishStatus() })
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(100)); timer.setEventHandler { [weak self] in self?.upload.tick() }; timer.resume(); self.timer = timer
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: queue)
        pressure.setEventHandler { [weak self, weak pressure] in self?.upload.memoryPressure(pressure?.data.contains(.normal) != true) }
        pressure.resume(); self.pressure = pressure
    }
    func update(_ configuration: RecordingStoreConfiguration) throws {
        let previous = self.configuration
        guard configuration.id == previous.id, configuration.ownerUID == previous.ownerUID, configuration.ownerUUID == previous.ownerUUID,
              let next = configuration.s3, let old = previous.s3, next.sameDestination(as: old) else {
            throw ServiceError("Cannot relocate or change ownership of a live S3 store; pending footage retains its original destination.")
        }
        try configuration.validate()
        try configuration.s3?.clientEncryption?.validate(requirePassword: true)
        guard next.settings.spoolDirectory == old.settings.spoolDirectory else {
            throw ServiceError("Changing SpoolDirectory requires a drained spool and an agent restart; no footage was moved.")
        }
        guard !upload.spool.requiresEncryption || next.clientEncryption?.enabled == true else {
            throw ServiceError("Cannot disable client-side encryption while spooling to an ignore-ownership volume. Move the drained spool to a private ownership-enabled directory first.")
        }
        lock.lock(); config = configuration; lock.unlock()
        queue.async { [self] in
            // Apply dispatch controls before finalizing anything: forcing spool
            // must not accidentally upload the short shard caused by this change.
            upload.update(configuration)
            // Finalize using the previous per-track configuration before accepting
            // new options. Frozen work is not reconstructed or relocated.
            if !configuration.differsOnlyInAdvancedSettings(from: previous) { finishTracks() }
            mediaConfiguration = configuration; publishStatus()
        }
    }
    func accept(_ event: RecordingEvent) {
        lock.lock()
        guard !shuttingDown, !receptionBlocked else { lock.unlock(); return }
        if event.bytes > 32 * 1024 * 1024 - queuedBytes {
            receptionBlocked = true; lock.unlock()
            queue.async { [self] in
                upload.memoryPressure(true); finishTracks()
                report(ServiceError("S3 input queue overflowed; new media was dropped while accepted shards were finalized."))
                lock.lock(); receptionBlocked = false; lock.unlock()
            }
            return
        }
        queuedBytes += event.bytes
        lock.unlock()
        queue.async { [self] in
            defer { lock.lock(); queuedBytes -= event.bytes; lock.unlock(); publishStatus() }
            do {
                switch event {
                case .end(let camera): if let track = tracks.removeValue(forKey: camera) { try finish(track, camera: camera) }
                case .media(let camera, let name, let media):
                    if !mediaConfiguration.enabled || upload.suspended { finishTracks(); return }
                    try consume(camera: camera, name: name, media: media)
                }
            } catch {
                report(error)
                if case .media(let camera, _, _) = event, let track = tracks[camera] {
                    track.failed = true
                    do { try finish(track, camera: camera) } catch { report(error) }
                }
            }
        }
    }
    private func consume(camera: String, name: String, media: EncodedMedia) throws {
        guard UUID(uuidString: camera) != nil else { throw ServiceError("Invalid camera identity.") }
        let track = tracks[camera] ?? Track(); tracks[camera] = track
        guard !track.failed else { return }
        if track.name != name || track.codec != media.codec {
            try finish(track, camera: camera)
            if track.codec != media.codec { track.sets.removeAll() }
            track.name = name; track.codec = media.codec
        }
        let nals = try LocalRecordingStore.nals(media.frame.payload), required = media.codec == "H264" ? [7, 8] : [32, 33, 34]
        var changed = false
        for (source, overwrite) in [(media.parameterSets, false), (nals, true)] {
            for nal in source where !nal.isEmpty {
                let type = media.codec == "H264" ? Int(nal[0] & 31) : Int((nal[0] >> 1) & 63)
                if required.contains(type), (overwrite || track.sets[type] == nil), track.sets[type] != nal { changed = true; track.sets[type] = nal }
            }
        }
        if changed { try finish(track, camera: camera) }
        guard required.allSatisfy({ track.sets[$0] != nil }), nals.contains(where: { media.codec == "H264" ? (1...5).contains(Int($0[0] & 31)) : ($0[0] >> 1) & 63 < 32 }) else { return }
        if let writer = track.writer, media.frame.keyFrame, writer.elapsed(media.frame.timestamp) >= Double(try IntervalText.seconds(mediaConfiguration.shardDuration)) { try finish(track, camera: camera) }
        if track.writer == nil {
            guard media.frame.keyFrame, !upload.suspended else { return }
            track.writer = try MemoryMP4Shard(codec: media.codec, sets: required.map { track.sets[$0]! }, clock: media.clockRate, timestamp: media.frame.timestamp)
            track.config = mediaConfiguration
        }
        try track.writer!.append(media.frame)
        lock.lock(); status.recordedFrames &+= 1; lock.unlock()
    }
    private func finish(_ track: Track, camera: String) throws {
        guard let writer = track.writer, let config = track.config else { return }
        track.writer = nil; track.config = nil
        var bytes = try writer.finish()
        let encrypted = config.s3?.clientEncryption?.enabled == true
        if encrypted {
            guard let password = config.s3?.clientEncryption?.password else { throw ServiceError("Encryption password unavailable; refusing plaintext recording.") }
            bytes = try RecordingEncryption.encrypt(bytes, password: password)
        }
        let metadata = S3ShardMetadata.make(store: config, camera: camera, name: track.name, capturedAt: writer.capturedAt, data: bytes, encrypted: encrypted)
        upload.ready(metadata, data: bytes)
        lock.lock(); status.completedShards &+= 1; lock.unlock()
    }
    private func finishTracks() {
        for (camera, track) in tracks { do { try finish(track, camera: camera) } catch { report(error) } }
        tracks.removeAll()
    }
    private func report(_ error: Error) {
        let message = (error as? ServiceError)?.message ?? "S3 recording failed; incomplete video was not uploaded."
        let changed = mediaError != message
        mediaError = message
        lock.lock(); status.lastError = message; if shuttingDown { shutdownSafe = false }; lock.unlock()
        if changed { log("Store \(mediaConfiguration.id): \(message)") }
    }
    private func publishStatus() {
        upload.cameraCount = tracks.values.filter { $0.writer != nil }.count
        var detail = upload.snapshot(assemblingBytes: tracks.values.reduce(0) { $0 + ($1.writer?.residentBytes ?? 0) })
        detail.clientEncrypted = mediaConfiguration.s3?.clientEncryption?.enabled == true
        lock.lock(); defer { lock.unlock() }
        var next = RecordingStoreStatus(id: config.id, name: config.name, enabled: config.enabled,
            state: shuttingDown ? "stopping" : (upload.suspended ? "suspended" : (config.enabled ? (detail.spooling ? "spooling" : "recording") : "disabled")))
        next.activeRecordings = tracks.values.filter { $0.writer != nil }.count
        next.completedShards = status.completedShards; next.recordedFrames = status.recordedFrames
        next.pendingBytes = Int(clamping: detail.residentBytes + detail.assemblingBytes + Int64(queuedBytes))
        next.lastError = upload.lastError ?? mediaError; next.s3 = detail; status = next
    }
    func snapshot() -> RecordingStoreStatus { lock.lock(); defer { lock.unlock() }; return status }
    func removable() -> Bool {
        drainBlocker() == nil
    }
    func drainBlocker() -> String? {
        guard !configuration.enabled else { return "Store is enabled; disable it first." }
        guard flush(timeout: 0.1) else { return "Store is disabled but still finishing work; check status and retry." }
        let current = snapshot()
        guard let detail = current.s3 else { return "Store status is not yet ready; retry shortly." }
        let unreadable = detail.unreadableSpoolCount ?? 0
        guard detail.active == 0, detail.queued == 0, detail.volatileShards == 0, detail.spoolCount == 0,
              unreadable == 0, current.activeRecordings == 0 else {
            return "Store is disabled but has \(current.activeRecordings) open shards, \(detail.active) active uploads, \(detail.queued) queued work items, \(detail.spoolCount) spooled entries, \(unreadable) unreadable entries, and \(detail.volatileShards) RAM-only shards. Retries continue; inspect status for errors. Pending files are never abandoned or migrated."
        }
        return nil
    }
    func flush(timeout: TimeInterval) -> Bool {
        let barrier = DispatchSemaphore(value: 0); queue.async { barrier.signal() }
        return barrier.wait(timeout: .now() + timeout) == .success
    }
    func finish(timeout: TimeInterval) -> Bool {
        lock.lock()
        if !shuttingDown {
            shuttingDown = true; done.enter()
            queue.async { [self] in
                timer?.cancel(); pressure?.cancel(); upload.stopDispatch(); finishTracks(); upload.stopDispatch()
                lock.lock(); shutdownSafe = shutdownSafe && upload.safeToExit; lock.unlock()
                publishStatus(); done.leave()
            }
        }
        lock.unlock()
        guard done.wait(timeout: .now() + timeout) == .success else { return false }
        lock.lock(); defer { lock.unlock() }; return shutdownSafe
    }
}
