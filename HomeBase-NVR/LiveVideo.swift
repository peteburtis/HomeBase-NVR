import Foundation
import Darwin

/// Additive camera-watch capability. No camera address, URL, or credentials.
struct LiveVideoProfile: Codable, Equatable {
    var version = 1
    var frameTagsVersion: Int? = 1
    let codec: String
    let width: Int
    let height: Int
    let frameRate: Double?
    let bitrateKbps: Int?

    static func advertised(_ camera: CameraConfiguration) -> Self? {
        guard camera.enabled, camera.rtspURL != nil, let profile = camera.videoProfile,
              profile.encoding == "H264" else { return nil }
        return Self(codec: profile.encoding, width: profile.width, height: profile.height,
                    frameRate: profile.frameRate, bitrateKbps: profile.bitrateKbps)
    }
}

struct LiveVideoSessionInfo: Codable {
    var version = 1
    var frameTagsVersion = 1
    let cameraID: String
    let profile: LiveVideoProfile
    var framing = "media-v1"
    var sampleFormat = "avcc"
    var maximumFrameBytes = LiveVideoBuffer.maximumBytes - VideoTags.maximumJSONBytes
}

struct LiveVideoFrameHeader: Codable {
    var type = "frame"
    let timestamp: UInt32
    let clockRate: UInt32
    let keyFrame: Bool
    let parameterSets: [Data]
    let byteCount: Int
    var cameraUTC: Double? = nil
    var tags: [String: String] = [:]
}

/// Queue budget includes the frame currently being written. A slow reader is
/// disconnected rather than delaying recording or retaining an unbounded GOP.
struct LiveVideoBuffer {
    static let maximumBytes = 8 * 1024 * 1024
    static let maximumFrames = 120
    private(set) var bytes = 0
    private(set) var frames = 0
    private var waitingForKeyframe = true
    private var ssrc: UInt32?
    private var clockRate: UInt32?
    private var pending: [EncodedMedia] = []

    mutating func offer(_ media: EncodedMedia) -> Bool {
        guard media.codec == "H264", media.clockRate > 0,
              media.parameterSets.count == 2, media.parameterSets.allSatisfy({ !$0.isEmpty && $0.count <= 4096 }),
              !media.frame.payload.isEmpty else { return false }
        if waitingForKeyframe && !media.frame.keyFrame { return true }
        if !waitingForKeyframe, media.ssrc != ssrc || media.clockRate != clockRate { return false }
        guard (try? VideoTags.validate(media.tags)) != nil else { return false }
        let count = media.frame.payload.count + VideoTags.maximumJSONBytes
        guard count <= Self.maximumBytes - bytes, frames < Self.maximumFrames else { return false }
        waitingForKeyframe = false
        ssrc = media.ssrc; clockRate = media.clockRate
        pending.append(media); bytes += count; frames += 1
        return true
    }
    mutating func take() -> EncodedMedia? {
        pending.isEmpty ? nil : pending.removeFirst()
    }
    mutating func completed(_ media: EncodedMedia) {
        bytes -= media.frame.payload.count + VideoTags.maximumJSONBytes; frames -= 1
    }
}

