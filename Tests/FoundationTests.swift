import XCTest
import Foundation
import Darwin

final class FoundationTests: XCTestCase {
    let owner = Controller(uid: 501, accountUUID: UUID(uuidString: "00000000-0000-0000-0000-000000000501")!)
    private func openDescriptorCount() -> Int {
        (0..<4096).reduce(0) { count, fd in
            count + (fcntl(Int32(fd), F_GETFD) >= 0 ? 1 : 0)
        }
    }
    func testRepeatedProcessRunsReleasePipesWithoutAutoreleasePoolDrain() throws {
        // Installed IPC authorization repeatedly runs dscl on long-lived workers.
        // An outer autorelease pool must not retain one pipe per authorization.
        _ = try Processes.run("/usr/bin/printf", ["warmup"])
        let before = openDescriptorCount()
        for _ in 0..<32 {
            let result = try Processes.run("/usr/bin/printf", ["authorized"])
            XCTAssertEqual(result.status, 0)
            XCTAssertEqual(result.output, "authorized")
        }
        XCTAssertLessThanOrEqual(openDescriptorCount(), before + 2)
    }
    func testFailedProcessLaunchesReleaseBothPipeEnds() {
        let before = openDescriptorCount()
        for _ in 0..<32 {
            XCTAssertThrowsError(try Processes.run("/nonexistent-hbnvr-test-executable", []))
        }
        XCTAssertLessThanOrEqual(openDescriptorCount(), before + 2)
    }
    func testProcessOutputAndExitStatusSurvivePipeCleanup() throws {
        let result = try Processes.run("/bin/sh", ["-c", "printf stdout; printf stderr >&2; exit 7"])
        XCTAssertEqual(result.status, 7)
        XCTAssertEqual(result.output, "stdoutstderr")
    }
    func testLocalAuthorizationOnlyAcceptsAgentUser() {
        let auth = Authorization.local(501)
        XCTAssertTrue(auth.permits(uid: 501)); XCTAssertFalse(auth.permits(uid: 502)); XCTAssertFalse(auth.permits(uid: 0))
        XCTAssertFalse(auth.permits(uid: 502, daemonUID: 502))
    }
    func testInstalledAuthorizationUsesUIDAndUUID() {
        let auth = Authorization.installed(owner)
        XCTAssertTrue(auth.permits(uid: 0, daemonUID: 400))
        XCTAssertTrue(auth.permits(uid: 501, daemonUID: 400, lookup: { _ in self.owner }))
        XCTAssertFalse(auth.permits(uid: 502, daemonUID: 400, lookup: { _ in self.owner }))
        XCTAssertFalse(auth.permits(uid: 501, daemonUID: 400, lookup: { Controller(uid: $0, accountUUID: UUID()) }))
        XCTAssertFalse(auth.permits(uid: 501, daemonUID: 400, lookup: { _ in throw ServiceError("lookup failed") }))
    }
    func testInstalledAuthorizationAcceptsDaemonUIDWithoutAccountLookup() {
        let auth = Authorization.installed(owner)
        XCTAssertTrue(auth.permits(uid: 400, daemonUID: 400, lookup: { _ in
            XCTFail("The daemon's own UID does not need a controller identity lookup.")
            throw ServiceError("lookup failed")
        }))
    }
    func testInstallerSelectsSudoUser() throws {
        let result = try Accounts.initialOwner(explicit: nil, sudoUID: "501", byUID: { XCTAssertEqual($0, 501); return self.owner })
        XCTAssertEqual(result, owner)
    }
    func testDirectRootNeedsExplicitOwner() {
        XCTAssertThrowsError(try Accounts.initialOwner(explicit: nil, sudoUID: nil))
        XCTAssertThrowsError(try Accounts.initialOwner(explicit: nil, sudoUID: "0"))
        XCTAssertThrowsError(try Accounts.initialOwner(explicit: nil, sudoUID: "bad"))
    }
    func testExplicitOwnerAndUpgradePreservation() throws {
        XCTAssertEqual(try Accounts.initialOwner(explicit: "operator", sudoUID: nil, byName: { XCTAssertEqual($0, "operator"); return self.owner }), owner)
        XCTAssertEqual(try Accounts.selectOwner(existing: owner, explicit: nil, sudoUID: "502"), owner)
        XCTAssertThrowsError(try Accounts.selectOwner(existing: owner, explicit: "someone", sudoUID: nil, byName: { _ in Controller(uid: 502, accountUUID: UUID()) }))
    }
    func testLockAndSymlinkProtection() throws {
        let path = temporary(); defer { try? FileManager.default.removeItem(atPath: path) }
        try SecureFiles.ensureDirectory(path, owner: geteuid(), mode: 0o700)
        let lock = try InstanceLock(path: path + "/lock")
        XCTAssertThrowsError(try InstanceLock(path: path + "/lock"))
        withExtendedLifetime(lock) {}
        try FileManager.default.createSymbolicLink(atPath: path + "/link", withDestinationPath: path + "/lock")
        XCTAssertThrowsError(try InstanceLock(path: path + "/link"))
        XCTAssertThrowsError(try SecureFiles.atomicWrite(Data(), to: path + "/link", mode: 0o600))
    }
    func testRuntimeDirectoryMustBePrivateAndOwned() throws {
        let path = temporary(); defer { try? FileManager.default.removeItem(atPath: path) }
        try SecureFiles.ensureDirectory(path, owner: geteuid(), mode: 0o755)
        XCTAssertThrowsError(try SecureFiles.ensureDirectory(path, owner: geteuid(), mode: 0o700))
        XCTAssertThrowsError(try SecureFiles.validateDirectory(path, owner: 0, mode: 0o755))
    }
    func testDirectoryErrorReportsRequiredAndObservedOwnerAndMode() throws {
        let path = temporary(); defer { try? FileManager.default.removeItem(atPath: path) }
        try SecureFiles.ensureDirectory(path, owner: geteuid(), mode: 0o755)
        XCTAssertThrowsError(try SecureFiles.validateDirectory(path, owner: geteuid(), mode: 0o700)) { error in
            let failure = error as? ServiceError
            XCTAssertEqual(failure?.code, .permission)
            XCTAssertTrue(failure?.message.contains(path) == true)
            XCTAssertTrue(failure?.message.contains("permissions 0700 (owner read/write/traverse; no group or other access)") == true)
            XCTAssertTrue(failure?.message.contains("Found: directory, owner") == true)
            XCTAssertTrue(failure?.message.contains("UID \(geteuid())") == true)
            XCTAssertTrue(failure?.message.contains("permissions 0755") == true)
        }
        // Different expected UID, without needing privilege to chown the fixture.
        XCTAssertThrowsError(try SecureFiles.validateDirectory(path, owner: geteuid() + 1, mode: 0o755)) { error in
            let message = (error as? ServiceError)?.message ?? ""
            XCTAssertTrue(message.contains("UID \(geteuid() + 1)")); XCTAssertTrue(message.contains("UID \(geteuid())"))
        }
        XCTAssertEqual(try XCTUnwrap(SecureFiles.info(path)).st_mode & 0o777, 0o755) // Diagnostics never repair silently.
    }
    func testDirectoryErrorDescribesMissingPathsFilesAndSymlinks() throws {
        let path = temporary(); defer { try? FileManager.default.removeItem(atPath: path) }
        try SecureFiles.ensureDirectory(path, owner: geteuid(), mode: 0o700)
        try SecureFiles.atomicWrite(Data(), to: path + "/file", mode: 0o600)
        try FileManager.default.createSymbolicLink(atPath: path + "/link", withDestinationPath: path)
        for (leaf, description) in [("missing", "path does not exist"), ("file", "regular file"), ("link", "symbolic link")] {
            XCTAssertThrowsError(try SecureFiles.validateDirectory(path + "/" + leaf, owner: geteuid(), mode: 0o700)) { error in
                let message = (error as? ServiceError)?.message ?? ""
                XCTAssertTrue(message.contains("Required: a directory (not a symbolic link)"))
                XCTAssertTrue(message.contains("Found: " + description))
                XCTAssertTrue(message.contains("permissions 0700"))
            }
        }
    }
    func testOversizeSocketPathRejected() {
        XCTAssertThrowsError(try SocketIO.address("/" + String(repeating: "x", count: 120)) { _, _ in () })
    }
    func testActualPeerCredentialsRejectUnlistedUID() throws {
        var pair = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { pair.forEach { close($0) } }
        let server = AgentServer(directory: "/unused", authorization: .local(geteuid() + 1), system: false)
        server.handle(pair[0], started: ProcessInfo.processInfo.systemUptime)
        let data = try SocketIO.read(fd: pair[1], deadline: ProcessInfo.processInfo.systemUptime + 1)
        XCTAssertEqual(try JSONDecoder().decode(Reply.self, from: data).code, .permission)
    }
    func testActualPeerCredentialsAcceptInstalledDaemonUser() throws {
        var pair = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { pair.forEach { close($0) } }
        let controller = Controller(uid: geteuid() + 1, accountUUID: UUID())
        let server = AgentServer(directory: "/unused", authorization: .installed(controller), system: false)
        let request = Request(protocolVersion: 1, operation: "status")
        try SocketIO.write(JSONEncoder().encode(request), fd: pair[1], deadline: ProcessInfo.processInfo.systemUptime + 1)
        server.handle(pair[0], started: ProcessInfo.processInfo.systemUptime)
        let data = try SocketIO.read(fd: pair[1], deadline: ProcessInfo.processInfo.systemUptime + 1)
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        XCTAssertNil(reply.error); XCTAssertNil(reply.code)
        XCTAssertEqual(reply.status?.ready, true)
        XCTAssertEqual(reply.status?.pid, getpid())
    }
    final class DirectoryMock {
        var records: [String: [String: String]] = [:]
        var writes: [[String]] = []
        func run(_ executable: String, _ args: [String]) throws -> ProcessResult {
            XCTAssertEqual(executable, "/usr/bin/dscl")
            let path = args[2]
            switch args[1] {
            case "-list":
                let output = records.filter { $0.key.hasPrefix(path + "/") }.compactMap { name, fields in fields[args[3]].map { "\(name.split(separator: "/").last!) \($0)" } }.joined(separator: "\n")
                return ProcessResult(status: 0, output: output)
            case "-read":
                guard let record = records[path] else { return ProcessResult(status: 185, output: "eDSRecordNotFound") }
                guard let value = record[args[3]] else { return ProcessResult(status: 0, output: "No such key: \(args[3])") }
                let key = args[3] == "IsHidden" ? "dsAttrTypeNative:IsHidden" : args[3]
                return ProcessResult(status: 0, output: "\(key): \(value)")
            case "-create":
                if args[3] == "GeneratedUID", records[path]?["GeneratedUID"] != nil {
                    return ProcessResult(status: 40, output: "eDSPermissionError")
                }
                writes.append(args)
                if records[path] == nil { records[path] = ["GeneratedUID": UUID().uuidString, "Password": "********"] }
                records[path]![args[3]] = args[4]
                return ProcessResult(status: 0, output: "")
            default: throw ServiceError("Unexpected mock operation")
            }
        }
    }
    func testProvisionPreservesAutomaticallyGeneratedUUIDs() throws {
        let directory = DirectoryMock()
        _ = try Accounts.provision(run: directory.run)
        let identities = directory.records.mapValues { $0["GeneratedUID"] }
        XCTAssertFalse(directory.writes.contains { $0[3] == "GeneratedUID" })
        directory.writes = []
        _ = try Accounts.provision(run: directory.run)
        XCTAssertTrue(directory.writes.isEmpty)
        XCTAssertEqual(directory.records.mapValues { $0["GeneratedUID"] }, identities)
    }
    func testProvisionRepairsObservedPartialRecordsWithoutChangingIdentity() throws {
        let directory = DirectoryMock()
        directory.records = [
            "/Users/_hbnvr": ["RealName": "HomeBase NVR service", "UniqueID": "401", "PrimaryGroupID": "401", "GeneratedUID": "C5732621-C2ED-4DF9-997F-403CF235363E"],
            "/Groups/_hbnvr": ["RealName": "HomeBase NVR service", "PrimaryGroupID": "401", "GeneratedUID": "28EC4EBE-1D23-4704-B7E8-C3F7B66A73D5", "Password": "*"]
        ]
        let result = try Accounts.provision(run: directory.run)
        XCTAssertEqual(result.uid, 401); XCTAssertEqual(result.gid, 401)
        XCTAssertEqual(directory.records["/Users/_hbnvr"]?["UserShell"], "/usr/bin/false")
        XCTAssertFalse(directory.writes.contains { ["GeneratedUID", "UniqueID", "PrimaryGroupID"].contains($0[3]) })
    }
    func testProvisionRepairsSettingsAndPrimaryGroupWithoutChangingIdentity() throws {
        let directory = DirectoryMock()
        directory.records = [
            "/Users/_hbnvr": ["RealName": "Old label", "UniqueID": "401", "PrimaryGroupID": "20", "UserShell": "/bin/zsh", "IsHidden": "0", "NFSHomeDirectory": "/var/empty", "GeneratedUID": UUID().uuidString],
            "/Groups/_hbnvr": ["RealName": "Old group", "PrimaryGroupID": "402", "GeneratedUID": UUID().uuidString]
        ]
        let result = try Accounts.provision(run: directory.run)
        XCTAssertEqual(result.uid, 401); XCTAssertEqual(result.gid, 402)
        XCTAssertEqual(directory.records["/Users/_hbnvr"]?["PrimaryGroupID"], "402")
        XCTAssertEqual(directory.records["/Users/_hbnvr"]?["UserShell"], "/usr/bin/false")
        XCTAssertFalse(directory.writes.contains { ["UniqueID", "GeneratedUID"].contains($0[3]) })
    }
    func testProvisionRejectsUIDCollisionBeforeWrites() {
        let directory = DirectoryMock()
        directory.records = ["/Users/_hbnvr": ["UniqueID": "401"], "/Users/someone": ["UniqueID": "401"]]
        XCTAssertThrowsError(try Accounts.provision(run: directory.run))
        XCTAssertTrue(directory.writes.isEmpty)
    }
    private func temporary() -> String { "/tmp/hbnvr-unit-" + UUID().uuidString }

