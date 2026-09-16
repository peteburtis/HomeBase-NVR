import Foundation
import Darwin
import MachO

enum BuildInfo { static let version = "0.1.4" }

enum FailureCode: Int32, Codable {
    case failure = 1, unavailable = 3, permission = 4, incompatible = 5, timeout = 6, invalidMessage = 7
}
struct ServiceError: Error {
    let code: FailureCode
    let message: String
    init(_ code: FailureCode, _ message: String) { self.code = code; self.message = message }
    init(_ message: String) { self.init(.failure, message) }
    static func posix(_ operation: String) -> ServiceError { ServiceError("\(operation): \(String(cString: strerror(errno)))") }
}
struct Paths {
    let base: String
    let binary: String
    let plist: String
    static let label = "com.graygoolabs.hbnvr"
    static let system = Paths(base: "/Library/Application Support/HomeBase-NVR", binary: "/usr/local/bin/hbnvr", plist: "/Library/LaunchDaemons/com.graygoolabs.hbnvr.plist")
    var runtime: String { base + "/run" }
    var authorization: String { base + "/authorization.json" }
}
struct ProcessResult { let status: Int32; let output: String }
typealias ProcessRunner = (String, [String]) throws -> ProcessResult

enum Processes {
    static func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe
        do { try process.run() } catch { throw ServiceError("Could not run \(executable): \(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
    static func require(_ result: ProcessResult, _ operation: String) throws {
        guard result.status == 0 else { throw ServiceError("\(operation) failed (\(result.status)): \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))") }
    }
}

enum SecureFiles {
    static func validateSystemAncestors(of path: String) throws {
        var parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        while true {
            if let s = try info(parent.path) {
                guard s.st_mode & S_IFMT == S_IFDIR, s.st_uid == 0, s.st_mode & 0o022 == 0 else {
                    throw ServiceError(.permission, "System installation requires root-owned, non-writable parent directories: \(parent.path).")
                }
            }
            if parent.path == "/" { break }
            parent.deleteLastPathComponent()
        }
    }
    static func info(_ path: String) throws -> stat? {
        var value = stat()
        if lstat(path, &value) == 0 { return value }
        if errno == ENOENT { return nil }
        throw ServiceError.posix("Inspect \(path)")
    }
    static func validateDirectory(_ path: String, owner: uid_t, mode: mode_t) throws {
        guard let s = try info(path), s.st_mode & S_IFMT == S_IFDIR, s.st_uid == owner, s.st_mode & 0o777 == mode else {
            throw ServiceError(.permission, "Unsafe ownership, permissions, or directory type at \(path).")
        }
    }
    static func ensureDirectory(_ path: String, owner: uid_t, mode: mode_t, group: gid_t? = nil) throws {
        if try info(path) == nil {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: NSNumber(value: mode)])
            if chown(path, owner, group ?? getegid()) != 0 { throw ServiceError.posix("Set ownership of \(path)") }
            if chmod(path, mode) != 0 { throw ServiceError.posix("Set permissions of \(path)") }
        }
        try validateDirectory(path, owner: owner, mode: mode)
    }
    static func atomicWrite(_ data: Data, to path: String, mode: mode_t) throws {
        if let s = try info(path), s.st_mode & S_IFMT != S_IFREG || s.st_uid != geteuid() {
            throw ServiceError(.permission, "Refusing to replace an unexpected file at \(path).")
        }
        let temporary = path + "." + UUID().uuidString
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
        guard fd >= 0 else { throw ServiceError.posix("Create \(temporary)") }
        defer { close(fd); unlink(temporary) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw ServiceError.posix("Write \(temporary)") }
                offset += n
            }
        }
        guard fchmod(fd, mode) == 0, fsync(fd) == 0, rename(temporary, path) == 0 else { throw ServiceError.posix("Publish \(path)") }
    }
    static func readAuthorization(_ path: String) throws -> Controller {
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw ServiceError.posix("Open authorization") }
        defer { close(fd) }
        var s = stat()
        guard fstat(fd, &s) == 0, s.st_mode & S_IFMT == S_IFREG, s.st_uid == 0, s.st_mode & 0o022 == 0, s.st_size <= 65536 else {
            throw ServiceError(.permission, "Authorization must be a root-owned, non-writable regular file.")
        }
        let data = FileHandle(fileDescriptor: fd, closeOnDealloc: false).readDataToEndOfFile()
        return try JSONDecoder().decode(Controller.self, from: data)
    }
    static func removeFile(_ path: String) throws {
        guard let s = try info(path) else { return }
        guard s.st_mode & S_IFMT == S_IFREG, s.st_uid == geteuid() else { throw ServiceError(.permission, "Refusing to remove unexpected file at \(path).") }
        guard unlink(path) == 0 else { throw ServiceError.posix("Remove \(path)") }
    }
}

final class InstanceLock {
    private let fd: Int32
    init(path: String) throws {
        fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ServiceError.posix("Open lock \(path)") }
        var s = stat()
        guard fstat(fd, &s) == 0, s.st_mode & S_IFMT == S_IFREG, s.st_uid == geteuid(), s.st_nlink == 1 else {
            close(fd); throw ServiceError(.permission, "Unsafe lock file at \(path).")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw ServiceError("Another instance or lifecycle operation already holds \(path).") }
    }
    deinit { close(fd) }
}

enum EmbeddedPlist {
    static func load() throws -> Data {
        guard let header = _dyld_get_image_header(0) else { throw ServiceError("Missing executable Mach-O header.") }
        var size: UInt = 0
        let data = header.withMemoryRebound(to: mach_header_64.self, capacity: 1) {
            getsectiondata($0, "__TEXT", "__launchd_plist", &size)
        }
        guard let data, size > 0 else { throw ServiceError("Executable is missing its embedded launchd plist.") }
        let result = Data(bytes: data, count: Int(size))
        guard let plist = try PropertyListSerialization.propertyList(from: result, format: nil) as? [String: Any],
              plist["Label"] as? String == Paths.label,
              plist["UserName"] as? String == "_hbnvr",
              plist["ProgramArguments"] as? [String] == [Paths.system.binary, "agent", "--system"] else {
            throw ServiceError("Invalid embedded launchd configuration.")
        }
        return result
    }
    static func executablePath() throws -> String {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { throw ServiceError("Cannot locate executable.") }
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
    }
}
