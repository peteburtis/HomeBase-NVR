// RTSP control/authentication transport adapted from Homebase's native client.
// No Homebase runtime dependencies. Network.framework handles TCP/TLS.
import Foundation
import CryptoKit
@preconcurrency import Network

struct RTSPSource: Sendable {
    let cameraIdentifier: String
    let streamURL: URL
    let username: String
    let password: String
    let authenticated: Bool
    let preferredCodec: String?
}
enum RTSPError: Error, Sendable {
    case invalidResponse(String), unsupported(String), transport(String), authenticationRejected
    var message: String {
        switch self {
        case .invalidResponse(let text), .unsupported(let text), .transport(let text): return text
        case .authenticationRejected: return "Camera rejected its RTSP credentials."
        }
    }
}
struct EncodedVideoFrame: Sendable {
    let payload: Data
    let timestamp: UInt32
    let keyFrame: Bool
}
struct RTSPVideoDescription {
    let controlURL: URL
    let payloadType: UInt8
    let clockRate: UInt32
    let codec: String
    var parameterSets: [Data] = []
}
enum RTSPURLResolver {
    static func constrain(_ candidate: URL, to authority: URL) -> URL? {
        guard var parts = URLComponents(url: candidate, resolvingAgainstBaseURL: true) else { return nil }
        parts.scheme = authority.scheme; parts.host = authority.host; parts.port = authority.port
        parts.user = nil; parts.password = nil; parts.fragment = nil
        return parts.url
    }
    static func resolve(_ reference: String, baseURL: URL) -> URL? {
        guard let candidate = URL(string: reference, relativeTo: baseURL)?.absoluteURL else { return nil }
        return constrain(candidate, to: baseURL)
    }
}
enum RTSPSDPParser {
    static func parse(_ text: String, baseURL: URL, preferredCodec: String? = nil) throws -> RTSPVideoDescription {
        struct Track {
            var video = false
            var payloads: [UInt8] = []
            var mappings: [UInt8: (String, UInt32)] = [:]
            var control: String?
            var don = false
            var parameters: [UInt8: [Data]] = [:]
        }
        var tracks: [Track] = [], track: Track?, sessionControl: String?
        for line in text.components(separatedBy: .newlines).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("m=") {
                if let track { tracks.append(track) }
                let fields = line.dropFirst(2).split(separator: " ")
                track = Track(video: fields.first == "video", payloads: fields.dropFirst(3).compactMap { UInt8($0) })
            } else if line.lowercased().hasPrefix("a=control:") {
                let value = String(line.dropFirst(10))
                if track == nil { sessionControl = value } else { track?.control = value }
            } else if line.lowercased().hasPrefix("a=rtpmap:") {
                let fields = line.dropFirst(9).split(separator: " ", maxSplits: 1)
                if fields.count == 2, let pt = UInt8(fields[0]) {
                    let format = fields[1].split(separator: "/")
                    if format.count >= 2, let clock = UInt32(format[1]), clock > 0 {
                        track?.mappings[pt] = (format[0].uppercased(), clock)
                    }
                }
            } else if line.lowercased().hasPrefix("a=fmtp:") {
                let parts = line.dropFirst(7).split(separator: " ", maxSplits: 1)
                let payload = parts.first.flatMap { UInt8($0) }
                let parameters = parts.dropFirst().first ?? ""
                for field in parameters.components(separatedBy: ";") {
                    let pair = field.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1).map(String.init)
                    if pair.count == 2, pair[0].hasSuffix("sprop-max-don-diff"), (Int(pair[1]) ?? 0) > 0 { track?.don = true }
                    if pair.count == 2, let payload, ["sprop-parameter-sets", "sprop-vps", "sprop-sps", "sprop-pps"].contains(pair[0].lowercased()) {
                        let sets = pair[1].split(separator: ",").compactMap { Data(base64Encoded: String($0)) }.filter { !$0.isEmpty && $0.count <= 65536 }
                        track?.parameters[payload, default: []].append(contentsOf: sets)
                    }
                }
            }
        }
        if let track { tracks.append(track) }
        for track in tracks where track.video {
            for payload in track.payloads {
                guard let (codec, clock) = track.mappings[payload], ["H264", "H265"].contains(codec),
                      preferredCodec == nil || preferredCodec == codec else { continue }
                guard !track.don else { throw RTSPError.unsupported("H.265 decoding-order-number RTP is not supported.") }
                guard let control = track.control ?? sessionControl, control != "*",
                      let url = RTSPURLResolver.resolve(control, baseURL: baseURL) else {
                    throw RTSPError.invalidResponse("Video track omitted its control URL.")
                }
                return RTSPVideoDescription(controlURL: url, payloadType: payload, clockRate: clock, codec: codec, parameterSets: track.parameters[payload] ?? [])
            }
        }
        throw RTSPError.unsupported("No matching H.264/H.265 video track in SDP.")
    }
}
struct RTPPacket {
    let marker: Bool
    let payloadType: UInt8
    let sequence: UInt16
    let timestamp: UInt32
    let ssrc: UInt32
    let payload: Data
    static func parse(_ data: Data) -> RTPPacket? {
        guard data.count >= 12, data[0] >> 6 == 2 else { return nil }
        var offset = 12 + Int(data[0] & 15) * 4
        guard offset <= data.count else { return nil }
        if data[0] & 0x10 != 0 {
            guard offset + 4 <= data.count else { return nil }
            offset += 4 + Int(data.uint16(at: offset + 2)) * 4
        }
        var end = data.count
        if data[0] & 0x20 != 0 {
            guard let padding = data.last, padding > 0 else { return nil }
            end -= Int(padding)
        }
        guard offset < end, end <= data.count else { return nil }
        return RTPPacket(marker: data[1] & 0x80 != 0, payloadType: data[1] & 0x7f,
                         sequence: data.uint16(at: 2), timestamp: data.uint32(at: 4),
                         ssrc: data.uint32(at: 8), payload: Data(data[offset..<end]))
    }
}
final class RTPFrameAssembler {
    let payloadType: UInt8
    let codec: String
    private let maximumBytes: Int
    private var timestamp: UInt32?, ssrc: UInt32?, expected: UInt16?
    private var frame = Data(), fragment: Data?
    private var invalid = false, keyFrame = false
    private var packets = 0
    private(set) var droppedFrames: UInt64 = 0
    init(payloadType: UInt8, codec: String, maximumBytes: Int = 8 * 1024 * 1024) {
        self.payloadType = payloadType; self.codec = codec; self.maximumBytes = maximumBytes
    }
    private func reset() { frame.removeAll(keepingCapacity: false); fragment = nil; invalid = false; keyFrame = false; packets = 0 }
    private func append(_ nal: Data) {
        guard !nal.isEmpty, frame.count + nal.count + 4 <= maximumBytes else { invalid = true; return }
        let type = codec == "H264" ? Int(nal[0] & 31) : Int((nal[0] >> 1) & 63)
        if codec == "H264" ? type == 5 : (16...21).contains(type) { keyFrame = true }
        var length = UInt32(nal.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(nal)
    }
    func consume(_ packet: RTPPacket) -> EncodedVideoFrame? {
        guard packet.payloadType == payloadType else { return nil }
        if timestamp != packet.timestamp || ssrc != packet.ssrc {
            if timestamp != nil, !frame.isEmpty || fragment != nil || invalid { droppedFrames &+= 1 }
            reset(); timestamp = packet.timestamp
            if ssrc != packet.ssrc { expected = nil; ssrc = packet.ssrc }
        }
        if let expected, packet.sequence != expected { invalid = true; fragment = nil }
        expected = packet.sequence &+ 1
        packets += 1
        if packets > 8192 { invalid = true }
        if !invalid { consumePayload(packet.payload) }
        guard packet.marker else { return nil }
        defer { reset(); timestamp = nil }
        guard !invalid, fragment == nil, !frame.isEmpty else { droppedFrames &+= 1; return nil }
        return EncodedVideoFrame(payload: frame, timestamp: packet.timestamp, keyFrame: keyFrame)
    }
    private func consumePayload(_ payload: Data) {
        let hevc = codec == "H265"
        guard payload.count >= (hevc ? 2 : 1) else { invalid = true; return }
        let type = hevc ? Int((payload[0] >> 1) & 63) : Int(payload[0] & 31)
        if (hevc && type < 48) || (!hevc && (1...23).contains(type)) {
            guard fragment == nil else { invalid = true; return }
            append(payload)
        } else if type == (hevc ? 48 : 24) {
            guard fragment == nil else { invalid = true; return }
            var offset = hevc ? 2 : 1
            while offset + 2 <= payload.count {
                let size = Int(payload.uint16(at: offset)); offset += 2
                guard size >= (hevc ? 2 : 1), offset + size <= payload.count else { invalid = true; return }
                append(Data(payload[offset..<offset + size])); offset += size
            }
            if offset != payload.count { invalid = true }
        } else if type == (hevc ? 49 : 28) {
            let header = hevc ? 2 : 1
            guard payload.count > header + 1 else { invalid = true; return }
            let fu = payload[header], start = fu & 0x80 != 0, end = fu & 0x40 != 0
            let nalType = fu & (hevc ? 63 : 31)
            guard !(start && end), (hevc ? nalType < 48 : (1...23).contains(nalType)) else { invalid = true; return }
            if start {
                guard fragment == nil else { invalid = true; return }
                fragment = hevc ? Data([(payload[0] & 0x81) | (nalType << 1), payload[1]]) : Data([(payload[0] & 0xe0) | nalType])
            }
            guard let size = fragment?.count, frame.count + size + payload.count <= maximumBytes else { invalid = true; fragment = nil; return }
            // Mutate the owned buffer in place rather than copying the growing NAL per packet.
            fragment?.append(payload.dropFirst(header + 1))
            if end, let complete = fragment { append(complete); fragment = nil }
        } else { invalid = true }
    }
}
private extension Data {
    func uint16(at offset: Int) -> UInt16 { self[offset..<offset + 2].reduce(0) { ($0 << 8) | UInt16($1) } }
    func uint32(at offset: Int) -> UInt32 { self[offset..<offset + 4].reduce(0) { ($0 << 8) | UInt32($1) } }
}

private struct RTSPResponse {
    let statusCode: Int
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

private struct RTSPDigestChallenge {
    let realm: String
    let nonce: String
    let opaque: String?
    let algorithm: String
    let qop: String?

