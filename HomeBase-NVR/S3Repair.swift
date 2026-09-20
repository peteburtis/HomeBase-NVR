import Foundation
import Darwin

struct S3RepairDiagnostic: Codable {
    let reason: String
    let candidate: Int
    let shardID: String
    let message: String
    var description: String { "Download diagnostic [\(reason)], candidate \(candidate), shard \(shardID): \(message)" }
}

struct S3RepairStatus: Codable {
    let id: String
    let storeID: String
    var state: String
    var message: String
    var scanned = 0
    var candidates = 0
    var candidateBytes: Int64 = 0
    var downloadedBytes: Int64 = 0
    var alreadyIndexed = 0
    var recovered = 0
    // Cumulative submissions during this repair, not outstanding uploads.
    // Keep the existing Codable field name for IPC compatibility.
    var thumbnailsQueued = 0
    var thumbnailsPresent = 0
    var skipped: [String: Int] = [:]
    // Optional for older agents; bounded to keep every poll within the IPC limit.
    var diagnostics: [S3RepairDiagnostic]? = nil
}
struct S3RepairSink: Sendable {
    var knownKeys: @Sendable () async throws -> Set<String>
    var merge: @Sendable (S3ShardMetadata, Cancellation) async throws -> Bool
    var publish: @Sendable (Cancellation) async throws -> Void
    var indexedShards: @Sendable () async throws -> [String: S3PlaybackShard] = { [:] }
    var thumbnailKeys: @Sendable () async throws -> Set<String> = { [] }
    var thumbnail: @Sendable (S3ObjectMetadata, Data, Cancellation) async throws -> Bool = { _, _, _ in false }
}

