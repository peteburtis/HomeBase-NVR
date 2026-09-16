import Foundation
import Darwin

struct CameraCredentials: Codable, Equatable {
    var schemaVersion = 1
    let username: String
    let password: String
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "SchemaVersion", username = "Username", password = "Password"
    }
    func validate() throws {
        guard schemaVersion == 1, CameraConfiguration.printable(username, limit: 512),
              CameraConfiguration.printable(password, limit: 512) else {
            throw ServiceError(.invalidMessage, "Camera credentials require SchemaVersion 1 and a username/password of 1...512 printable characters.")
        }
    }
}

struct CameraConfiguration: Codable, Equatable {
    var schemaVersion = 1
    var name: String
    var provider = "RTSP"
    let ipAddress: String
    var onvifPort: UInt16? = nil
    var rtspPort: UInt16 = 554
    var rtspURL: String? = nil
    var homebaseDeviceID: String? = nil
    var videoProfile: VideoProfile? = nil
    let credentials: CameraCredentials?
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "SchemaVersion", name = "Name", provider = "Provider"
        case ipAddress = "IPAddress", onvifPort = "ONVIFPort", rtspPort = "RTSPPort", credentials = "Credentials"
        case rtspURL = "RTSPURL"
        case homebaseDeviceID = "HomebaseDeviceID"
        case videoProfile = "VideoProfile"
    }
    static func printable(_ text: String, limit: Int) -> Bool {
        !text.isEmpty && text.count <= limit && text.utf8.count <= limit * 4 &&
        !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    static func validHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253 else { return false }
        var ipv6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 { return true }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
            label.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
        }
    }
    static func streamURL(_ input: String, host: String, port: UInt16) throws -> String? {
        if input.isEmpty { return nil }
        let address = host.contains(":") ? "[\(host)]" : host
        let url = input.hasPrefix("/") ? "rtsp://\(address):\(port)\(input)" : input
        guard printable(url, limit: 2048), let parts = URLComponents(string: url),
              ["rtsp", "rtsps"].contains(parts.scheme?.lowercased() ?? ""),
              parts.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased() == host.lowercased(),
              (parts.port ?? 554) == Int(port), parts.user == nil, parts.password == nil,
              parts.fragment == nil, !url.contains(where: { $0.isWhitespace }) else {
            throw ServiceError(.invalidMessage, "RTSP URL must match the camera host and RTSP port, use rtsp:// or rtsps://, and contain no embedded login, fragment, or whitespace. Store the login in Credentials.")
        }
        return url
    }
    var endpoint: String { "\(ipAddress.lowercased()):\(rtspPort)" }
    func validate() throws {
        guard schemaVersion == 1, ["RTSP", "ONVIF"].contains(provider) else {
            throw ServiceError(.invalidMessage, "Camera configuration requires SchemaVersion 1 and Provider RTSP or ONVIF.")
        }
        guard Self.printable(name, limit: 80), !name.trimmingCharacters(in: .whitespaces).isEmpty,
              Self.validHost(ipAddress), onvifPort == nil || onvifPort! > 0, rtspPort > 0 else {
            throw ServiceError(.invalidMessage, "Camera requires a name (1...80 printable characters), an IP address or hostname without a URL/port, and ports in 1...65535.")
        }
        if let rtspURL {
            guard !rtspURL.isEmpty else { throw ServiceError(.invalidMessage, "Omit RTSPURL if the stream URL is not yet known.") }
            _ = try Self.streamURL(rtspURL, host: ipAddress, port: rtspPort)
        }
        try credentials?.validate()
        if let videoProfile {
            try videoProfile.validate()
            guard rtspURL != nil else { throw ServiceError(.invalidMessage, "A selected video profile requires an RTSP URL.") }
        }
        if let homebaseDeviceID {
            guard Self.printable(homebaseDeviceID, limit: 512), homebaseDeviceID.hasPrefix("camera-") else {
                throw ServiceError(.invalidMessage, "Invalid Homebase camera hardware identifier.")
            }
        }
    }
}

