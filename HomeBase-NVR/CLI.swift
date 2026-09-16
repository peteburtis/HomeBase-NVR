import ArgumentParser
import Foundation
import Darwin
import os

@main
struct HBNVR: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hbnvr", abstract: "Manage the HomeBase NVR service.", version: BuildInfo.version,
        subcommands: [Install.self, Uninstall.self, Start.self, Stop.self, Status.self, Add.self, Remove.self, Camera.self, Store.self, Agent.self])
}

func command(_ work: () throws -> Void) throws {
    do { try work() }
    catch let error as ServiceError {
        Logger(subsystem: "com.graygoolabs.hbnvr", category: "cli").error("\(error.message, privacy: .public)")
        FileHandle.standardError.write(Data("Error: \(error.message)\n".utf8))
        throw ExitCode(error.code.rawValue)
    }
    catch {
        let message = String(describing: error)
        Logger(subsystem: "com.graygoolabs.hbnvr", category: "cli").error("\(message, privacy: .public)")
        FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
        throw ExitCode.failure
    }
}

func rootOnly() throws {
    guard geteuid() == 0 else { throw ServiceError(.permission, "This command requires sudo and only manages the system installation.") }
}

struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Install or upgrade the system service (sudo required). New installations remain disabled.")
    @Option(help: "Initial controller account; required for direct-root installation without SUDO_UID.") var owner: String?
    func run() throws {
        try command {
            try rootOnly()
            let started = try Installer().install(owner: owner)
            print(started
                ? "Installed hbnvr. Service restarted."
                : "Installed hbnvr. Use sudo hbnvr start to enable and start the service.")
        }
    }
}
struct Uninstall: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop and remove the system service (sudo required). Preserve its account, authorization, and private data.")
    func run() throws { try command { try rootOnly(); try Installer().uninstall(); print("Uninstalled hbnvr. Service account, authorization, and private data were preserved.") } }
}
struct Start: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Start the system service and enable startup at boot (sudo required).")
    func run() throws { try command { try rootOnly(); try Installer().start(); print("hbnvr is enabled and started.") } }
}
struct Stop: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop the system service and disable startup at boot (sudo required).")
    func run() throws { try command { try rootOnly(); try Installer().stop(); print("hbnvr is stopped and disabled.") } }
}
struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Query the installed service, or an isolated local agent, without sudo.")
    @Option(help: "Local agent runtime directory. Omit to query the system service.") var runtimeDir: String?
    @Flag(help: "Print a structured JSON response.") var json = false
    func run() throws {
        try command {
            let reply = try SocketClient.status(directory: runtimeDir ?? Paths.system.runtime)
            if json {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                print(String(decoding: try encoder.encode(reply), as: UTF8.self))
            } else if let status = reply.status {
                print("hbnvr ready — version \(status.version), PID \(status.pid), uptime \(Int(status.uptimeSeconds))s")
                for stream in status.streams ?? [] {
                    print("  \(stream.name): \(stream.state) — \(stream.frames) frames, \(String(format: "%.1f", stream.framesPerSecond)) fps, \(String(format: "%.1f", stream.receiveKbps)) kb/s (\(stream.mode))")
                    print("    \(stream.enabled ? "enabled" : "disabled"), recording intent: \(stream.recordingStarted ? "started" : "stopped"); recording: \(stream.recordingState)")
                    if let error = stream.lastError { print("    \(error)") }
                }
                for store in status.stores ?? [] {
                    print("  Store \(store.name): \(store.state) — \(store.activeRecordings) active, \(store.completedShards) completed shards, \(store.pendingBytes) queued bytes")
                    if let error = store.lastError { print("    \(error)") }
                }
            }
        }
    }
}
struct Agent: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run in the foreground. Local mode requires no installation or sudo.")
    @Option(help: "Private local runtime directory (default: ~/Library/Caches/HomeBase-NVR/run).") var runtimeDir: String?
    @Flag(help: "Use installed configuration as the _hbnvr service account (for launchd).") var system = false
    func validate() throws {
        if system && runtimeDir != nil { throw ValidationError("--system and --runtime-dir cannot be combined.") }
    }
    func run() throws {
        try command {
            guard geteuid() != 0 else { throw ServiceError(.permission, "Run local agents without sudo; launchd runs the system agent as _hbnvr.") }
            umask(0o077)
            let authorization: Authorization
            let directory: String
            if system {
                let account = try Accounts.lookup(name: "_hbnvr")
                guard account.uid == geteuid() else { throw ServiceError(.permission, "System mode requires the _hbnvr account.") }
                try SecureFiles.validateSystemAncestors(of: Paths.system.runtime)
                authorization = .installed(try SecureFiles.readAuthorization(Paths.system.authorization))
                directory = Paths.system.runtime
                try SecureFiles.validateDirectory(directory, owner: account.uid, mode: 0o755)
            } else {
                authorization = .local(geteuid())
                directory = runtimeDir ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/HomeBase-NVR/run").path
                try SecureFiles.ensureDirectory(directory, owner: geteuid(), mode: 0o700)
            }
            try AgentServer(directory: directory, authorization: authorization, system: system).run()
        }
    }
}