    static func parse(_ value: String) -> Self? {
        guard value.lowercased().hasPrefix("digest ") else { return nil }
        let body = String(value.dropFirst(7))
        var fields: [String: String] = [:]
        var start = body.startIndex
        var quoted = false
        var cursor = start
        func consume(_ range: Range<String.Index>) {
            let item = body[range].trimmingCharacters(in: .whitespaces)
            let pair = item.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { return }
            let key = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            var value = pair[1].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.first == "\"", value.last == "\"" {
                value.removeFirst()
                value.removeLast()
            }
            fields[key] = value
        }
        while cursor < body.endIndex {
            if body[cursor] == "\"" { quoted.toggle() }
            if body[cursor] == ",", !quoted {
                consume(start ..< cursor)
                start = body.index(after: cursor)
            }
            cursor = body.index(after: cursor)
        }
        consume(start ..< body.endIndex)
        guard let realm = fields["realm"], let nonce = fields["nonce"] else {
            return nil
        }
        let qop = fields["qop"]?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .first(where: { $0 == "auth" })
        guard fields["qop"] == nil || qop != nil,
              ["md5", "md5-sess"].contains((fields["algorithm"] ?? "MD5").lowercased()) else { return nil }
        return Self(
            realm: realm,
            nonce: nonce,
            opaque: fields["opaque"],
            algorithm: fields["algorithm"] ?? "MD5",
            qop: qop
        )
    }
}

private enum RTSPAuthentication {
    case basic
    case digest(RTSPDigestChallenge)
}

final class RTSPClient: @unchecked Sendable {
    enum Event: Sendable {
        case connected(String)
        case received(Int)
        case video(packets: UInt64, frames: UInt64, dropped: UInt64, media: EncodedMedia?)
        case failed(RTSPError)
    }

