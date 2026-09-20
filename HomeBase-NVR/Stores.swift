import Foundation
import Darwin

struct RecordingStoreConfiguration: Codable, Equatable {
    var schemaVersion = 1
    var id = UUID().uuidString
    var name = "Local recordings"
    var type = "Local"
    var enabled = true
    var directory: String = ""
    var shardDuration = "1m"
    var retentionPeriod = "1w"
    var ownerUID: uid_t
    var ownerUUID: UUID
    var s3: S3Configuration?
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "SchemaVersion", id = "ID", name = "Name", type = "Type", enabled = "Enabled"
        case directory = "Directory", shardDuration = "ShardDuration", retentionPeriod = "RetentionPeriod"
        case ownerUID = "OwnerUID", ownerUUID = "OwnerUUID"
        case s3 = "S3"
    }
    func validate() throws {
        guard (schemaVersion == 1 || ((2...4).contains(schemaVersion) && type == "S3")), ["Local", "S3"].contains(type), UUID(uuidString: id) != nil,
              CameraConfiguration.printable(name, limit: 80), !name.trimmingCharacters(in: .whitespaces).isEmpty,
              ownerUID != 0 else { throw ServiceError(.invalidMessage, "Invalid store configuration.") }
        if type == "Local" {
            guard s3 == nil, directory.hasPrefix("/"), directory != "/", CameraConfiguration.printable(directory, limit: 1024),
                  directory == "/" + directory.split(separator: "/").joined(separator: "/"),
                  !directory.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw ServiceError("Invalid local directory.") }
        } else {
            guard let s3, directory.isEmpty else { throw ServiceError("S3 settings are required; Directory must be empty.") }
            guard s3.clientEncryption?.enabled != true || schemaVersion >= 2 else {
                throw ServiceError("Encrypted S3 stores require SchemaVersion 2 or newer, so older daemons cannot silently record plaintext.")
            }
            guard s3.settings.spoolDirectory == nil || schemaVersion >= 3 else { throw ServiceError("A custom SpoolDirectory requires SchemaVersion 3 or newer, so older daemons cannot silently use the default disk.") }
            guard !s3.settings.forceSpooling || schemaVersion >= 4 else { throw ServiceError("ForceSpooling requires SchemaVersion 4, so older daemons cannot silently resume uploading.") }
            try s3.validate()
            let seconds = try IntervalText.seconds(retentionPeriod)
            guard seconds >= 86400, seconds % 86400 == 0 else { throw ServiceError("S3 retention must be a positive whole number of days.") }
        }
        let shard = try IntervalText.seconds(shardDuration), retention = try IntervalText.seconds(retentionPeriod)
        guard shard <= 86400, retention >= shard, retention <= 3153600000 else {
            throw ServiceError(.invalidMessage, "Shard duration must be 1s...1d; retention must be at least the shard duration and at most 100y.")
        }
        guard try StoreDirectory.identity(ownerUID) == ownerUUID else { throw ServiceError(.permission, "Store owner identity changed; refusing access.") }
    }
}

struct RecordingStoreRepository {
    let directory: String
    func list() throws -> [RecordingStoreConfiguration] {
        try SecureFiles.ensureDirectory(directory, owner: geteuid(), mode: 0o700)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory).filter { $0.hasSuffix(".json") }.sorted()
        guard files.count <= 16 else { throw ServiceError("At most 16 recording stores are supported.") }
        let configs = try files.map { file -> RecordingStoreConfiguration in
            let data = try CameraJSON.read(directory + "/" + file, privateFile: true)
            guard let config = try? JSONDecoder().decode(RecordingStoreConfiguration.self, from: data), file == config.id + ".json" else {
                throw ServiceError(.invalidMessage, "Invalid store JSON: \(file).")
            }
            try config.validate(); try config.s3?.clientEncryption?.validate(requirePassword: true); return config
        }
        for (i, config) in configs.enumerated() {
            for other in configs.dropFirst(i + 1) where Self.overlap(config, other) {
                throw ServiceError("Recording destinations must not overlap.")
            }
        }
        return configs.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }
    static func overlap(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || lhs.hasPrefix(rhs + "/") || rhs.hasPrefix(lhs + "/")
    }
    static func overlap(_ lhs: RecordingStoreConfiguration, _ rhs: RecordingStoreConfiguration) -> Bool {
        let aSpool = lhs.s3?.settings.spoolDirectory, bSpool = rhs.s3?.settings.spoolDirectory
        if let aSpool, let bSpool, overlap(aSpool, bSpool) { return true }
        if let aSpool, rhs.type == "Local", overlap(aSpool, rhs.directory) { return true }
        if let bSpool, lhs.type == "Local", overlap(bSpool, lhs.directory) { return true }
        guard lhs.type == rhs.type else { return false }
        if let a = lhs.s3, let b = rhs.s3 { return a.partition == b.partition && a.bucket == b.bucket && (a.prefix.hasPrefix(b.prefix) || b.prefix.hasPrefix(a.prefix)) }
        return overlap(lhs.directory, rhs.directory)
    }
    func save(_ config: RecordingStoreConfiguration, replacing: Bool) throws {
        try config.validate()
        try config.s3?.clientEncryption?.validate(requirePassword: true)
        let current = try list()
        guard current.contains(where: { $0.id == config.id }) == replacing,
              replacing || current.count < 16 else { throw ServiceError("Store no longer exists, already exists, or the 16-store limit was reached.") }
        guard !current.contains(where: { $0.id != config.id && Self.overlap($0, config) }) else {
            throw ServiceError("Recording destinations must not overlap.")
        }
        try SecureFiles.atomicWrite(CameraJSON.encode(config), to: directory + "/" + config.id + ".json", mode: 0o600)
    }
    func remove(_ id: String) throws {
        guard try list().contains(where: { $0.id == id }) else { throw ServiceError("Unknown recording store.") }
        try SecureFiles.removeFile(directory + "/" + id + ".json")
    }
}

