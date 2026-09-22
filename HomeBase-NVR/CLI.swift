import ArgumentParser
import Foundation
import Darwin
import os

@main
struct HBNVR: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hbnvr", abstract: "Manage the HomeBase NVR service.", version: BuildInfo.version,
        subcommands: [Install.self, Uninstall.self, Start.self, Stop.self, Status.self, Add.self, Remove.self, Camera.self, Store.self, Media.self, Decrypt.self, Agent.self])
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
                    if let bytes = store.playbackRAMBytes { print("    Playback RAM: \(bytes) bytes") }
                    if let local = store.local {
                        if local.retryingDestination { print("    Destination unavailable; reopening automatically with 1–30s backoff.") }
                        if local.retryingCameras > 0 { print("    Automatically retrying \(local.retryingCameras) camera(s), with 1–30s backoff; waiting for fresh keyframes.") }
                        if local.droppedEvents > 0 { print("    Queue overload: \(local.droppedEvents) dropped events (since startup)") }
                        if let warning = local.manifestWarning { print("    Playback index warning: \(warning) Video writes continue; indexing retries on new shards, without backfill.") }
                        if let warning = local.retentionWarning { print("    Retention warning: \(warning) Cleanup retries every 30s; recording continues.") }
                        if let warning = local.errorLogWarning { print("    \(warning)") }
                    }
                    if let s3 = store.s3 {
                        print("    Client-side encryption: \(s3.clientEncrypted == true ? "enabled for new objects" : "off for new objects")")
                        print("    S3: \(s3.acceptingRecording ? "accepting recording" : "not accepting recording"); \(s3.spooling ? "spooling (" + s3.reasons.joined(separator: ", ") + ")" : "immediate uploads")")
                        print("    Uploads: \(s3.active) active, \(s3.queued) queued, \(s3.retrying) retrying, \(s3.confirmedUploads) confirmed")
                        print("    RAM: \(s3.assemblingBytes) assembling + \(s3.residentBytes) finalized bytes; spool: \(s3.spoolCount) objects / \(s3.spoolBytes) bytes; unreadable: \(s3.unreadableSpoolCount ?? s3.quarantinedCount ?? 0)")
                        if let path = s3.spoolDirectory {
                            print("    Spool directory: \(path)")
                            if let free = s3.spoolVolumeAvailableBytes, let capacity = s3.spoolVolumeCapacityBytes {
                                print("    Spool volume: \(s3.spoolVolume ?? "unknown"); \(free) / \(capacity) bytes available; quota \(s3.spoolLimitBytes ?? 0), free-space reserve \(s3.spoolMinimumFreeBytes ?? 0) bytes")
                            } else { print("    Spool volume: unavailable; no fallback disk") }
                        }
                        if let age = s3.oldestBacklogSeconds { print("    Oldest backlog: \(Int(age))s") }
                        if let probe = s3.nextProbeSeconds { print("    Next recovery probe: \(Int(probe.rounded(.up)))s") }
                        if let retry = s3.nextReadRetrySeconds { print("    Next spool read check: \(Int(retry.rounded(.up)))s") }
                        print("    Retention: desired \(s3.desiredRetentionDays)d; \(s3.lifecycleState)\(s3.appliedRetentionDays.map { " (\($0)d)" } ?? "")")
                        if let warning = s3.lifecycleWarning { print("    \(warning)") }
                        if let pending = s3.pendingPlaybackManifests, pending > 0 { print("    Playback manifests: \(pending) pending publication") }
                        if let warning = s3.playbackWarning { print("    \(warning)") }
                        if let pending = s3.pendingThumbnails, pending > 0 { print("    Thumbnails: \(pending) rendering or awaiting upload") }
                        if let warning = s3.thumbnailWarning { print("    \(warning)") }
                    }
                }
            }
        }
    }
}

struct Decrypt: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Decrypt a downloaded HBNVR-encrypted recording, thumbnail, or manifest locally. Prompts for its password; no AWS access or daemon required. Never overwrites output.")
    @Argument(help: "Downloaded encrypted object (one complete object is held in RAM).") var input: String
    @Argument(help: "New output path (MP4, JPEG, or JSON); created with owner-only permissions.") var output: String
    func run() throws { try command {
        let password = try CameraPrompt.line("Recording encryption password", secret: true)
        try RecordingEncryption.decryptFile(input: input, output: output, password: password)
        print("Decrypted object saved to \(output).")
    } }
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
