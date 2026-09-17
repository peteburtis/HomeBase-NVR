import Foundation
import Darwin

/// Dependencies are injectable so lifecycle ordering and failures can be exercised without launchd or root.
struct Installer {
    var paths = Paths.system
    var run: ProcessRunner = Processes.run
    var provision: () throws -> ServiceAccount = { try Accounts.provision() }
    var embedded: () throws -> Data = EmbeddedPlist.load
    var executable: () throws -> String = EmbeddedPlist.executablePath
    var readOwner: (String) throws -> Controller = SecureFiles.readAuthorization
    var chooseOwner: (Controller?, String?, String?) throws -> Controller = { try Accounts.selectOwner(existing: $0, explicit: $1, sudoUID: $2) }
    var fileOwner: uid_t = 0
    var waitUntilReady: (String) throws -> Void = { try AgentReadiness.wait(directory: $0) }

    private var service: String { "system/" + Paths.label }
    private func locked(_ body: () throws -> Void) throws {
        if fileOwner == 0 {
            for path in [paths.base, paths.binary, paths.plist] { try SecureFiles.validateSystemAncestors(of: path) }
        }
        try SecureFiles.ensureDirectory(paths.base, owner: fileOwner, mode: 0o755)
        let lock = try InstanceLock(path: paths.base + "/lifecycle.lock")
        defer { withExtendedLifetime(lock) {} }
        try body()
    }
    private func launch(_ arguments: [String]) throws {
        try Processes.require(run("/bin/launchctl", arguments), "launchctl " + arguments.joined(separator: " "))
    }
    private func loaded() throws -> Bool {
        let result = try run("/bin/launchctl", ["print", service])
        if result.status == 0 { return true }
        // launchctl reports ESRCH (3) or service-not-found (113) for an absent job.
        if result.status == 3 || result.status == 113 { return false }
        throw ServiceError("Cannot inspect system service (\(result.status)): \(result.output)")
    }
    private func disabled() throws -> Bool {
        let result = try run("/bin/launchctl", ["print-disabled", "system"])
        try Processes.require(result, "Inspect persistent launchd state")
        return try Self.parseDisabledState(result.output)
    }
    static func parseDisabledState(_ output: String) throws -> Bool {
        let label = "\"" + Paths.label + "\""
        // An absent override means launchd's default enabled state.
        guard output.contains(label) else { return false }
        let pattern = NSRegularExpression.escapedPattern(for: label) + "\\s*=>\\s*([^\\s;}]+)"
        let regex = try NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let range = Range(match.range(at: 1), in: output) else {
            throw ServiceError("Cannot parse the hbnvr launchd enable/disable state; refusing to change it.")
        }
        switch output[range] {
        case "disabled", "true": return true
        case "enabled", "false": return false
        default: throw ServiceError("Unknown hbnvr launchd state: \(output[range]); refusing to change it.")
        }
    }
    private func stopLoaded() throws {
        if try loaded() { try launch(["bootout", service]) }
        // bootout removes the job; wait for the previous process to release its runtime lock before an upgrade.
        let lockPath = paths.runtime + "/agent.lock"
        guard try SecureFiles.info(lockPath) != nil else { return }
        let fd = open(lockPath, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ServiceError.posix("Open daemon lock") }
        defer { close(fd) }
        var s = stat()
        guard fstat(fd, &s) == 0, s.st_mode & S_IFMT == S_IFREG, s.st_nlink == 1 else { throw ServiceError("Invalid daemon lock.") }
        let deadline = ProcessInfo.processInfo.systemUptime + 75
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN else { throw ServiceError.posix("Check daemon lock") }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ServiceError(.timeout, "Previous agent did not stop; refusing to replace its installation.") }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
    private func requireInstalled() throws {
        guard try SecureFiles.info(paths.binary) != nil, try SecureFiles.info(paths.plist) != nil else { throw ServiceError(.unavailable, "hbnvr is not installed. Run sudo hbnvr install first.") }
        for path in [paths.binary, paths.plist] {
            guard let s = try SecureFiles.info(path), s.st_mode & S_IFMT == S_IFREG, s.st_uid == fileOwner, s.st_mode & 0o022 == 0 else {
                throw ServiceError(.permission, "Unsafe installed file at \(path).")
            }
        }
    }
    @discardableResult
    func install(owner: String?) throws -> Bool {
        var started = false
        try locked {
            // Validate all inputs before changing service state.
            let plist = try embedded()
            let binary = try Data(contentsOf: URL(fileURLWithPath: executable()))
            let existing = try SecureFiles.info(paths.authorization) == nil ? nil : readOwner(paths.authorization)
            let controller = try chooseOwner(existing, owner, ProcessInfo.processInfo.environment["SUDO_UID"])
            let wasInstalled = try SecureFiles.info(paths.plist) != nil
            let wasLoaded = try loaded()
            let wasEnabled = wasInstalled ? try !disabled() : false
            let account = try provision()
            try SecureFiles.ensureDirectory(paths.base + "/private", owner: account.uid, mode: 0o700, group: account.gid)
            try SecureFiles.ensureDirectory(paths.runtime, owner: account.uid, mode: 0o755, group: account.gid)
            if existing == nil { try SecureFiles.atomicWrite(JSONEncoder().encode(controller), to: paths.authorization, mode: 0o644) }
            if !wasInstalled { try launch(["disable", service]) }
            if wasLoaded { try stopLoaded() }
            let binaryParent = URL(fileURLWithPath: paths.binary).deletingLastPathComponent().path
            if try SecureFiles.info(binaryParent) == nil { try SecureFiles.ensureDirectory(binaryParent, owner: fileOwner, mode: 0o755) }
            let plistParent = URL(fileURLWithPath: paths.plist).deletingLastPathComponent().path
            if try SecureFiles.info(plistParent) == nil { try SecureFiles.ensureDirectory(plistParent, owner: fileOwner, mode: 0o755) }
            try SecureFiles.atomicWrite(binary, to: paths.binary, mode: 0o755)
            try SecureFiles.atomicWrite(plist, to: paths.plist, mode: 0o644)
            if wasEnabled || wasLoaded {
                if wasEnabled { try launch(["enable", service]) }
                // An explicitly disabled but currently running service is restored without changing its boot policy.
                if !wasEnabled { try launch(["enable", service]) }
                do { try launch(["bootstrap", "system", paths.plist]) }
                catch { if !wasEnabled { try? launch(["disable", service]) }; throw error }
                if !wasEnabled { try launch(["disable", service]) }
                try waitUntilReady(paths.runtime)
                started = true
            }
        }
        return started
    }
    func start() throws {
        try locked {
            try requireInstalled()
            try launch(["enable", service])
            if try !loaded() { try launch(["bootstrap", "system", paths.plist]) }
            try launch(["kickstart", service])
            try waitUntilReady(paths.runtime)
        }
    }
    func stop() throws { try locked { try launch(["disable", service]); try stopLoaded() } }
    func uninstall() throws {
        try locked {
            try launch(["disable", service]); try stopLoaded()
            try SecureFiles.removeFile(paths.plist)
            try SecureFiles.removeFile(paths.binary)
        }
    }
}
