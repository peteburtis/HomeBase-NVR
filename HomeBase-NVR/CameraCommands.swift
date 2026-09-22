import ArgumentParser
import Foundation
import Darwin

enum CameraPrompt {
    static func line(_ prompt: String, default fallback: String? = nil, secret: Bool = false) throws -> String {
        let suffix = fallback.map { " [\($0)]" } ?? ""
        let message = prompt + suffix + ": "
        let value: String
        if secret {
            // Restores terminal settings on signals and refuses nonterminal input.
            var buffer = [CChar](repeating: 0, count: 4096)
            defer { _ = buffer.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
            guard readpassphrase(message, &buffer, buffer.count, RPP_REQUIRE_TTY) != nil else {
                throw ServiceError("Password entry requires a terminal, or was cancelled.")
            }
            value = String(cString: buffer)
        } else {
            FileHandle.standardError.write(Data(message.utf8))
            guard let input = readLine() else { throw ServiceError("Input ended; no configuration changes were made.") }
            value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? fallback ?? "" : value
    }
    static func choose(_ labels: [String], title: String, defaultIndex: Int? = nil) throws -> Int {
        print(title)
        for (index, label) in labels.enumerated() { print("  \(index + 1). \(label)") }
        while true {
            let answer = try line("Choose 1...\(labels.count) (q to cancel)", default: defaultIndex.map { String($0 + 1) })
            if answer.lowercased() == "q" { throw ServiceError("Cancelled; no configuration changes were made.") }
            if let number = Int(answer), labels.indices.contains(number - 1) { return number - 1 }
            print("Please choose a listed number.")
        }
    }
    static func port(_ title: String, default value: UInt16) throws -> UInt16 {
        while true {
            if let port = UInt16(try line(title, default: String(value))), port > 0 { return port }
            print("Enter a port from 1 to 65535.")
        }
    }
    static func confirm(_ message: String) throws -> Bool {
        let answer = try line(message, default: "no").lowercased()
        return answer == "y" || answer == "yes"
    }
}

/// The same name/profile editor is used by add and change.
enum CameraOptionsUI {
    static func name(_ current: String) throws -> String { try CameraPrompt.line("Camera name", default: current) }
    static func choose(_ profiles: [VideoProfile], defaultIndex: Int?, current: VideoProfile?) throws -> Int {
        let hint = current == nil ? "default: nearest 720p"
            : defaultIndex == nil ? "saved profile unavailable; choose a replacement" : "default: saved profile"
        return try CameraPrompt.choose(profiles.map(\.label), title: "Video quality (\(hint))", defaultIndex: defaultIndex)
    }
    static func edit(_ current: CameraConfiguration, client: ONVIFClient, media: ONVIFClient.Media) throws -> CameraConfiguration {
        try CameraOptionsEditor.edit(current, profiles: media.profiles, askName: name, chooseProfile: { profiles, defaultIndex in
            try choose(profiles, defaultIndex: defaultIndex, current: current.videoProfile)
        }, resolveStream: {
            try client.stream(profile: $0, media: media, deadline: ProcessInfo.processInfo.systemUptime + 5)
        })
    }
}

enum ResourceSelection {
    static func select<T>(_ values: [T], selector: String?, id: (T) -> String, name: (T) -> String,
                          label: (T) -> String, kind: String) throws -> T {
        let matches: [T]
        if let selector, let exact = values.first(where: { id($0) == selector }) { return exact }
        if let selector { matches = values.filter { name($0) == selector } } else { matches = values }
        guard !matches.isEmpty else { throw ServiceError("No matching \(kind)s.") }
        if selector != nil, matches.count == 1 { return matches[0] }
        guard isatty(STDIN_FILENO) == 1 else { throw ServiceError("Specify an unambiguous \(kind) name or UUID when not using a terminal.") }
        return matches[try CameraPrompt.choose(matches.map(label), title: "Choose a \(kind)")]
    }
}

struct Camera: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Configure cameras and persist streaming/recording controls. No sudo.",
        subcommands: [Add.self, CameraList.self, CameraChange.self, Remove.self, CameraEnable.self, CameraDisable.self, CameraStart.self, CameraStop.self, CameraTag.self])
}
struct CameraTag: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "tag", abstract: "Read or change opaque tags for future frames only. Changes persist; historical footage is never edited.",
        subcommands: [CameraTagList.self, CameraTagSet.self, CameraTagRemove.self])
}
enum CameraTagCommand {
    static func run(_ operation: String, target: CameraTarget, key: String? = nil, value: String? = nil) throws {
        let (connection, camera) = try target.selected()
        let reply = try connection.send(Request(protocolVersion: 1, operation: "cameras.tags." + operation,
            cameraID: camera.id, tagKey: key, tagValue: value))
        guard let tags = reply.tags else { throw ServiceError("Agent did not confirm tags; update HBNVR before using this command.") }
        // JSON escapes arbitrary strings safely, including terminal control characters.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        print(String(decoding: try encoder.encode(tags), as: UTF8.self))
    }
}
struct CameraTagList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "Show the current tag dictionary as JSON.")
    @OptionGroup var target: CameraTarget
    func run() throws { try command { try CameraTagCommand.run("get", target: target) } }
}
struct CameraTagSet: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Set one tag for subsequent frames; preserve other keys. Empty values are valid.")
    @OptionGroup var target: CameraTarget
    @Option var key: String
    @Option var value: String
    func run() throws { try command { try CameraTagCommand.run("set", target: target, key: key, value: value) } }
}
struct CameraTagRemove: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Stop applying one tag to subsequent frames. Does not erase historical tags.")
    @OptionGroup var target: CameraTarget
    @Option var key: String
    func run() throws { try command { try CameraTagCommand.run("remove", target: target, key: key) } }
}
struct CameraTarget: ParsableArguments {
    @Option(help: "Local agent runtime directory; omit for the installed service.") var runtimeDir: String?
    @Argument(help: "Camera name or UUID. Omit for an interactive picker.") var selector: String?
    func selected() throws -> (CameraConnection, CameraSummary) {
        let connection = try CameraConnection(runtimeDir: runtimeDir)
        let selected = try ResourceSelection.select(connection.list(), selector: selector, id: { $0.id }, name: { $0.name },
            label: { "\($0.name) — \($0.ipAddress):\($0.rtspPort) [\($0.id)]" }, kind: "camera")
        return (connection, selected)
    }
}
struct CameraList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List camera configuration and persistent state without credentials.")
    @Option var runtimeDir: String?
    @Flag(help: "Print JSON.") var json = false
    func run() throws { try command {
        let cameras = try CameraConnection(runtimeDir: runtimeDir).list()
        if json { print(String(decoding: try CameraJSON.encode(cameras), as: UTF8.self)) }
        else if cameras.isEmpty { print("No cameras are configured.") }
        else { for camera in cameras {
            print("\(camera.name) [\(camera.id)] — \(camera.enabled ? "enabled" : "disabled"), recording intent: \(camera.recordingStarted ? "started" : "stopped")")
            if let profile = camera.videoProfile { print("  \(profile.label)") }
        } }
    } }
}
struct CameraChange: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "change", abstract: "Edit camera name and video profile. Login and persistent controls are preserved; no camera hardware settings are changed.")
    @OptionGroup var target: CameraTarget
    func run() throws { try command {
        let (connection, camera) = try target.selected()
        guard let options = try connection.send(Request(protocolVersion: 1, operation: "cameras.options", cameraID: camera.id)).cameraOptions else {
            throw ServiceError("Agent does not support camera editing; install hbnvr 0.6.0 or newer.")
        }
        let (name, profile) = try CameraOptionsEditor.select(name: options.name, profile: options.selectedProfile, profiles: options.profiles,
            askName: CameraOptionsUI.name, chooseProfile: { try CameraOptionsUI.choose($0, defaultIndex: $1, current: options.selectedProfile) })
        if options.profiles == nil { print("RTSP-only camera: keeping its configured stream URL.") }
        guard try CameraPrompt.confirm("Save these camera options? Any active shard will be finalized.") else { print("Cancelled; no changes made."); return }
        let edit = CameraEdit(name: name, profileToken: profile?.token, revision: options.revision)
        let reply = try connection.send(Request(protocolVersion: 1, operation: "cameras.change", cameraID: camera.id, cameraEdit: edit))
        guard reply.camera?.id == camera.id else { throw ServiceError("Agent did not confirm the change; check camera list before retrying.") }
        print("Updated \(name).")
    } }
}
enum CameraControl {
    static func run(_ operation: String, target: CameraTarget) throws {
        let (connection, camera) = try target.selected()
        let reply = try connection.send(Request(protocolVersion: 1, operation: "cameras." + operation, cameraID: camera.id))
        guard let saved = reply.camera, saved.id == camera.id else { throw ServiceError("Agent did not confirm camera control; check camera list before retrying.") }
        print("\(saved.name): \(saved.enabled ? "enabled" : "disabled"), recording intent: \(saved.recordingStarted ? "started" : "stopped") (saved).")
    }
}
struct CameraEnable: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "enable", abstract: "Persistently enable streaming; resume recording if its saved state is started.")
    @OptionGroup var target: CameraTarget
    func run() throws { try command { try CameraControl.run("enable", target: target) } }
}
struct CameraDisable: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "disable", abstract: "Finalize recording and persistently disconnect; preserve recording intent.")
    @OptionGroup var target: CameraTarget
    func run() throws { try command { try CameraControl.run("disable", target: target) } }
}
struct CameraStart: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "start", abstract: "Persist recording intent for an enabled camera; resume across reconnects/restarts. Wait if no store is usable.")
    @OptionGroup var target: CameraTarget
    func run() throws { try command { try CameraControl.run("start", target: target) } }
}
struct CameraStop: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop", abstract: "Persistently stop recording and finalize its shard; leave streaming enabled.")
    @OptionGroup var target: CameraTarget
    func run() throws { try command { try CameraControl.run("stop", target: target) } }
}