/// A file-free media contract. Containers belong exclusively to implementations.
struct EncodedMedia: Sendable {
    let codec: String
    let clockRate: UInt32
    let parameterSets: [Data]
    let frame: EncodedVideoFrame
    let receivedAt: Date
    let receivedUptime: TimeInterval
    let cameraUTC: Double?
    let cameraClock: CameraClockEvidence?
    let ssrc: UInt32?
    var time: RecordingTime?
    init(codec: String, clockRate: UInt32, parameterSets: [Data], frame: EncodedVideoFrame,
         receivedAt: Date = Date(), receivedUptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
         cameraUTC: Double? = nil, ssrc: UInt32? = nil, time: RecordingTime? = nil, cameraClock: CameraClockEvidence? = nil) {
        self.codec = codec; self.clockRate = clockRate; self.parameterSets = parameterSets; self.frame = frame
        self.receivedAt = receivedAt; self.receivedUptime = receivedUptime
        self.cameraUTC = cameraUTC; self.ssrc = ssrc; self.time = time
        self.cameraClock = cameraClock
    }
}
enum RecordingEvent: Sendable {
    case media(camera: String, name: String, EncodedMedia, homebaseDeviceID: String? = nil)
    case end(camera: String)
    var bytes: Int { if case .media(_, _, let media, _) = self { return media.frame.payload.count }; return 0 }
}
struct LocalStoreStatus: Codable {
    var retryingDestination: Bool
    var retryingCameras: Int
    var droppedEvents: UInt64
    var manifestWarning: String?
    var retentionWarning: String?
    var errorLogWarning: String?
}
struct RecordingStoreStatus: Codable {
    let id: String
    let name: String
    let enabled: Bool
    var state: String
    var activeRecordings = 0
    var completedShards: UInt64 = 0
    var recordedFrames: UInt64 = 0
    var pendingBytes = 0
    var playbackRAMBytes: Int? = nil
    var lastError: String?
    var s3: S3StoreStatus?
    var local: LocalStoreStatus?
    mutating func recordFailure(_ message: String) {
        state = "error"
        // Cleanup/finalization can fail too; preserve the cause that stopped recording.
        if lastError == nil { lastError = message }
    }
}
protocol RecordingDestination: AnyObject {
    var configuration: RecordingStoreConfiguration { get }
    func accept(_ event: RecordingEvent)
    func snapshot() -> RecordingStoreStatus
    func finish(timeout: TimeInterval) -> Bool
    func flush(timeout: TimeInterval) -> Bool
}

