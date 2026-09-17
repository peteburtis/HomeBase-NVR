import Foundation
import Darwin

struct S3SetupStatus: Codable {
    let id: String
    let state: String
    let message: String
    let storeID: String
}

/// Network work happens off the IPC loop. Configuration publication happens
/// only in an authenticated commit request, after checking its original revision.
final class S3SetupJobs: @unchecked Sendable {
    // Older agents must reject rather than downgrade/ignore encryption or the
    // persistent manual-spooling hold when editing a configuration draft.
    static let startOperation = "stores.setup.start.v3"
    private final class Job {
        let id = UUID().uuidString
        let uid: uid_t
        let identity: UUID
        let draft: RecordingStoreConfiguration
        let original: RecordingStoreConfiguration?
        let deadline: Double
        var state = "validating"
        var message = "Checking bucket compatibility and write access."
        var task: Task<Void, Never>?
        init(uid: uid_t, identity: UUID, draft: RecordingStoreConfiguration, original: RecordingStoreConfiguration?, deadline: Double) {
            self.uid = uid; self.identity = identity; self.draft = draft; self.original = original; self.deadline = deadline
        }
        var summary: S3SetupStatus { .init(id: id, state: state, message: message, storeID: draft.id) }
    }
    private let lock = NSLock()
    private var jobs: [String: Job] = [:]
    private let factory: S3TransportFactory
    private let now: () -> Double
    private var expiry: DispatchSourceTimer?
    init(factory: @escaping S3TransportFactory = AWSS3Transport.make, now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.factory = factory; self.now = now
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in guard let self else { return }; self.lock.lock(); self.expire(); self.lock.unlock() }
        timer.resume(); expiry = timer
    }
    deinit { expiry?.cancel(); for job in jobs.values { job.task?.cancel() } }
    private func expire() {
        for (id, job) in jobs where now() >= job.deadline { job.task?.cancel(); jobs[id] = nil }
    }
    func start(draft: RecordingStoreConfiguration, original: RecordingStoreConfiguration?, uid: uid_t) throws -> S3SetupStatus {
        try draft.validate(); try draft.s3?.validate(requireCredentials: true)
        guard draft.type == "S3", uid != 0, draft.ownerUID == uid else { throw ServiceError(.permission, "S3 setup must be requested by its non-root owner.") }
        lock.lock(); defer { lock.unlock() }; expire()
        guard jobs.count < 16, !jobs.values.contains(where: { $0.draft.id == draft.id && $0.state == "validating" }) else { throw ServiceError("A setup job is already active or the job limit was reached.") }
        let job = Job(uid: uid, identity: try StoreDirectory.identity(uid), draft: draft, original: original, deadline: now() + 900)
        jobs[job.id] = job
        job.task = Task { [weak self, factory, id = job.id, config = draft] in
            let result: Result<Void, Error>
            do {
                let transport = try await factory(config.s3!)
                try await transport.validate(config.s3!); try Task.checkCancellation()
                let bytes = Data("hbnvr S3 setup validation\n".utf8), s3 = config.s3!
                let metadata = S3ShardMetadata(id: UUID().uuidString, storeID: config.id, cameraID: UUID().uuidString,
                    bucket: s3.bucket, region: s3.region, expectedOwner: s3.expectedOwner, prefix: s3.prefix,
                    key: s3.prefix + "setup/" + UUID().uuidString + ".txt", capturedAt: Date(), size: Int64(bytes.count), sha256: S3ShardMetadata.hash(bytes))
                try await transport.upload(metadata, payload: .memory(bytes)); try Task.checkCancellation(); result = .success(())
            } catch { result = .failure(error) }
            self?.completed(id, result: result)
        }
        return job.summary
    }
    private func completed(_ id: String, result: Result<Void, Error>) {
        lock.lock(); defer { lock.unlock() }; expire()
        guard let job = jobs[id], job.state == "validating" else { return }
        job.task = nil
        switch result {
        case .success: job.state = "validated"; job.message = "Bucket and write access validated. Ready to save."
        case .failure(let error): job.state = "failed"; job.message = AWSS3Transport.classify(error).message
        }
    }
    private func owned(_ id: String, uid: uid_t) throws -> Job {
        expire()
        guard let job = jobs[id], job.uid == uid, try StoreDirectory.identity(uid) == job.identity else { throw ServiceError(.permission, "Setup job expired or belongs to another identity.") }
        return job
    }
    func poll(_ id: String, uid: uid_t) throws -> S3SetupStatus { lock.lock(); defer { lock.unlock() }; return try owned(id, uid: uid).summary }
    func cancel(_ id: String, uid: uid_t) throws -> S3SetupStatus {
        lock.lock(); defer { lock.unlock() }
        let job = try owned(id, uid: uid); job.task?.cancel(); job.task = nil; job.state = "cancelled"; job.message = "Cancelled. A setup object may remain and expire under the bucket policy."
        return job.summary
    }
    func prepared(_ id: String, uid: uid_t, saveDisabled: Bool, current: RecordingStoreConfiguration?) throws -> RecordingStoreConfiguration {
        lock.lock(); defer { lock.unlock() }
        let job = try owned(id, uid: uid)
        guard current == job.original else { throw ServiceError("Store changed during validation; start setup again.") }
        guard job.state == "validated" || (job.state == "failed" && saveDisabled) else { throw ServiceError("Setup must validate successfully, or explicitly save a failed validation disabled.") }
        var draft = job.draft
        if saveDisabled { draft.enabled = false }
        return draft
    }
    func committed(_ id: String, uid: uid_t) throws {
        lock.lock(); defer { lock.unlock() }; let job = try owned(id, uid: uid)
        job.state = "committed"; job.message = "Saved. Lifecycle reconciliation is independent of upload validation."
    }
    func stop() { lock.lock(); defer { lock.unlock() }; for job in jobs.values { job.task?.cancel() }; jobs.removeAll() }
}