/// Subscribers only tap an already-owned receiver. Subscribing never connects,
/// restarts, enables, or changes the quality/recording intent of a camera.
final class LiveVideoSessions: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [UUID: LiveVideoSubscriber] = [:]
    private var stopped = false

    /// Caller owns fd on failure; subscriber owns it after a successful reply.
    func open(_ fd: Int32, camera: String, profile: LiveVideoProfile, deadline: Double,
              authorizationInterval: TimeInterval = 30, authorize: @escaping () -> Bool) throws {
        // Installed authorization resolves the account's GeneratedUID. That can
        // invoke directory services: never do it under a lock used by recording.
        guard authorize() else { throw ServiceError(.permission, "Not authorized to read live video.") }
        lock.lock()
        guard !stopped, sessions.count < 8 else {
            lock.unlock()
            throw ServiceError(.unavailable, "Live session unavailable or limit reached.")
        }
        var reply = Reply(protocolVersion: 1, status: nil, error: nil, code: nil)
        reply.liveSession = LiveVideoSessionInfo(cameraID: camera, profile: profile)
        let id = UUID()
        let session = LiveVideoSubscriber(fd: fd, camera: camera, authorizationInterval: authorizationInterval, authorize: authorize) { [weak self] in
            guard let self else { return }; self.lock.lock(); self.sessions[id] = nil; self.lock.unlock()
        }
        sessions[id] = session
        lock.unlock()
        // No socket I/O under the hub lock or on the recording queue.
        do { try SocketIO.write(JSONEncoder().encode(reply), fd: fd, deadline: deadline) }
        catch {
            lock.lock(); sessions[id] = nil; lock.unlock()
            throw error
        }
        session.start()
    }

    func accept(_ event: RecordingEvent) {
        lock.lock(); let values = Array(sessions.values); lock.unlock()
        switch event {
        case .media(let camera, _, let media, _):
            values.filter { $0.camera == camera }.forEach { $0.offer(media) }
        case .end(let camera):
            values.filter { $0.camera == camera }.forEach { $0.stop() }
        }
    }
    func stop() {
        lock.lock(); stopped = true; let values = Array(sessions.values); lock.unlock()
        values.forEach { $0.stop() }
    }
}

private final class LiveVideoSubscriber: @unchecked Sendable {
    let camera: String
    private let fd: Int32
    private let condition = NSCondition()
    private let cancellation = Cancellation()
    private let authorize: () -> Bool
    private let authorizationInterval: TimeInterval
    private let ended: () -> Void
    private var buffer = LiveVideoBuffer()
    private var closed = false
    init(fd: Int32, camera: String, authorizationInterval: TimeInterval,
         authorize: @escaping () -> Bool, ended: @escaping () -> Void) {
        self.fd = fd; self.camera = camera; self.authorize = authorize; self.ended = ended
        self.authorizationInterval = authorizationInterval
    }
    func offer(_ media: EncodedMedia) {
        condition.lock(); defer { condition.unlock() }
        guard !cancellation.isStopped else { return }
        if !buffer.offer(media) { cancelLocked() }
        condition.signal()
    }
    func stop() {
        condition.lock(); cancelLocked(); condition.unlock()
    }
    private func cancelLocked() {
        cancellation.stop()
        if !closed { _ = shutdown(fd, SHUT_RDWR) }
        condition.signal()
    }
    func start() { DispatchQueue.global(qos: .utility).async { [self] in run() } }
    private func run() {
        defer { condition.lock(); closed = true; close(fd); condition.unlock(); ended() }
        var nextAuthorization: TimeInterval = 0
        while !cancellation.isStopped {
            condition.lock()
            var media = buffer.take()
            if media == nil && !cancellation.isStopped {
                _ = condition.wait(until: Date().addingTimeInterval(1))
                media = buffer.take()
            }
            condition.unlock()
            guard !cancellation.isStopped else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if now >= nextAuthorization {
                guard authorize() else { return }
                nextAuthorization = now + authorizationInterval
            }
            let work = MediaWork(cancellation: cancellation, deadline: ProcessInfo.processInfo.systemUptime + 5, peer: fd)
            do {
                try work.check()
                guard let media else { continue }
                let header = LiveVideoFrameHeader(timestamp: media.frame.timestamp, clockRate: media.clockRate,
                    keyFrame: media.frame.keyFrame, parameterSets: media.parameterSets, byteCount: media.frame.payload.count,
                    cameraUTC: media.cameraUTC.flatMap { $0.isFinite && abs($0) < 1e11 ? $0 : nil }, tags: media.tags)
                try MediaWire.write(JSONEncoder().encode(header), type: MediaWire.json, fd: fd, work: work)
                var offset = 0
                while offset < media.frame.payload.count {
                    let end = min(media.frame.payload.count, offset + MediaLimits.messageBytes)
                    try MediaWire.write(media.frame.payload.subdata(in: offset..<end), type: MediaWire.bytes, fd: fd, work: work)
                    offset = end
                }
                condition.lock(); buffer.completed(media); condition.unlock()
            } catch { return }
        }
    }
}
