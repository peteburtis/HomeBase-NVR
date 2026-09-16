import Foundation
import CryptoKit

struct VideoProfile: Codable, Equatable {
    let token: String
    let encoding: String
    let width: Int
    let height: Int
    let frameRate: Double?
    let bitrateKbps: Int?
    enum CodingKeys: String, CodingKey {
        case token = "Token", encoding = "Encoding", width = "Width", height = "Height"
        case frameRate = "FrameRate", bitrateKbps = "BitrateKbps"
    }
    func validate() throws {
        guard CameraConfiguration.printable(token, limit: 512), ["H264", "H265"].contains(encoding),
              (1...16384).contains(width), (1...16384).contains(height),
              frameRate.map({ $0.isFinite && $0 > 0 && $0 <= 1000 }) ?? true,
              bitrateKbps.map({ (1...1_000_000).contains($0) }) ?? true else {
            throw ServiceError(.invalidMessage, "Invalid or unsupported video profile.")
        }
    }
    var label: String {
        var result = "\(width) x \(height), \(encoding)"
        if let frameRate { result += ", \(frameRate.formatted()) fps" }
        if let bitrateKbps { result += ", \(bitrateKbps) kbps" }
        return result
    }
    static func preferredIndex(_ profiles: [VideoProfile]) -> Int {
        profiles.indices.min {
            let left = profiles[$0], right = profiles[$1]
            let a = abs(left.width * left.height - 1280 * 720), b = abs(right.width * right.height - 1280 * 720)
            if a != b { return a < b }
            if left.encoding != right.encoding { return left.encoding == "H264" }
            return (left.bitrateKbps ?? Int.max) < (right.bitrateKbps ?? Int.max)
        } ?? 0
    }
}

// A bounded, namespace-aware tree for the small read-only SOAP responses we use.
// External entities and DTDs are prohibited; raw camera responses never enter logs.
final class ONVIFXML: NSObject, XMLParserDelegate {
    final class Node {
        let name: String
        let attributes: [String: String]
        var children: [Node] = []
        var text = ""
        init(_ name: String, _ attributes: [String: String]) { self.name = name; self.attributes = attributes }
        func child(_ name: String) -> Node? { children.first { $0.name == name } }
        func value(_ name: String) -> String? { child(name)?.text.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    private var stack: [Node] = []
    private var root: Node?
    private var count = 0
    static func response(_ data: Data, operation: String) throws -> Node {
        guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8),
              !text.localizedCaseInsensitiveContains("<!DOCTYPE"), !text.localizedCaseInsensitiveContains("<!ENTITY") else {
            throw ServiceError(.invalidMessage, "Unsafe or oversized camera XML.")
        }
        let delegate = ONVIFXML(), parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), let envelope = delegate.root, envelope.name == "Envelope",
              let body = envelope.child("Body") else { throw ServiceError(.invalidMessage, "Malformed camera SOAP response.") }
        if body.child("Fault") != nil {
            if text.localizedCaseInsensitiveContains("NotAuthorized") {
                throw ServiceError(.permission, "Camera rejected ONVIF authentication. Check camera credentials and clock synchronization.")
            }
            throw ServiceError("Camera returned an ONVIF fault during \(operation).")
        }
        guard let response = body.child(operation + "Response") else {
            throw ServiceError(.invalidMessage, "Camera omitted the \(operation) response.")
        }
        return response
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        count += 1
        guard count <= 4096, stack.count < 32 else { parser.abortParsing(); return }
        let node = Node(elementName, attributeDict)
        if let parent = stack.last { parent.children.append(node) } else { root = node }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        stack.last?.text += String(decoding: CDATABlock, as: UTF8.self)
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if !stack.isEmpty { stack.removeLast() }
    }
}

struct ONVIFResponse { let status: Int; let data: Data }
typealias ONVIFTransport = (URLRequest, TimeInterval) throws -> ONVIFResponse

