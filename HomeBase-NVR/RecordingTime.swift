import Foundation
import AVFoundation
import CoreMedia

/// RTCP SR timestamps map a source's RTP clock to its own wall clock (RFC 3550 §6.4.1).
/// Malformed compounds are ignored as a whole; they must never break video reception.
struct RTCPSenderReport: Equatable, Sendable {
    let ssrc: UInt32
    let ntpSeconds: UInt32
    let ntpFraction: UInt32
    let rtpTimestamp: UInt32

    static func parse(_ bytes: Data) -> [Self] {
        let data = Data(bytes) // normalize slices before indexing packet offsets
        func word(_ i: Int) -> UInt32 { data[i..<i + 4].reduce(0) { ($0 << 8) | UInt32($1) } }
        var offset = 0, reports: [Self] = []
        while offset < data.count {
            guard data.count - offset >= 4, data[offset] >> 6 == 2 else { return [] }
            let length = (Int(data[offset + 2]) * 256 + Int(data[offset + 3]) + 1) * 4
            guard length <= data.count - offset else { return [] }
            var contentLength = length
            if data[offset] & 0x20 != 0 {
                let padding = Int(data[offset + length - 1])
                guard offset + length == data.count, padding > 0, padding <= length - 4 else { return [] }
                contentLength -= padding
            }
            if data[offset + 1] == 200 {
                guard contentLength >= 28 + Int(data[offset] & 31) * 24 else { return [] }
                reports.append(.init(ssrc: word(offset + 4), ntpSeconds: word(offset + 8),
                                     ntpFraction: word(offset + 12), rtpTimestamp: word(offset + 16)))
            }
            offset += length
        }
        return reports
    }
    func unixTime(near received: Date) -> Double? {
        guard ntpSeconds != 0 || ntpFraction != 0 else { return nil }
        let offset = 2_208_988_800.0, era = 4_294_967_296.0
        let reference = received.timeIntervalSince1970 + offset
        // Before the first NTP rollover, a clear high bit denotes a relative
        // clock, not UTC. After rollover choose the era nearest the receiver.
        guard reference >= era || ntpSeconds & 0x80000000 != 0 else { return nil }
        let eraNumber = ((reference - Double(ntpSeconds)) / era).rounded()
        return Double(ntpSeconds) + eraNumber * era + Double(ntpFraction) / era - offset
    }
}

