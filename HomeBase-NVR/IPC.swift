import Foundation
import Darwin
import os

struct Request: Codable { let protocolVersion: Int; let operation: String }
struct AgentStatus: Codable { let ready: Bool; let version: String; let pid: Int32; let uptimeSeconds: Double }
struct Reply: Codable {
    let protocolVersion: Int
    let status: AgentStatus?
    let error: String?
    let code: FailureCode?
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
        // Server authenticates first and may immediately send a denial. A failed write can still have a readable denial.
        do { try SocketIO.write(JSONEncoder().encode(Request(protocolVersion: 1, operation: "status")), fd: fd, deadline: deadline) }
        catch { /* Read the server's error, if one is available. */ }
        let data = try SocketIO.read(fd: fd, deadline: deadline)
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { throw ServiceError(.invalidMessage, "Malformed agent reply.") }
        guard reply.protocolVersion == 1 else { throw ServiceError(.incompatible, "Incompatible IPC protocol version.") }
        if let error = reply.error { throw ServiceError(reply.code ?? .failure, error) }
        guard let status = reply.status, status.ready else { throw ServiceError(.invalidMessage, "Agent reply omitted ready status.") }
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
    let directory: String
    let authorization: Authorization
    let system: Bool
    private let cancellation = Cancellation()
    private let logger = Logger(subsystem: "com.graygoolabs.hbnvr", category: "agent")
    init(directory: String, authorization: Authorization, system: Bool) {
        self.directory = directory; self.authorization = authorization; self.system = system
    }
    private func log(_ message: String) {
        if system { logger.notice("\(message, privacy: .public)") }
        else { FileHandle.standardError.write(Data((message + "\n").utf8)) }
    }
    func run() throws {
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
            handle(client, started: started)
            close(client)
        }
        log("hbnvr stopped")
    }
    func handle(_ fd: Int32, started: TimeInterval) {
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
            guard request.operation == "status" else { throw ServiceError(.invalidMessage, "Unknown operation.") }
            let status = AgentStatus(ready: true, version: BuildInfo.version, pid: getpid(), uptimeSeconds: ProcessInfo.processInfo.systemUptime - started)
            let reply = Reply(protocolVersion: 1, status: status, error: nil, code: nil)
            try SocketIO.write(JSONEncoder().encode(reply), fd: fd, deadline: deadline, cancellation: cancellation)
        } catch {
            let failure = error as? ServiceError ?? ServiceError("Request failed: \(error)")
            if !cancellation.isStopped {
                // Allow a short error-response window after a read timeout.
                try? SocketIO.write(JSONEncoder().encode(Reply.failure(failure)), fd: fd, deadline: ProcessInfo.processInfo.systemUptime + 0.2, cancellation: cancellation)
                log("IPC: \(failure.message)")
            }
        }
    }
}