/// Shared options workflow for add and a future change command. Inputs are a
/// configuration draft and current capabilities, not the import source.
/// Discovery, camera selection, confirmation, and persistence belong to callers.
/// This returns a validated draft; cancellation/errors never write configuration.
enum CameraOptionsEditor {
    static func edit(
        _ current: CameraConfiguration,
        profiles: [VideoProfile]?,
        askName: (String) throws -> String,
        chooseProfile: ([VideoProfile], Int?) throws -> Int,
        resolveStream: (VideoProfile) throws -> String
    ) throws -> CameraConfiguration {
        if let profiles {
            guard !profiles.isEmpty else { throw ServiceError("No video profiles are available.") }
            try profiles.forEach { try $0.validate() }
        }
        var draft = current
        draft.name = try askName(current.name)
        if let profiles {
            let defaultIndex: Int?
            if let saved = current.videoProfile {
                // Preserve the saved choice, not its position in a reordered list.
                // If it disappeared, require an explicit replacement.
                defaultIndex = profiles.firstIndex { $0.token == saved.token }
            } else {
                defaultIndex = VideoProfile.preferredIndex(profiles)
            }
            let index = try chooseProfile(profiles, defaultIndex)
            guard profiles.indices.contains(index) else { throw ServiceError(.invalidMessage, "Invalid video profile selection.") }
            let profile = profiles[index]
            draft.rtspURL = try resolveStream(profile)
            draft.videoProfile = profile
        }
        // No discoverable profiles (manual RTSP): retain its existing stream.
        try draft.validate()
        return draft
    }
}

// This is the only camera representation returned over IPC. It has no credential fields.
struct CameraSummary: Codable {
    let id: String
    let name: String
    let ipAddress: String
    let onvifPort: UInt16?
    let rtspPort: UInt16
    init(id: String, camera: CameraConfiguration) {
        self.id = id; name = camera.name; ipAddress = camera.ipAddress
        onvifPort = camera.onvifPort; rtspPort = camera.rtspPort
    }
}

enum CameraJSON {
    static func read(_ path: String, privateFile: Bool) throws -> Data {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ServiceError.posix("Open camera JSON at \(path)") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= 65536,
              !privateFile || ((info.st_uid == geteuid() || info.st_uid == 0) && info.st_mode & 0o077 == 0) else {
            throw ServiceError(.permission, "Camera JSON must be a regular file of at most 64 KiB; credential files must belong to this user or root and have no group/other access.")
        }
        // A bounded read also protects against a file growing after fstat.
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 65537) ?? Data()
        guard data.count <= 65536 else { throw ServiceError(.invalidMessage, "Camera JSON exceeds 64 KiB.") }
        return data
    }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value) + Data([10])
    }
}

struct CameraStore {
    let directory: String
    static let maximumCameras = 64
    private func prepare() throws {
        try SecureFiles.ensureDirectory(directory, owner: geteuid(), mode: 0o700)
    }
    private func entries() throws -> [(String, CameraConfiguration)] {
        try prepare()
        let files = try FileManager.default.contentsOfDirectory(atPath: directory).filter { $0.hasSuffix(".json") }.sorted()
        guard files.count <= Self.maximumCameras else { throw ServiceError("At most 64 cameras are supported in this increment.") }
        var endpoints = Set<String>()
        return try files.map { filename in
            let id = String(filename.dropLast(5))
            guard UUID(uuidString: id) != nil else { throw ServiceError("Camera JSON filenames must be UUIDs followed by .json.") }
            let data = try CameraJSON.read(directory + "/" + filename, privateFile: true)
            guard let camera = try? JSONDecoder().decode(CameraConfiguration.self, from: data) else {
                throw ServiceError(.invalidMessage, "Invalid camera JSON in \(filename). Check the documented schema.")
            }
            try camera.validate()
            guard endpoints.insert(camera.endpoint).inserted else { throw ServiceError("Duplicate camera endpoint in configuration.") }
            return (id, camera)
        }
    }
    func list() throws -> [CameraSummary] {
        try entries().map { CameraSummary(id: $0.0, camera: $0.1) }.sorted {
            ($0.name, $0.id) < ($1.name, $1.id)
        }
    }
    /// Private daemon input, never included in status or list replies.
    func configurations() throws -> [(String, CameraConfiguration)] { try entries() }
    func add(_ camera: CameraConfiguration) throws -> CameraSummary {
        try camera.validate()
        let existing = try entries()
        guard existing.count < Self.maximumCameras else { throw ServiceError("At most 64 cameras are supported in this increment.") }
        guard !existing.contains(where: { $0.1.endpoint == camera.endpoint }) else {
            throw ServiceError("That camera endpoint is already configured. Remove it before adding a replacement.")
        }
        let id = UUID().uuidString
        try SecureFiles.atomicWrite(CameraJSON.encode(camera), to: directory + "/" + id + ".json", mode: 0o600)
        return CameraSummary(id: id, camera: camera)
    }
    func remove(id: String) throws -> CameraSummary {
        guard UUID(uuidString: id) != nil else { throw ServiceError(.invalidMessage, "Invalid camera ID.") }
        guard let camera = try entries().first(where: { $0.0 == id }) else { throw ServiceError("Camera no longer exists. Run remove again.") }
        try SecureFiles.removeFile(directory + "/" + id + ".json")
        return CameraSummary(id: id, camera: camera.1)
    }
}