/// The IPC thread only starts/polls/cancels jobs. Keys/passwords stay in job RAM,
/// are discarded at completion/cancellation, and never replace recorder secrets.
final class S3RepairJobs: @unchecked Sendable {
    typealias Inspector = @Sendable (Data, S3RepairCandidate, RecordingStoreConfiguration, [String]) async throws -> S3ShardMetadata
    private final class Job {
        let id = UUID().uuidString
        let uid: uid_t
        let identity: UUID
        var config: RecordingStoreConfiguration
        let cameras: Set<String>
        let sink: S3RepairSink
        let dryRun: Bool
        let cancellation = Cancellation()
        var status: S3RepairStatus
        var deadline: Double
        var credentials: S3RepairCredentials?
        var password: String?
        var skipUnreadableEncrypted = false
        var candidates: [S3RepairCandidate] = []
        var keys = Set<String>()
        var known: Set<String>?
        var indexed: [String: S3PlaybackShard] = [:]
        var thumbnailKeys = Set<String>()
        var next: String?
        var tokens = Set<String>()
        var pageCount = 0
        var index = 0
        var scanning = true
        var task: Task<Void, Never>?
        init(config: RecordingStoreConfiguration, cameras: Set<String>, sink: S3RepairSink,
             uid: uid_t, identity: UUID, dryRun: Bool, deadline: Double) {
            self.config = config; self.cameras = cameras; self.sink = sink; self.uid = uid
            self.identity = identity; self.dryRun = dryRun; self.deadline = deadline
            status = .init(id: id, storeID: config.id, state: "scanning", message: "Listing this store's objects; no recordings are downloaded yet.")
            credentials = config.s3?.credentials.map { .init(accessKeyID: $0.accessKeyID, secretAccessKey: $0.secretAccessKey) }
        }
        var active: Bool { !["completed", "cancelled", "failed"].contains(status.state) }
        func clearPrivateState() {
            credentials = nil; password = nil; config = config.summary
            candidates.removeAll(); keys.removeAll(); known = nil; tokens.removeAll(); task = nil
            indexed.removeAll(); thumbnailKeys.removeAll()
        }
    }
    private let lock = NSLock()
    private var jobs: [String: Job] = [:]
    private let factory: S3RepairReaderFactory
    private let inspect: Inspector
    private let now: () -> Double
    private let identity: (uid_t) throws -> UUID
    private let log: @Sendable (String) -> Void
    private var timer: DispatchSourceTimer?
    init(factory: @escaping S3RepairReaderFactory = AWSS3RepairReader.make,
         inspect: @escaping Inspector = { try await S3RepairMedia.inspect($0, candidate: $1, store: $2, passwords: $3) },
         now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
         identity: @escaping (uid_t) throws -> UUID = StoreDirectory.identity,
         log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.factory = factory; self.inspect = inspect; self.now = now; self.identity = identity
        self.log = log
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in self?.locked { self?.expire() } }
        timer.resume(); self.timer = timer
    }
    deinit { timer?.cancel(); for job in jobs.values { job.cancellation.stop(); job.task?.cancel() } }
    @discardableResult private func locked<T>(_ action: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try action()
    }
    private func expire() {
        for (id, job) in jobs where now() >= job.deadline {
            job.cancellation.stop(); job.task?.cancel(); job.clearPrivateState(); jobs[id] = nil
        }
    }
    private func owned(_ id: String, uid: uid_t) throws -> Job {
        expire()
        guard let job = jobs[id], job.uid == uid, try identity(uid) == job.identity else {
            throw ServiceError(.permission, "Repair job expired or belongs to another identity.")
        }
        job.deadline = now() + 900 // Lease renewed only by authenticated client contact.
        return job
    }
    func isBusy(_ storeID: String) -> Bool { locked { expire(); return jobs.values.contains { $0.config.id == storeID && $0.active } } }
    func requireIdle(_ storeID: String) throws {
        guard !isBusy(storeID) else { throw ServiceError("A metadata repair is active for this store. Cancel it before changing or removing the store.") }
    }
    func start(config: RecordingStoreConfiguration, cameras: Set<String>, sink: S3RepairSink, uid: uid_t, dryRun: Bool) throws -> S3RepairStatus {
        try config.validate()
        guard config.type == "S3", !cameras.isEmpty else { throw ServiceError("Repair requires an S3 store and at least one currently configured camera.") }
        let owner = try identity(uid)
        guard uid == 0 || (uid == config.ownerUID && owner == config.ownerUUID) else { throw ServiceError(.permission, "Only the store owner or root may repair its metadata.") }
        return try locked {
            expire()
            guard jobs.count < 8, !jobs.values.contains(where: { $0.config.id == config.id && $0.active }) else { throw ServiceError("A repair is already active for this store, or the repair job limit was reached.") }
            let job = Job(config: config, cameras: cameras, sink: sink, uid: uid, identity: owner, dryRun: dryRun, deadline: now() + 900)
            jobs[job.id] = job; launch(job); return job.status
        }
    }
    func poll(_ id: String, uid: uid_t) throws -> S3RepairStatus { try locked { try owned(id, uid: uid).status } }
    func cancel(_ id: String, uid: uid_t) throws -> S3RepairStatus {
        try locked {
            let job = try owned(id, uid: uid)
            job.cancellation.stop(); job.task?.cancel()
            job.status.state = "cancelled"; job.status.message = "Cancelled. Already merged metadata is preserved; no video objects were changed."
            job.clearPrivateState(); return job.status
        }
    }
    func resume(_ id: String, uid: uid_t, credentials: S3RepairCredentials?, password: String?, skipEncrypted: Bool, begin: Bool) throws -> S3RepairStatus {
        try credentials?.validate()
        if let password { try RecordingEncryption.validatePassword(password) }
        return try locked {
            let job = try owned(id, uid: uid)
            switch job.status.state {
            case "credentials":
                guard let credentials, password == nil, !skipEncrypted, !begin else { throw ServiceError("Temporary repair credentials are required.") }
                job.credentials = credentials
            case "password":
                guard credentials == nil, !begin, (password != nil) != skipEncrypted else { throw ServiceError("Supply an encryption password or explicitly skip unreadable encrypted recordings.") }
                job.password = password; job.skipUnreadableEncrypted = skipEncrypted
            case "ready":
                guard begin, credentials == nil, password == nil, !skipEncrypted, !job.dryRun else { throw ServiceError("Confirm the repair preview before downloading recordings.") }
                job.scanning = false
            default: throw ServiceError("Repair is not waiting for input.")
            }
            launch(job); return job.status
        }
    }
    /// Caller holds lock. Only immutable snapshots cross into the worker task.
    private func launch(_ job: Job) {
        guard let credentials = job.credentials else { job.status.state = "credentials"; job.status.message = S3RepairFailure.credentials.localizedDescription; return }
        job.status.state = job.scanning ? "scanning" : "repairing"
        job.status.message = job.scanning ? "Listing this store's objects; no recordings are downloaded yet." : "Reading recordings and merging recoverable metadata."
        let config = job.config, passwords = [job.password, job.config.s3?.clientEncryption?.password].compactMap { $0 }
        job.task = Task { [weak self, job, factory] in
            guard let self else { return }
            do {
                let reader = try await factory(config.s3!, credentials)
                if self.locked({ job.scanning }) { try await self.scan(job, reader: reader) }
                else { try await self.repair(job, config: config, passwords: passwords, reader: reader) }
            } catch {
                self.locked {
                    guard !job.cancellation.isStopped, job.active else { return }
                    if error is CancellationError { job.status.state = "cancelled"; job.status.message = "Repair cancelled; merged metadata was preserved."; job.clearPrivateState() }
                    else if case S3RepairFailure.credentials = error { job.status.state = "credentials"; job.status.message = S3RepairFailure.credentials.localizedDescription; job.task = nil }
                    else if case S3RepairFailure.password = error { job.status.state = "password"; job.status.message = S3RepairFailure.password.localizedDescription; job.task = nil }
                    else {
                        job.status.state = "failed"
                        job.status.message = (error as? S3RepairReadFailure)?.localizedDescription ?? (error as? S3RepairFailure)?.localizedDescription ?? (error as? ServiceError)?.message ?? "Repair failed; already merged metadata and all video objects were preserved."
                        job.clearPrivateState()
                    }
                }
            }
        }
    }
    private func check(_ job: Job) throws {
        try Task.checkCancellation()
        guard !job.cancellation.isStopped else { throw CancellationError() }
    }
    private func scan(_ job: Job, reader: any S3RepairReading) async throws {
        let known = try await job.sink.knownKeys(); try check(job)
        let indexed = try await job.sink.indexedShards(), thumbnails = try await job.sink.thumbnailKeys(); try check(job)
        locked { job.known = known; job.indexed = indexed; job.thumbnailKeys.formUnion(thumbnails) }
        while true {
            try check(job)
            let page = try await reader.list(after: locked { job.next }); try check(job)
            try locked {
                guard page.objects.count <= 1000, job.pageCount < 10_000 else { throw ServiceError("Repair listing limit reached. No repair was started.") }
                job.pageCount += 1
                for object in page.objects {
                    job.status.scanned += 1
                    if S3Thumbnail.listed(object.key, prefix: job.config.s3!.prefix, cameras: job.cameras) {
                        guard job.thumbnailKeys.count < 100_000 else { throw ServiceError("Thumbnail listing limit reached; no repair was started.") }
                        if job.thumbnailKeys.insert(object.key).inserted { job.status.thumbnailsPresent += 1 }
                        continue
                    }
                    guard let candidate = S3RepairCandidate.parse(object, prefix: job.config.s3!.prefix, cameras: job.cameras) else {
                        job.status.skipped[S3RepairSkip.unexpected.rawValue, default: 0] += 1; continue
                    }
                    if known.contains(object.key), indexed[object.key] == nil { job.status.alreadyIndexed += 1; continue }
                    if object.size > AWSS3RepairReader.maximumObjectBytes { job.status.skipped[S3RepairSkip.oversized.rawValue, default: 0] += 1; continue }
                    guard job.keys.insert(object.key).inserted else { continue }
                    guard job.candidates.count < 100_000 else { throw ServiceError("Repair candidate limit reached. No repair was started.") }
                    job.candidates.append(candidate); job.status.candidates += 1; job.status.candidateBytes += object.size
                }
                if let next = page.next {
                    guard !next.isEmpty, next.utf8.count <= 16384, job.tokens.insert(next).inserted else { throw S3RepairFailure.invalidResponse }
                }
                job.next = page.next
            }
            if page.next == nil { break }
        }
        locked {
            guard !job.cancellation.isStopped else { return }
            // Wait for ALL listing pages: images sort separately from video.
            job.candidates = job.candidates.filter { candidate in
                guard let shard = indexed[candidate.object.key] else { return true }
                let missing = S3Thumbnail.slots(start: shard.start, end: shard.end).contains {
                    !hasThumbnail(job, camera: candidate.cameraID, slot: $0)
                }
                if !missing { job.status.alreadyIndexed += 1 }
                return missing
            }
            job.status.candidates = job.candidates.count
            job.status.candidateBytes = job.candidates.reduce(0) { $0 + $1.object.size }
            job.status.state = job.dryRun ? "completed" : "ready"
            job.status.message = "Preview complete. Candidates may still be skipped if they lack valid embedded timing. No recordings have been downloaded or metadata repaired."
            job.task = nil
            if job.dryRun { job.clearPrivateState() }
        }
    }
    private func repair(_ job: Job, config: RecordingStoreConfiguration, passwords: [String], reader: any S3RepairReading) async throws {
        while let candidate = locked({ job.index < job.candidates.count ? job.candidates[job.index] : nil }) {
            try check(job)
            do {
                let bytes = try await reader.read(candidate.object); try check(job)
                locked { job.status.downloadedBytes += Int64(bytes.count) }
                let metadata: S3ShardMetadata
                do { metadata = try await inspect(bytes, candidate, config, passwords) }
                catch {
                    try check(job)
                    if error is S3RepairSkip || error is S3RepairFailure || error is S3RepairReadFailure || error is CancellationError { throw error }
                    throw S3RepairSkip.invalidMedia
                }
                try check(job)
                let added = try await job.sink.merge(metadata, job.cancellation); try check(job)
                locked { if added { job.status.recovered += 1 } else { job.status.alreadyIndexed += 1 } }
                let start = metadata.timing!.time.canonicalUTC
                let end = start + Double(metadata.endTicks!) / Double(metadata.timing!.timescale)
                let missing = locked { S3Thumbnail.slots(start: start, end: end).filter { !hasThumbnail(job, camera: metadata.cameraID, slot: $0) } }
                if !missing.isEmpty {
                    try await S3RepairMedia.thumbnails(bytes, candidate: candidate, store: config, passwords: passwords,
                        metadata: metadata, slots: missing, cancellation: job.cancellation) { object, data in
                        try self.check(job)
                        let accepted = try await job.sink.thumbnail(object, data, job.cancellation)
                        try self.check(job)
                        self.locked {
                            job.thumbnailKeys.insert(object.key)
                            if accepted { job.status.thumbnailsQueued += 1 }
                        }
                    }
                }
            } catch {
                try check(job)
                if let failure = error as? S3RepairReadFailure {
                    let diagnostic: S3RepairDiagnostic? = locked {
                        let reason = failure.reason.rawValue
                        job.status.skipped[reason, default: 0] += 1
                        var examples = job.status.diagnostics ?? []
                        guard examples.count < 15, examples.filter({ $0.reason == reason }).count < 3 else { return nil }
                        let example = S3RepairDiagnostic(reason: reason, candidate: job.index + 1,
                            shardID: candidate.shardID, message: failure.detail)
                        examples.append(example); job.status.diagnostics = examples
                        return example
                    }
                    if let diagnostic { log("Repair \(job.id): \(diagnostic.description)") }
                }
                else if let reason = error as? S3RepairSkip { locked { job.status.skipped[reason.rawValue, default: 0] += 1 } }
                else if case S3RepairFailure.changed = error { locked { job.status.skipped[S3RepairSkip.changed.rawValue, default: 0] += 1 } }
                else if case S3RepairFailure.tooLarge = error { locked { job.status.skipped[S3RepairSkip.oversized.rawValue, default: 0] += 1 } }
                else if case S3RepairFailure.password = error, locked({ job.skipUnreadableEncrypted }) { locked { job.status.skipped["unreadableEncrypted", default: 0] += 1 } }
                else { throw error }
            }
            locked { job.index += 1 }
        }
        try check(job); try await job.sink.publish(job.cancellation); try check(job)
        let summary: String = locked {
            guard !job.cancellation.isStopped else { return "Repair \(job.id) cancelled." }
            job.status.state = "completed"
            if job.status.recovered == 0 && job.status.thumbnailsQueued == 0 {
                job.status.message = "Repair scan finished: no new metadata was recovered and no thumbnails were queued. Existing journal manifests were requested for republication. All video and unexpected objects were left untouched."
            } else {
                job.status.message = "Repair metadata merged durably; manifests and thumbnails are queued with the saved writer credentials. Check hbnvr status for delivery. All video and unexpected objects were left untouched."
            }
            job.clearPrivateState()
            let reasons = job.status.skipped.keys.sorted().map { "\($0)=\(job.status.skipped[$0]!)" }.joined(separator: ", ")
            return "Repair \(job.id) finished: \(job.status.recovered) recovered; \(job.status.thumbnailsQueued) thumbnails submitted for upload; skipped: \(reasons.isEmpty ? "none" : reasons)."
        }
        log(summary)
    }
    private func hasThumbnail(_ job: Job, camera: String, slot: Double) -> Bool {
        [false, true].contains { job.thumbnailKeys.contains(S3Thumbnail.key(prefix: job.config.s3!.prefix, camera: camera, slot: slot, encrypted: $0)) }
    }
    func stop() {
        locked { for job in jobs.values { job.cancellation.stop(); job.task?.cancel(); job.clearPrivateState() }; jobs.removeAll() }
    }
}
