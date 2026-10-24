import XCTest
import AVFoundation
import ImageIO
import Darwin

final class ThumbnailTests: XCTestCase {
    private func query(_ camera: String, at: Double, timeline: MediaTimeline? = nil, relative: String? = nil,
                       width: Int = 32, height: Int = 18) -> MediaThumbnailRequest {
        .init(requestID: "thumb-1", cameraID: camera, timeline: timeline, timestamp: at,
              relativeTo: relative, size: .init(width: width, height: height))
    }
    private func response(_ query: MediaThumbnailRequest, provider: LocalMediaProvider) throws -> ([MediaMessage], Data) {
        var messages: [MediaMessage] = [], data = Data()
        try MediaThumbnailResponse.run(query, provider: provider, work: MediaWork(), emit: { messages.append($0) }, bytes: { data.append($0) })
        return (messages, data)
    }
    func testThumbnailsCarrySelectedKeyframeTagsForFinalizedDiskGrowingAndRAM() throws {
        let fixtures = MediaTests()
        for active in [false, true] {
            let f = try fixtures.fixture(count: 180, initialCount: active ? 180 : nil,
                tags: { ["homebase.hidden": String($0)] })
            defer { _ = f.store.finish(timeout: 10); try? FileManager.default.removeItem(atPath: f.root) }
            if active { Thread.sleep(forTimeInterval: 0.15) }
            for (provider, offset) in active ? [(f.provider, 1.6), (f.ramProvider, 11.6)] : [(f.provider, 1.6)] {
                let point = fixtures.base + offset
                let (messages, _) = try response(query(f.camera, at: point), provider: provider)
                let thumbnail = try XCTUnwrap(messages.compactMap(\.thumbnail).first)
                let ordinal = Int((thumbnail.timestamp - fixtures.base) * 15.0 + 0.01)
                XCTAssertEqual(thumbnail.tags, ["homebase.hidden": String(ordinal)])
            }
        }
    }

