import XCTest
import Foundation

final class RTSPTests: XCTestCase {
    func packet(_ bytes: [UInt8], sequence: UInt16 = 1, timestamp: UInt32 = 100, marker: Bool = true, pt: UInt8 = 96) -> RTPPacket {
        RTPPacket(marker: marker, payloadType: pt, sequence: sequence, timestamp: timestamp, ssrc: 42, payload: Data(bytes))
    }
    func testH264SingleAndAggregation() {
        let assembler = RTPFrameAssembler(payloadType: 96, codec: "H264")
        let single = assembler.consume(packet([0x65, 1, 2]))
        XCTAssertEqual(single?.payload, Data([0, 0, 0, 3, 0x65, 1, 2]))
        XCTAssertEqual(single?.keyFrame, true)
        let aggregate = assembler.consume(packet([24, 0, 2, 0x67, 1, 0, 2, 0x65, 2], sequence: 2, timestamp: 200))
        XCTAssertEqual(aggregate?.payload, Data([0, 0, 0, 2, 0x67, 1, 0, 0, 0, 2, 0x65, 2]))
    }
    func testFragmentationLossAndRecovery() {
        let assembler = RTPFrameAssembler(payloadType: 96, codec: "H264")
        XCTAssertNil(assembler.consume(packet([0x7c, 0x85, 1, 2], sequence: 65535, marker: false)))
        XCTAssertEqual(assembler.consume(packet([0x7c, 0x45, 3], sequence: 0))?.payload, Data([0, 0, 0, 4, 0x65, 1, 2, 3]))
        XCTAssertNil(assembler.consume(packet([0x7c, 0x81, 1], sequence: 1, timestamp: 200, marker: false)))
        XCTAssertNil(assembler.consume(packet([0x7c, 0x41, 3], sequence: 3, timestamp: 200)))
        XCTAssertEqual(assembler.droppedFrames, 1)
        XCTAssertNotNil(assembler.consume(packet([0x61, 2], sequence: 4, timestamp: 300)))
    }
    func testH265SingleAggregationAndFragments() {
        let assembler = RTPFrameAssembler(payloadType: 96, codec: "H265")
        XCTAssertEqual(assembler.consume(packet([38, 1, 7]))?.keyFrame, true)
        XCTAssertNotNil(assembler.consume(packet([96, 1, 0, 3, 2, 1, 7], sequence: 2, timestamp: 200)))
        XCTAssertNil(assembler.consume(packet([98, 1, 0x93, 4], sequence: 3, timestamp: 300, marker: false)))
        XCTAssertEqual(assembler.consume(packet([98, 1, 0x53, 5], sequence: 4, timestamp: 300))?.payload, Data([0, 0, 0, 4, 38, 1, 4, 5]))
    }
    func testBoundedAndMalformedFrames() {
        let assembler = RTPFrameAssembler(payloadType: 96, codec: "H264", maximumBytes: 8)
        XCTAssertNil(assembler.consume(packet([0x61, 1, 2, 3, 4])))
        XCTAssertNil(assembler.consume(packet([24, 0, 9, 0x61], sequence: 2, timestamp: 200)))
        XCTAssertNil(assembler.consume(packet([0x7c, 0x45, 3], sequence: 3, timestamp: 300)))
        XCTAssertEqual(assembler.droppedFrames, 3)
        XCTAssertNil(assembler.consume(packet([0x61, 1], sequence: 4, timestamp: 400, pt: 97)))
        XCTAssertNotNil(assembler.consume(packet([0x61, 1], sequence: 4, timestamp: 400)))
    }
    func testMissingMarkerDropsIncompleteFrame() {
        let assembler = RTPFrameAssembler(payloadType: 96, codec: "H264")
        XCTAssertNil(assembler.consume(packet([0x61, 1], marker: false)))
        XCTAssertNotNil(assembler.consume(packet([0x61, 2], sequence: 2, timestamp: 200)))
        XCTAssertEqual(assembler.droppedFrames, 1)
    }
    func testRTPHeaderExtensionAndPadding() {
        var raw = Data([0xb1, 0xe0, 0, 1, 0, 0, 0, 9, 0, 0, 0, 42,
                        0, 0, 0, 1, 0xbe, 0xde, 0, 1, 1, 2, 3, 4, 0x65, 7, 0, 2])
        XCTAssertEqual(RTPPacket.parse(raw)?.payload, Data([0x65, 7]))
        XCTAssertEqual(RTPPacket.parse(raw)?.timestamp, 9)
        raw[19] = 255
        XCTAssertNil(RTPPacket.parse(raw))
        XCTAssertNil(RTPPacket.parse(Data([0x80, 96])))
    }
    func testSDPSelectionAndAuthorityPinning() throws {
        let sdp = """
        v=0
        a=control:*
        m=audio 0 RTP/AVP 0
        a=control:audio
        m=video 0 RTP/AVP 96 97
        a=rtpmap:96 H264/90000
        a=rtpmap:97 H265/90000
        a=fmtp:96 sprop-parameter-sets=Zw==,aA==
        a=fmtp:97 sprop-vps=QA==; sprop-sps=Qg==; sprop-pps=RA==
        a=control:rtsp://user:secret@evil.example:999/track1
        """
        let description = try RTSPSDPParser.parse(sdp, baseURL: URL(string: "rtsp://192.0.2.1:554/live/")!, preferredCodec: "H265")
        XCTAssertEqual(description.codec, "H265")
        XCTAssertEqual(description.payloadType, 97)
        XCTAssertEqual(description.parameterSets, [Data([0x40]), Data([0x42]), Data([0x44])])
        let h264 = try RTSPSDPParser.parse(sdp, baseURL: description.controlURL, preferredCodec: "H264")
        XCTAssertEqual(h264.parameterSets, [Data([0x67]), Data([0x68])])
        XCTAssertEqual(description.controlURL.absoluteString, "rtsp://192.0.2.1:554/track1")
        XCTAssertThrowsError(try RTSPSDPParser.parse("m=video 0 RTP/AVP 26\na=rtpmap:26 JPEG/90000\na=control:track", baseURL: description.controlURL))
        XCTAssertThrowsError(try RTSPSDPParser.parse(sdp + "\na=fmtp:97 sprop-max-don-diff=1", baseURL: description.controlURL))
    }
    func testUnconfiguredSnapshotIsCredentialFree() throws {
        let streams = StreamingCoordinator { _ in }
        streams.add(id: "fixture", camera: CameraConfiguration(name: "Front", ipAddress: "192.0.2.1", credentials: CameraCredentials(username: "viewer", password: "secret")))
        let status = try XCTUnwrap(streams.snapshot().first)
        XCTAssertEqual(status.state, "unconfigured")
        XCTAssertEqual(status.frames, 0)
        let text = String(decoding: try JSONEncoder().encode(status), as: UTF8.self)
        XCTAssertFalse(text.contains("secret")); XCTAssertFalse(text.contains("viewer"))
        streams.remove(id: "fixture")
        XCTAssertTrue(streams.snapshot().isEmpty)
        streams.stop(); streams.stop()
    }
}