    final class LaunchMock {
        var loaded = false, disabled = false
        var commands: [[String]] = []
        var fail: String?
        var removalPrints = 0, removalNeverCompletes = false
        var removalInspectionFailure: Int32?
        private(set) var removing = false
        func run(_ path: String, _ args: [String]) throws -> ProcessResult {
            XCTAssertEqual(path, "/bin/launchctl")
            commands.append(args)
            if args.first == fail { return ProcessResult(status: 1, output: "injected failure") }
            switch args[0] {
            case "print":
                if removing {
                    if let status = removalInspectionFailure { return ProcessResult(status: status, output: "injected inspection failure") }
                    if removalNeverCompletes { return ProcessResult(status: 0, output: "removal pending") }
                    if removalPrints > 0 { removalPrints -= 1; return ProcessResult(status: 0, output: "removal pending") }
                    loaded = false; removing = false
                }
                return ProcessResult(status: loaded ? 0 : 113, output: "")
            case "print-disabled": return ProcessResult(status: 0, output: "disabled services = {\n\t\"\(Paths.label)\" => \(disabled ? "disabled" : "enabled")\n}")
            case "disable": disabled = true
            case "enable": disabled = false
            case "bootstrap":
                guard !loaded else { return ProcessResult(status: 5, output: "Bootstrap failed: 5: Input/output error") }
                loaded = true
            case "kickstart": loaded = true
            case "bootout":
                removing = removalPrints > 0 || removalNeverCompletes || removalInspectionFailure != nil
                if !removing { loaded = false }
            default: XCTFail("Unexpected launchctl command")
            }
            return ProcessResult(status: 0, output: "")
        }
    }
    private func fixture(_ mock: LaunchMock) throws -> (String, Installer) {
        let root = temporary()
        try SecureFiles.ensureDirectory(root, owner: geteuid(), mode: 0o700)
        let source = root + "/source"
        try Data("binary".utf8).write(to: URL(fileURLWithPath: source))
        var installer = Installer()
        installer.paths = Paths(base: root + "/state", binary: root + "/bin/hbnvr", plist: root + "/daemons/hbnvr.plist")
        installer.fileOwner = geteuid()
        installer.run = mock.run
        installer.provision = { ServiceAccount(uid: geteuid(), gid: getegid()) }
        installer.embedded = { Data("plist".utf8) }
        installer.executable = { source }
        installer.readOwner = { try JSONDecoder().decode(Controller.self, from: Data(contentsOf: URL(fileURLWithPath: $0))) }
        installer.chooseOwner = { existing, _, _ in existing ?? self.owner }
        installer.waitUntilReady = { _ in }
        return (root, installer)
    }
    func testNewInstallRemainsDisabledAndStartStopAreIdempotent() throws {
        let mock = LaunchMock(), (root, installer) = try fixture(mock)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try installer.install(owner: nil)
        XCTAssertTrue(mock.disabled); XCTAssertFalse(mock.loaded)
        try installer.start(); try installer.start()
        XCTAssertFalse(mock.disabled); XCTAssertTrue(mock.loaded)
        XCTAssertEqual(mock.commands.filter { $0.first == "bootstrap" }.count, 1)
        try installer.stop(); try installer.stop()
        XCTAssertTrue(mock.disabled); XCTAssertFalse(mock.loaded)
    }
    func testUpgradeRestartsEnabledServiceAndPreservesOwner() throws {
        let mock = LaunchMock(), (root, installer) = try fixture(mock)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try installer.install(owner: nil); try installer.start()
        let before = try Data(contentsOf: URL(fileURLWithPath: installer.paths.authorization))
        XCTAssertTrue(try installer.install(owner: nil))
        XCTAssertTrue(mock.loaded); XCTAssertFalse(mock.disabled)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: installer.paths.authorization)), before)
        XCTAssertTrue(mock.commands.contains { $0.first == "bootout" })
    }
    func testUpgradeWaitsForLaunchdRemovalWithMissingOrReleasedLockAndPreservesBootPolicy() throws {
        for hasLock in [false, true] {
            for wasDisabled in [false, true] {
                let mock = LaunchMock()
                var (root, installer) = try fixture(mock)
                defer { try? FileManager.default.removeItem(atPath: root) }
                try installer.install(owner: nil); try installer.start()
                if hasLock { try SecureFiles.atomicWrite(Data(), to: installer.paths.runtime + "/agent.lock", mode: 0o600) }
                mock.disabled = wasDisabled; mock.removalPrints = 3
                try Data("replacement binary".utf8).write(to: URL(fileURLWithPath: root + "/source"))
                installer.embedded = { Data("replacement plist".utf8) }
                let paths = installer.paths
                var time: TimeInterval = 0, sleeps = 0
                installer.now = { time }
                installer.sleep = { interval in
                    time += interval; sleeps += 1
                    do {
                        let binary = try Data(contentsOf: URL(fileURLWithPath: paths.binary))
                        let plist = try Data(contentsOf: URL(fileURLWithPath: paths.plist))
                        XCTAssertEqual(binary, Data("binary".utf8))
                        XCTAssertEqual(plist, Data("plist".utf8))
                    } catch { XCTFail("Could not inspect installation while waiting: \(error)") }
                }
                XCTAssertTrue(try installer.install(owner: nil))
                XCTAssertEqual(sleeps, 3)
                XCTAssertTrue(mock.loaded); XCTAssertFalse(mock.removing)
                XCTAssertEqual(mock.disabled, wasDisabled)
                XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: installer.paths.binary)), Data("replacement binary".utf8))
                XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: installer.paths.plist)), Data("replacement plist".utf8))
            }
        }
    }
    func testUpgradeRemovalTimeoutPreservesInstallationAndDoesNotBootstrap() throws {
        let mock = LaunchMock()
        var (root, installer) = try fixture(mock)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try installer.install(owner: nil); try installer.start()
        mock.removalNeverCompletes = true
        try Data("replacement binary".utf8).write(to: URL(fileURLWithPath: root + "/source"))
        installer.embedded = { Data("replacement plist".utf8) }
        let bootstraps = mock.commands.filter { $0.first == "bootstrap" }.count
        var time: TimeInterval = 0
        installer.now = { time }; installer.sleep = { _ in time += 25 }
        XCTAssertThrowsError(try installer.install(owner: nil)) { XCTAssertEqual(($0 as? ServiceError)?.code, .timeout) }
        XCTAssertEqual(time, 75)
        XCTAssertEqual(mock.commands.filter { $0.first == "bootstrap" }.count, bootstraps)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: installer.paths.binary)), Data("binary".utf8))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: installer.paths.plist)), Data("plist".utf8))
    }
    func testUpgradeRemovalInspectionFailurePreservesInstallationAndDoesNotBootstrap() throws {
        let mock = LaunchMock()
        var (root, installer) = try fixture(mock)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try installer.install(owner: nil); try installer.start()
        mock.removalInspectionFailure = 77
        try Data("replacement binary".utf8).write(to: URL(fileURLWithPath: root + "/source"))
        installer.embedded = { Data("replacement plist".utf8) }
        installer.sleep = { _ in XCTFail("An inspection failure must not be treated as absence or retried.") }
        let bootstraps = mock.commands.filter { $0.first == "bootstrap" }.count
        XCTAssertThrowsError(try installer.install(owner: nil)) { error in
            XCTAssertEqual((error as? ServiceError)?.code, .failure)
            XCTAssertTrue((error as? ServiceError)?.message.contains("77") == true)
        }
        XCTAssertEqual(mock.commands.filter { $0.first == "bootstrap" }.count, bootstraps)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: installer.paths.binary)), Data("binary".utf8))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: installer.paths.plist)), Data("plist".utf8))
    }
    func testUpgradeWaitsForRuntimeLockAfterLaunchdRemoval() throws {
        let mock = LaunchMock()
        var (root, installer) = try fixture(mock)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try installer.install(owner: nil); try installer.start()
        let fd = open(installer.paths.runtime + "/agent.lock", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ServiceError.posix("Create fixture lock") }
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        mock.removalPrints = 2
        var time: TimeInterval = 0, sleeps = 0
        installer.now = { time }
        installer.sleep = { interval in
            time += interval; sleeps += 1
            if !mock.removing { XCTAssertEqual(flock(fd, LOCK_UN), 0) }
        }
        XCTAssertTrue(try installer.install(owner: nil))
        XCTAssertEqual(sleeps, 3)
        XCTAssertTrue(mock.loaded)
    }
    func testUpgradeRemovalAndRuntimeLockShareTimeoutAndPreserveInstallation() throws {
        let mock = LaunchMock()
        var (root, installer) = try fixture(mock)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try installer.install(owner: nil); try installer.start()
        let fd = open(installer.paths.runtime + "/agent.lock", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ServiceError.posix("Create fixture lock") }
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        mock.removalPrints = 1
        try Data("replacement binary".utf8).write(to: URL(fileURLWithPath: root + "/source"))
        installer.embedded = { Data("replacement plist".utf8) }
        let bootstraps = mock.commands.filter { $0.first == "bootstrap" }.count
        var time: TimeInterval = 0
        installer.now = { time }; installer.sleep = { _ in time += 25 }
        XCTAssertThrowsError(try installer.install(owner: nil)) { XCTAssertEqual(($0 as? ServiceError)?.code, .timeout) }
        XCTAssertEqual(time, 75)
        XCTAssertFalse(mock.loaded)
        XCTAssertEqual(mock.commands.filter { $0.first == "bootstrap" }.count, bootstraps)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: installer.paths.binary)), Data("binary".utf8))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: installer.paths.plist)), Data("plist".utf8))
    }
    func testStoppedUpgradeDoesNotStartService() throws {
        let mock = LaunchMock(), (root, installer) = try fixture(mock)
        defer { try? FileManager.default.removeItem(atPath: root) }
        XCTAssertFalse(try installer.install(owner: nil))
        XCTAssertFalse(try installer.install(owner: nil))
        XCTAssertFalse(mock.loaded); XCTAssertTrue(mock.disabled)
    }
    func testLaunchdStateParsingSupportsCurrentAndLegacyOutput() throws {
        for (value, expected) in [("disabled", true), ("enabled", false), ("true", true), ("false", false)] {
            XCTAssertEqual(try Installer.parseDisabledState("disabled services = {\n\t\"com.unrelated\" => disabled\n\t\"\(Paths.label)\" => \(value)\n}"), expected)
        }
        XCTAssertFalse(try Installer.parseDisabledState("disabled services = {\n\t\"com.unrelated\" => disabled\n}"))
        XCTAssertThrowsError(try Installer.parseDisabledState("\"\(Paths.label)\" => unexpected"))
        XCTAssertThrowsError(try Installer.parseDisabledState("\"\(Paths.label)\" =>"))
    }
    func testReadinessRetriesTransientFailuresThenSucceeds() throws {
        var time: TimeInterval = 0, attempts = 0
        try AgentReadiness.wait(directory: "/test", timeout: 1, now: { time }, sleep: { time += $0 }, probe: { directory, budget in
            XCTAssertEqual(directory, "/test"); XCTAssertLessThanOrEqual(budget, 1 - time)
            attempts += 1
            if attempts == 1 { throw ServiceError(.unavailable, "Socket not created yet") }
            if attempts == 2 { throw ServiceError(.timeout, "Still initializing") }
        })
        XCTAssertEqual(attempts, 3)
    }
    func testReadinessDeadlineIncludesProbeTime() {
        var time: TimeInterval = 0, attempts = 0
        XCTAssertThrowsError(try AgentReadiness.wait(directory: "/test", timeout: 6, now: { time }, sleep: { time += $0 }, probe: { _, budget in
            attempts += 1; time += budget
            throw ServiceError(.timeout, "No reply")
        })) { XCTAssertEqual(($0 as? ServiceError)?.code, .timeout) }
        XCTAssertEqual(time, 6, accuracy: 0.00001)
        XCTAssertEqual(attempts, 2)
    }
    func testReadinessDoesNotRetryPermanentFailures() {
        for code in [FailureCode.permission, .incompatible, .invalidMessage] {
            var attempts = 0
            XCTAssertThrowsError(try AgentReadiness.wait(directory: "/test", sleep: { _ in XCTFail("Unexpected retry") }, probe: { _, _ in
                attempts += 1; throw ServiceError(code, "Permanent failure")
            })) { XCTAssertEqual(($0 as? ServiceError)?.code, code) }
            XCTAssertEqual(attempts, 1)
        }
    }
    func testLifecycleWaitsOnlyWhenStartingAndPropagatesReadinessFailure() throws {
        let mock = LaunchMock()
        var (root, installer) = try fixture(mock)
        defer { try? FileManager.default.removeItem(atPath: root) }
        var checks = 0
        installer.waitUntilReady = { directory in
            XCTAssertTrue(mock.loaded)
            XCTAssertEqual(directory, root + "/state/run")
            checks += 1
        }
        try installer.install(owner: nil)
        XCTAssertEqual(checks, 0)
        try installer.start(); try installer.start()
        XCTAssertEqual(checks, 2)
        try installer.install(owner: nil)
        XCTAssertEqual(checks, 3)
        installer.waitUntilReady = { _ in throw ServiceError(.timeout, "Not ready") }
        XCTAssertThrowsError(try installer.start()) { XCTAssertEqual(($0 as? ServiceError)?.code, .timeout) }
        XCTAssertThrowsError(try installer.install(owner: nil)) { XCTAssertEqual(($0 as? ServiceError)?.code, .timeout) }
        try installer.stop()
        XCTAssertFalse(try installer.install(owner: nil))
    }
    func testLaunchctlFailureDoesNotReportSuccessOrDeleteInstallation() throws {
        let mock = LaunchMock(), (root, installer) = try fixture(mock)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try installer.install(owner: nil); try installer.start()
        mock.fail = "bootout"
        XCTAssertThrowsError(try installer.uninstall())
        XCTAssertTrue(FileManager.default.fileExists(atPath: installer.paths.binary))
        XCTAssertTrue(FileManager.default.fileExists(atPath: installer.paths.plist))
    }
    func testUninstallPreservesStateAndIsRepeatable() throws {
        let mock = LaunchMock(), (root, installer) = try fixture(mock)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try installer.install(owner: nil); try installer.start(); try installer.uninstall(); try installer.uninstall()
        XCTAssertFalse(mock.loaded); XCTAssertTrue(mock.disabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.paths.binary))
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.paths.plist))
        XCTAssertTrue(FileManager.default.fileExists(atPath: installer.paths.authorization))
        XCTAssertTrue(FileManager.default.fileExists(atPath: installer.paths.base + "/private"))
    }
}