// Per-request transport: bounded time/body, no redirects, no cookies or cached
// credentials, normal TLS verification. A camera cannot redirect authentication.
final class ONVIFHTTP: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var result: Result<ONVIFResponse, Error>?
    private var data = Data()
    private var status = 0
    private func finish(_ result: Result<ONVIFResponse, Error>) {
        lock.lock(); defer { lock.unlock() }
        guard self.result == nil else { return }
        self.result = result; done.signal()
    }
    static func send(_ request: URLRequest, timeout: TimeInterval) throws -> ONVIFResponse {
        let delegate = ONVIFHTTP()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.connectionProxyDictionary = [:]
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
        defer { session.invalidateAndCancel() }
        session.dataTask(with: request).resume()
        guard delegate.done.wait(timeout: .now() + timeout) == .success else {
            throw ServiceError(.timeout, "Camera discovery timed out.")
        }
        delegate.lock.lock(); defer { delegate.lock.unlock() }
        return try delegate.result!.get()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(.failure(ServiceError(.permission, "Camera discovery refused an HTTP redirect.")))
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.expectedContentLength <= 1_048_576 else {
            completionHandler(.cancel); finish(.failure(ServiceError("Invalid or oversized camera HTTP response."))); return
        }
        status = response.statusCode
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard data.count + chunk.count <= 1_048_576 else {
            dataTask.cancel(); finish(.failure(ServiceError("Camera response exceeds 1 MiB."))); return
        }
        data.append(chunk)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(ServiceError((error as NSError).code == NSURLErrorTimedOut ? .timeout : .unavailable, "Could not contact the camera's ONVIF service.")))
        } else { finish(.success(ONVIFResponse(status: status, data: data))) }
    }
}

