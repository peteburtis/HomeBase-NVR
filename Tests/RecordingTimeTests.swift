import XCTest
import Foundation
import AVFoundation
import VideoToolbox

final class RecordingTimeTests: XCTestCase {
    func report(ssrc: UInt32 = 42, utc: Double = 1_789_680_000, rtp: UInt32 = 90_000, nanoseconds: Bool = false) -> Data {
        let ntp = utc + 2_208_988_800
        let words: [UInt32] = [0x80c80006, ssrc, UInt32(truncatingIfNeeded: UInt64(ntp)), UInt32((ntp - floor(ntp)) * (nanoseconds ? 1_000_000_000 : 4_294_967_296)), rtp, 0, 0]
        return words.reduce(into: Data()) { data, word in
            data.append(contentsOf: [UInt8(truncatingIfNeeded: word >> 24), UInt8(truncatingIfNeeded: word >> 16), UInt8(truncatingIfNeeded: word >> 8), UInt8(truncatingIfNeeded: word)])
        }
    }
    func media(_ timestamp: UInt32 = 0, received: Double = 1000, uptime: Double = 100,
               camera: Double? = nil, key: Bool = true, ssrc: UInt32 = 42) -> EncodedMedia {
        EncodedMedia(codec: "H264", clockRate: 90_000, parameterSets: [],
            frame: .init(payload: Data(), timestamp: timestamp, keyFrame: key),
            receivedAt: Date(timeIntervalSince1970: received), receivedUptime: uptime, cameraUTC: camera, ssrc: ssrc)
    }
    func testSenderReportCompoundMalformedAndPadding() throws {
        let sr = report(utc: 1_789_680_000.5)
        XCTAssertEqual(RTCPSenderReport.parse(sr).count, 1)
        let compound = sr + Data([0x80, 202, 0, 1, 0, 0, 0, 0])
        XCTAssertEqual(RTCPSenderReport.parse(compound), RTCPSenderReport.parse(sr))
        XCTAssertEqual(RTCPSenderReport.parse((Data([1, 2]) + sr).dropFirst(2)), RTCPSenderReport.parse(sr))
        XCTAssertTrue(RTCPSenderReport.parse(compound.dropLast()).isEmpty)
        var padded = sr; padded[0] |= 0x20; padded[3] = 7; padded.append(contentsOf: [0, 0, 0, 4])
        XCTAssertEqual(RTCPSenderReport.parse(padded), RTCPSenderReport.parse(sr))
        XCTAssertTrue(RTCPSenderReport.parse(padded + sr).isEmpty)
        var truncatedReports = sr; truncatedReports[0] = 0x81
        XCTAssertTrue(RTCPSenderReport.parse(truncatedReports).isEmpty)
        var wrongVersion = sr; wrongVersion[0] = 0x40
        XCTAssertTrue(RTCPSenderReport.parse(wrongVersion).isEmpty)
        for count in 0..<28 { XCTAssertTrue(RTCPSenderReport.parse(sr.prefix(count)).isEmpty) }
    }
    func testMappingFractionWrapSSRCExpiryAndNTPEra() throws {
        var clock = RTPCameraClock()
        let utc = 1_789_680_000.5, received = Date(timeIntervalSince1970: utc + 0.2)
        clock.receive(report(utc: utc, rtp: UInt32.max - 44999), at: received, uptime: 100)
        XCTAssertEqual(try XCTUnwrap(clock.time(ssrc: 42, timestamp: 45000, rate: 90000, uptime: 101)), utc + 1, accuracy: 0.000001)
        XCTAssertNil(clock.time(ssrc: 43, timestamp: 45000, rate: 90000, uptime: 101))
        XCTAssertNil(clock.time(ssrc: 42, timestamp: 45000, rate: 90000, uptime: 221))
        let future = 2_100_000_000.25 // after 2036 rollover
        let parsed = try XCTUnwrap(RTCPSenderReport.parse(report(utc: future)).first)
        XCTAssertEqual(try XCTUnwrap(parsed.unixTime(near: Date(timeIntervalSince1970: future))), future, accuracy: 0.000001)
        XCTAssertNil(RTCPSenderReport(ssrc: 42, ntpSeconds: 0, ntpFraction: 0, rtpTimestamp: 0).unixTime(near: received))
        XCTAssertNil(RTCPSenderReport(ssrc: 42, ntpSeconds: 100, ntpFraction: 0, rtpTimestamp: 0).unixTime(near: received))
    }
    func testCanonicalToleranceIsInclusiveAndSymmetric() throws {
        for difference in [-100.0, -2.501, -2.5, 0, 2.5, 2.501, 100] {
            var timeline = RecordingTimeline()
            let time = try timeline.observe(media(camera: 1000 + difference))
            let expected: CanonicalTimeSource = abs(difference) <= 2.5 ? .camera : .received
            XCTAssertEqual(time.canonicalSource, expected)
            XCTAssertEqual(time.canonicalUTC, expected == .camera ? 1000 + difference : 1000)
            XCTAssertEqual(time.cameraUTC, 1000 + difference)
        }
        var timeline = RecordingTimeline()
        XCTAssertEqual(try timeline.observe(media()).canonicalSource, .received)
    }
    func testChannelBindingRequiresConsistentUniqueFreshReportsAndResetsOnSSRCChange() throws {
        var clock = RTPCameraClock(allowInterleavedChannelBinding: true)
        let utc = 1_789_680_000.0
        XCTAssertNil(clock.mapping(ssrc: 7, timestamp: 0, rate: 90000, uptime: 100))
        clock.receive(report(utc: utc, rtp: 0), at: Date(timeIntervalSince1970: utc), uptime: 100)
        XCTAssertNil(clock.mapping(ssrc: 7, timestamp: 0, rate: 90000, uptime: 100))
        clock.receive(report(utc: utc + 1, rtp: 90000), at: Date(timeIntervalSince1970: utc + 1), uptime: 101)
        let mapped = try XCTUnwrap(clock.mapping(ssrc: 7, timestamp: 135000, rate: 90000, uptime: 101.5))
        XCTAssertEqual(mapped.utc, utc + 1.5); XCTAssertEqual(mapped.evidence.method, .interleavedChannel)
        XCTAssertEqual(mapped.evidence.reportSSRC, 42)
        XCTAssertNil(clock.mapping(ssrc: 7, timestamp: 135000, rate: 90000, uptime: 107))
        XCTAssertNil(clock.mapping(ssrc: 7, timestamp: 13500000, rate: 90000, uptime: 101.5))
        XCTAssertNil(clock.mapping(ssrc: 8, timestamp: 135000, rate: 90000, uptime: 102))
        // A second source on the same channel makes a mismatched association ambiguous.
        clock.receive(report(ssrc: 43, utc: utc + 2, rtp: 180000), at: Date(timeIntervalSince1970: utc + 2), uptime: 102)
        XCTAssertNil(clock.mapping(ssrc: 8, timestamp: 180000, rate: 90000, uptime: 102))
        var invalid = RTPCameraClock(allowInterleavedChannelBinding: true)
        _ = invalid.mapping(ssrc: 7, timestamp: 0, rate: 90000, uptime: 100)
        invalid.receive(report(utc: utc, rtp: 0), at: Date(timeIntervalSince1970: utc), uptime: 100)
        invalid.receive(report(utc: utc + 20, rtp: 90000), at: Date(timeIntervalSince1970: utc + 1), uptime: 101)
        XCTAssertNil(invalid.mapping(ssrc: 7, timestamp: 90000, rate: 90000, uptime: 101))
    }
    func testLateCameraMappingSwitchesOnlyAtKeyframe() throws {
        var timeline = RecordingTimeline()
        let a = try timeline.observe(media())
        let b = try timeline.observe(media(9000, received: 1000.1, uptime: 100.1, camera: 999.9, key: false))
        XCTAssertEqual(a.epochID, b.epochID); XCTAssertNil(b.cameraUTC)
        let c = try timeline.observe(media(18000, received: 1000.2, uptime: 100.2, camera: 1000))
        XCTAssertNotEqual(c.epochID, b.epochID); XCTAssertEqual(c.canonicalSource, .camera)
        XCTAssertEqual(c.canonicalUTC, 1000)
    }
    func testNonstandardNanosecondFractionRequiresThreeCoherentReports() throws {
        var clock = RTPCameraClock(allowInterleavedChannelBinding: true)
        let utc = 1_789_680_000.2
        _ = clock.mapping(ssrc: 7, timestamp: 0, rate: 90000, uptime: 100)
        for i in 0..<3 {
            let elapsed = Double(i) * 48000 / 90000
            clock.receive(report(utc: utc + elapsed, rtp: UInt32(i * 48000), nanoseconds: true),
                at: Date(timeIntervalSince1970: utc + elapsed + 0.4), uptime: 100 + elapsed)
            let value = clock.mapping(ssrc: 7, timestamp: UInt32(i * 48000), rate: 90000, uptime: 100 + elapsed)
            if i < 2 { XCTAssertNil(value) }
            else {
                XCTAssertEqual(try XCTUnwrap(value).utc, utc + elapsed, accuracy: 0.000001)
                XCTAssertEqual(value?.evidence.fractionEncoding, .nanoseconds)
            }
        }
        var matchedSource = clock
        let matched = try XCTUnwrap(matchedSource.mapping(ssrc: 42, timestamp: 96000, rate: 90000, uptime: 101.1))
        XCTAssertEqual(matched.evidence.method, .ssrc); XCTAssertEqual(matched.evidence.fractionEncoding, .nanoseconds)
        XCTAssertEqual(matched.utc, utc + 96000.0 / 90000, accuracy: 0.000001)
        // One corrupted pair does not replace a good anchor or extend its expiry.
        clock.receive(report(utc: utc + 5, rtp: 144000, nanoseconds: true), at: Date(timeIntervalSince1970: utc + 2), uptime: 102)
        XCTAssertEqual(try XCTUnwrap(clock.mapping(ssrc: 7, timestamp: 144000, rate: 90000, uptime: 102)).utc, utc + 1.6, accuracy: 0.000001)
        XCTAssertNil(clock.mapping(ssrc: 7, timestamp: 144000, rate: 90000, uptime: 107))
    }
    func testJitterDoesNotRetimeFramesAndClockStepsStartEpochs() throws {
        var timeline = RecordingTimeline()
        let a = try timeline.observe(media(camera: 999))
        let b = try timeline.observe(media(9000, received: 1000.8, uptime: 100.8, camera: 999.1))
        XCTAssertEqual(b.epochID, a.epochID)
        XCTAssertEqual(b.receivedUTC, 1000.1, accuracy: 0.000001)
        XCTAssertEqual(b.canonicalUTC, 999.1, accuracy: 0.000001)
        let c = try timeline.observe(media(18000, received: 1004, uptime: 101, camera: 999.2))
        XCTAssertNotEqual(c.epochID, b.epochID); XCTAssertEqual(c.canonicalSource, .received)
        let d = try timeline.observe(media(0, received: 1004.1, uptime: 101.1, camera: 1003, ssrc: 43))
        XCTAssertNotEqual(d.epochID, c.epochID)
    }
    func testCameraClockStepAndExpiryDoNotModifyExistingEpoch() throws {
        var timeline = RecordingTimeline()
        let a = try timeline.observe(media(camera: 999))
        let b = try timeline.observe(media(9000, received: 1000.1, uptime: 100.1, camera: 600, key: false))
        XCTAssertEqual(b.epochID, a.epochID)
        let c = try timeline.observe(media(18000, received: 1000.2, uptime: 100.2, camera: 600.1))
        XCTAssertNotEqual(c.epochID, a.epochID); XCTAssertEqual(c.canonicalSource, .received)
        XCTAssertEqual(c.cameraUTC, 600.1)
        let d = try timeline.observe(media(27000, received: 1000.3, uptime: 100.3))
        XCTAssertNotEqual(d.epochID, c.epochID); XCTAssertNil(d.cameraUTC)
    }
    func testBothMP4WritersPreserveTimingAndDecodeWithoutTranscoding() async throws {
        for codec in [kCMVideoCodecType_H264, kCMVideoCodecType_HEVC] {
            let helper = StoreTests(), root = try helper.temporary(), config = try helper.config(root + "/local")
            defer { try? FileManager.default.removeItem(atPath: root) }
            let camera = UUID().uuidString, store = try LocalRecordingStore(configuration: config)
            var timeline = RecordingTimeline(), samples: [EncodedMedia] = []
            for input in try StoreTests.video(codec: codec) {
                let offset = Double(input.frame.timestamp) / Double(input.clockRate)
                var sample = EncodedMedia(codec: input.codec, clockRate: input.clockRate, parameterSets: input.parameterSets, frame: input.frame,
                    receivedAt: Date(timeIntervalSince1970: 1_789_680_000 + offset), receivedUptime: 100 + offset,
                    cameraUTC: 1_789_679_999 + offset, ssrc: 42)
                sample.time = try timeline.observe(sample)
                sample.tags = samples.count < 5 ? [:] : samples.count < 10 ? ["arbitrary": "yes", "empty": ""] : [:]
                samples.append(sample)
                store.accept(.media(camera: camera, name: "Clock Camera", sample))
            }
            XCTAssertTrue(store.finish(timeout: 30)); XCTAssertNil(store.snapshot().lastError)
            let path = config.directory + "/Clock Camera", fd = try StoreDirectory.openDirectory(path)
            let directory = LocalRecordingLayout.Directory(path: path, fd: fd)
            let db = try LocalRecordingManifest(directory: directory, identity: .init(storeID: config.id, cameraID: camera), owner: geteuid(), readOnly: true)
            let rows = try db.recordings(); XCTAssertEqual(rows.count, 1)
            let row = try XCTUnwrap(rows.first), timing = row.timing
            XCTAssertEqual(timing.time.canonicalSource, .camera)
            try await verify(path: path + "/" + row.filename, timing: timing, samples: samples)
            let first = try XCTUnwrap(samples.first)
            let memory = try MemoryMP4Shard(codec: first.codec, sets: first.parameterSets, clock: first.clockRate,
                timestamp: first.frame.timestamp, timing: timing)
            for sample in samples { try memory.append(sample.frame, tags: sample.tags) }
            let bytes = try memory.finish(), file = root + "/memory.mp4"
            try SecureFiles.atomicWrite(bytes, to: file, mode: 0o600)
            try await verify(path: file, timing: timing, samples: samples)
        }
    }
    func verify(path: String, timing: ShardTimingMetadata, samples: [EncodedMedia]) async throws {
        let tags = try XCTUnwrap(VideoTagMP4.read(Data(contentsOf: URL(fileURLWithPath: path))))
        for (index, sample) in samples.enumerated() {
            let ticks = Int64(sample.frame.timestamp &- samples[0].frame.timestamp)
            XCTAssertEqual(tags.tags(at: ticks), sample.tags, "frame \(index)")
        }
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let embedded = try await ShardTimingMetadata.read(from: asset)
        XCTAssertEqual(try XCTUnwrap(embedded, path), timing)
        let tracks = try await asset.loadTracks(withMediaType: .video), track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset), output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output); XCTAssertTrue(reader.startReading())
        var index = 0
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) == 0 { continue }
            guard index < samples.count, let block = CMSampleBufferGetDataBuffer(sample) else {
                XCTFail("Unexpected sample in \(path): samples=\(CMSampleBufferGetNumSamples(sample)) index=\(index) bytes=\(CMSampleBufferGetTotalSampleSize(sample))")
                break
            }
            var data = Data(count: CMBlockBufferGetDataLength(block))
            let size = data.count
            XCTAssertEqual(data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: $0.baseAddress!) }, noErr)
            XCTAssertEqual(data, samples[index].frame.payload)
            index += 1
        }
        XCTAssertEqual(index, samples.count); XCTAssertEqual(reader.status, .completed)
        let decoder = try AVAssetReader(asset: asset), decoded = AVAssetReaderTrackOutput(track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        decoder.add(decoded); XCTAssertTrue(decoder.startReading())
        var decodedCount = 0
        while decoded.copyNextSampleBuffer() != nil { decodedCount += 1 }
        XCTAssertEqual(decodedCount, samples.count); XCTAssertEqual(decoder.status, .completed)
    }
}