    private struct PendingRequest {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data
        let retriedAuthentication: Bool
        let completion: (Result<RTSPResponse, RTSPError>) -> Void
    }

    private static let maximumHeaderBytes = 64 * 1_024
    private static let maximumBodyBytes = 1_024 * 1_024

    private let source: RTSPSource
    private let queue: DispatchQueue
    private let eventHandler: @Sendable (Event) -> Void
    private var keepaliveInterval: TimeInterval
    private var connection: NWConnection?
    private var buffer = Data()
    private var pending: PendingRequest?
    private var sequence = 0
    private var authentication: RTSPAuthentication?
    private var nonceCount: UInt32 = 0
    private var sessionIdentifier: String?
    private var aggregateURL: URL
    private var depacketizer: RTPFrameAssembler?
    private var videoDescription: RTSPVideoDescription?
    private var keepalive: DispatchSourceTimer?
    private var requestTimeout: DispatchWorkItem?
    private var connectTimeout: DispatchWorkItem?
    private var teardownTimeout: DispatchWorkItem?
    private var stopCompletions: [@Sendable () -> Void] = []
    private var stopping = false
    private var stopped = false
    private var reportedFailure = false
    private var stopRetention: RTSPClient?

    init(
        source: RTSPSource,
        keepaliveInterval: TimeInterval = 20,
        eventHandler: @escaping @Sendable (Event) -> Void
    ) {
        self.source = source
        aggregateURL = source.streamURL
        self.keepaliveInterval = keepaliveInterval
        self.eventHandler = eventHandler
        queue = DispatchQueue(
            label: "com.graygoolabs.hbnvr.rtsp.\(source.cameraIdentifier)"
        )
    }