struct CameraConnection {
    let directory: String
    let uid: uid_t
    init(runtimeDir: String?) throws {
        directory = runtimeDir ?? Paths.system.runtime
        uid = try runtimeDir == nil ? Accounts.lookup(name: "_hbnvr").uid : geteuid()
    }
    func send(_ request: Request) throws -> Reply {
        try SocketClient.exchange(request, directory: directory, expectedUID: uid)
    }
    func list() throws -> [CameraSummary] {
        guard let cameras = try send(Request(protocolVersion: 1, operation: "cameras.list")).cameras else {
            throw ServiceError(.invalidMessage, "Agent did not return a camera list.")
        }
        return cameras
    }
}

struct Add: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Interactively add an RTSP camera, manually or by copying Homebase configuration. No sudo; agent must be running.")
    @Option(help: "Local agent runtime directory. Omit to configure the installed service.") var runtimeDir: String?
    @Option(help: "Homebase configuration directory (default: ~/Library/Application Support/HomeBase).") var homebaseDir: String?
    func run() throws {
        try command {
            let connection = try CameraConnection(runtimeDir: runtimeDir)
            _ = try connection.list() // Fail before asking for credentials if unavailable/unauthorized.
            let directory = homebaseDir ?? HomebaseImport.defaultDirectory
            var imported: CameraConfiguration?
            if HomebaseImport.shouldOfferImport(directory: directory) {
                let source = try CameraPrompt.choose(["Import from Homebase", "Enter camera details manually"], title: "Add a camera")
                if source == 0 {
                    let endpoints: [HomebaseImport.Endpoint]
                    do {
                        print("Discovering cameras directly (Homebase need not be running)...")
                        endpoints = try HomebaseCameraDiscovery.discover(directory: directory)
                        if endpoints.isEmpty { print("Homebase has no cameras to import.") }
                    } catch {
                        let reason = (error as? ServiceError)?.message ?? "The camera configuration could not be read."
                        print("Homebase import is unavailable: \(reason)")
                        endpoints = []
                    }
                    if endpoints.isEmpty {
                        print("Continuing with manual camera setup.")
                    } else {
                        let index = try CameraPrompt.choose(endpoints.map(\.label), title: "Homebase cameras")
                        let endpoint = endpoints[index]
                        if let error = endpoint.discoveryError { throw ServiceError(endpoint.discoveryFailureCode ?? .failure, "Could not discover this camera: \(error) No configuration was saved; check the camera and retry.") }
                        let camera = try HomebaseImport.configuration(endpoint, name: endpoint.suggestedName, directory: directory)
                        let client = ONVIFClient(endpoint: endpoint, credentials: camera.credentials!)
                        print("Reading available video qualities...")
                        let media = try client.media(expectedID: endpoint.deviceID, deadline: ProcessInfo.processInfo.systemUptime + 12)
                        imported = try CameraOptionsUI.edit(camera, client: client, media: media)
                    }
                }
            } else {
                print("Homebase was not detected. Enter camera details manually.")
            }
            var camera: CameraConfiguration
            if let imported {
                camera = imported
            } else {
                let name = try CameraPrompt.line("Camera name")
                let host = try CameraPrompt.line("IP address or hostname (no URL or port)")
                let rtspPort = try CameraPrompt.port("RTSP port", default: 554)
                let username = try CameraPrompt.line("Camera username (blank for no authentication)")
                let credentials: CameraCredentials?
                if username.isEmpty { credentials = nil }
                else {
                    credentials = CameraCredentials(username: username, password: try CameraPrompt.line("Camera password", secret: true))
                }
                camera = CameraConfiguration(name: name, ipAddress: host, rtspPort: rtspPort, credentials: credentials)
                let stream = try CameraPrompt.line("RTSP path or full URL, without login (blank to configure later)")
                camera.rtspURL = try CameraConfiguration.streamURL(stream, host: camera.ipAddress, port: camera.rtspPort)
                try camera.validate()
            }
            print("\(camera.name) — \(camera.ipAddress), RTSP port \(camera.rtspPort)")
            if let profile = camera.videoProfile { print("Video: \(profile.label)") }
            if camera.rtspURL == nil { print("Stream URL is unset; it will be needed before recording can be enabled.") }
            guard try CameraPrompt.confirm("Save this camera and its login to HBNVR?") else { print("Cancelled; no changes made."); return }
            let reply = try connection.send(Request(protocolVersion: 1, operation: "cameras.add", camera: camera))
            guard let saved = reply.camera else { throw ServiceError(.invalidMessage, "Agent did not confirm the added camera. Check configuration before retrying.") }
            print("Added \(saved.name) (\(saved.id)). Enabled stores will record automatically.")
        }
    }
}

struct Remove: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Interactively remove a camera and its HBNVR credential copy. Homebase is unchanged. No sudo; agent must be running.")
    @OptionGroup var target: CameraTarget
    func run() throws {
        try command {
            let (connection, camera) = try target.selected()
            guard try CameraPrompt.confirm("Remove \(camera.name) and its saved HBNVR login?") else { print("Cancelled; no changes made."); return }
            let reply = try connection.send(Request(protocolVersion: 1, operation: "cameras.remove", cameraID: camera.id))
            guard reply.camera?.id == camera.id else { throw ServiceError(.invalidMessage, "Agent did not confirm removal. Check configuration before retrying.") }
            print("Removed \(camera.name) and its HBNVR credential copy. Homebase was not changed.")
        }
    }
}
