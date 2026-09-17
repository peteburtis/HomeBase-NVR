import Foundation
import Darwin
import os

struct Request: Codable {
    let protocolVersion: Int
    let operation: String
    var camera: CameraConfiguration? = nil
    var cameraID: String? = nil
    var cameraEdit: CameraEdit? = nil
    var store: RecordingStoreConfiguration? = nil
    var storeID: String? = nil
    var storeOriginal: RecordingStoreConfiguration? = nil
    var setupID: String? = nil
    var saveDisabled: Bool? = nil
    var recordingStarted: Bool? = nil
    var homebaseDeviceID: String? = nil
    var nvrInstanceID: String? = nil
}
struct AgentStatus: Codable {
    let ready: Bool
    let version: String
    let pid: Int32
    let uptimeSeconds: Double
    var streams: [CameraStreamStatus]? = nil
    var stores: [RecordingStoreStatus]? = nil
}
struct Reply: Codable {
    let protocolVersion: Int
    let status: AgentStatus?
    let error: String?
    let code: FailureCode?
    var cameras: [CameraSummary]? = nil
    var camera: CameraSummary? = nil
    var cameraOptions: CameraEditableOptions? = nil
    var stores: [RecordingStoreConfiguration]? = nil
    var store: RecordingStoreConfiguration? = nil
    var setup: S3SetupStatus? = nil
    var cameraSnapshot: NVRCameraSnapshot? = nil
    static func failure(_ error: ServiceError) -> Reply { Reply(protocolVersion: 1, status: nil, error: error.message, code: error.code) }
}

final class Cancellation {
    private let lock = NSLock()
    private var stopped = false
    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func stop() { lock.lock(); stopped = true; lock.unlock() }
}

enum SocketIO {
    static let limit = 65536
    static func path(_ directory: String) -> String { URL(fileURLWithPath: directory).standardizedFileURL.path + "/control.sock" }
    static func address<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
        var address = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw ServiceError("Unix socket path is too long: \(path). Use a shorter --runtime-dir.") }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return try withUnsafePointer(to: &address) {
            try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }
    static func configure(_ fd: Int32) throws {
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw ServiceError.posix("Configure socket") }
        var one: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one))) == 0 else { throw ServiceError.posix("Configure socket signals") }
    }
    static func wait(_ fd: Int32, events: Int16, deadline: TimeInterval, cancellation: Cancellation? = nil) throws {
        while true {
            if cancellation?.isStopped == true { throw ServiceError(.unavailable, "Agent is shutting down.") }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw ServiceError(.timeout, "IPC deadline exceeded.") }
            var item = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&item, 1, Int32(min(remaining * 1000, 100).rounded(.up)))
            if result < 0 && errno == EINTR { continue }
            guard result >= 0 else { throw ServiceError.posix("Poll socket") }
            if result > 0 {
                guard item.revents & Int16(POLLNVAL) == 0 else { throw ServiceError(.unavailable, "Socket closed.") }
                return
            }
        }
    }
    static func write(_ data: Data, fd: Int32, deadline: TimeInterval, cancellation: Cancellation? = nil) throws {
        guard data.count <= limit else { throw ServiceError(.invalidMessage, "IPC message exceeds 64 KiB.") }
        let framed = data + Data([10])
        try framed.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try wait(fd, events: Int16(POLLOUT), deadline: deadline, cancellation: cancellation)
                let n = send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                if n < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                guard n > 0 else { throw ServiceError(.unavailable, "Peer disconnected while writing.") }
                offset += n
            }
        }
    }
    static func read(fd: Int32, deadline: TimeInterval, cancellation: Cancellation? = nil) throws -> Data {
        var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            try wait(fd, events: Int16(POLLIN), deadline: deadline, cancellation: cancellation)
            let n = recv(fd, &buffer, buffer.count, 0)
            if n < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            guard n > 0 else { throw ServiceError(.unavailable, "Peer disconnected before completing a message.") }
            result.append(contentsOf: buffer.prefix(n))
            if let end = result.firstIndex(of: 10) {
                guard end <= limit else { throw ServiceError(.invalidMessage, "IPC message exceeds 64 KiB.") }
                return result.prefix(end)
            }
            guard result.count <= limit else { throw ServiceError(.invalidMessage, "IPC message exceeds 64 KiB.") }
        }
    }
}