struct RTPCameraClock {
    struct Sample { let utc: Double; let evidence: CameraClockEvidence }
    private struct Point { let report: RTCPSenderReport; let utc: Double; let uptime: Double }
    private struct Anchor {
        let point: Point; let previous: Point?; let earlier: Point?
        var fractionEncoding: CameraClockEvidence.FractionEncoding?
    }
    private struct ChannelAnchor { let point: Point; let utc: Double; let rate: UInt32; let evidence: CameraClockEvidence }
    private var channelAnchor: ChannelAnchor?
    private var anchors: [UInt32: Anchor] = [:]
    private var source: UInt32?
    private var sourceSince: Double = 0
    let allowInterleavedChannelBinding: Bool
    init(allowInterleavedChannelBinding: Bool = false) { self.allowInterleavedChannelBinding = allowInterleavedChannelBinding }
    static let maximumAge: Double = 120
    mutating func receive(_ data: Data, at date: Date, uptime: Double) {
        anchors = anchors.filter { uptime - $0.value.point.uptime <= Self.maximumAge }
        for report in RTCPSenderReport.parse(data) {
            guard let utc = report.unixTime(near: date) else { continue }
            if anchors[report.ssrc] == nil, anchors.count >= 8,
               let oldest = anchors.min(by: { $0.value.point.uptime < $1.value.point.uptime })?.key { anchors.removeValue(forKey: oldest) }
            if anchors[report.ssrc]?.point.report == report { continue } // replay is not fresh evidence
            anchors[report.ssrc] = Anchor(point: Point(report: report, utc: utc, uptime: uptime),
                previous: anchors[report.ssrc]?.point, earlier: anchors[report.ssrc]?.previous,
                fractionEncoding: anchors[report.ssrc]?.fractionEncoding)
        }
    }
    func time(ssrc: UInt32, timestamp: UInt32, rate: UInt32, uptime: Double) -> Double? {
        guard let anchor = anchors[ssrc], let utc = time(anchor.point, timestamp: timestamp, rate: rate, uptime: uptime) else { return nil }
        if anchor.fractionEncoding == .nanoseconds { return nanoseconds(anchor.point).map { utc + ($0 - anchor.point.utc) } }
        return utc
    }
    private func time(_ anchor: Point, timestamp: UInt32, rate: UInt32, uptime: Double) -> Double? {
        guard rate > 0, uptime >= anchor.uptime, uptime - anchor.uptime <= Self.maximumAge else { return nil }
        let delta = Double(Int32(bitPattern: timestamp &- anchor.report.rtpTimestamp)) / Double(rate)
        guard abs(delta) <= Self.maximumAge else { return nil }
        return anchor.utc + delta
    }
    mutating func mapping(ssrc: UInt32, timestamp: UInt32, rate: UInt32, uptime: Double) -> Sample? {
        if source != ssrc { source = ssrc; sourceSince = uptime; channelAnchor = nil }
        if let utc = time(ssrc: ssrc, timestamp: timestamp, rate: rate, uptime: uptime) {
            return Sample(utc: utc, evidence: .init(method: .ssrc, reportSSRC: ssrc, fractionEncoding: anchors[ssrc]?.fractionEncoding ?? .ntp))
        }
        // Some cameras (including the tested TP-Link pair) give RTCP its own
        // SSRC. Only the receiver of a single, explicitly negotiated video/RTCP
        // channel pair may opt into binding by that channel. Never guess across
        // tracks, multiple report sources, clock rates, or stale/replayed reports.
        let fresh = anchors.values.filter { uptime >= $0.point.uptime && uptime - $0.point.uptime <= Self.maximumAge }
        guard allowInterleavedChannelBinding, rate > 0, fresh.count == 1, let anchor = fresh.first else {
            channelAnchor = nil; return nil
        }
        if let sample = channelMapping(anchor, timestamp: timestamp, rate: rate, uptime: uptime) { return sample }
        // A single inconsistent report must not erase recently validated evidence.
        // This never extends the five-second freshness of that good report.
        guard let cached = channelAnchor, cached.rate == rate,
              cached.evidence.reportSSRC == anchor.point.report.ssrc,
              uptime >= cached.point.uptime, uptime - cached.point.uptime <= 5 else { return nil }
        let delta = Double(Int32(bitPattern: timestamp &- cached.point.report.rtpTimestamp)) / Double(rate)
        guard abs(delta) <= 5 else { return nil }
        return Sample(utc: cached.utc + delta, evidence: cached.evidence)
    }
    private mutating func channelMapping(_ anchor: Anchor, timestamp: UInt32, rate: UInt32, uptime: Double) -> Sample? {
        guard let previous = anchor.previous, previous.uptime >= sourceSince,
              anchor.point.uptime - previous.uptime > 0, anchor.point.uptime - previous.uptime <= 5 else { return nil }
        let ticks = Double(Int32(bitPattern: anchor.point.report.rtpTimestamp &- previous.report.rtpTimestamp)) / Double(rate)
        var elapsed = anchor.point.utc - previous.utc
        var base = anchor.point.utc
        var encoding = anchor.fractionEncoding ?? .ntp
        if encoding == .nanoseconds {
            guard let a = nanoseconds(previous), let b = nanoseconds(anchor.point) else { return nil }
            base = b; elapsed = b - a
        }
        // A second observed firmware defect: the fractional word contains
        // nanoseconds rather than NTP's 2^-32 fractions. Only infer this on the
        // already isolated channel after THREE reports / two coherent intervals,
        // and only when standard interpretation actually fails the cadence test.
        if encoding == .ntp, abs(ticks - elapsed) > 0.1, let earlier = anchor.earlier,
           earlier.uptime >= sourceSince, previous.uptime > earlier.uptime,
           previous.uptime - earlier.uptime <= 5,
           let a = nanoseconds(earlier), let b = nanoseconds(previous), let c = nanoseconds(anchor.point) {
            let priorTicks = Double(Int32(bitPattern: previous.report.rtpTimestamp &- earlier.report.rtpTimestamp)) / Double(rate)
            if priorTicks > 0, b > a, c > b, abs((b - a) - priorTicks) <= 0.1, abs((c - b) - ticks) <= 0.1 {
                base = c; elapsed = c - b; encoding = .nanoseconds
            }
        }
        let frameOffset = Double(Int32(bitPattern: timestamp &- anchor.point.report.rtpTimestamp)) / Double(rate)
        guard ticks > 0, elapsed > 0, abs(ticks - elapsed) <= 0.1,
              abs(frameOffset) <= 5, uptime - anchor.point.uptime <= 5,
              let utc = time(anchor.point, timestamp: timestamp, rate: rate, uptime: uptime) else { return nil }
        let evidence = CameraClockEvidence(method: .interleavedChannel, reportSSRC: anchor.point.report.ssrc, fractionEncoding: encoding)
        anchors[anchor.point.report.ssrc]?.fractionEncoding = encoding
        channelAnchor = ChannelAnchor(point: anchor.point, utc: base, rate: rate, evidence: evidence)
        return Sample(utc: utc + (base - anchor.point.utc), evidence: evidence)
    }
    private func nanoseconds(_ point: Point) -> Double? {
        guard point.report.ntpFraction < 1_000_000_000 else { return nil }
        return point.utc - Double(point.report.ntpFraction) / 4_294_967_296 + Double(point.report.ntpFraction) / 1_000_000_000
    }
}