// Adapted from Homebase's WS-Security requests and hardware-ID algorithm.
// No Homebase process, library, CLI preference, or API is consulted at runtime.
final class ONVIFClient {
    let endpoint: HomebaseImport.Endpoint
    let credentials: CameraCredentials
    let transport: ONVIFTransport
    private var servicePath = "/onvif/service"
    init(endpoint: HomebaseImport.Endpoint, credentials: CameraCredentials, transport: @escaping ONVIFTransport = ONVIFHTTP.send) {
        self.endpoint = endpoint; self.credentials = credentials; self.transport = transport
    }
    static func xml(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
    static func hardwareID(manufacturer: String, serial: String) throws -> String {
        func component(_ text: String, hyphen: Bool) throws -> String {
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard CameraConfiguration.printable(text, limit: 128) else { throw ServiceError("Camera omitted a usable hardware identity.") }
            return text.utf8.map {
                (97...122).contains($0) || (48...57).contains($0) || (hyphen && $0 == 45)
                    ? String(UnicodeScalar($0)) : String(format: "%%%02x", $0)
            }.joined()
        }
        let value = try "camera-" + component(manufacturer, hyphen: true) + "-" + component(serial, hyphen: false)
        guard value.utf8.count <= 512 else { throw ServiceError("Camera hardware identity is too long.") }
        return value
    }
    private func deviceURL() throws -> URL {
        var url = URLComponents()
        url.scheme = "http"; url.host = endpoint.ipAddress; url.port = Int(endpoint.onvifPort ?? 80); url.path = servicePath
        guard let result = url.url else { throw ServiceError(.invalidMessage, "Invalid camera service address.") }
        return result
    }
    static func request(url: URL, operation: String, media: Bool, body: String, credentials: CameraCredentials, timeout: TimeInterval, date: Date = Date(), nonce: Data = Data(UUID().uuidString.utf8)) -> URLRequest {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime]
        let created = formatter.string(from: date)
        let digest = Data(Insecure.SHA1.hash(data: nonce + Data(created.utf8) + Data(credentials.password.utf8))).base64EncodedString()
        let action = "http://www.onvif.org/ver10/\(media ? "media" : "device")/wsdl/\(operation)"
        let envelope = """
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
         xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"
         xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd"
         xmlns:tds="http://www.onvif.org/ver10/device/wsdl" xmlns:trt="http://www.onvif.org/ver10/media/wsdl"
         xmlns:tt="http://www.onvif.org/ver10/schema">
        <s:Header><wsse:Security s:mustUnderstand="1"><wsse:UsernameToken>
        <wsse:Username>\(xml(credentials.username))</wsse:Username>
        <wsse:Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">\(digest)</wsse:Password>
        <wsse:Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">\(nonce.base64EncodedString())</wsse:Nonce>
        <wsu:Created>\(created)</wsu:Created></wsse:UsernameToken></wsse:Security></s:Header>
        <s:Body>\(body)</s:Body></s:Envelope>
        """
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.timeoutInterval = timeout; request.httpBody = Data(envelope.utf8)
        request.setValue("application/soap+xml; charset=utf-8; action=\"\(action)\"", forHTTPHeaderField: "Content-Type")
        return request
    }
    private func call(_ operation: String, url: URL? = nil, body: String, deadline: TimeInterval) throws -> ONVIFXML.Node {
        let remaining = min(5, deadline - ProcessInfo.processInfo.systemUptime)
        guard remaining > 0 else { throw ServiceError(.timeout, "Camera discovery timed out.") }
        let service = try url ?? deviceURL()
        let response = try transport(Self.request(url: service, operation: operation, media: url != nil, body: body, credentials: credentials, timeout: remaining), remaining)
        if response.status == 404, url == nil, servicePath == "/onvif/service" {
            servicePath = "/onvif/device_service"
            return try call(operation, body: body, deadline: deadline)
        }
        if response.status == 401 || response.status == 403 {
            throw ServiceError(.permission, "Camera rejected ONVIF authentication. Check camera credentials.")
        }
        guard response.status == 200 else { throw ServiceError("Camera ONVIF request failed with HTTP \(response.status).") }
        return try ONVIFXML.response(response.data, operation: operation)
    }
    func identify(deadline: TimeInterval) throws -> String {
        let response = try call("GetDeviceInformation", body: "<tds:GetDeviceInformation/>", deadline: deadline)
        return try Self.hardwareID(manufacturer: response.value("Manufacturer") ?? "", serial: response.value("SerialNumber") ?? "")
    }
    struct Media { let deviceID: String; let serviceURL: URL; let profiles: [VideoProfile] }
    func media(expectedID: String?, deadline: TimeInterval) throws -> Media {
        let identifier = try identify(deadline: deadline)
        if let expectedID, expectedID != identifier { throw ServiceError("Camera hardware changed during import. Run add again.") }
        let capabilities = try call("GetCapabilities", body: "<tds:GetCapabilities><tds:Category>Media</tds:Category></tds:GetCapabilities>", deadline: deadline)
        guard let address = capabilities.child("Capabilities")?.child("Media")?.value("XAddr"),
              var url = URLComponents(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.fragment == nil,
              url.port.map({ (1...65535).contains($0) }) ?? true else { throw ServiceError("Camera did not advertise a usable ONVIF media service.") }
        // Cameras sometimes advertise 0.0.0.0 or another interface. Never forward
        // the authentication header to an advertised host other than this camera.
        url.host = endpoint.ipAddress
        guard let service = url.url else { throw ServiceError("Invalid camera media service address.") }
        let response = try call("GetProfiles", url: service, body: "<trt:GetProfiles/>", deadline: deadline)
        let profiles = try Self.profiles(response)
        return Media(deviceID: identifier, serviceURL: service, profiles: profiles)
    }
    static func profiles(_ response: ONVIFXML.Node) throws -> [VideoProfile] {
        var seen = Set<String>()
        let profiles = response.children.filter { $0.name == "Profiles" }.compactMap { node -> VideoProfile? in
            guard let token = node.attributes["token"], let encoder = node.child("VideoEncoderConfiguration"),
                  let encoding = encoder.value("Encoding")?.uppercased(),
                  let resolution = encoder.child("Resolution"), let width = Int(resolution.value("Width") ?? ""),
                  let height = Int(resolution.value("Height") ?? "") else { return nil }
            let profile = VideoProfile(token: token, encoding: encoding, width: width, height: height,
                                       frameRate: encoder.child("RateControl")?.value("FrameRateLimit").flatMap(Double.init),
                                       bitrateKbps: encoder.child("RateControl")?.value("BitrateLimit").flatMap(Int.init))
            guard (try? profile.validate()) != nil, seen.insert(token).inserted else { return nil }
            return profile
        }.sorted {
            if $0.width * $0.height != $1.width * $1.height { return $0.width * $0.height > $1.width * $1.height }
            return $0.token < $1.token
        }
        guard !profiles.isEmpty, profiles.count <= 64 else { throw ServiceError("Camera advertised no usable H.264/H.265 profiles, or too many profiles.") }
        return profiles
    }
    func stream(profile: VideoProfile, media: Media, deadline: TimeInterval) throws -> String {
        // The user may have spent time at the quality prompt. Recheck identity
        // before resolving the selected profile, rather than trusting a stale scan.
        guard try identify(deadline: deadline) == media.deviceID else {
            throw ServiceError("Camera hardware changed during import. Run add again.")
        }
        let body = "<trt:GetStreamUri><trt:StreamSetup><tt:Stream>RTP-Unicast</tt:Stream><tt:Transport><tt:Protocol>RTSP</tt:Protocol></tt:Transport></trt:StreamSetup><trt:ProfileToken>\(Self.xml(profile.token))</trt:ProfileToken></trt:GetStreamUri>"
        let response = try call("GetStreamUri", url: media.serviceURL, body: body, deadline: deadline)
        guard let value = response.child("MediaUri")?.value("Uri"),
              var url = URLComponents(string: value), ["rtsp", "rtsps"].contains(url.scheme?.lowercased() ?? "") else {
            throw ServiceError("Camera did not return a usable RTSP stream URL.")
        }
        url.host = endpoint.ipAddress; url.port = Int(endpoint.rtspPort ?? 554)
        url.user = nil; url.password = nil; url.fragment = nil
        guard let string = url.string, let result = try CameraConfiguration.streamURL(string, host: endpoint.ipAddress, port: endpoint.rtspPort ?? 554) else {
            throw ServiceError("Camera returned an invalid RTSP stream URL.")
        }
        return result
    }
}

enum HomebaseCameraDiscovery {
    static func names(identifier: String, directory: String) throws -> (alias: String?, display: String) {
        let path = directory + "/aliases.json"
        let aliases = try SecureFiles.info(path) == nil ? [:] : JSONDecoder().decode([String: String].self, from: CameraJSON.read(path, privateFile: false))
        let alias = aliases.filter { $0.value == identifier }.map(\.key).sorted().first
        var display = humanize(alias ?? identifier)
        // Match Homebase's whole-document preference: ID-named device file wins.
        for stem in [identifier, alias].compactMap({ $0 }) {
            guard !stem.contains("/"), stem != ".", stem != ".." else { continue }
            let file = directory + "/devices/" + stem + ".json"
            if try SecureFiles.info(file) != nil {
                let object = try JSONSerialization.jsonObject(with: CameraJSON.read(file, privateFile: false)) as? [String: Any]
                if let name = object?["DisplayName"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    display = name.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                break
            }
        }
        guard CameraConfiguration.printable(display, limit: 80),
              alias.map({ CameraConfiguration.printable($0, limit: 80) }) ?? true else {
            throw ServiceError("Homebase camera name must be 1...80 printable characters.")
        }
        return (alias, display)
    }
    static func humanize(_ identifier: String) -> String {
        if identifier.contains("-") { return identifier }
        var value = identifier.replacingOccurrences(of: "_+", with: " ", options: .regularExpression)
        for pattern in ["([A-Z]+)([A-Z][a-z])", "([a-z])([A-Z])", "([A-Za-z])([0-9])", "([0-9])([A-Za-z])"] {
            value = value.replacingOccurrences(of: pattern, with: "$1 $2", options: .regularExpression)
        }
        return value.split(whereSeparator: \.isWhitespace).map {
            let text = String($0)
            return text == text.uppercased() ? text : text.prefix(1).uppercased() + text.dropFirst()
        }.joined(separator: " ")
    }
    final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int: HomebaseImport.Endpoint] = [:]
        func set(_ index: Int, _ value: HomebaseImport.Endpoint) { lock.lock(); defer { lock.unlock() }; values[index] = value }
        func get(_ index: Int) -> HomebaseImport.Endpoint? { lock.lock(); defer { lock.unlock() }; return values[index] }
    }
    static func discover(directory: String) throws -> [HomebaseImport.Endpoint] {
        let endpoints = try HomebaseImport.cameras(directory: directory)
        guard endpoints.count <= 64 else { throw ServiceError("At most 64 cameras can be discovered at once.") }
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 4
        let results = Results()
        for (index, endpoint) in endpoints.enumerated() {
            queue.addOperation {
                var resolved = endpoint
                do {
                    let camera = try HomebaseImport.configuration(endpoint, name: endpoint.suggestedName, directory: directory)
                    let client = ONVIFClient(endpoint: endpoint, credentials: camera.credentials!)
                    let id = try client.identify(deadline: min(deadline, ProcessInfo.processInfo.systemUptime + 4))
                    let names = try names(identifier: id, directory: directory)
                    resolved.deviceID = id; resolved.alias = names.alias; resolved.displayName = names.display
                } catch {
                    resolved.discoveryError = (error as? ServiceError)?.message ?? "Camera identity or Homebase naming configuration could not be read."
                    resolved.discoveryFailureCode = (error as? ServiceError)?.code ?? .failure
                }
                results.set(index, resolved)
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        return endpoints.enumerated().map { results.get($0.offset) ?? $0.element }
    }
}