enum SocketClient {
    static func status(directory: String, timeout: TimeInterval = 5) throws -> Reply {
        let reply = try exchange(Request(protocolVersion: 1, operation: "status"), directory: directory, timeout: timeout)
        guard let status = reply.status, status.ready else { throw ServiceError(.invalidMessage, "Agent reply omitted ready status.") }
        return reply
    }
    static func exchange(_ request: Request, directory: String, timeout: TimeInterval = 5, expectedUID: uid_t? = nil) throws -> Reply {
        let encoded = try JSONEncoder().encode(request)
        guard encoded.count <= SocketIO.limit else { throw ServiceError(.invalidMessage, "IPC message exceeds 64 KiB.") }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServiceError.posix("Create client socket") }
        defer { close(fd) }
        try SocketIO.configure(fd)
        let connected = try SocketIO.address(SocketIO.path(directory)) { connect(fd, $0, $1) }
        if connected != 0 {
            let error = errno
            if error == EINPROGRESS {
                try SocketIO.wait(fd, events: Int16(POLLOUT), deadline: deadline)
                var value: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &value, &length) == 0, value == 0 else { throw ServiceError(.unavailable, "Could not connect to agent.") }
            } else {
                throw ServiceError(error == EACCES || error == EPERM ? .permission : .unavailable, "Could not connect to agent: \(String(cString: strerror(error))).")
            }
        }
        // Never send camera credentials to an unexpected server account.
        if let expectedUID {
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == expectedUID else {
                throw ServiceError(.permission, "Unexpected agent identity; refusing to send camera configuration.")
            }
        }
        // Server authenticates first and may immediately send a denial. A failed write can still have a readable denial.
        do { try SocketIO.write(encoded, fd: fd, deadline: deadline) }
        catch { /* Read the server's error, if one is available. */ }
        let data = try SocketIO.read(fd: fd, deadline: deadline)
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { throw ServiceError(.invalidMessage, "Malformed agent reply.") }
        guard reply.protocolVersion == 1 else { throw ServiceError(.incompatible, "Incompatible IPC protocol version.") }
        if let error = reply.error { throw ServiceError(reply.code ?? .failure, error) }
        return reply
    }
}

enum AgentReadiness {
    /// Allow launchd's 30-second restart throttle, while bounding the complete wait.
    static func wait(
        directory: String,
        timeout: TimeInterval = 35,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        probe: (String, TimeInterval) throws -> Void = { directory, timeout in
            _ = try SocketClient.status(directory: directory, timeout: timeout)
        }
    ) throws {
        let deadline = now() + timeout
        var lastFailure = "No ready response received."
        while now() < deadline {
            do {
                try probe(directory, min(5, max(0, deadline - now())))
                return
            } catch let error as ServiceError where error.code == .unavailable || error.code == .timeout {
                lastFailure = error.message
            }
            // Authentication, protocol, and malformed-response failures propagate immediately.
            let remaining = deadline - now()
            if remaining > 0 { sleep(min(0.1, remaining)) }
        }
        throw ServiceError(.timeout, "hbnvr did not become IPC-ready within \(Int(timeout)) seconds. Last error: \(lastFailure) launchd may still start or retry the service; check hbnvr status and the service logs.")
    }
}