    func start() {
        queue.async { [weak self] in self?.startOnQueue() }
    }

    func stop(completion: (@Sendable () -> Void)? = nil) {
        queue.async {
            if let completion {
                self.stopCompletions.append(completion)
            }
            self.stopOnQueue()
        }
    }

    private func startOnQueue() {
        let portValue = source.streamURL.port ?? 554
        guard !stopped, connection == nil,
              ["rtsp", "rtsps"].contains(source.streamURL.scheme?.lowercased() ?? ""),
              let host = source.streamURL.host,
              (1 ... Int(UInt16.max)).contains(portValue),
              let port = NWEndpoint.Port(rawValue: UInt16(portValue)) else {
            fail(.invalidResponse("The camera returned an invalid RTSP URI."))
            return
        }
        let connection = NWConnection(
            host: NWEndpoint.Host(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))),
            port: port,
            using: source.streamURL.scheme?.lowercased() == "rtsps" ? .tls : .tcp
        )
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.connectTimeout?.cancel()
                self.receiveNext()
                self.sendOptions()
            case .failed:
                self.fail(.transport("The RTSP connection failed."))
            case .cancelled where !self.stopped:
                self.fail(.transport("The RTSP connection closed."))
            default:
                break
            }
        }
        connection.start(queue: queue)
        let timeout = DispatchWorkItem { [weak self] in self?.fail(.transport("The RTSP connection timed out.")) }
        connectTimeout = timeout
        queue.asyncAfter(deadline: .now() + 10, execute: timeout)
    }

    private func sendOptions() {
        perform(method: "OPTIONS", url: source.streamURL) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.sendDescribe()
            case .failure(let error):
                self.fail(error)
            }
        }
    }

    private func sendDescribe() {
        perform(
            method: "DESCRIBE",
            url: source.streamURL,
            headers: ["Accept": "application/sdp"]
        ) { [weak self] result in
            guard let self else { return }
            do {
                let response = try result.get()
                guard let sdp = String(data: response.body, encoding: .utf8) else {
                    throw RTSPError.invalidResponse(
                        "The camera returned non-UTF-8 SDP."
                    )
                }
                let advertisedBase = response.header("content-base")
                    .flatMap(URL.init(string:))
                let baseURL = advertisedBase.flatMap {
                    RTSPURLResolver.constrain(
                        $0,
                        to: self.source.streamURL
                    )
                } ?? self.source.streamURL
                self.aggregateURL = baseURL
                let description = try RTSPSDPParser.parse(
                    sdp,
                    baseURL: baseURL,
                    preferredCodec: self.source.preferredCodec
                )
                self.depacketizer = RTPFrameAssembler(
                    payloadType: description.payloadType,
                    codec: description.codec
                )
                self.videoDescription = description
                self.sendSetup(description)
            } catch let error as RTSPError {
                self.fail(error)
            } catch {
                self.fail(.invalidResponse(error.localizedDescription))
            }
        }
    }

    private func sendSetup(_ description: RTSPVideoDescription) {
        perform(
            method: "SETUP",
            url: description.controlURL,
            headers: [
                "Transport": "RTP/AVP/TCP;unicast;interleaved=0-1"
            ]
        ) { [weak self] result in
            guard let self else { return }
            do {
                let response = try result.get()
                guard let rawSession = response.header("session") else {
                    throw RTSPError.invalidResponse(
                        "The RTSP SETUP response omitted its Session header."
                    )
                }
                guard let transport = response.header("transport")?.lowercased(),
                      transport.contains("rtp/avp/tcp"),
                      transport.contains("interleaved=0-1") else {
                    throw RTSPError.invalidResponse(
                        "The camera did not accept interleaved RTP/RTCP channels 0-1."
                    )
                }
                self.sessionIdentifier = rawSession
                    .split(separator: ";", maxSplits: 1)
                    .first.map(String.init)
                guard let session = self.sessionIdentifier, !session.isEmpty, session.count <= 1024 else {
                    throw RTSPError.invalidResponse("Invalid RTSP session identifier.")
                }
                for part in rawSession.split(separator: ";").dropFirst() {
                    let pair = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
                    if pair.count == 2, pair[0].lowercased() == "timeout", let seconds = Double(pair[1]), seconds.isFinite, seconds > 0 {
                        self.keepaliveInterval = min(self.keepaliveInterval, max(1, seconds / 2))
                    }
                }
                self.sendPlay(description.codec)
            } catch let error as RTSPError {
                self.fail(error)
            } catch {
                self.fail(.invalidResponse(error.localizedDescription))
            }
        }
    }

    private func sendPlay(_ codec: String) {
        var headers: [String: String] = [:]
        if let sessionIdentifier { headers["Session"] = sessionIdentifier }
        perform(method: "PLAY", url: aggregateURL, headers: headers) {
            [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.eventHandler(.connected(codec))
                self.startKeepalive()
            case .failure(let error):
                self.fail(error)
            }
        }
    }

    private func startKeepalive() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + keepaliveInterval,
            repeating: keepaliveInterval
        )
        timer.setEventHandler { [weak self] in self?.sendKeepalive() }
        keepalive = timer
        timer.resume()
    }

    private func sendKeepalive() {
        guard pending == nil, !stopped else { return }
        var headers: [String: String] = [:]
        if let sessionIdentifier { headers["Session"] = sessionIdentifier }
        perform(method: "OPTIONS", url: aggregateURL, headers: headers) {
            [weak self] result in
            if case .failure(let error) = result { self?.fail(error) }
        }
    }

    private func perform(
        method: String,
        url: URL,
        headers: [String: String] = [:],
        body: Data = Data(),
        retriedAuthentication: Bool = false,
        completion: @escaping (
            Result<RTSPResponse, RTSPError>
        ) -> Void
    ) {
        guard !stopped, pending == nil, let connection else {
            completion(.failure(.transport("The RTSP connection is unavailable.")))
            return
        }
        sequence += 1
        var requestHeaders = headers
        requestHeaders["CSeq"] = String(sequence)
        requestHeaders["User-Agent"] = "hbnvr/0.4"
        if !body.isEmpty {
            requestHeaders["Content-Length"] = String(body.count)
        }
        if let authorization = authorizationHeader(method: method, url: url) {
            requestHeaders["Authorization"] = authorization
        }

        var text = "\(method) \(url.absoluteString) RTSP/1.0\r\n"
        for key in requestHeaders.keys.sorted() {
            text += "\(key): \(requestHeaders[key]!)\r\n"
        }
        text += "\r\n"
        var data = Data(text.utf8)
        data.append(body)
        pending = PendingRequest(
            method: method,
            url: url,
            headers: headers,
            body: body,
            retriedAuthentication: retriedAuthentication,
            completion: completion
        )
        let timeout = DispatchWorkItem { [weak self] in
            self?.fail(.transport("The RTSP request timed out."))
        }
        requestTimeout?.cancel()
        requestTimeout = timeout
        queue.asyncAfter(deadline: .now() + 10, execute: timeout)
        connection.send(content: data, completion: .contentProcessed {
            [weak self] error in
            if error != nil {
                self?.queue.async {
                    self?.fail(.transport("Sending an RTSP request failed."))
                }
            }
        })
    }

    private func authorizationHeader(method: String, url: URL) -> String? {
        guard source.authenticated, let authentication else { return nil }
        switch authentication {
        case .basic:
            let value = Data("\(source.username):\(source.password)".utf8)
                .base64EncodedString()
            return "Basic \(value)"
        case .digest(let challenge):
            guard challenge.algorithm.caseInsensitiveCompare("MD5") == .orderedSame
                    || challenge.algorithm.caseInsensitiveCompare("MD5-sess")
                        == .orderedSame else { return nil }
            nonceCount &+= 1
            let nc = String(format: "%08x", nonceCount)
            let cnonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let uri = url.absoluteString
            var ha1 = Self.md5("\(source.username):\(challenge.realm):\(source.password)")
            if challenge.algorithm.caseInsensitiveCompare("MD5-sess") == .orderedSame {
                ha1 = Self.md5("\(ha1):\(challenge.nonce):\(cnonce)")
            }
            let ha2 = Self.md5("\(method):\(uri)")
            let response: String
            if let qop = challenge.qop {
                response = Self.md5(
                    "\(ha1):\(challenge.nonce):\(nc):\(cnonce):\(qop):\(ha2)"
                )
            } else {
                response = Self.md5("\(ha1):\(challenge.nonce):\(ha2)")
            }
            var values = [
                "username=\"\(Self.quoted(source.username))\"",
                "realm=\"\(Self.quoted(challenge.realm))\"",
                "nonce=\"\(Self.quoted(challenge.nonce))\"",
                "uri=\"\(Self.quoted(uri))\"",
                "response=\"\(response)\"",
                "algorithm=\(challenge.algorithm)",
            ]
            if let opaque = challenge.opaque {
                values.append("opaque=\"\(Self.quoted(opaque))\"")
            }
            if let qop = challenge.qop {
                values.append("qop=\(qop)")
                values.append("nc=\(nc)")
                values.append("cnonce=\"\(cnonce)\"")
            } else if challenge.algorithm.lowercased() == "md5-sess" {
                values.append("cnonce=\"\(cnonce)\"")
            }
            return "Digest " + values.joined(separator: ", ")
        }
    }

    private func receiveNext() {
        guard !stopped, let connection else { return }
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1_024
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.eventHandler(.received(data.count))
                self.buffer.append(data)
                guard self.buffer.count
                        <= Self.maximumHeaderBytes + Self.maximumBodyBytes else {
                    self.fail(.invalidResponse(
                        "The RTSP response exceeded the receive limit."
                    ))
                    return
                }
                self.consumeBuffer()
            }
            if error != nil {
                self.fail(.transport("Receiving RTSP data failed."))
            } else if isComplete {
                self.fail(.transport("The RTSP peer closed the connection."))
            } else {
                self.receiveNext()
            }
        }
    }

    private func consumeBuffer() {
        while !buffer.isEmpty, !reportedFailure, !stopped {
            if buffer[0] == 0x24 {
                guard buffer.count >= 4 else { return }
                let channel = buffer[1]
                let length = Int(buffer.uint16(at: 2))
                guard buffer.count >= 4 + length else { return }
                let payload = Data(buffer[4 ..< 4 + length])
                buffer = Data(buffer.dropFirst(4 + length))
                if channel == 0, let assembler = depacketizer {
                    guard let packet = RTPPacket.parse(payload) else {
                        fail(.invalidResponse("Malformed video RTP packet.")); return
                    }
                    if packet.payloadType == assembler.payloadType {
                        let before = assembler.droppedFrames
                        let complete = assembler.consume(packet)
                        let media = complete.flatMap { frame in videoDescription.map { EncodedMedia(codec: $0.codec, clockRate: $0.clockRate, parameterSets: $0.parameterSets, frame: frame) } }
                        eventHandler(.video(packets: 1, frames: complete == nil ? 0 : 1, dropped: assembler.droppedFrames - before, media: media))
                    }
                }
                continue
            }

            let separator = Data("\r\n\r\n".utf8)
            guard let headerRange = buffer.range(of: separator) else {
                if buffer.count > Self.maximumHeaderBytes { fail(.invalidResponse("The RTSP response header is too large.")) }
                return
            }
            guard headerRange.lowerBound <= Self.maximumHeaderBytes else {
                fail(.invalidResponse("The RTSP response header is too large."))
                return
            }
            let headerEnd = headerRange.upperBound
            guard let headerText = String(
                data: buffer[..<headerRange.lowerBound],
                encoding: .utf8
            ) else {
                fail(.invalidResponse("The RTSP response header is not UTF-8."))
                return
            }
            let lines = headerText.components(separatedBy: "\r\n")
            guard let statusLine = lines.first else { return }
            let statusFields = statusLine.split(separator: " ", maxSplits: 2)
            guard statusFields.count >= 2,
                  statusFields[0].uppercased() == "RTSP/1.0",
                  let statusCode = Int(statusFields[1]) else {
                fail(.invalidResponse("The RTSP status line is invalid."))
                return
            }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon]
                    .trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
                if let existing = headers[key] {
                    headers[key] = existing + ", " + value
                } else {
                    headers[key] = value
                }
            }
            guard headers["content-length"] == nil || Int(headers["content-length"]!) != nil else {
                fail(.invalidResponse("Invalid RTSP Content-Length.")); return
            }
            let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
            guard contentLength >= 0,
                  contentLength <= Self.maximumBodyBytes else {
                fail(.invalidResponse("The RTSP response body is too large."))
                return
            }
            guard buffer.count >= headerEnd + contentLength else { return }
            let body = Data(buffer[headerEnd ..< headerEnd + contentLength])
            buffer = Data(buffer.dropFirst(headerEnd + contentLength))
            receiveResponse(RTSPResponse(
                statusCode: statusCode,
                headers: headers,
                body: body
            ))
        }
    }

    private func receiveResponse(_ response: RTSPResponse) {
        guard let pending else { return }
        guard response.header("cseq").flatMap(Int.init) == sequence else {
            fail(.invalidResponse("RTSP response CSeq did not match its request.")); return
        }
        self.pending = nil
        requestTimeout?.cancel()
        requestTimeout = nil
        teardownTimeout?.cancel()
        teardownTimeout = nil

        if stopping {
            if pending.method == "TEARDOWN" {
                finishStop()
            } else {
                beginTeardownOrFinish()
            }
            return
        }

        if response.statusCode == 401, source.authenticated, !pending.retriedAuthentication,
           let header = response.header("www-authenticate") {
            if header.lowercased().hasPrefix("basic ") {
                authentication = .basic
            } else if let challenge = RTSPDigestChallenge.parse(header) {
                authentication = .digest(challenge)
            } else {
                pending.completion(.failure(.authenticationRejected))
                return
            }
            perform(
                method: pending.method,
                url: pending.url,
                headers: pending.headers,
                body: pending.body,
                retriedAuthentication: true,
                completion: pending.completion
            )
            return
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            let error: RTSPError = response.statusCode == 401
                ? .authenticationRejected
                : .invalidResponse(
                    "The RTSP endpoint returned status \(response.statusCode)."
                )
            pending.completion(.failure(error))
            return
        }
        pending.completion(.success(response))
    }

    private func stopOnQueue() {
        guard !stopped else {
            drainStopCompletions()
            return
        }
        guard !stopping else { return }
        stopping = true
        stopRetention = self
        connectTimeout?.cancel()
        // A pending request must not delay shutdown for its full request deadline.
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.finishStop() }
        keepalive?.cancel()
        keepalive = nil
        guard pending == nil else { return }
        beginTeardownOrFinish()
    }

    private func beginTeardownOrFinish() {
        requestTimeout?.cancel()
        requestTimeout = nil
        guard connection != nil,
              let sessionIdentifier else {
            finishStop()
            return
        }
        let timeout = DispatchWorkItem { [weak self] in self?.finishStop() }
        teardownTimeout?.cancel()
        teardownTimeout = timeout
        queue.asyncAfter(deadline: .now() + 2, execute: timeout)
        perform(
            method: "TEARDOWN",
            url: aggregateURL,
            headers: ["Session": sessionIdentifier]
        ) { [weak self] _ in
            self?.finishStop()
        }
    }

    private func finishStop() {
        guard !stopped else { return }
        stopped = true
        connectTimeout?.cancel()
        depacketizer = nil
        stopping = false
        keepalive?.cancel()
        keepalive = nil
        requestTimeout?.cancel()
        requestTimeout = nil
        teardownTimeout?.cancel()
        teardownTimeout = nil
        pending = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        buffer.removeAll()
        drainStopCompletions()
        stopRetention = nil
    }

    private func drainStopCompletions() {
        let completions = stopCompletions
        stopCompletions.removeAll()
        completions.forEach { $0() }
    }

    private func fail(_ error: RTSPError) {
        guard !stopped, !reportedFailure else { return }
        if stopping {
            finishStop()
            return
        }
        reportedFailure = true
        connectTimeout?.cancel()
        depacketizer = nil
        buffer.removeAll()
        keepalive?.cancel()
        keepalive = nil
        requestTimeout?.cancel()
        requestTimeout = nil
        pending = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        eventHandler(.failed(error))
    }

    private static func md5(_ value: String) -> String {
        Insecure.MD5.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func quoted(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