struct CameraClockEvidence: Codable, Equatable, Sendable {
    enum Method: String, Codable, Sendable { case ssrc, interleavedChannel }
    enum FractionEncoding: String, Codable, Sendable { case ntp, nanoseconds }
    let method: Method
    let reportSSRC: UInt32
    let fractionEncoding: FractionEncoding
}

enum CanonicalTimeSource: String, Codable, Sendable { case camera, received }

/// All three anchors describe the SAME media instant. ReceivedUTC is a smooth
/// receipt-anchored timeline, not a log of individual packet arrival times.
struct RecordingTime: Codable, Equatable, Sendable {
    let cameraUTC: Double?
    let receivedUTC: Double
    let canonicalUTC: Double
    let canonicalSource: CanonicalTimeSource
    let epochID: String
    var cameraClock: CameraClockEvidence? = nil
    static let cameraTolerance: Double = 2.5
}

/// Shared at reception, before fan-out to stores. Epochs freeze their mapping;
/// source/mapping changes wait for a keyframe, never rewrite an existing shard.
struct RecordingTimeline {
    private var first: RecordingTime?
    private var last: EncodedMedia?
    private var ticks: Int64 = 0
    private var lastDelta: Int64 = 0
    mutating func observe(_ media: EncodedMedia) throws -> RecordingTime {
        guard media.clockRate > 0, media.receivedAt.timeIntervalSince1970.isFinite,
              media.receivedUptime.isFinite, media.cameraUTC?.isFinite != false else { throw ServiceError("Invalid recording clock.") }
        var reset = first == nil
        if let last {
            let delta = Int64(Int32(bitPattern: media.frame.timestamp &- last.frame.timestamp))
            reset = media.clockRate != last.clockRate || media.ssrc != last.ssrc
                || abs(media.receivedAt.timeIntervalSince(last.receivedAt) - (media.receivedUptime - last.receivedUptime)) > 1
                || Double(delta) / Double(media.clockRate) > max(2, 8 * Double(lastDelta) / Double(media.clockRate))
            if !reset && delta <= 0 { throw ServiceError("This stream reorders presentation timestamps; recording requires a no-B-frame camera profile in this increment.") }
            if !reset { ticks += delta }
            lastDelta = delta
        }
        let received = media.receivedAt.timeIntervalSince1970
        let candidate: CanonicalTimeSource = media.cameraUTC.map { abs($0 - received) <= RecordingTime.cameraTolerance } == true ? .camera : .received
        if let first, !reset, media.frame.keyFrame {
            let elapsed = Double(ticks) / Double(media.clockRate)
            let mappingChanged: Bool
            if let camera = media.cameraUTC, let anchor = first.cameraUTC {
                mappingChanged = abs(camera - (anchor + elapsed)) > 0.25
            } else { mappingChanged = (media.cameraUTC == nil) != (first.cameraUTC == nil) }
            reset = candidate != first.canonicalSource || mappingChanged || media.cameraClock != first.cameraClock
        }
        if reset {
            ticks = 0; lastDelta = 0
            first = RecordingTime(cameraUTC: media.cameraUTC, receivedUTC: received,
                canonicalUTC: candidate == .camera ? media.cameraUTC! : received,
                canonicalSource: candidate, epochID: UUID().uuidString, cameraClock: media.cameraClock)
        }
        last = media
        let first = first!, elapsed = Double(ticks) / Double(media.clockRate)
        return RecordingTime(cameraUTC: first.cameraUTC.map { $0 + elapsed }, receivedUTC: first.receivedUTC + elapsed,
            canonicalUTC: first.canonicalUTC + elapsed, canonicalSource: first.canonicalSource, epochID: first.epochID, cameraClock: first.cameraClock)
    }
}