final class AgentServer {
    private let cameraEvents = NVRCameraEvents()
    private lazy var recordings = RecordingStoreManager(spoolRoot: system ? Paths.system.base + "/private/spool" : directory + "/spool", transportFactory: transportFactory, log: { [weak self] message in self?.log(message) })
    private let setupJobs: S3SetupJobs
    private let transportFactory: S3TransportFactory
    private lazy var streams = StreamingCoordinator(log: { [weak self] message in self?.log(message) }, record: { [weak self] event in self?.recordings.accept(event) })
    var stores: RecordingStoreRepository {
        RecordingStoreRepository(directory: system ? Paths.system.base + "/private/stores" : directory + "/stores")
    }
    let directory: String
    let authorization: Authorization
    let system: Bool
    var cameras: CameraStore {
        CameraStore(directory: system ? Paths.system.base + "/private/cameras" : directory + "/cameras")
    }
    private let cancellation = Cancellation()
    private let logger = Logger(subsystem: "com.graygoolabs.hbnvr", category: "agent")
    init(directory: String, authorization: Authorization, system: Bool, transportFactory: @escaping S3TransportFactory = AWSS3Transport.make) {
        self.directory = directory; self.authorization = authorization; self.system = system
        self.transportFactory = transportFactory; setupJobs = S3SetupJobs(factory: transportFactory)
    }
    private func log(_ message: String) {
        if system { logger.notice("\(message, privacy: .public)") }
        else { FileHandle.standardError.write(Data((message + "\n").utf8)) }
    }
    func run() throws {
        defer { cameraEvents.stop() }
        let path = SocketIO.path(directory)
        // Validate length before acquiring resources.
        try SocketIO.address(path) { _, _ in () }
        let lock = try InstanceLock(path: directory + "/agent.lock")
        defer { withExtendedLifetime(lock) {} }
        if let old = try SecureFiles.info(path) {
            guard old.st_mode & S_IFMT == S_IFSOCK, old.st_uid == geteuid() else { throw ServiceError(.permission, "Refusing to remove unexpected object at \(path).") }
            guard unlink(path) == 0 else { throw ServiceError.posix("Remove stale socket") }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServiceError.posix("Create listening socket") }
        defer { close(fd) }
        try SocketIO.configure(fd)
        guard try SocketIO.address(path, { bind(fd, $0, $1) }) == 0 else { throw ServiceError.posix("Bind socket") }
        defer { unlink(path) }
        guard chmod(path, system ? 0o666 : 0o600) == 0, listen(fd, 16) == 0 else { throw ServiceError.posix("Listen on socket") }
        signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
        let signalQueue = DispatchQueue(label: "hbnvr.signals")
        let sources = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
            let source = DispatchSource.makeSignalSource(signal: number, queue: signalQueue)
            source.setEventHandler { [cancellation] in cancellation.stop() }
            source.resume(); return source
        }
        defer { sources.forEach { $0.cancel() } }
        var cleanedUp = false
        defer { if !cleanedUp { setupJobs.stop(); streams.stop(); recordings.stop() } }
        recordings.load(try stores.list())
        let initialCameras = try cameras.configurations()
        try cameraEvents.replace(initialCameras)
        for (id, camera) in initialCameras { streams.add(id: id, camera: camera) }
        let started = ProcessInfo.processInfo.systemUptime
        log("hbnvr ready (PID \(getpid())) at \(path)")
        // A bounded serial request loop: at most one active client, each with a five-second deadline.
        while !cancellation.isStopped {
            do { try SocketIO.wait(fd, events: Int16(POLLIN), deadline: ProcessInfo.processInfo.systemUptime + 3600, cancellation: cancellation) }
            catch let error as ServiceError where error.code == .timeout { continue }
            catch { if cancellation.isStopped { break }; throw error }
            let client = accept(fd, nil, nil)
            if client < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard client >= 0 else { throw ServiceError.posix("Accept client") }
            if !handle(client, started: started) { close(client) }
        }
        cameraEvents.stop()
        setupJobs.stop()
        let shutdownDeadline = ProcessInfo.processInfo.systemUptime + 45
        recordings.beginShutdown()
        streams.stop()
        let safe = recordings.stop(deadline: shutdownDeadline)
        cleanedUp = true
        guard safe else { throw ServiceError("Agent stopped with recording finalization/persistence errors; shutdown was not safe.") }
        log("hbnvr stopped")
    }
    /// True transfers the connected descriptor to a bounded event subscriber.
    @discardableResult func handle(_ fd: Int32, started: TimeInterval) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        do {
            try SocketIO.configure(fd)
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, authorization.permits(uid: uid) else {
                throw ServiceError(.permission, "This account is not authorized to control hbnvr.")
            }
            let data = try SocketIO.read(fd: fd, deadline: deadline, cancellation: cancellation)
            guard let request = try? JSONDecoder().decode(Request.self, from: data) else { throw ServiceError(.invalidMessage, "Malformed request.") }
            guard request.protocolVersion == 1 else { throw ServiceError(.incompatible, "Unsupported IPC protocol version.") }
            // Publish even if a post-save finalization wait fails. Intent was
            // durably accepted and observers must not retain the old value.
            defer {
                if request.operation.hasPrefix("cameras."), let values = try? cameras.configurations() {
                    try? cameraEvents.replace(values)
                }
            }
            var reply = Reply(protocolVersion: 1, status: nil, error: nil, code: nil)
            switch request.operation {
            case "cameras.snapshot":
                try cameraEvents.replace(cameras.configurations())
                reply.cameraSnapshot = cameraEvents.snapshot
            case "cameras.watch":
                try cameraEvents.replace(cameras.configurations())
                try cameraEvents.subscribe(fd)
                return true
            case "cameras.recording.set":
                guard request.nvrInstanceID == cameraEvents.instanceID,
                      let id = request.cameraID, let hardwareID = request.homebaseDeviceID,
                      let started = request.recordingStarted else {
                    throw ServiceError(.unavailable, "NVR session changed or recording request is incomplete; reconnect before writing.")
                }
                var camera = try cameras.configuration(id: id)
                guard camera.enabled, camera.homebaseDeviceID == hardwareID else {
                    throw ServiceError(.unavailable, "Camera is disabled, removed, or no longer matches this Homebase device.")
                }
                camera.recordingStarted = started
                reply.camera = try cameras.save(camera, id: id)
                streams.add(id: id, camera: camera)
                try cameraEvents.replace(cameras.configurations())
                reply.cameraSnapshot = cameraEvents.snapshot
                // This acknowledges persistent intent. Finalization proceeds on
                // each store's queue and is not an observation of disk health.
            case "status":
                let storeStatus = recordings.snapshot()
                var streamStatus = streams.snapshot()
                let recording = recordings.hasWritableStore
                for index in streamStatus.indices { streamStatus[index].updateRecordingState(hasWritableStore: recording) }
                let status = AgentStatus(ready: true, version: BuildInfo.version, pid: getpid(), uptimeSeconds: ProcessInfo.processInfo.systemUptime - started, streams: streamStatus, stores: storeStatus)
                reply = Reply(protocolVersion: 1, status: status, error: nil, code: nil)
            case "cameras.list":
                reply.cameras = try cameras.list()
            case "cameras.add":
                guard let camera = request.camera else { throw ServiceError(.invalidMessage, "Camera configuration is required.") }
                reply.camera = try cameras.add(camera)
                streams.add(id: reply.camera!.id, camera: camera)
            case "cameras.remove":
                guard let id = request.cameraID else { throw ServiceError(.invalidMessage, "Camera ID is required.") }
                reply.camera = try cameras.remove(id: id)
                streams.remove(id: id)
                try recordings.drain()
            case "cameras.options":
                guard let id = request.cameraID else { throw ServiceError(.invalidMessage, "Camera ID is required.") }
                let camera = try cameras.configuration(id: id)
                let profiles = try camera.onvifPort == nil ? nil : camera.onvifClient().media(expectedID: camera.homebaseDeviceID, deadline: min(deadline - 0.5, ProcessInfo.processInfo.systemUptime + 3)).profiles
                reply.cameraOptions = CameraEditableOptions(name: camera.name, selectedProfile: camera.videoProfile, profiles: profiles, revision: camera.revision)
            case "cameras.change":
                guard let id = request.cameraID, let edit = request.cameraEdit else { throw ServiceError(.invalidMessage, "Camera ID and options are required.") }
                var camera = try cameras.configuration(id: id)
                guard edit.revision == camera.revision else { throw ServiceError("Camera changed while editing; run camera change again.") }
                camera.name = edit.name
                try camera.validate()
                if edit.profileToken != camera.videoProfile?.token {
                    guard let token = edit.profileToken else { throw ServiceError("A video profile cannot be cleared through camera change.") }
                    let client = try camera.onvifClient(), discoveryDeadline = min(deadline - 0.5, ProcessInfo.processInfo.systemUptime + 3)
                    let media = try client.media(expectedID: camera.homebaseDeviceID, deadline: discoveryDeadline)
                    guard let profile = media.profiles.first(where: { $0.token == token }) else { throw ServiceError("Selected video profile is no longer available; run camera change again.") }
                    camera.rtspURL = try client.stream(profile: profile, media: media, deadline: discoveryDeadline)
                    camera.videoProfile = profile
                }
                reply.camera = try cameras.save(camera, id: id)
                streams.add(id: id, camera: camera)
                try recordings.drain(timeout: max(0, min(3, deadline - ProcessInfo.processInfo.systemUptime - 0.3)))
            case "cameras.enable", "cameras.disable", "cameras.start", "cameras.stop":
                guard let id = request.cameraID else { throw ServiceError(.invalidMessage, "Camera ID is required.") }
                var camera = try cameras.configuration(id: id)
                switch request.operation {
                case "cameras.enable": camera.enabled = true
                case "cameras.disable": camera.enabled = false
                case "cameras.start":
                    guard camera.enabled else { throw ServiceError("Camera is disabled; enable it before starting recording.") }
                    camera.recordingStarted = true
                default: camera.recordingStarted = false
                }
                reply.camera = try cameras.save(camera, id: id)
                streams.add(id: id, camera: camera)
                if !camera.enabled || !camera.recordingStarted { try recordings.drain() }
            case "stores.list": reply.stores = try stores.list().map(\.summary)
            case "stores.spool.on", "stores.spool.off", "stores.advanced.change":
                let id = request.storeID ?? request.store?.id
                guard let id, let old = try stores.list().first(where: { $0.id == id }), old.type == "S3" else { throw ServiceError("Select an S3 store for spooling or advanced settings.") }
                guard uid == 0 || uid == old.ownerUID else { throw ServiceError(.permission, "Only the store owner or root may change these options.") }
                var config = old
                if request.operation == "stores.advanced.change" {
                    guard let draft = request.store, request.storeOriginal == old.summary,
                          draft.differsOnlyInAdvancedSettings(from: old.summary) else {
                        throw ServiceError("Store changed while editing, or this edit requires S3 validation. Run store change again.")
                    }
                    config.s3?.tuning = draft.s3?.tuning
                } else {
                    var settings = config.s3!.settings
                    settings.forceSpooling = request.operation == "stores.spool.on"
                    config.s3?.tuning = settings
                }
                config.updateS3ReaderVersion()
                try stores.save(config, replacing: true)
                do { try recordings.install(config) }
                catch { try? stores.save(old, replacing: true); throw error }
                reply.store = config.summary
            case "stores.setup.start", "stores.setup.start.v2", S3SetupJobs.startOperation:
                guard var draft = request.store, draft.type == "S3", uid != 0 else { throw ServiceError(.permission, "Run S3 setup as the requesting user.") }
                let configs = try stores.list(), old = configs.first { $0.id == draft.id }
                guard request.operation == S3SetupJobs.startOperation ||
                        ((old?.schemaVersion ?? 1) < 4 && draft.schemaVersion < 4 && draft.s3?.settings.forceSpooling != true) else {
                    throw ServiceError(.incompatible, "This store uses manual-spooling-aware configuration; update the CLI before editing it.")
                }
                guard old != nil || configs.count < 16 else { throw ServiceError("The 16-store limit was reached.") }
                if let old {
                    guard old.type == "S3", old.ownerUID == uid, let previous = old.s3, let next = draft.s3,
                          previous.sameDestination(as: next) else { throw ServiceError("S3 destination and owner are immutable; relocation requires remove/add.") }
                    draft.s3?.preservePrivateSettings(from: previous)
                }
                draft.ownerUID = uid; draft.ownerUUID = try StoreDirectory.identity(uid)
                draft.schemaVersion = max(draft.schemaVersion, old?.schemaVersion ?? 1)
                draft.updateS3ReaderVersion()
                guard !configs.contains(where: { $0.id != draft.id && RecordingStoreRepository.overlap($0, draft) }) else { throw ServiceError("S3 destination prefixes must not overlap.") }
                reply.setup = try setupJobs.start(draft: draft, original: old, uid: uid)
            case "stores.setup.poll", "stores.setup.cancel", "stores.setup.commit":
                guard let id = request.setupID else { throw ServiceError("Setup job ID is required.") }
                if request.operation == "stores.setup.cancel" { reply.setup = try setupJobs.cancel(id, uid: uid) }
                else if request.operation == "stores.setup.poll" { reply.setup = try setupJobs.poll(id, uid: uid) }
                else {
                    let progress = try setupJobs.poll(id, uid: uid)
                    let old = try stores.list().first { $0.id == progress.storeID }
                    let config = try setupJobs.prepared(id, uid: uid, saveDisabled: request.saveDisabled == true, current: old)
                    try stores.save(config, replacing: old != nil)
                    do { try recordings.install(config) }
                    catch {
                        if let old { try? stores.save(old, replacing: true) } else { try? stores.remove(config.id) }
                        throw error
                    }
                    try setupJobs.committed(id, uid: uid); reply.store = config.summary
                }
            case "stores.add", "stores.change":
                guard var config = request.store, uid != 0 else { throw ServiceError(.permission, "Run store setup as the requesting user, without sudo.") }
                guard config.type == "Local" else { throw ServiceError("S3 setup uses asynchronous validation; use store add/change with hbnvr 0.7.0 or newer.") }
                let old = try stores.list().first { $0.id == config.id }
                if let old {
                    guard request.operation == "stores.change", old.ownerUID == uid else { throw ServiceError(.permission, "Only the requesting owner may change this store.") }
                    guard old.type == "Local", old.directory == config.directory else { throw ServiceError("Destination changes require removing and adding a store; existing recordings are preserved.") }
                } else if request.operation == "stores.change" { throw ServiceError("Store no longer exists.") }
                config.ownerUID = uid; config.ownerUUID = try StoreDirectory.identity(uid)
                try config.validate()
                let root = try StoreDirectory.openDirectory(config.directory); defer { close(root) }
                try StoreDirectory.validate(root, owner: uid, daemon: geteuid())
                try stores.save(config, replacing: old != nil)
                do { try recordings.install(config) }
                catch {
                    if let old { try? stores.save(old, replacing: true); recordings.load([old]) }
                    else { try? stores.remove(config.id) }
                    throw error
                }
                reply.store = config.summary
            case "stores.enable", "stores.disable", "stores.remove":
                guard let id = request.storeID, var config = try stores.list().first(where: { $0.id == id }) else { throw ServiceError("Unknown recording store.") }
                if request.operation == "stores.remove" {
                    try recordings.remove(id)
                    do { try stores.remove(id) }
                    catch { recordings.load([config]); throw error }
                } else {
                    let old = config
                    config.enabled = request.operation == "stores.enable"
                    if config.type == "S3", config.enabled, !old.enabled { throw ServiceError("Enabling an S3 store requires asynchronous validation; use hbnvr 0.7.0 store enable.") }
                    if old.enabled == config.enabled, recordings.snapshot().contains(where: { $0.id == id && $0.state != "error" && $0.state != "stopping" }) {
                        reply.store = config.summary
                        break
                    }
                    try stores.save(config, replacing: true)
                    do { try recordings.install(config) }
                    catch { try? stores.save(old, replacing: true); recordings.load([old]); throw error }
                }
                reply.store = config.summary
            default:
                throw ServiceError(.invalidMessage, "Unknown operation. Camera controls require hbnvr 0.6.0 or newer; reinstall if the agent is older.")
            }
            try SocketIO.write(JSONEncoder().encode(reply), fd: fd, deadline: deadline, cancellation: cancellation)
        } catch {
            let failure = error as? ServiceError ?? ServiceError("Request failed: \(error)")
            if !cancellation.isStopped {
                // Allow a short error-response window after a read timeout.
                try? SocketIO.write(JSONEncoder().encode(Reply.failure(failure)), fd: fd, deadline: ProcessInfo.processInfo.systemUptime + 0.2, cancellation: cancellation)
                log("IPC: \(failure.message)")
            }
        }
        return false
    }
}

