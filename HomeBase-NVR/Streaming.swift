import Foundation

/// Public, credential-free snapshots. Rates count received application bytes, not IP/TCP overhead.
struct CameraStreamStatus: Codable {
    let id: String
    let name: String
    var state = "connecting"
    var mode = "discard"
    var enabled = true
    var recordingStarted = true
    var recordingState = "waitingForStream"
    var codec: String?
    var receivedBytes: UInt64 = 0
    var rtpPackets: UInt64 = 0
    var frames: UInt64 = 0
    var droppedFrames: UInt64 = 0
    var receiveKbps: Double = 0
    var framesPerSecond: Double = 0
    var reconnects: UInt64 = 0
    var lastFrameAgeSeconds: Double?
    var lastError: String?
    mutating func updateRecordingState(hasWritableStore: Bool) {
        recordingState = !enabled ? "disabled" : !recordingStarted ? "stopped"
            : state != "streaming" ? "waitingForStream" : !hasWritableStore ? "waitingForStore" : "recording"
        mode = recordingState == "recording" ? "record" : "discard"
    }
}

/// Owns independent camera sessions. All mutable state lives on `queue`; no video is retained.
final class StreamingCoordinator: @unchecked Sendable {
    private final class Entry: @unchecked Sendable {
        var camera: CameraConfiguration
        var status: CameraStreamStatus
        var client: RTSPClient?
        var generation = UUID()
        var began: TimeInterval = 0
        var firstFrame: TimeInterval?
        var lastFrame: TimeInterval?
        var latestTime: RecordingTime?
        var retryAt: TimeInterval?
        var failures = 0
        var sampleTime: TimeInterval = 0
        var sampleBytes: UInt64 = 0
        var sampleFrames: UInt64 = 0
        init(id: String, camera: CameraConfiguration) {
            self.camera = camera
            status = CameraStreamStatus(id: id, name: camera.name)
            status.enabled = camera.enabled; status.recordingStarted = camera.recordingStarted
        }
    }
    private let queue = DispatchQueue(label: "com.graygoolabs.hbnvr.streams")
    private var entries: [String: Entry] = [:]
    private var timer: DispatchSourceTimer?
    private var stopped = false
    private let log: (String) -> Void
    private let record: (RecordingEvent) -> Void
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    init(log: @escaping (String) -> Void, record: @escaping (RecordingEvent) -> Void = { _ in }) {
        self.log = log; self.record = record
    }