enum HomebaseImport {
    struct Endpoint: Decodable {
        let provider: String
        let ipAddress: String
        let onvifPort: UInt16?
        let rtspPort: UInt16?
        let credentialsPath: String
        var deviceID: String? = nil
        var alias: String? = nil
        var displayName: String? = nil
        var discoveryError: String? = nil
        var discoveryFailureCode: FailureCode? = nil
        enum CodingKeys: String, CodingKey {
            case provider = "Provider", ipAddress = "IPAddress", onvifPort = "ONVIFPort"
            case rtspPort = "RTSPPort", credentialsPath = "CredentialsPath"
        }
        var suggestedName: String {
            displayName ?? alias ?? deviceID.map { String($0.prefix(80)) } ?? "Camera at \(ipAddress.prefix(65))"
        }
        var label: String {
            let aliasLabel = alias.flatMap { $0 == suggestedName ? nil : " [\($0)]" } ?? ""
            let state = discoveryError == nil ? "" : " [discovery unavailable]"
            return "\(suggestedName)\(aliasLabel) — \(ipAddress):\(onvifPort ?? 80)\(state)"
        }
    }
    private struct Module: Decodable {
        let cameras: [Endpoint]
        enum CodingKeys: String, CodingKey { case cameras = "Cameras" }
    }
    static var defaultDirectory: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/HomeBase").path
    }
    static var installationMarkers: [String] {
        [
            "/usr/local/bin/homebase",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents/com.graygoolabs.homebase.agent.plist").path
        ]
    }
    // Detection is independent of the camera list: a fresh Homebase installation
    // should still advertise import. Existing configuration also permits imports
    // from a development installation or an explicitly supplied backup.
    static func shouldOfferImport(
        directory: String,
        markers: [String] = installationMarkers,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        exists(directory) || markers.contains(where: exists)
    }
    static func cameras(directory: String) throws -> [Endpoint] {
        let data = try CameraJSON.read(directory + "/modules/cameras.json", privateFile: false)
        guard let module = try? JSONDecoder().decode(Module.self, from: data) else {
            throw ServiceError(.invalidMessage, "Homebase modules/cameras.json does not contain a valid Cameras array.")
        }
        for camera in module.cameras {
            guard camera.provider.uppercased() == "ONVIF", CameraConfiguration.validHost(camera.ipAddress),
                  (camera.onvifPort ?? 80) > 0, (camera.rtspPort ?? 554) > 0,
                  CameraConfiguration.printable(camera.credentialsPath, limit: 1024) else {
                throw ServiceError(.invalidMessage, "Homebase camera has an invalid provider, address, port, or credential path.")
            }
        }
        return module.cameras
    }
    static func configuration(_ endpoint: Endpoint, name: String, directory: String) throws -> CameraConfiguration {
        let path = endpoint.credentialsPath.hasPrefix("/") ? endpoint.credentialsPath : directory + "/" + endpoint.credentialsPath
        let data = try CameraJSON.read(path, privateFile: true)
        guard let credentials = try? JSONDecoder().decode(CameraCredentials.self, from: data) else {
            throw ServiceError(.invalidMessage, "Homebase credentials must contain SchemaVersion, Username, and Password.")
        }
        let camera = CameraConfiguration(name: name, provider: "ONVIF", ipAddress: endpoint.ipAddress,
                                         onvifPort: endpoint.onvifPort ?? 80, rtspPort: endpoint.rtspPort ?? 554,
                                         homebaseDeviceID: endpoint.deviceID,
                                         credentials: credentials)
        try camera.validate()
        return camera
    }
}