/// Explicit opt-in, no AWS, no installed configuration changes, no saved video.
final class CameraClockLiveTests: XCTestCase {
    final class Observation: @unchecked Sendable {
        let lock = NSLock()
        var frames = 0, mapped = 0, canonical = Set<String>(), offsets: [Double] = []
        var rtcpPackets = 0, reports: [RTCPSenderReport] = [], sources = Set<UInt32>(), failure = ""
        var firstFrames: [String] = []
        func control(_ data: Data) {
            lock.lock(); defer { lock.unlock() }; rtcpPackets += 1
            if reports.count < 5 { reports.append(contentsOf: RTCPSenderReport.parse(data)) }
        }
        func failed(_ error: RTSPError) { lock.lock(); defer { lock.unlock() }; failure = error.message }
        func accept(_ media: EncodedMedia) {
            lock.lock(); defer { lock.unlock() }; frames += 1
            if let ssrc = media.ssrc { sources.insert(ssrc) }
            if firstFrames.count < 8 { firstFrames.append("rtp=\(media.frame.timestamp) received=\(media.receivedAt.timeIntervalSince1970)") }
            if let utc = media.cameraUTC {
                mapped += 1; offsets.append(media.receivedAt.timeIntervalSince1970 - utc)
            }
            if let time = media.time { canonical.insert(time.canonicalSource.rawValue) }
        }
        var enough: Bool { lock.lock(); defer { lock.unlock() }; return mapped >= 120 }
        func summary() -> String {
            lock.lock(); defer { lock.unlock() }
            return "frames=\(frames) mapped=\(mapped) receipt-minus-camera=\(offsets.min() ?? .nan)...\(offsets.max() ?? .nan)s canonical=\(canonical.sorted()) rtcp=\(rtcpPackets) reports=\(reports) sources=\(sources) first=\(firstFrames) failure=\(failure)"
        }
    }
    func testHomebaseCameraClockMapping() async throws {
        guard ProcessInfo.processInfo.environment["HBNVR_LIVE_CLOCK_TEST"] == "1" else { throw XCTSkip("Opt-in live-camera clock probe") }
        let directory = HomebaseImport.defaultDirectory
        for endpoint in try HomebaseImport.cameras(directory: directory) {
            let configuration = try HomebaseImport.configuration(endpoint, name: "Timing probe", directory: directory)
            let credentials = try XCTUnwrap(configuration.credentials)
            let onvif = ONVIFClient(endpoint: endpoint, credentials: credentials)
            let deadline = ProcessInfo.processInfo.systemUptime + 20
            let media = try onvif.media(expectedID: nil, deadline: deadline)
            let profile = try XCTUnwrap(media.profiles.last)
            let url = try XCTUnwrap(URL(string: onvif.stream(profile: profile, media: media, deadline: deadline)))
            let observation = Observation()
            let record = ProcessInfo.processInfo.environment["HBNVR_LIVE_CLOCK_RECORD"] == "1"
            let helper = StoreTests(), root = record ? try helper.temporary() : nil
            defer { if let root { try? FileManager.default.removeItem(atPath: root) } }
            var store: LocalRecordingStore?
            var storeConfig: RecordingStoreConfiguration?
            let cameraID = UUID().uuidString
            if let root {
                var config = try helper.config(root + "/local"); config.shardDuration = "2s"
                storeConfig = config; store = try LocalRecordingStore(configuration: config)
            }
            let recording = store
            defer { _ = recording?.finish(timeout: 30) }
            let client = RTSPClient(source: .init(cameraIdentifier: media.deviceID, streamURL: url,
                username: credentials.username, password: credentials.password, authenticated: true, preferredCodec: nil), rtcpObserver: { observation.control($0) }) { event in
                if case .video(_, _, _, let sample?) = event {
                    observation.accept(sample)
                    recording?.accept(.media(camera: cameraID, name: "Clock probe", sample))
                }
                if case .failed(let error) = event { observation.failed(error) }
            }
            client.start()
            let seconds = Double(ProcessInfo.processInfo.environment["HBNVR_LIVE_CLOCK_SECONDS"] ?? "45") ?? 45
            let end = ProcessInfo.processInfo.systemUptime + min(60, max(5, seconds))
            while !observation.enough && ProcessInfo.processInfo.systemUptime < end { try await Task.sleep(for: .milliseconds(100)) }
            let stopped = DispatchSemaphore(value: 0); client.stop { stopped.signal() }
            XCTAssertEqual(stopped.wait(timeout: .now() + 5), .success)
            FileHandle.standardOutput.write(Data("CAMERA CLOCK \(endpoint.ipAddress): \(observation.summary())\n".utf8))
            XCTAssertTrue(observation.enough, "No usable RTCP camera-clock mapping observed")
            if let recording, let config = storeConfig {
                XCTAssertTrue(recording.finish(timeout: 30)); XCTAssertNil(recording.snapshot().lastError)
                let path = config.directory + "/Clock probe"
                let directory = LocalRecordingLayout.Directory(path: path, fd: try StoreDirectory.openDirectory(path))
                let db = try LocalRecordingManifest(directory: directory, identity: .init(storeID: config.id, cameraID: cameraID), owner: geteuid(), readOnly: true)
                let rows = try db.recordings()
                XCTAssertTrue(rows.contains { $0.timing.time.canonicalSource == .camera })
                for row in rows {
                    let asset = AVURLAsset(url: URL(fileURLWithPath: path + "/" + row.filename))
                    let embedded = try await ShardTimingMetadata.read(from: asset)
                    XCTAssertEqual(embedded, row.timing)
                    let playable = try await asset.load(.isPlayable); XCTAssertTrue(playable)
                }
                FileHandle.standardOutput.write(Data("LIVE SHARDS \(endpoint.ipAddress): \(rows.count) playable MP4s, embedded timing matches SQLite; temporary footage removed after test.\n".utf8))
            }
        }
    }
}
