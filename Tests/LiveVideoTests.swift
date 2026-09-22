import Foundation
import Darwin
import XCTest

final class LiveVideoTests: XCTestCase {
    private func media(key: Bool = true, bytes: Int = 5, codec: String = "H264", ssrc: UInt32? = nil) -> EncodedMedia {
        EncodedMedia(codec: codec, clockRate: 90_000, parameterSets: [Data([0x67, 1]), Data([0x68, 2])],
            frame: EncodedVideoFrame(payload: Data(repeating: 3, count: bytes), timestamp: 1234, keyFrame: key), ssrc: ssrc)
    }
    func testBufferStartsOnKeyframeAndCountsInFlightBytes() throws {
        var buffer = LiveVideoBuffer()
        XCTAssertTrue(buffer.offer(media(key: false)))
        XCTAssertNil(buffer.take())
        XCTAssertEqual(buffer.bytes, 0)
        XCTAssertTrue(buffer.offer(media(bytes: LiveVideoBuffer.maximumBytes - VideoTags.maximumJSONBytes)))
        let inFlight = try XCTUnwrap(buffer.take())
        XCTAssertEqual(buffer.bytes, LiveVideoBuffer.maximumBytes)
        XCTAssertFalse(buffer.offer(media()))
        buffer.completed(inFlight)
        XCTAssertEqual(buffer.bytes, 0)
        XCTAssertTrue(buffer.offer(media(key: false)))
        XCTAssertFalse(buffer.offer(media(codec: "H265")))
    }
    func testBufferBoundsSmallFramesToo() {
        var buffer = LiveVideoBuffer()
        for _ in 0..<LiveVideoBuffer.maximumFrames { XCTAssertTrue(buffer.offer(media())) }
        XCTAssertFalse(buffer.offer(media()))
        XCTAssertEqual(buffer.frames, LiveVideoBuffer.maximumFrames)
    }
    func testRTPSourceChangeRequiresANewDecoderGeneration() {
        var buffer = LiveVideoBuffer()
        XCTAssertTrue(buffer.offer(media(ssrc: 1)))
        XCTAssertFalse(buffer.offer(media(ssrc: 2)))
    }
    func testLiveAdvertisementIndependentOfRecordingAndContainsNoSecrets() throws {
        var camera = CameraConfiguration(name: "private", ipAddress: "192.0.2.1",
            rtspURL: "rtsp://192.0.2.1/live", homebaseDeviceID: "camera-test",
            videoProfile: VideoProfile(token: "private-token", encoding: "H264", width: 1280, height: 720, frameRate: 15, bitrateKbps: 1000),
            credentials: CameraCredentials(username: "private-user", password: "private-password"))
        camera.recordingStarted = false
        let events = NVRCameraEvents()
        try events.replace([(UUID().uuidString, camera)])
        let profile = try XCTUnwrap(events.snapshot.cameras.first?.liveVideo)
        XCTAssertEqual(profile.width, 1280)
        let json = String(decoding: try JSONEncoder().encode(events.snapshot), as: UTF8.self)
        for secret in ["private", "192.0.2.1", "rtsp:"] { XCTAssertFalse(json.contains(secret)) }
        camera.enabled = false
        XCTAssertNil(LiveVideoProfile.advertised(camera))
        camera.enabled = true
        camera.videoProfile = VideoProfile(token: "hevc", encoding: "H265", width: 1280, height: 720, frameRate: nil, bitrateKbps: nil)
        XCTAssertNil(LiveVideoProfile.advertised(camera))
    }
    private func sockets() throws -> [Int32] {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        for fd in fds {
            var one: Int32 = 1
            XCTAssertEqual(fcntl(fd, F_SETFL, O_NONBLOCK), 0)
            XCTAssertEqual(setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)), 0)
        }
        return fds
    }
    private var profile: LiveVideoProfile { LiveVideoProfile(codec: "H264", width: 1280, height: 720, frameRate: 15, bitrateKbps: 1000) }
    private func readRecord(_ fd: Int32, type: UInt8) throws -> Data {
        let deadline = ProcessInfo.processInfo.systemUptime + 2, cancel = Cancellation()
        let header = try MediaWire.readExactly(5, fd: fd, deadline: deadline, cancellation: cancel)
        XCTAssertEqual(header[0], type)
        let length = header.dropFirst().reduce(0) { ($0 << 8) | Int($1) }
        return try MediaWire.readExactly(length, fd: fd, deadline: deadline, cancellation: cancel)
    }
    func testSubscriberFramesAreBoundedBinaryAndStreamEndDoesNotAffectAnotherCamera() throws {
        let hub = LiveVideoSessions(), a = try sockets(), b = try sockets()
        defer { hub.stop(); close(a[1]); close(b[1]) }
        for (camera, fds) in [("a", a), ("b", b)] {
            try hub.open(fds[0], camera: camera, profile: profile,
                deadline: ProcessInfo.processInfo.systemUptime + 2, authorize: { true })
            let reply = try JSONDecoder().decode(Reply.self, from: SocketIO.read(fd: fds[1], deadline: ProcessInfo.processInfo.systemUptime + 2))
            XCTAssertEqual(reply.liveSession?.cameraID, camera)
        }
        hub.accept(.media(camera: "a", name: "", media(key: false)))
        var sample = media(bytes: 100_000)
        sample.tags = ["example.annotation": "original"]
        hub.accept(.media(camera: "a", name: "", sample))
        sample.tags = [:] // Already queued frames retain their original value.
        let header = try JSONDecoder().decode(LiveVideoFrameHeader.self, from: readRecord(a[1], type: 1))
        XCTAssertTrue(header.keyFrame)
        XCTAssertEqual(header.byteCount, 100_000)
        XCTAssertEqual(header.tags, ["example.annotation": "original"])
        XCTAssertEqual(try readRecord(a[1], type: 2).count, 65_536)
        XCTAssertEqual(try readRecord(a[1], type: 2).count, 34_464)
        hub.accept(.end(camera: "a"))
        XCTAssertThrowsError(try readRecord(a[1], type: 1))
        hub.accept(.media(camera: "b", name: "", media()))
        XCTAssertEqual(try JSONDecoder().decode(LiveVideoFrameHeader.self, from: readRecord(b[1], type: 1)).timestamp, 1234)
    }
    func testAdmissionDeniedOrStoppedDoesNotTakeOwnership() throws {
        let fds = try sockets(), hub = LiveVideoSessions()
        defer { close(fds[0]); close(fds[1]) }
        XCTAssertThrowsError(try hub.open(fds[0], camera: "a", profile: profile,
            deadline: ProcessInfo.processInfo.systemUptime + 1, authorize: { false }))
        hub.stop()
        XCTAssertThrowsError(try hub.open(fds[0], camera: "a", profile: profile,
            deadline: ProcessInfo.processInfo.systemUptime + 1, authorize: { true }))
        XCTAssertNotEqual(fcntl(fds[0], F_GETFD), -1)
    }

    func testAuthorizationRevocationClosesExistingReader() throws {
        let fds = try sockets(), hub = LiveVideoSessions(), revoked = Cancellation()
        defer { hub.stop(); close(fds[1]) }
        try hub.open(fds[0], camera: "a", profile: profile,
            deadline: ProcessInfo.processInfo.systemUptime + 1, authorizationInterval: 0,
            authorize: { !revoked.isStopped })
        _ = try SocketIO.read(fd: fds[1], deadline: ProcessInfo.processInfo.systemUptime + 1)
        revoked.stop()
        hub.accept(.media(camera: "a", name: "", media()))
        XCTAssertThrowsError(try readRecord(fds[1], type: 1))
    }

    func testSessionLimitLeavesNinthSocketWithCaller() throws {
        let hub = LiveVideoSessions()
        var clients: [Int32] = []
        defer { hub.stop(); clients.forEach { close($0) } }
        for _ in 0..<8 {
            let fds = try sockets(); clients.append(fds[1])
            try hub.open(fds[0], camera: "a", profile: profile,
                deadline: ProcessInfo.processInfo.systemUptime + 1, authorize: { true })
            _ = try SocketIO.read(fd: fds[1], deadline: ProcessInfo.processInfo.systemUptime + 1)
        }
        let extra = try sockets()
        defer { close(extra[0]); close(extra[1]) }
        XCTAssertThrowsError(try hub.open(extra[0], camera: "a", profile: profile,
            deadline: ProcessInfo.processInfo.systemUptime + 1, authorize: { true }))
        XCTAssertNotEqual(fcntl(extra[0], F_GETFD), -1)
    }
}
