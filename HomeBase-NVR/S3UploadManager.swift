import Foundation

/// All mutable scheduling/accounting runs on the destination's serial queue.
/// Transport tasks never own policy and report exactly one tokened completion.
final class S3UploadManager: @unchecked Sendable {
    enum Lane { case live, replay, retry }
    final class Work {
        let metadata: S3ShardMetadata
        var payload: S3Payload
        var lane: Lane
        let readyAt: Double
        var token: UUID?
        var task: Task<Void, Never>?
        var probe = false
        var activeRAM: Int64 = 0
        var lastAttempt: Double?
        var lastProbeAttempt: Double?
        var uploadError: String?
        var persistenceError: String?
        var confirmedDelivery = false
        var cleanupAt = 0.0
        init(_ metadata: S3ShardMetadata, payload: S3Payload, lane: Lane, now: Double) {
            self.metadata = metadata; self.payload = payload; self.lane = lane; readyAt = now
        }
    }
    var configuration: RecordingStoreConfiguration
    let spool: S3Spool
    private let queue: DispatchQueue
    private let factory: S3TransportFactory
    private let now: () -> Double
    private let date: () -> Date
    private let jitter: () -> Double
    private let changed: () -> Void
    private var work: [String: Work] = [:]
    private(set) var policy: S3UploadPolicy
    private(set) var suspended = false
    var lastError: String? {
        if let storageError { return storageError }
        if let scanError { return scanError }
        for item in work.values.sorted(by: { $0.metadata.capturedAt < $1.metadata.capturedAt }) {
            if let error = item.persistenceError ?? item.uploadError { return "Shard \(item.metadata.id): \(error)" }
        }
        if let leaf = spool.damaged.first { return "Spool entry \(leaf): \(spool.readErrors[leaf]!). Retained; will retry reading." }
        return nil
    }
    private var storageError: String?
    private var scanError: String?
    private var volumeStatus: S3SpoolVolume?
    private(set) var confirmed: UInt64 = 0
    private var lifecycleTask: Task<Void, Never>?
    private var transportTask: Task<any S3Transport, Error>?
    private var lifecycleGeneration = UUID()
    private var lifecycleDue = 0.0
    private var lifecycleWarning: String?
    private var appliedDays: Int?
    private var shutdown = false
    private var nextSpoolCheck: Double
    var cameraCount = 0
    init(configuration: RecordingStoreConfiguration, spool: S3Spool, queue: DispatchQueue,
         factory: @escaping S3TransportFactory = AWSS3Transport.make,
         now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }, date: @escaping () -> Date = Date.init,
         jitter: @escaping () -> Double = { Double.random(in: 0...1) }, changed: @escaping () -> Void = {}) {
        self.configuration = configuration; self.spool = spool; self.queue = queue; self.factory = factory
        self.now = now; self.date = date; self.jitter = jitter; self.changed = changed
        policy = S3UploadPolicy(settings: configuration.s3!.settings)
        nextSpoolCheck = now() + configuration.s3!.settings.probeInterval
        volumeStatus = spool.mountedVolume
        for entry in spool.entries.values { work[entry.metadata.id] = Work(entry.metadata, payload: entry.payload, lane: .replay, now: now()) }
    }
    var outstanding: Bool { !work.isEmpty || !spool.damaged.isEmpty }
    var safeToExit: Bool { work.values.allSatisfy { if $0.confirmedDelivery { return true }; if case .file = $0.payload { return true }; return false } }
    func update(_ config: RecordingStoreConfiguration) {
        let previous = configuration
        configuration = config; policy.settings = config.s3!.settings; spool.settings = policy.settings
        if previous.s3?.credentials != config.s3?.credentials || previous.s3?.settings.requestTimeout != config.s3?.settings.requestTimeout { transportTask = nil }
        if previous.retentionPeriod != config.retentionPeriod || previous.s3?.lifecycle != config.s3?.lifecycle || previous.s3?.credentials != config.s3?.credentials {
            lifecycleTask?.cancel(); lifecycleTask = nil; lifecycleGeneration = UUID(); lifecycleDue = 0; appliedDays = nil
        }
        // A credential repair is allowed while backlog exists. Try a controlled
        // probe promptly; don't fan out all previously failing work.
        if policy.spooling { policy.nextProbe = now() }
        tick()
    }
    func ready(_ metadata: S3ShardMetadata, data: Data) {
        guard work[metadata.id] == nil else { return }
        work[metadata.id] = Work(metadata, payload: .memory(data), lane: .live, now: now())
        tick()
    }
    func memoryPressure(_ warning: Bool) { policy.memoryPressure = warning; tick() }
    func tick() {
        let clock = now()
        let storageAvailable: Bool
        do {
            volumeStatus = try spool.validateLocation(); storageAvailable = true
            storageError = nil
        }
        catch {
            storageAvailable = false; suspended = true; volumeStatus = nil
            storageError = (error as? ServiceError)?.message ?? "Spool volume is unavailable; no fallback disk will be used."
        }
        // Recheck unreadable/invalid entries, including files repaired in place
        // or atomically replaced. Healthy known entries are not rehashed here.
        if storageAvailable, !shutdown, clock >= nextSpoolCheck {
            nextSpoolCheck = clock + policy.settings.probeInterval
            let excluded = Set(work.values.filter {
                if $0.token != nil || $0.confirmedDelivery { return true }
                if case .memory = $0.payload { return true }; return false
            }.map { $0.metadata.id })
            do {
                try spool.scan(retryOnly: true, excluding: excluded)
                scanError = nil
                for entry in spool.entries.values where !excluded.contains(entry.metadata.id) && spool.readErrors[entry.metadata.id] == nil {
                    if let item = work[entry.metadata.id] {
                        if item.metadata == entry.metadata { item.payload = entry.payload }
                    } else { work[entry.metadata.id] = Work(entry.metadata, payload: entry.payload, lane: .replay, now: clock) }
                }
            } catch { scanError = (error as? ServiceError)?.message ?? "Could not rescan spool; files retained for retry." }
        }
        // Delivery is already confirmed: a local cleanup failure retries cleanup,
        // not the network upload. A manual upload hold does not block this work.
        if storageAvailable, !shutdown {
            for item in work.values.filter({ $0.confirmedDelivery && clock >= $0.cleanupAt }) { cleanup(item) }
        }
        func eligible(_ item: Work) -> Bool {
            guard item.token == nil, !item.confirmedDelivery else { return false }
            if case .file = item.payload { return storageAvailable && spool.readErrors[item.metadata.id] == nil }
            return true
        }
        let resident = work.values.filter { if case .memory = $0.payload { return true }; return $0.activeRAM > 0 }
        let oldest = work.values.filter {
            guard $0.token == nil, !$0.confirmedDelivery else { return false }
            if case .memory = $0.payload { return true }; return false
        }.map { clock - $0.readyAt }.max() ?? 0
        let wasSpooling = policy.spooling
        policy.pressure(count: resident.count, cameras: cameraCount, oldestAge: oldest, duration: Double((try? IntervalText.seconds(configuration.shardDuration)) ?? 60))
        if !wasSpooling && policy.spooling { policy.nextProbe = clock + policy.settings.probeInterval }
        if policy.spooling || suspended || shutdown { persistRAM() }
        if suspended, spool.hasCapacity(), work.values.allSatisfy({ if case .memory = $0.payload { return false }; return true }) { suspended = false }
        // Manual spooling is a persistent dispatch hold, including probes and
        // replay. In-flight requests may finish; accepted bytes remain owned.
        guard !shutdown, !policy.settings.forceSpooling else { changed(); return }
        reconcileIfDue()
        let active = work.values.filter { $0.token != nil }
        if policy.spooling {
            if clock >= policy.nextProbe, !active.contains(where: { $0.probe }), active.count < policy.settings.concurrentUploads {
                let candidates = work.values.filter(eligible).sorted {
                    let a = $0.lastProbeAttempt ?? -.infinity, b = $1.lastProbeAttempt ?? -.infinity
                    if a != b { return a < b }
                    return ($0.metadata.capturedAt, $0.metadata.id) < ($1.metadata.capturedAt, $1.metadata.id)
                }
                // Prefer durable work; retained RAM is only a deadlock escape when
                // persistence failed and there is no eligible durable entry.
                let selected = candidates.first(where: { if case .file = $0.payload { return true }; return false }) ?? candidates.first
                policy.nextProbe = clock + policy.settings.probeInterval
                if let selected { dispatch(selected, probe: true) }
            }
        } else {
            while work.values.filter({ $0.token != nil }).count < policy.settings.concurrentUploads {
                let queued = work.values.filter(eligible).sorted { $0.metadata.capturedAt < $1.metadata.capturedAt }
                if let live = queued.first(where: { $0.lane == .live }) { dispatch(live); continue }
                let running = work.values.filter { $0.token != nil }
                guard running.filter({ $0.lane != .live }).count < policy.settings.concurrentUploads - policy.settings.reservedLiveSlots else { break }
                if clock >= policy.retryAt, !running.contains(where: { $0.lane == .retry }), let retry = queued.filter({ $0.lane == .retry }).sorted(by: retryOrder).first { dispatch(retry); continue }
                if let replay = queued.first(where: { $0.lane == .replay }) { dispatch(replay); continue }
                break
            }
        }
        changed()
    }
    private func retryOrder(_ lhs: Work, _ rhs: Work) -> Bool {
        let a = lhs.lastAttempt ?? -.infinity, b = rhs.lastAttempt ?? -.infinity
        if a != b { return a < b }
        return (lhs.metadata.capturedAt, lhs.metadata.id) < (rhs.metadata.capturedAt, rhs.metadata.id)
    }
    private func dispatch(_ item: Work, probe: Bool = false) {
        guard !shutdown, item.token == nil else { return }
        let token = UUID(), metadata = item.metadata, payload = item.payload, config = configuration.s3!
        if transportTask == nil { transportTask = Task { [factory] in try await factory(config) } }
        let provider = transportTask!
        item.token = token; item.probe = probe
        item.lastAttempt = now()
        // Start recovery with the oldest eligible shard, but rotate failed
        // probes so one persistently rejected/read-failing entry cannot starve others.
        if probe { item.lastProbeAttempt = item.lastAttempt }
        if case .memory(let data) = payload { item.activeRAM = Int64(data.count) }
        item.task = Task { [weak self, queue] in
            let result: Result<Void, Error>
            do { let transport = try await provider.value; try Task.checkCancellation(); try await transport.upload(metadata, payload: payload); result = .success(()) }
            catch { result = .failure(error) }
            queue.async { [weak self] in self?.completed(metadata.id, token: token, result: result) }
        }
    }
    func completed(_ id: String, token: UUID, result: Result<Void, Error>) {
        guard let item = work[id], item.token == token else { return } // Late/duplicate callbacks are inert.
        item.token = nil; item.task = nil; item.activeRAM = 0
        guard !shutdown else { changed(); return } // Retain shutdown publications for safe replay.
        switch result {
        case .success:
            policy.succeeded(probe: item.probe); confirmed &+= 1
            item.confirmedDelivery = true; item.uploadError = nil; cleanup(item)
        case .failure(let error):
            if case .file = item.payload, (try? spool.validateLocation()) == nil {
                // A detached drive is not a permanently rejected S3 object. Keep
                // it replayable when the same volume/path becomes available again.
                item.lane = .retry; item.probe = false; suspended = true; tick(); return
            }
            let failure = AWSS3Transport.classify(error)
            if failure.kind == .destination { transportTask = nil }
            item.uploadError = failure.message; item.lane = .retry
            if failure.kind == .localRead, case .file = item.payload { spool.noteReadFailure(id, failure.message) }
            policy.failed(failure.kind, now: now(), jitter: jitter())
        }
        item.probe = false
        tick()
    }
    private func cleanup(_ item: Work) {
        do {
            // A previously failed publication may have left staging while the
            // retained RAM upload succeeded. Finish our own publication before
            // cleaning it, rather than abandoning those files after confirmation.
            if case .memory(let data) = item.payload, spool.readErrors[item.metadata.id + ".staging"] != nil {
                item.payload = try spool.publish(item.metadata, data: data).payload
                item.persistenceError = nil
            }
            try spool.delivered(item.metadata.id); work[item.metadata.id] = nil
        }
        catch {
            item.lane = .retry; item.cleanupAt = now() + policy.settings.probeInterval
            item.uploadError = "S3 confirmed delivery; local cleanup will retry: " + ((error as? ServiceError)?.message ?? "filesystem failure")
            spool.noteReadFailure(item.metadata.id, item.uploadError!)
        }
    }
    private func persist(_ item: Work) {
        guard case .memory(let data) = item.payload else { return }
        do {
            let entry = try spool.publish(item.metadata, data: data)
            item.payload = entry.payload
            item.persistenceError = nil
            if item.lane == .live { item.lane = .replay }
        } catch {
            suspended = true
            item.persistenceError = (error as? ServiceError)?.message ?? "Could not durably spool completed video; RAM-only work remains volatile."
        }
    }
    private func persistRAM() {
        for item in work.values.sorted(by: { $0.metadata.capturedAt < $1.metadata.capturedAt }) { persist(item) }
    }
    func stopDispatch() {
        shutdown = true; policy.reasons.insert("shutdown")
        lifecycleTask?.cancel(); lifecycleTask = nil
        transportTask?.cancel()
        for item in work.values { item.task?.cancel() }
        persistRAM(); changed()
    }
    private func reconcileIfDue() {
        guard configuration.s3?.lifecycle == "Managed" else { lifecycleWarning = nil; appliedDays = nil; return }
        guard lifecycleTask == nil, now() >= lifecycleDue else { return }
        lifecycleDue = now() + 3600
        let config = configuration, generation = lifecycleGeneration
        lifecycleTask = Task { [weak self, factory, queue] in
            var warning: String?
            do { let transport = try await factory(config.s3!); try await S3LifecycleCoordinator.shared.reconcile(config, transport: transport) }
            catch { warning = "Retention unverified: " + AWSS3Transport.classify(error).message }
            let result = warning
            queue.async { [weak self] in
                guard let self, self.lifecycleGeneration == generation, !self.shutdown else { return }
                self.lifecycleTask = nil; self.lifecycleWarning = result; self.appliedDays = result == nil ? config.retentionDays : nil; self.changed()
            }
        }
    }
    func snapshot(assemblingBytes: Int64) -> S3StoreStatus {
        var result = S3StoreStatus()
        result.spoolDirectory = spool.path
        result.spoolVolume = spool.mountedVolume.mountPoint
        result.spoolVolumeUUID = spool.mountedVolume.uuid
        // Media publishes status for every frame; volume I/O belongs to tick(),
        // not that hot path. These values are refreshed by the one-second timer.
        let volume = volumeStatus
        result.spoolVolumeCapacityBytes = volume?.capacity
        result.spoolVolumeAvailableBytes = volume?.available
        result.spoolLimitBytes = spool.settings.spoolLimitBytes
        result.spoolMinimumFreeBytes = spool.settings.minimumFreeBytes
        result.acceptingRecording = configuration.enabled && !suspended && !shutdown
        result.spooling = policy.spooling; result.reasons = policy.reasons.sorted()
        if policy.settings.forceSpooling { result.reasons.append("manual") }
        if suspended { result.reasons.append("spool-unavailable") }
        result.queued = work.values.filter { $0.token == nil }.count
        result.active = work.values.filter { $0.token != nil }.count
        result.retrying = work.values.filter { $0.lane == .retry }.count
        result.assemblingBytes = assemblingBytes
        result.residentBytes = work.values.reduce(0) { value, item in
            if case .memory(let data) = item.payload { return value + Int64(data.count) }
            return value + item.activeRAM
        }
        result.volatileShards = work.values.filter { if case .memory = $0.payload { return true }; return false }.count
        result.spoolBytes = spool.bytes; result.spoolCount = spool.entries.count
        result.unreadableSpoolCount = spool.readErrors.count
        result.oldestBacklogSeconds = work.values.map { max(0, date().timeIntervalSince($0.metadata.capturedAt)) }.max()
        result.confirmedUploads = confirmed
        if policy.spooling && !shutdown && !policy.settings.forceSpooling { result.nextProbeSeconds = max(0, policy.nextProbe - now()) }
        if (!spool.readErrors.isEmpty || scanError != nil) && !shutdown { result.nextReadRetrySeconds = max(0, nextSpoolCheck - now()) }
        result.desiredRetentionDays = configuration.retentionDays; result.appliedRetentionDays = appliedDays
        result.lifecycleState = configuration.s3?.lifecycle == "External" ? "external/unverified" : (appliedDays == nil ? "unverified" : "applied")
        result.lifecycleWarning = lifecycleWarning
        return result
    }
}