/// Small integration projection: no endpoints, names, credentials, or statistics.
struct NVRCameraState: Codable, Equatable {
    let id: String
    let homebaseDeviceID: String?
    let enabled: Bool
    let recordingStarted: Bool
}
struct NVRCameraSnapshot: Codable, Equatable {
    let instanceID: String
    let revision: UInt64
    let cameras: [NVRCameraState]
}

/// Called by the serial command loop; socket writes are independent. Each watcher
/// keeps only the newest complete snapshot, so slow clients cannot grow a journal.
final class NVRCameraEvents {
    let instanceID = UUID().uuidString
    private let lock = NSLock()
    private var revision: UInt64 = 0
    private var cameras: [NVRCameraState] = []
    private var subscribers: [UUID: NVRCameraSubscriber] = [:]
    var snapshot: NVRCameraSnapshot {
        lock.lock(); defer { lock.unlock() }
        return NVRCameraSnapshot(instanceID: instanceID, revision: revision, cameras: cameras)
    }
    func replace(_ values: [(String, CameraConfiguration)]) throws {
        let next = values.map { NVRCameraState(id: $0.0, homebaseDeviceID: $0.1.homebaseDeviceID,
                                               enabled: $0.1.enabled, recordingStarted: $0.1.recordingStarted) }.sorted { $0.id < $1.id }
        lock.lock(); defer { lock.unlock() }
        guard next != cameras else { return }
        let update = NVRCameraSnapshot(instanceID: instanceID, revision: revision + 1, cameras: next)
        let data = try Self.encode(update)
        cameras = next; revision = update.revision
        for subscriber in subscribers.values { subscriber.offer(data) }
    }
    func subscribe(_ fd: Int32) throws {
        lock.lock(); defer { lock.unlock() }
        guard subscribers.count < 8 else { throw ServiceError(.unavailable, "Camera subscription limit reached; retry later.") }
        let id = UUID(), data = try Self.encode(NVRCameraSnapshot(instanceID: instanceID, revision: revision, cameras: cameras))
        let subscriber = NVRCameraSubscriber(fd: fd, initial: data) { [weak self] in
            guard let self else { return }; self.lock.lock(); self.subscribers[id] = nil; self.lock.unlock()
        }
        subscribers[id] = subscriber
        subscriber.start()
    }
    func stop() {
        lock.lock(); let values = Array(subscribers.values); subscribers.removeAll(); lock.unlock()
        values.forEach { $0.stop() }
    }
    private static func encode(_ snapshot: NVRCameraSnapshot) throws -> Data {
        var reply = Reply(protocolVersion: 1, status: nil, error: nil, code: nil)
        reply.cameraSnapshot = snapshot
        let data = try JSONEncoder().encode(reply)
        guard data.count <= SocketIO.limit else { throw ServiceError(.invalidMessage, "Camera snapshot exceeds 64 KiB.") }
        return data
    }
}

