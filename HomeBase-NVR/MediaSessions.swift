import Foundation
import Darwin

enum MediaResponse {
    static func run(_ request: MediaRequest, provider: LocalMediaProvider, work: MediaWork,
                    emit: (MediaMessage) throws -> Void, bytes: (Data) throws -> Void) throws {
        try work.check()
        let resolved = try request.resolve(now: provider.now(), live: request.relativeTo == "live" ? provider.live(request.cameraID) : nil)
        var begin = MediaMessage(type: "begin", requestID: request.requestID)
        begin.cameraID = request.cameraID; begin.timeline = request.timeline
        begin.range = resolved.range; begin.anchor = resolved.anchor
        try emit(begin)
        if request.operation == "neighbors" {
            var message = MediaMessage(type: "neighbors", requestID: request.requestID)
            message.neighbors = try provider.neighbors(camera: request.cameraID, range: resolved.range,
                timeline: request.timeline, work: work)
            try emit(message)
            var end = MediaMessage(type: "end", requestID: request.requestID)
            end.outcome = "complete"; end.frames = 0
            try emit(end)
            return
        }
        let sources = try provider.catalog(camera: request.cameraID, range: resolved.range, timeline: request.timeline, work: work)
        let pieces = try LocalMediaProvider.plan(sources, range: resolved.range, work: work)
        var coverage: [MediaRange] = [], frames: UInt64 = 0
        if request.operation == "availability" {
            coverage = MediaRange.merged(pieces.map(\.range))
            for interval in coverage {
                try work.check()
                var message = MediaMessage(type: "available", requestID: request.requestID)
                message.range = interval; try emit(message)
            }
        } else {
            for (number, piece) in pieces.enumerated() {
                try work.check()
                let result = try LocalMediaReader.read(piece, number: number, request: request, work: work, emit: emit, bytes: bytes)
                coverage = MediaRange.merged(coverage + result.coverage); frames += result.frames
                guard coverage.count <= MediaLimits.candidates else { throw ServiceError(.invalidMessage, "Too many recording gaps; request a smaller range.") }
            }
        }
        let gaps = resolved.range.subtracting(coverage)
        for interval in gaps {
            var message = MediaMessage(type: "gap", requestID: request.requestID)
            message.range = interval; message.reason = "notAvailableInLocalRecordings"
            try emit(message)
        }
        var end = MediaMessage(type: "end", requestID: request.requestID)
        end.outcome = coverage.isEmpty ? "unavailable" : gaps.isEmpty ? "complete" : "partial"
        end.frames = frames; try emit(end)
    }
}

final class MediaSessions {
    private let lock = NSLock()
    private var sessions: [UUID: MediaSession] = [:]
    private var stopped = false
    private let provider: LocalMediaProvider
    private let authorize: (uid_t) -> Bool
    init(provider: LocalMediaProvider, authorize: @escaping (uid_t) -> Bool) {
        self.provider = provider; self.authorize = authorize
    }
    deinit { stop() }
    /// On success owns fd. On failure the ordinary command handler still owns it.
    func open(_ fd: Int32, uid: uid_t, version: Int?, deadline: Double) throws {
        guard version == 1 else { throw ServiceError(.incompatible, "media.open requires mediaProtocolVersion 1.") }
        guard authorize(uid) else { throw ServiceError(.permission, "Not authorized to read media.") }
        lock.lock()
        guard !stopped, sessions.count < MediaLimits.sessions else {
            lock.unlock(); throw ServiceError(.unavailable, "Media session limit reached or agent is stopping.")
        }
        let id = UUID()
        let session = MediaSession(fd: fd, uid: uid, provider: provider, authorize: authorize) { [weak self] in
            guard let self else { return }; self.lock.lock(); self.sessions[id] = nil; self.lock.unlock()
        }
        sessions[id] = session; lock.unlock()
        do {
            var reply = Reply(protocolVersion: 1, status: nil, error: nil, code: nil)
            reply.mediaSession = MediaSessionInfo()
            try SocketIO.write(JSONEncoder().encode(reply), fd: fd, deadline: deadline)
        } catch {
            lock.lock(); sessions[id] = nil; lock.unlock(); throw error
        }
        session.start()
    }
    func stop() {
        lock.lock(); stopped = true; let values = Array(sessions.values); lock.unlock()
        values.forEach { $0.stop() }
    }
}