    func add(id: String, camera: CameraConfiguration) {
        queue.sync {
            guard !stopped else { return }
            if let entry = entries[id] {
                if entry.camera == camera { return }
                var changed = entry.camera
                changed.recordingStarted = camera.recordingStarted
                if changed == camera {
                    // Recording control does not interrupt the receiver or reset counters.
                    entry.camera = camera; entry.status.recordingStarted = camera.recordingStarted
                    if !camera.recordingStarted { record(.end(camera: id)) }
                    return
                }
                record(.end(camera: id))
            }
            entries[id]?.client?.stop()
            let entry = Entry(id: id, camera: camera)
            entries[id] = entry
            if !camera.enabled { entry.status.state = "disabled" }
            else if camera.rtspURL == nil { entry.status.state = "unconfigured" }
            else { connect(entry) }
            if timer == nil {
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + 1, repeating: 1)
                timer.setEventHandler { [weak self] in self?.tick() }
                self.timer = timer
                timer.resume()
            }
        }
    }

    func remove(id: String) {
        queue.sync { entries.removeValue(forKey: id)?.client?.stop(); record(.end(camera: id)) }
    }

    func snapshot() -> [CameraStreamStatus] {
        queue.sync {
            entries.values.map { entry in
                var status = entry.status
                status.lastFrameAgeSeconds = entry.lastFrame.map { max(0, now - $0) }
                return status
            }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
        }
    }

    /// Only timing is retained. A live anchor is not a promise of buffered video.
    func liveTime(camera: String) -> RecordingTime? {
        queue.sync {
            guard let entry = entries[camera], entry.status.state == "streaming",
                  let last = entry.lastFrame, now - last <= 15 else { return nil }
            return entry.latestTime
        }
    }

    func stop() {
        let clients: [RTSPClient] = queue.sync {
            stopped = true
            timer?.cancel(); timer = nil
            let clients = entries.values.compactMap(\.client)
            entries.keys.forEach { record(.end(camera: $0)) }
            entries.removeAll()
            return clients
        }
        let group = DispatchGroup()
        for client in clients { group.enter(); client.stop { group.leave() } }
        // RTSPClient closes within one second, even when a camera ignores TEARDOWN.
        _ = group.wait(timeout: .now() + 2)
    }

    private func connect(_ entry: Entry) {
        guard entry.camera.enabled, let text = entry.camera.rtspURL, let url = URL(string: text) else { return }
        entry.generation = UUID()
        let generation = entry.generation
        entry.began = now
        entry.firstFrame = nil; entry.lastFrame = nil; entry.retryAt = nil; entry.latestTime = nil
        entry.sampleTime = now; entry.sampleBytes = entry.status.receivedBytes; entry.sampleFrames = entry.status.frames
        entry.status.state = "connecting"
        let source = RTSPSource(cameraIdentifier: entry.status.id, streamURL: url,
                                username: entry.camera.credentials?.username ?? "",
                                password: entry.camera.credentials?.password ?? "",
                                authenticated: entry.camera.credentials != nil,
                                preferredCodec: entry.camera.videoProfile?.encoding)
        let client = RTSPClient(source: source) { [weak self, weak entry] event in
            guard let self, let entry else { return }
            // Synchronous counter updates provide backpressure instead of accumulating events.
            // Stores enqueue bounded references and never perform I/O on this queue.
            self.queue.sync {
                guard !self.stopped, self.entries[entry.status.id] === entry,
                      entry.generation == generation, entry.client != nil else { return }
                switch event {
                case .connected(let codec):
                    entry.status.codec = codec
                    entry.status.state = "waitingForVideo"
                    entry.began = self.now
                case .received(let bytes): entry.status.receivedBytes &+= UInt64(bytes)
                case .video(let packets, let frames, let dropped, let media):
                    if let media { entry.latestTime = media.time }
                    entry.status.rtpPackets &+= packets
                    entry.status.frames &+= frames
                    entry.status.droppedFrames &+= dropped
                    if dropped > 0 { self.record(.end(camera: entry.status.id)) }
                    if entry.camera.recordingStarted, let media {
                        self.record(.media(camera: entry.status.id, name: entry.status.name, media, homebaseDeviceID: entry.camera.homebaseDeviceID))
                    }
                    if frames > 0 {
                        if entry.firstFrame == nil {
                            entry.firstFrame = self.now
                            self.log("Camera \(entry.status.id): receiving \(entry.status.codec ?? "video")")
                        }
                        entry.lastFrame = self.now
                        entry.status.state = "streaming"
                        entry.status.lastError = nil
                    }
                case .failed(let error): self.retry(entry, error: error.message)
                }
            }
        }
        entry.client = client
        client.start()
    }

    private func retry(_ entry: Entry, error: String) {
        record(.end(camera: entry.status.id))
        let client = entry.client
        entry.client = nil
        entry.generation = UUID()
        entry.status.state = "retrying"
        entry.status.lastError = error
        entry.status.receiveKbps = 0; entry.status.framesPerSecond = 0
        let delay = min(30, pow(2, Double(min(entry.failures, 5))))
        entry.failures += 1
        log("Camera \(entry.status.id): \(error) Retrying in \(Int(delay))s.")
        // Don't overlap the old and new sessions, including during a stalled PLAY/keepalive.
        client?.stop { [weak self, weak entry] in
            guard let self, let entry else { return }
            self.queue.async {
                guard !self.stopped, self.entries[entry.status.id] === entry else { return }
                entry.retryAt = self.now + delay
            }
        }
    }

    private func tick() {
        for entry in entries.values {
            if let retryAt = entry.retryAt, now >= retryAt {
                entry.status.reconnects &+= 1
                connect(entry)
            }
            guard entry.client != nil else { continue }
            let elapsed = now - entry.sampleTime
            if elapsed > 0 {
                entry.status.receiveKbps = Double(entry.status.receivedBytes - entry.sampleBytes) * 8 / elapsed / 1000
                entry.status.framesPerSecond = Double(entry.status.frames - entry.sampleFrames) / elapsed
            }
            entry.sampleTime = now; entry.sampleBytes = entry.status.receivedBytes; entry.sampleFrames = entry.status.frames
            if let first = entry.firstFrame, now - first >= 30 { entry.failures = 0 }
            // Byte traffic alone isn't health: require complete video frames within 15s.
            if now - (entry.lastFrame ?? entry.began) > 15 {
                retry(entry, error: "No complete video frames received for 15 seconds.")
            }
        }
    }
}