private final class NVRCameraSubscriber: @unchecked Sendable {
    private let fd: Int32
    private let condition = NSCondition()
    private var pending: Data?
    private var latest: Data
    private var stopped = false
    private var closed = false
    private let ended: () -> Void
    init(fd: Int32, initial: Data, ended: @escaping () -> Void) {
        self.fd = fd; pending = initial; latest = initial; self.ended = ended
    }
    func offer(_ data: Data) {
        condition.lock(); defer { condition.unlock() }
        guard !stopped else { return }
        pending = data; condition.signal()
    }
    func stop() {
        condition.lock(); defer { condition.unlock() }
        stopped = true
        if !closed { _ = shutdown(fd, SHUT_RDWR) }
        condition.signal()
    }
    func start() { DispatchQueue.global(qos: .utility).async { [self] in run() } }
    private func run() {
        defer {
            condition.lock(); closed = true; close(fd); condition.unlock(); ended()
        }
        while true {
            condition.lock()
            let heartbeat = Date().addingTimeInterval(30)
            while pending == nil && !stopped {
                if !condition.wait(until: heartbeat) { break }
            }
            if stopped { condition.unlock(); return }
            if let pending { latest = pending }; pending = nil
            let data = latest
            condition.unlock()
            do { try SocketIO.write(data, fd: fd, deadline: ProcessInfo.processInfo.systemUptime + 5) }
            catch { return }
        }
    }
}
