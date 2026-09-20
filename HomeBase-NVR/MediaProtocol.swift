import Foundation
import Darwin

/// Media protocol v1 is independent of the command protocol. No filenames, URLs,
/// credentials, opaque memory handles, or client-supplied filesystem paths cross it.
enum MediaTimeline: String, Codable { case canonical, camera, received
    func anchor(_ time: RecordingTime) -> Double? {
        switch self { case .canonical: return time.canonicalUTC; case .camera: return time.cameraUTC; case .received: return time.receivedUTC }
    }
    var column: String {
        switch self { case .canonical: return "start_utc"; case .camera: return "camera_utc"; case .received: return "received_utc" }
    }
}
struct MediaRange: Codable, Equatable {
    let start: Double
    let end: Double
    static func merged(_ ranges: [Self]) -> [Self] {
        var result: [Self] = []
        for range in ranges.sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) where range.end > range.start {
            if let last = result.last, range.start <= last.end {
                result[result.count - 1] = Self(start: last.start, end: max(last.end, range.end))
            } else { result.append(range) }
        }
        return result
    }
    func subtracting(_ ranges: [Self]) -> [Self] {
        var result: [Self] = [], cursor = start
        for range in Self.merged(ranges) where range.end > cursor && range.start < end {
            if range.start > cursor { result.append(Self(start: cursor, end: min(end, range.start))) }
            cursor = max(cursor, range.end)
        }
        if cursor < end { result.append(Self(start: cursor, end: end)) }
        return result
    }
}
struct MediaRequest: Codable {
    let requestID: String
    let operation: String // frames | availability | neighbors
    let cameraID: String
    var timeline: MediaTimeline = .canonical
    let range: MediaRange // Unix seconds for absolute; signed seconds for relative
    var relativeTo: String? = nil // nil (absolute) | live | now
    enum CodingKeys: String, CodingKey { case requestID, operation, cameraID, timeline, range, relativeTo }
    init(requestID: String, operation: String, cameraID: String, timeline: MediaTimeline = .canonical,
         range: MediaRange, relativeTo: String? = nil) {
        self.requestID = requestID; self.operation = operation; self.cameraID = cameraID
        self.timeline = timeline; self.range = range; self.relativeTo = relativeTo
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try c.decode(String.self, forKey: .requestID)
        operation = try c.decode(String.self, forKey: .operation)
        cameraID = try c.decode(String.self, forKey: .cameraID)
        timeline = try c.decodeIfPresent(MediaTimeline.self, forKey: .timeline) ?? .canonical
        range = try c.decode(MediaRange.self, forKey: .range)
        relativeTo = try c.decodeIfPresent(String.self, forKey: .relativeTo)
    }
    func resolve(now: Double, live: RecordingTime?) throws -> (range: MediaRange, anchor: Double?) {
        guard CameraConfiguration.printable(requestID, limit: 64), requestID.utf8.count <= 64,
              UUID(uuidString: cameraID) != nil, ["frames", "availability", "neighbors"].contains(operation),
              range.start.isFinite, range.end.isFinite, range.start < range.end,
              range.end - range.start <= MediaLimits.maximumRangeSeconds else {
            throw ServiceError(.invalidMessage, "Expected a camera UUID, request ID, frames/availability/neighbors operation, and finite range of at most 24 hours.")
        }
        let anchor = try MediaTimeSelection.anchor(relativeTo: relativeTo, timeline: timeline, now: now, live: live)
        if relativeTo != nil, range.end > 0 { throw ServiceError(.invalidMessage, "Relative ranges must end at or before their anchor.") }
        let resolved = MediaRange(start: range.start + (anchor ?? 0), end: range.end + (anchor ?? 0))
        guard resolved.start.isFinite, resolved.end.isFinite, resolved.start < resolved.end,
              abs(resolved.start) < 100_000_000_000, abs(resolved.end) < 100_000_000_000 else {
            throw ServiceError(.invalidMessage, "Time range is outside the supported Unix timestamp bounds.")
        }
        return (resolved, anchor)
    }
}
/// Shared anchor semantics for ranges and thumbnail points. NVR alone resolves
/// a relative request, once, using the selected timeline's current live anchor.
enum MediaTimeSelection {
    static func anchor(relativeTo: String?, timeline: MediaTimeline, now: Double, live: RecordingTime?) throws -> Double? {
        switch relativeTo {
        case nil: return nil
        case "now": return now
        case "live":
            guard let live, let value = timeline.anchor(live) else {
                throw ServiceError(.unavailable, "No current live frame is available in the requested timeline.")
            }
            return value
        default: throw ServiceError(.invalidMessage, "relativeTo must be live or now, or omitted for absolute time.")
        }
    }
}
enum MediaLimits {
    static let sessions = 8
    static let messageBytes = 65_536
    static let maximumRangeSeconds: Double = 86_400
    static let candidates = 10_000
    static let directories = 4096
    static let idleSeconds: Double = 60
    static let stallSeconds: Double = 5
    static let requestSeconds: Double = 300
}
struct MediaSessionInfo: Codable {
    var supportsThumbnails = true
    var thumbnailFormats = ["image/jpeg"]
    var maxThumbnailDimension = 2048
    var maxThumbnailBytes = 8 * 1024 * 1024
    var supportsNeighbors = true
    var supportsKeepalive = true
    var discovery = "playback.snapshot"
    var discoveryWatch = "playback.watch"
    var version = 1
    var framing = "type-u8,length-u32be,payload"
    var maxMessageBytes = MediaLimits.messageBytes
    var maxRangeSeconds = MediaLimits.maximumRangeSeconds
    var idleTimeoutSeconds = MediaLimits.idleSeconds
    var requestTimeoutSeconds = MediaLimits.requestSeconds
    var source = "localRecordings"
    var includesActiveDiskFragments = true
    var includesResidentLocalFrames = true
}