/// Routing does not perform muxing or disk I/O on camera queues.
final class RecordingStoreManager: @unchecked Sendable {
    private let lock = NSLock()
    private var destinations: [String: any RecordingDestination] = [:]
    private var unavailable: [String: RecordingStoreStatus] = [:]
    private var unavailableS3 = Set<String>()
    private let log: (String) -> Void
    private let spoolRoot: String
    private let transportFactory: S3TransportFactory
    init(spoolRoot: String = Paths.system.base + "/private/spool", transportFactory: @escaping S3TransportFactory = AWSS3Transport.make, log: @escaping (String) -> Void = { _ in }) { self.spoolRoot = spoolRoot; self.transportFactory = transportFactory; self.log = log }
    func install(_ config: RecordingStoreConfiguration, recoverUnavailable: Bool = false) throws {
        lock.lock(); let existing = destinations[config.id] as? S3RecordingStore; lock.unlock()
        if let existing, config.type == "S3" {
            let previous = existing.configuration
            if previous.s3?.settings.spoolDirectory == config.s3?.settings.spoolDirectory { try existing.update(config); return }
            guard !config.enabled else { throw ServiceError("Keep the S3 store disabled while changing SpoolDirectory; enable it separately afterward.") }
            if let blocker = existing.drainBlocker() { throw ServiceError("Cannot change SpoolDirectory: " + blocker) }
            guard config.ownerUID == previous.ownerUID,
                  config.ownerUUID == previous.ownerUUID, config.s3!.sameDestination(as: previous.s3!) else {
                throw ServiceError("Spool relocation cannot change store ownership or its S3 destination.")
            }
            // Prepare the new, empty spool before retiring the old instance. A
            // missing drive or permissions failure leaves the old store intact.
            try config.validate()
            let replacement = try S3RecordingStore(configuration: config, spoolRoot: spoolRoot, factory: transportFactory, log: log)
            _ = existing.finish(timeout: 0) // Already disabled, flushed, and empty.
            lock.lock(); destinations[config.id] = replacement; lock.unlock()
            return
        }
        if config.type == "S3" {
            let destination = try S3RecordingStore(configuration: config, spoolRoot: spoolRoot, factory: transportFactory, log: log)
            lock.lock(); destinations[config.id] = destination; unavailable[config.id] = nil; unavailableS3.remove(config.id); lock.unlock()
            return
        }
        try remove(config.id)
        let destination: LocalRecordingStore
        do { destination = try LocalRecordingStore(configuration: config, recoverUnavailable: recoverUnavailable, log: log) }
        catch {
            guard !config.enabled else { throw error }
            lock.lock()
            unavailable[config.id] = RecordingStoreStatus(id: config.id, name: config.name, enabled: false, state: "disabled", lastError: "Retention is unavailable: " + ((error as? ServiceError)?.message ?? "Cannot access destination."))
            lock.unlock()
            log("Store \(config.id): disabled; retention destination is unavailable.")
            return
        }
        lock.lock(); destinations[config.id] = destination; unavailable[config.id] = nil; lock.unlock()
    }
    func load(_ configs: [RecordingStoreConfiguration]) {
        for config in configs {
            do { try install(config, recoverUnavailable: true) }
            catch {
                lock.lock()
                if config.type == "S3" { unavailableS3.insert(config.id) }
                unavailable[config.id] = RecordingStoreStatus(id: config.id, name: config.name, enabled: config.enabled, state: "error", lastError: (error as? ServiceError)?.message ?? "Store could not be opened.")
                lock.unlock()
                log("Store \(config.id): could not open destination; inspect status for details.")
            }
        }
    }
    func accept(_ event: RecordingEvent) {
        lock.lock(); let values = Array(destinations.values); lock.unlock()
        for store in values where store.configuration.enabled { store.accept(event) }
    }
    var hasWritableStore: Bool {
        snapshot().contains { $0.s3?.acceptingRecording ?? ($0.enabled && !["error", "retrying", "stopping"].contains($0.state)) }
    }
    func drain(timeout: TimeInterval = 3) throws {
        lock.lock(); let values = Array(destinations.values); lock.unlock()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        for store in values {
            guard store.flush(timeout: max(0, deadline - ProcessInfo.processInfo.systemUptime)) else {
                throw ServiceError(.timeout, "Camera settings were saved and applied; recording finalization is still pending. Check status before retrying.")
            }
        }
    }
    func snapshot() -> [RecordingStoreStatus] {
        lock.lock(); let values = Array(destinations.values), errors = Array(unavailable.values); lock.unlock()
        return (values.map { $0.snapshot() } + errors).sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }
    func remove(_ id: String) throws {
        lock.lock(); let store = destinations[id], unknownBacklog = unavailableS3.contains(id); lock.unlock()
        guard !unknownBacklog else { throw ServiceError("S3 spool could not be inspected; repair its access before removing this store.") }
        if let s3 = store as? S3RecordingStore, let blocker = s3.drainBlocker() { throw ServiceError("Cannot remove S3 store: " + blocker) }
        guard store?.finish(timeout: 3) ?? true else { throw ServiceError("Store has pending work; retry removal after it drains.") }
        lock.lock(); destinations[id] = nil; unavailable[id] = nil; lock.unlock()
    }
    func beginShutdown() {
        lock.lock(); let values = Array(destinations.values); lock.unlock()
        for store in values { _ = store.finish(timeout: 0) }
    }
    @discardableResult func stop(deadline requestedDeadline: Double? = nil) -> Bool {
        lock.lock(); let values = Array(destinations.values); lock.unlock()
        beginShutdown()
        let deadline = requestedDeadline ?? ProcessInfo.processInfo.systemUptime + 45
        var safe = true
        for store in values {
            if !store.finish(timeout: max(0, deadline - ProcessInfo.processInfo.systemUptime)) {
                safe = false
                log("Store \(store.configuration.id): shutdown was NOT safe; finalization or persistence failed and RAM-only video may be lost. Inspect store status and spool.")
            }
        }
        return safe
    }
}
