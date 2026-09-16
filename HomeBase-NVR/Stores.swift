import Foundation
import Darwin

struct RecordingStoreConfiguration: Codable, Equatable {
    var schemaVersion = 1
    var id = UUID().uuidString
    var name = "Local recordings"
    var type = "Local"
    var enabled = true
    var directory: String
    var shardDuration = "1m"
    var retentionPeriod = "1w"
    var ownerUID: uid_t
    var ownerUUID: UUID
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "SchemaVersion", id = "ID", name = "Name", type = "Type", enabled = "Enabled"
        case directory = "Directory", shardDuration = "ShardDuration", retentionPeriod = "RetentionPeriod"
        case ownerUID = "OwnerUID", ownerUUID = "OwnerUUID"
    }
    func validate() throws {
        guard schemaVersion == 1, type == "Local", UUID(uuidString: id) != nil,
              CameraConfiguration.printable(name, limit: 80), !name.trimmingCharacters(in: .whitespaces).isEmpty,
              directory.hasPrefix("/"), directory != "/", CameraConfiguration.printable(directory, limit: 1024),
              directory == "/" + directory.split(separator: "/").joined(separator: "/"),
              !directory.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              ownerUID != 0 else { throw ServiceError(.invalidMessage, "Invalid local store configuration.") }
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
            try config.validate(); return config
        }
        for (i, config) in configs.enumerated() {
            for other in configs.dropFirst(i + 1) where Self.overlap(config.directory, other.directory) {
                throw ServiceError("Local recording directories must not duplicate or contain each other.")
            }
        }
        return configs.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }
    static func overlap(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || lhs.hasPrefix(rhs + "/") || rhs.hasPrefix(lhs + "/")
    }
    func save(_ config: RecordingStoreConfiguration, replacing: Bool) throws {
        try config.validate()
        let current = try list()
        guard current.contains(where: { $0.id == config.id }) == replacing,
              replacing || current.count < 16 else { throw ServiceError("Store no longer exists, already exists, or the 16-store limit was reached.") }
        guard !current.contains(where: { $0.id != config.id && Self.overlap($0.directory, config.directory) }) else {
            throw ServiceError("Local recording directories must not duplicate or contain each other.")
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
}
enum RecordingEvent: Sendable {
    case media(camera: String, name: String, EncodedMedia)
    case end(camera: String)
    var bytes: Int { if case .media(_, _, let media) = self { return media.frame.payload.count }; return 0 }
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
    var lastError: String?
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
}

/// Routing does not perform muxing or disk I/O on camera queues.
final class RecordingStoreManager: @unchecked Sendable {
    private let lock = NSLock()
    private var destinations: [String: any RecordingDestination] = [:]
    private var unavailable: [String: RecordingStoreStatus] = [:]
    private let log: (String) -> Void
    init(log: @escaping (String) -> Void = { _ in }) { self.log = log }
    func install(_ config: RecordingStoreConfiguration) throws {
        try remove(config.id)
        let destination: LocalRecordingStore
        do { destination = try LocalRecordingStore(configuration: config, log: log) }
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
            do { try install(config) }
            catch {
                lock.lock()
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
        snapshot().contains { $0.enabled && $0.state != "error" && $0.state != "stopping" }
    }
    func snapshot() -> [RecordingStoreStatus] {
        lock.lock(); let values = Array(destinations.values), errors = Array(unavailable.values); lock.unlock()
        return (values.map { $0.snapshot() } + errors).sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }
    func remove(_ id: String) throws {
        lock.lock(); let store = destinations[id]; lock.unlock()
        guard store?.finish(timeout: 3) ?? true else { throw ServiceError("Store has pending work; retry removal after it drains.") }
        lock.lock(); destinations[id] = nil; unavailable[id] = nil; lock.unlock()
    }
    func stop() {
        lock.lock(); let values = Array(destinations.values); lock.unlock()
        for store in values { _ = store.finish(timeout: 0) }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        for store in values { _ = store.finish(timeout: max(0, deadline - ProcessInfo.processInfo.systemUptime)) }
    }
}