struct MediaKeepalive: Codable {
    let requestID: String
    let operation: String
    func validate() throws {
        guard operation == "keepalive", CameraConfiguration.printable(requestID, limit: 64),
              requestID.utf8.count <= 64 else {
            throw ServiceError(.invalidMessage, "Invalid media keepalive.")
        }
    }
}
struct MediaSegment: Codable {
    let number: Int // Request-local segment number, NOT a reusable frame reference.
    let range: MediaRange
    let time: RecordingTime // Anchors correspond to sample tick zero, not necessarily first returned frame.
    let timescale: UInt32
    let codec: String
    let parameterSets: [Data]
    let nalUnitLengthBytes: Int
}
struct MediaFrame: Codable {
    let segment: Int
    let presentationTicks: Int64
    let decodeTicks: Int64?
    let durationTicks: Int64
    let keyFrame: Bool
    let preroll: Bool
    let byteCount: Int
}
/// Nearest readable intervals outside the requested range, across the selected
/// local store's history. Missing sides mean none at query time, not a permanent boundary.
struct MediaNeighbors: Codable, Equatable {
    var previous: MediaRange?
    var next: MediaRange?
}
struct MediaMessage: Codable {
    let type: String // begin | available | neighbors | segment | frame | gap | end
    let requestID: String
    var cameraID: String? = nil
    var timeline: MediaTimeline? = nil
    var range: MediaRange? = nil
    var anchor: Double? = nil
    var segment: MediaSegment? = nil
    var frame: MediaFrame? = nil
    var outcome: String? = nil // end: complete | partial | unavailable | error
    var reason: String? = nil
    var error: String? = nil
    var code: FailureCode? = nil
    var frames: UInt64? = nil
    var neighbors: MediaNeighbors? = nil
    var timestamp: Double? = nil
    var thumbnail: MediaThumbnail? = nil
}

/// Checks both lifetime cancellation and peer closure even while scanning media,
/// rather than discovering a disconnected reader only at the next socket write.
final class MediaWork {
    let cancellation: Cancellation
    let deadline: Double
    private let peer: Int32?
    init(cancellation: Cancellation = Cancellation(), deadline: Double = ProcessInfo.processInfo.systemUptime + MediaLimits.requestSeconds, peer: Int32? = nil) {
        self.cancellation = cancellation; self.deadline = deadline; self.peer = peer
    }
    func check() throws {
        guard !cancellation.isStopped else { throw ServiceError(.unavailable, "Media session closed.") }
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw ServiceError(.timeout, "Media request deadline exceeded.") }
        if let peer {
            var state = pollfd(fd: peer, events: Int16(POLLIN), revents: 0)
            if poll(&state, 1, 0) > 0, state.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
                throw ServiceError(.unavailable, "Media peer disconnected.")
            }
            var byte: UInt8 = 0
            let n = recv(peer, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
            if n == 0 || (n < 0 && ![EAGAIN, EWOULDBLOCK, EINTR].contains(errno)) {
                throw ServiceError(.unavailable, "Media peer disconnected.")
            }
        }
    }
}

enum MediaWire {
    static let json: UInt8 = 1, bytes: UInt8 = 2
    static func read(fd: Int32, cancellation: Cancellation, idleSeconds: Double = MediaLimits.idleSeconds) throws -> Data {
        // Read exactly each record; never discard coalesced messages or assume a
        // read corresponds to a write. No pipelining before media.open's reply.
        let first = try readExactly(1, fd: fd, deadline: ProcessInfo.processInfo.systemUptime + idleSeconds, cancellation: cancellation)
        guard first[0] == json else { throw ServiceError(.invalidMessage, "Clients must send JSON media records.") }
        let deadline = ProcessInfo.processInfo.systemUptime + MediaLimits.stallSeconds
        let length = try readExactly(4, fd: fd, deadline: deadline, cancellation: cancellation)
            .reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= MediaLimits.messageBytes else { throw ServiceError(.invalidMessage, "Invalid media record length.") }
        return try readExactly(Int(length), fd: fd, deadline: deadline, cancellation: cancellation)
    }
    static func readExactly(_ count: Int, fd: Int32, deadline: Double, cancellation: Cancellation) throws -> Data {
        var data = Data(count: count), offset = 0
        try data.withUnsafeMutableBytes { raw in
            while offset < count {
                try SocketIO.wait(fd, events: Int16(POLLIN), deadline: deadline, cancellation: cancellation)
                let n = recv(fd, raw.baseAddress!.advanced(by: offset), count - offset, 0)
                if n < 0 && [EAGAIN, EINTR].contains(errno) { continue }
                guard n > 0 else { throw ServiceError(.unavailable, "Media peer disconnected.") }
                offset += n
            }
        }
        return data
    }
    static func write(_ data: Data, type: UInt8, fd: Int32, work: MediaWork) throws {
        try work.check()
        guard !data.isEmpty, data.count <= MediaLimits.messageBytes else { throw ServiceError(.invalidMessage, "Media record exceeds its negotiated bound.") }
        var length = UInt32(data.count).bigEndian
        let header = Data([type]) + withUnsafeBytes(of: &length) { Data($0) }
        let deadline = min(work.deadline, ProcessInfo.processInfo.systemUptime + MediaLimits.stallSeconds)
        for buffer in [header, data] {
            try buffer.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    try SocketIO.wait(fd, events: Int16(POLLOUT), deadline: deadline, cancellation: work.cancellation)
                    let n = send(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
                    if n < 0 && [EAGAIN, EINTR].contains(errno) { continue }
                    guard n > 0 else { throw ServiceError(.unavailable, "Media peer disconnected.") }
                    offset += n
                }
            }
        }
    }
}