private final class MediaSink {
    let fd: Int32
    let work: MediaWork
    var pendingBytes = 0
    var broken = false
    init(fd: Int32, work: MediaWork) { self.fd = fd; self.work = work }
    func emit(_ message: MediaMessage) throws {
        guard !broken, pendingBytes == 0 else { throw ServiceError(.unavailable, "Media response was interrupted.") }
        let data = try JSONEncoder().encode(message)
        broken = true
        try MediaWire.write(data, type: MediaWire.json, fd: fd, work: work)
        broken = false; pendingBytes = message.frame?.byteCount ?? message.thumbnail?.byteCount ?? 0
    }
    func bytes(_ data: Data) throws {
        guard !broken, !data.isEmpty, data.count <= pendingBytes else { throw ServiceError(.invalidMessage, "Invalid frame payload.") }
        broken = true
        try MediaWire.write(data, type: MediaWire.bytes, fd: fd, work: work)
        broken = false; pendingBytes -= data.count
    }
}

private final class MediaSession: @unchecked Sendable {
    private let fd: Int32
    private let uid: uid_t
    private let provider: LocalMediaProvider
    private let authorize: (uid_t) -> Bool
    private let ended: () -> Void
    private let cancellation = Cancellation()
    private let lock = NSLock()
    private var closed = false
    init(fd: Int32, uid: uid_t, provider: LocalMediaProvider, authorize: @escaping (uid_t) -> Bool, ended: @escaping () -> Void) {
        self.fd = fd; self.uid = uid; self.provider = provider; self.authorize = authorize; self.ended = ended
    }
    func start() { DispatchQueue.global(qos: .utility).async { [self] in run() } }
    func stop() {
        cancellation.stop()
        lock.lock(); defer { lock.unlock() }
        if !closed { _ = shutdown(fd, SHUT_RDWR) }
    }
    private func run() {
        defer { cancellation.stop(); lock.lock(); closed = true; close(fd); lock.unlock(); ended() }
        while !cancellation.isStopped {
            let data: Data
            do { data = try MediaWire.read(fd: fd, cancellation: cancellation) }
            catch { return } // Framing errors, idle/stalled peers, and EOF close the session.
            let work = MediaWork(cancellation: cancellation, peer: fd), sink = MediaSink(fd: fd, work: work)
            var requestID = ""
            do {
                // Revalidate local identity on every range, not just connection admission.
                guard authorize(uid) else { throw ServiceError(.permission, "Not authorized to read media.") }
                if let heartbeat = try? JSONDecoder().decode(MediaKeepalive.self, from: data), heartbeat.operation == "keepalive" {
                    try heartbeat.validate()
                    try sink.emit(MediaMessage(type: "alive", requestID: heartbeat.requestID))
                    continue
                }
                if let thumbnail = try? JSONDecoder().decode(MediaThumbnailRequest.self, from: data), thumbnail.operation == "thumbnail" {
                    if CameraConfiguration.printable(thumbnail.requestID, limit: 64), thumbnail.requestID.utf8.count <= 64 { requestID = thumbnail.requestID }
                    try MediaThumbnailResponse.run(thumbnail, provider: provider, work: work, emit: sink.emit, bytes: sink.bytes)
                    continue
                }
                guard let request = try? JSONDecoder().decode(MediaRequest.self, from: data) else {
                    throw ServiceError(.invalidMessage, "Malformed media request.")
                }
                if CameraConfiguration.printable(request.requestID, limit: 64), request.requestID.utf8.count <= 64 { requestID = request.requestID }
                try MediaResponse.run(request, provider: provider, work: work, emit: sink.emit, bytes: sink.bytes)
            } catch {
                // Never append a JSON error inside an unfinished binary frame or
                // record. EOF without End is explicitly an incomplete response.
                guard !sink.broken, sink.pendingBytes == 0, !cancellation.isStopped else { return }
                let failure = Self.sanitized(error)
                var end = MediaMessage(type: "end", requestID: requestID)
                end.outcome = "error"; end.code = failure.code; end.error = failure.message
                do {
                    // A timed-out operation gets a short terminal response window.
                    let final = MediaSink(fd: fd, work: MediaWork(cancellation: cancellation,
                        deadline: ProcessInfo.processInfo.systemUptime + 0.2, peer: fd))
                    try final.emit(end)
                } catch { return }
                if failure.code == .permission { return }
            }
        }
    }
    private static func sanitized(_ error: Error) -> ServiceError {
        guard let value = error as? ServiceError else { return ServiceError(.unavailable, "Could not read indexed local media. No recording files were changed.") }
        switch value.code {
        case .invalidMessage, .incompatible: return value // Protocol validation messages contain no private data.
        case .permission: return ServiceError(.permission, "Media authorization or recording-directory access was denied.")
        case .timeout: return ServiceError(.timeout, "Media operation exceeded its deadline.")
        default: return ServiceError(.unavailable, "Requested media is unavailable, unreadable, or changed while reading.")
        }
    }
}