/// Written verbatim to both MP4 metadata and the SQLite index. No credentials.
struct ShardTimingMetadata: Codable, Equatable, Sendable {
    static let key = "com.graygoolabs.hbnvr.timing"
    let format: String
    let schemaVersion: Int
    let storeID: String
    let cameraID: String
    let shardID: String
    let time: RecordingTime
    let firstFrameReceivedUTC: Double
    let timescale: UInt32
    let rtpTimestamp: UInt32
    let ssrc: UInt32?
    init(storeID: String, cameraID: String, shardID: String = UUID().uuidString, media: EncodedMedia, time: RecordingTime) {
        format = Self.key; schemaVersion = 1; self.storeID = storeID; self.cameraID = cameraID; self.shardID = shardID
        self.time = time; firstFrameReceivedUTC = media.receivedAt.timeIntervalSince1970
        timescale = media.clockRate; rtpTimestamp = media.frame.timestamp; ssrc = media.ssrc
    }
    func json() throws -> String {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
    func validate() throws {
        guard format == Self.key, schemaVersion == 1, [storeID, cameraID, shardID, time.epochID].allSatisfy({ UUID(uuidString: $0) != nil }),
              timescale > 0, timescale <= Int32.max, firstFrameReceivedUTC.isFinite,
              time.cameraUTC?.isFinite != false, time.receivedUTC.isFinite, time.canonicalUTC.isFinite,
              time.canonicalUTC == (time.canonicalSource == .camera ? time.cameraUTC : time.receivedUTC) else {
            throw ServiceError("Invalid shard timing metadata.")
        }
    }
    func assetMetadata() throws -> [AVMetadataItem] {
        let item = AVMutableMetadataItem()
        // Arbitrary mdta keys are silently discarded by AVAssetWriter's MP4
        // output. Description round-trips as ISO user data ('dscp'); the payload
        // identifies its own format instead of relying on AVFoundation's alias.
        item.identifier = .iTunesMetadataDescription
        item.value = try json() as NSString; item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return [item]
    }
    static func read(from asset: AVAsset) async throws -> Self? {
        for item in try await asset.load(.metadata) {
            guard let string = try await item.load(.stringValue), string.utf8.count <= 64 * 1024,
                  let value = try? JSONDecoder().decode(Self.self, from: Data(string.utf8)), value.format == key else { continue }
            try value.validate(); return value
        }
        return nil
    }
}
