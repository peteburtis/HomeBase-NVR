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
            guard let input = readLine() else { throw ServiceError("Input ended; no camera changes were made.") }
            value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? fallback ?? "" : value
    }
    static func choose(_ labels: [String], title: String, defaultIndex: Int? = nil) throws -> Int {
        print(title)
        for (index, label) in labels.enumerated() { print("  \(index + 1). \(label)") }
        while true {
            let answer = try line("Choose 1...\(labels.count) (q to cancel)", default: defaultIndex.map { String($0 + 1) })
            if answer.lowercased() == "q" { throw ServiceError("Cancelled; no camera changes were made.") }
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

/// Reusable UX adapter. A future change command will pass saved configuration
/// into this same flow after selecting a camera and refreshing its capabilities.
enum CameraOptionsUI {
    static func edit(_ current: CameraConfiguration, client: ONVIFClient, media: ONVIFClient.Media) throws -> CameraConfiguration {
        try CameraOptionsEditor.edit(current, profiles: media.profiles, askName: {
            try CameraPrompt.line("Camera name", default: $0)
        }, chooseProfile: { profiles, defaultIndex in
            let hint = current.videoProfile == nil ? "default: nearest 720p"
                : defaultIndex == nil ? "saved profile unavailable; choose a replacement" : "default: saved profile"
            return try CameraPrompt.choose(profiles.map(\.label), title: "Video quality (\(hint))", defaultIndex: defaultIndex)
        }, resolveStream: {
            try client.stream(profile: $0, media: media, deadline: ProcessInfo.processInfo.systemUptime + 5)
        })
    }
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
            print("Added \(saved.name) (\(saved.id)). Configuration saved; recording is not implemented yet.")
        }
    }
}

struct Remove: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Interactively remove a camera and its HBNVR credential copy. Homebase is unchanged. No sudo; agent must be running.")
    @Option(help: "Local agent runtime directory. Omit to configure the installed service.") var runtimeDir: String?
    func run() throws {
        try command {
            let connection = try CameraConnection(runtimeDir: runtimeDir)
            let cameras = try connection.list()
            guard !cameras.isEmpty else { print("No cameras are configured."); return }
            let index = try CameraPrompt.choose(cameras.map { "\($0.name) — \($0.ipAddress):\($0.rtspPort) [\($0.id)]" }, title: "Remove a camera")
            let camera = cameras[index]
            guard try CameraPrompt.confirm("Remove \(camera.name) and its saved HBNVR login?") else { print("Cancelled; no changes made."); return }
            let reply = try connection.send(Request(protocolVersion: 1, operation: "cameras.remove", cameraID: camera.id))
            guard reply.camera?.id == camera.id else { throw ServiceError(.invalidMessage, "Agent did not confirm removal. Check configuration before retrying.") }
            print("Removed \(camera.name) and its HBNVR credential copy. Homebase was not changed.")
        }
    }
}
