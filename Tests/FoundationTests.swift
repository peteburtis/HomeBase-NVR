import XCTest
import Foundation
import Darwin

final class FoundationTests: XCTestCase {
    let owner = Controller(uid: 501, accountUUID: UUID(uuidString: "00000000-0000-0000-0000-000000000501")!)
    func testLocalAuthorizationOnlyAcceptsAgentUser() {
        let auth = Authorization.local(501)
        XCTAssertTrue(auth.permits(uid: 501)); XCTAssertFalse(auth.permits(uid: 502)); XCTAssertFalse(auth.permits(uid: 0))
    }
    func testInstalledAuthorizationUsesUIDAndUUID() {
        let auth = Authorization.installed(owner)
        XCTAssertTrue(auth.permits(uid: 0))
        XCTAssertTrue(auth.permits(uid: 501, lookup: { _ in self.owner }))
        XCTAssertFalse(auth.permits(uid: 502, lookup: { _ in self.owner }))
        XCTAssertFalse(auth.permits(uid: 501, lookup: { Controller(uid: $0, accountUUID: UUID()) }))
        XCTAssertFalse(auth.permits(uid: 501, lookup: { _ in throw ServiceError("lookup failed") }))
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
        func run(_ path: String, _ args: [String]) throws -> ProcessResult {
            XCTAssertEqual(path, "/bin/launchctl")
            commands.append(args)
            if args.first == fail { return ProcessResult(status: 1, output: "injected failure") }
            switch args[0] {
            case "print": return ProcessResult(status: loaded ? 0 : 113, output: "")
            case "print-disabled": return ProcessResult(status: 0, output: "disabled services = {\n\t\"\(Paths.label)\" => \(disabled ? "disabled" : "enabled")\n}")
            case "disable": disabled = true
            case "enable": disabled = false
            case "bootstrap", "kickstart": loaded = true
            case "bootout": loaded = false
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