    func testPointsShareTimelineAndAnchorRulesAndRejectInvalidInput() throws {
        let id = UUID().uuidString
        for timeline in [MediaTimeline.canonical, .camera, .received] {
            let request = query(id, at: -30, timeline: timeline, relative: "now")
            let roundTrip = try JSONDecoder().decode(MediaThumbnailRequest.self, from: JSONEncoder().encode(request))
            XCTAssertEqual(try roundTrip.resolve(now: 1000, live: nil).timestamp, 970)
        }
        let data = Data("{\"requestID\":\"x\",\"operation\":\"thumbnail\",\"cameraID\":\"\(id)\",\"timestamp\":100,\"size\":{\"width\":320,\"height\":180}}".utf8)
        XCTAssertEqual(try JSONDecoder().decode(MediaThumbnailRequest.self, from: data).selectedTimeline, .canonical)
        for request in [query(id, at: .nan), query(id, at: .infinity), query(id, at: 1e11), query("alias", at: 0),
                        query(id, at: 1, relative: "now"), query(id, at: 0, relative: "bad"),
                        query(id, at: 0, width: 0), query(id, at: 0, height: -1), query(id, at: 0, width: 2049)] {
            XCTAssertThrowsError(try request.resolve(now: 1000, live: nil))
        }
        XCTAssertThrowsError(try query(id, at: 0, relative: "live").resolve(now: 1000, live: nil))
    }
    func testH264AndH265JPEGSizeKeyframeAndAllTimelines() throws {
        let fixtures = MediaTests()
        for codec in [kCMVideoCodecType_H264, kCMVideoCodecType_HEVC] {
            let f = try fixtures.fixture(codec: codec)
            defer { try? FileManager.default.removeItem(atPath: f.root) }
            for (timeline, offset) in [(MediaTimeline.canonical, 0.0), (.camera, 0), (.received, 0.4)] {
                let (messages, data) = try response(query(f.camera, at: fixtures.base + offset + 1.6, timeline: timeline), provider: f.provider)
                XCTAssertEqual(messages.map(\.type), ["begin", "thumbnail", "end"])
                let thumbnail = try XCTUnwrap(messages[1].thumbnail)
                XCTAssertEqual(thumbnail.timestamp, fixtures.base + offset + 1, accuracy: 0.001)
                XCTAssertEqual(thumbnail.width, 18); XCTAssertEqual(thumbnail.height, 18)
                XCTAssertEqual(thumbnail.mimeType, "image/jpeg"); XCTAssertTrue(thumbnail.keyFrame)
                XCTAssertEqual(thumbnail.byteCount, data.count)
                let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
                let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
                XCTAssertEqual(image.width, 18); XCTAssertEqual(image.height, 18)
                XCTAssertEqual(messages.last?.frames, 1); XCTAssertEqual(messages.last?.outcome, "complete")
            }
            let (messages, _) = try response(query(f.camera, at: fixtures.base, width: 2048, height: 2048), provider: f.provider)
            XCTAssertEqual(messages[1].thumbnail?.width, 64) // No upscaling.
            XCTAssertEqual(messages[1].thumbnail?.height, 64)
        }
    }
    func testGapsAndUnavailableCameraTimelineReturnNoImage() throws {
        let fixtures = MediaTests(), f = try fixtures.fixture(cameraClock: false)
        defer { try? FileManager.default.removeItem(atPath: f.root) }
        for request in [query(f.camera, at: fixtures.base - 1), query(f.camera, at: fixtures.base + 10),
                        query(UUID().uuidString, at: fixtures.base + 1), query(f.camera, at: fixtures.base + 1, timeline: .camera)] {
            let (messages, data) = try response(request, provider: f.provider)
            XCTAssertEqual(messages.map(\.type), ["begin", "end"])
            XCTAssertEqual(messages.last?.outcome, "unavailable"); XCTAssertTrue(data.isEmpty)
        }
    }
    func testActiveDiskAndRAMThumbnailsDoNotFinalizeOrWriteMedia() throws {
        let fixtures = MediaTests()
        for codec in [kCMVideoCodecType_H264, kCMVideoCodecType_HEVC] {
            let f = try fixtures.fixture(codec: codec, count: 180, initialCount: 180)
            defer { _ = f.store.finish(timeout: 10); try? FileManager.default.removeItem(atPath: f.root) }
            Thread.sleep(forTimeInterval: 0.15)
            let files = try FileManager.default.contentsOfDirectory(atPath: f.folder).sorted()
            for (provider, point) in [(f.provider, fixtures.base + 1.6), (f.ramProvider, fixtures.base + 11.6)] {
                let (messages, data) = try response(query(f.camera, at: point), provider: provider)
                XCTAssertFalse(data.isEmpty)
                XCTAssertEqual(messages[1].thumbnail?.timestamp ?? 0, point - 0.6, accuracy: 0.001)
            }
            XCTAssertEqual(f.store.snapshot().activeRecordings, 1)
            XCTAssertEqual(f.store.snapshot().completedShards, 0)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.folder).sorted(), files)
            let live = try XCTUnwrap(f.samples.last?.time)
            let provider = LocalMediaProvider(configurations: { [f.config] }, live: { _ in live }, now: { fixtures.base + 12 })
            let (relative, _) = try response(query(f.camera, at: -0.3, relative: "live"), provider: provider)
            XCTAssertEqual(relative.first?.anchor, live.canonicalUTC)
            XCTAssertEqual(relative.first?.timestamp ?? 0, live.canonicalUTC - 0.3, accuracy: 0.001)
        }
    }
    func testCancellationAndMissingFileAreNotFalseSuccesses() throws {
        let fixtures = MediaTests(), f = try fixtures.fixture()
        defer { try? FileManager.default.removeItem(atPath: f.root) }
        let cancellation = Cancellation(); cancellation.stop()
        XCTAssertThrowsError(try MediaThumbnailResponse.run(query(f.camera, at: fixtures.base + 1), provider: f.provider,
            work: MediaWork(cancellation: cancellation), emit: { _ in XCTFail() }, bytes: { _ in XCTFail() }))
        let files = try FileManager.default.contentsOfDirectory(atPath: f.folder).filter { $0.hasSuffix(".mp4") }
        for file in files { try FileManager.default.removeItem(atPath: f.folder + "/" + file) }
        XCTAssertEqual(try response(query(f.camera, at: fixtures.base + 1), provider: f.provider).0.last?.outcome, "unavailable")
    }
    func testSocketNegotiationImagePayloadAndSubsequentKeepalive() throws {
        let fixtures = MediaTests(), f = try fixtures.fixture()
        defer { try? FileManager.default.removeItem(atPath: f.root) }
        let fds = try fixtures.pair()
        let sessions = MediaSessions(provider: f.provider, authorize: { $0 == geteuid() })
        defer { sessions.stop(); close(fds[1]) }
        try sessions.open(fds[0], uid: geteuid(), version: 1, deadline: ProcessInfo.processInfo.systemUptime + 2)
        let ready = try JSONDecoder().decode(Reply.self, from: SocketIO.read(fd: fds[1], deadline: ProcessInfo.processInfo.systemUptime + 2))
        XCTAssertEqual(ready.mediaSession?.supportsThumbnails, true)
        XCTAssertEqual(ready.mediaSession?.maxThumbnailDimension, 2048)
        for data in [try JSONEncoder().encode(query(f.camera, at: fixtures.base + 1.5)),
                     try JSONEncoder().encode(MediaKeepalive(requestID: "warm", operation: "keepalive"))] {
            try MediaWire.write(data, type: 1, fd: fds[1], work: MediaWork())
            var remaining = 0, jpeg = Data()
            while true {
                let deadline = ProcessInfo.processInfo.systemUptime + 10
                let header = try MediaWire.readExactly(5, fd: fds[1], deadline: deadline, cancellation: Cancellation())
                let count = header.dropFirst().reduce(0) { ($0 << 8) | Int($1) }
                let payload = try MediaWire.readExactly(count, fd: fds[1], deadline: deadline, cancellation: Cancellation())
                if header[0] == 2 { XCTAssertLessThanOrEqual(count, remaining); jpeg.append(payload); remaining -= count; continue }
                XCTAssertEqual(remaining, 0)
                let message = try JSONDecoder().decode(MediaMessage.self, from: payload)
                if let image = message.thumbnail { remaining = image.byteCount }
                if message.type == "end" { XCTAssertEqual(message.outcome, "complete"); XCTAssertFalse(jpeg.isEmpty); break }
                if message.type == "alive" { break }
            }
        }
    }
}
