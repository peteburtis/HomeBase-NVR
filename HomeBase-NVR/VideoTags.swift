import Foundation
import Darwin

/// Opaque application metadata. No key has an NVR-defined meaning.
enum VideoTags {
    static let maximumJSONBytes = 8192
    static func validate(_ tags: [String: String]) throws {
        guard tags.count <= 32, tags.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 256 && $0.value.utf8.count <= 2048 }),
              try JSONEncoder().encode(tags).count <= maximumJSONBytes else {
            throw ServiceError(.invalidMessage, "Tags allow at most 32 keys, 256 UTF-8 bytes per key, 2048 per value, and 8192 encoded JSON bytes in total. Keys cannot be empty.")
        }
    }
}

/// Complete state at each change, relative to the first sample of one shard.
/// Missing metadata in an older file is unknown, NOT a known empty dictionary.
struct VideoTagTimeline: Codable, Equatable, Sendable {
    struct Change: Codable, Equatable, Sendable {
        let ticks: Int64
        let frame: Int64
        let tags: [String: String]
    }
    var version = 1
    var changes: [Change] = []
    // An explicit unknown tail protects recording under abusive metadata churn.
    // Readers must never interpret this tail as untagged footage.
    var unknownFromTicks: Int64?
    // Exact sample boundary for new recordings; older timelines use ticks.
    var unknownFromFrame: Int64? = nil
    // v2 records finite historical overrides. A nil value is an explicit
    // removal, including over unknown legacy state; it never falls back to MP4.
    struct Override: Codable, Equatable, Sendable {
        let start: Int64
        let end: Int64
        let key: String
        let value: String?
    }
    var overrides: [Override]? = nil
    static let maximumBytes = 512 * 1024
    func validate() throws {
        guard [1, 2].contains(version), changes.count <= 4096,
              (changes.first?.ticks == 0 && changes.first?.frame == 0)
                || (version == 2 && changes.isEmpty && unknownFromTicks == 0),
              version == 2 || overrides == nil else { throw ServiceError("Invalid recording tag timeline.") }
        var previous: Change?
        for change in changes {
            try VideoTags.validate(change.tags)
            guard change.ticks >= 0, change.frame >= 0,
                  previous.map({ change.ticks > $0.ticks && change.frame > $0.frame }) ?? true else {
                throw ServiceError("Invalid recording tag boundary.")
            }
            previous = change
        }
        if let unknownFromTicks, unknownFromTicks <= (previous?.ticks ?? -1) { throw ServiceError("Invalid unknown tag boundary.") }
        if let unknownFromFrame {
            guard unknownFromTicks != nil, unknownFromFrame >= 0,
                  unknownFromFrame > (previous?.frame ?? -1) else { throw ServiceError("Invalid unknown tag frame boundary.") }
        }
        guard (overrides?.count ?? 0) <= 4096 else { throw ServiceError("Too many historical tag intervals.") }
        var keys = Set<String>()
        for edit in overrides ?? [] {
            guard edit.start >= 0, edit.end > edit.start else { throw ServiceError("Invalid historical tag interval.") }
            try VideoTags.validate([edit.key: edit.value ?? ""])
            keys.insert(edit.key)
        }
        // Bound both the vocabulary and all effective dictionaries, not just
        // individual operations. Failed historical edits never truncate tags.
        guard keys.count <= 32 else { throw ServiceError("Too many historical tag keys.") }
        if !(overrides ?? []).isEmpty {
            let boundaries = Set(changes.map(\.ticks) + (overrides ?? []).flatMap { [$0.start, $0.end] })
            for tick in boundaries { try VideoTags.validate(state(at: tick).values) }
        }
        guard try JSONEncoder().encode(self).count <= Self.maximumBytes else { throw ServiceError("Recording tag metadata is oversized.") }
    }
    func tags(at ticks: Int64) -> [String: String]? {
        let value = state(at: ticks)
        return value.complete ? value.values : nil
    }
    struct State: Codable, Equatable {
        var values: [String: String]
        var knownAbsent: [String]
        let complete: Bool
    }
    func state(at ticks: Int64) -> State {
        let base = ticks >= 0 && (unknownFromTicks.map { ticks < $0 } ?? true)
            ? changes.last(where: { $0.ticks <= ticks })?.tags : nil
        var result = State(values: base ?? [:], knownAbsent: [], complete: base != nil)
        for edit in overrides ?? [] where ticks >= edit.start && ticks < edit.end {
            result.values[edit.key] = edit.value
            result.knownAbsent.removeAll { $0 == edit.key }
            if edit.value == nil { result.knownAbsent.append(edit.key) }
        }
        result.knownAbsent.sort()
        return result
    }
    static var unknown: Self { Self(version: 2, unknownFromTicks: 0) }
    mutating func apply(_ edit: Override) throws {
        var next = self
        next.version = 2
        // Replace only the overlapping portion for this key. This keeps repeated
        // jobs idempotent and prevents unbounded growth of an operation log.
        var values: [Override] = []
        for old in overrides ?? [] {
            if old.key != edit.key || old.end <= edit.start || old.start >= edit.end { values.append(old); continue }
            if old.start < edit.start { values.append(.init(start: old.start, end: edit.start, key: old.key, value: old.value)) }
            if old.end > edit.end { values.append(.init(start: edit.end, end: old.end, key: old.key, value: old.value)) }
        }
        values.append(edit)
        values.sort { ($0.key, $0.start, $0.end) < ($1.key, $1.start, $1.end) }
        var merged: [Override] = []
        for value in values {
            if let last = merged.last, last.key == value.key, last.value == value.value, last.end == value.start {
                merged[merged.count - 1] = .init(start: last.start, end: value.end, key: value.key, value: value.value)
            } else { merged.append(value) }
        }
        next.overrides = merged
        try next.validate(); self = next
    }
}

struct VideoTagAccumulator {
    private(set) var timeline = VideoTagTimeline()
    private var estimatedBytes = 128
    var residentBytes: Int64 { Int64(estimatedBytes) }
    /// Amend already accepted samples without changing subsequent camera tags.
    /// Validate the complete replacement before mutating the writer's state.
    mutating func apply(overrides: [VideoTagTimeline.Override]) throws {
        var next = timeline
        for edit in overrides { try next.apply(edit) }
        let bytes = try JSONEncoder().encode(next).count
        timeline = next
        estimatedBytes = bytes + 128
    }
    /// Returns true only on the first overflow; the caller logs it. Video continues.
    @discardableResult mutating func append(_ tags: [String: String], ticks: Int64, frame: Int64) throws -> Bool {
        guard timeline.unknownFromTicks == nil, timeline.changes.last?.tags != tags else { return false }
        try VideoTags.validate(tags)
        let size = try JSONEncoder().encode(tags).count + 96
        if estimatedBytes + size > VideoTagTimeline.maximumBytes || timeline.changes.count == 4096 {
            timeline.unknownFromTicks = ticks
            timeline.unknownFromFrame = frame
            return true
        }
        timeline.changes.append(.init(ticks: ticks, frame: frame, tags: tags))
        estimatedBytes += size
        return false
    }
}

/// Public playback projection: only value-bearing spans. Unknown and absent
/// both have no value; internal tombstones never cross the media protocol.
enum MediaTagRanges {
    struct Span: Codable, Equatable {
        let startFrame: Int
        let endFrame: Int // exclusive, relative to the returned segment/preroll
        let value: String
    }
    struct Point: Equatable {
        let ticks: Int64
        let frame: Int64 // original shard sample ordinal, not nominal-FPS math
    }
    typealias Map = [String: [Span]]

    static func build(_ timeline: VideoTagTimeline?, points: [Point], work: MediaWork) throws -> Map {
        guard points.count <= MediaLimits.taggedFrames else { throw ServiceError(.invalidMessage, "Too many frames for segment tags; request a smaller range.") }
        try work.check()
        guard let timeline, !points.isEmpty else { return [:] }
        try timeline.validate()
        for pair in zip(points, points.dropFirst()) {
            guard pair.0.ticks < pair.1.ticks, pair.0.frame < pair.1.frame else { throw ServiceError("Tag frame coordinates are not ordered.") }
        }
        func lower(_ value: Int64, frame: Bool) -> Int {
            var lo = 0, hi = points.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if (frame ? points[mid].frame : points[mid].ticks) < value { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }
        func coalesce(_ spans: [Span]) -> [Span] {
            var result: [Span] = []
            for span in spans where span.endFrame > span.startFrame {
                if let last = result.last, last.endFrame == span.startFrame, last.value == span.value {
                    result[result.count - 1] = .init(startFrame: last.startFrame, endFrame: span.endFrame, value: span.value)
                } else { result.append(span) }
            }
            return result
        }
        var map: Map = [:], count = 0
        func checkBound() throws {
            guard count <= MediaLimits.tagRanges else { throw ServiceError(.invalidMessage, "Too many tag ranges; request a smaller video range.") }
        }
        let knownEnd = timeline.unknownFromFrame.map { lower($0, frame: true) }
            ?? timeline.unknownFromTicks.map { lower($0, frame: false) } ?? points.count
        // Prospective changes carry exact sample ordinals. This avoids moving a
        // change one frame late when an MP4 track rounds its presentation clock.
        for (i, change) in timeline.changes.enumerated() {
            try work.check()
            let start = lower(change.frame, frame: true)
            let end = min(knownEnd, i + 1 < timeline.changes.count ? lower(timeline.changes[i + 1].frame, frame: true) : points.count)
            if end <= start { continue }
            for (key, value) in change.tags {
                var spans = map[key] ?? []
                if let last = spans.last, last.endFrame == start, last.value == value {
                    spans[spans.count - 1] = .init(startFrame: last.startFrame, endFrame: end, value: value)
                } else { spans.append(.init(startFrame: start, endFrame: end, value: value)); count += 1 }
                map[key] = spans
            }
            try checkBound()
        }
        // Historical overrides use the same sample PTS coordinate system as
        // historical editing. Explicit removal erases, never falls back to base.
        for edit in timeline.overrides ?? [] {
            try work.check()
            let start = lower(edit.start, frame: false), end = lower(edit.end, frame: false)
            if start >= end { continue }
            let old = map[edit.key] ?? []
            var spans: [Span] = []
            for span in old {
                if span.endFrame <= start || span.startFrame >= end { spans.append(span); continue }
                if span.startFrame < start { spans.append(.init(startFrame: span.startFrame, endFrame: start, value: span.value)) }
                if span.endFrame > end { spans.append(.init(startFrame: end, endFrame: span.endFrame, value: span.value)) }
            }
            if let value = edit.value { spans.append(.init(startFrame: start, endFrame: end, value: value)) }
            spans = coalesce(spans.sorted { $0.startFrame < $1.startFrame })
            count += spans.count - old.count
            map[edit.key] = spans.isEmpty ? nil : spans
            try checkBound()
        }
        return map
    }

    static func encode(_ timeline: VideoTagTimeline?, points: [Point], work: MediaWork) throws -> Data {
        let map = try build(timeline, points: points, work: work)
        // Bound before JSON allocation as well as after escaping. The maximum
        // per-value/key sizes were validated by the timeline.
        var estimate = 2
        for (key, spans) in map {
            estimate += key.utf8.count + 8
            for span in spans { estimate += span.value.utf8.count + 80 }
            guard estimate <= MediaLimits.tagBytes else { throw ServiceError(.invalidMessage, "Segment tag metadata exceeds its limit; request a smaller range.") }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(map)
        guard data.count <= MediaLimits.tagBytes else { throw ServiceError(.invalidMessage, "Segment tag metadata exceeds its limit; request a smaller range.") }
        try work.check(); return data
    }
    static func emit(_ segment: MediaSegment, tags: Data?, frameCount: Int, requestID: String,
                     work: MediaWork, emit: (MediaMessage) throws -> Void, bytes: (Data) throws -> Void) throws {
        var segment = segment
        if let tags {
            segment.tagRangesVersion = 1; segment.tagFrameCount = frameCount; segment.tagByteCount = tags.count
        }
        var message = MediaMessage(type: "segment", requestID: requestID); message.segment = segment
        try emit(message)
        if let tags {
            for start in stride(from: 0, to: tags.count, by: MediaLimits.messageBytes) {
                try work.check()
                try bytes(tags.subdata(in: start..<min(start + MediaLimits.messageBytes, tags.count)))
            }
        }
    }
}

/// Private ISO-BMFF UUID box, appended after finalization without moving samples.
/// No video decode/re-encode, no temporary plaintext S3 file, no custom media track.
enum VideoTagMP4 {
    static let identifier = Data([0x59, 0x6a, 0x0f, 0x37, 0x0b, 0xaf, 0x43, 0x7e, 0x9a, 0xab, 0x62, 0x1d, 0x5b, 0x9d, 0xf7, 0x60])
    static func box(_ timeline: VideoTagTimeline) throws -> Data {
        try timeline.validate()
        let payload = try JSONEncoder().encode(timeline)
        var size = UInt32(payload.count + 24).bigEndian
        return withUnsafeBytes(of: &size) { Data($0) } + Data("uuid".utf8) + identifier + payload
    }
    static func append(_ timeline: VideoTagTimeline, fd: Int32) throws {
        let data = try box(timeline)
        let offset = lseek(fd, 0, SEEK_END)
        guard offset >= 0 else { throw ServiceError.posix("Seek recording tag metadata") }
        try data.withUnsafeBytes { bytes in
            var done = 0
            while done < bytes.count {
                let n = pwrite(fd, bytes.baseAddress!.advanced(by: done), bytes.count - done, offset + off_t(done))
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw ServiceError.posix("Write recording tag metadata") }
                done += n
            }
        }
    }
    static func read(_ data: Data) throws -> VideoTagTimeline? {
        var offset = 0, found: VideoTagTimeline?
        func integer(_ start: Int, _ count: Int) -> UInt64 {
            data[data.startIndex + start..<data.startIndex + start + count].reduce(0) { ($0 << 8) | UInt64($1) }
        }
        while offset < data.count {
            guard data.count - offset >= 8 else { throw ServiceError("Truncated MP4 box.") }
            let small = integer(offset, 4)
            var header = 8
            let size: UInt64
            if small == 1 {
                guard data.count - offset >= 16 else { throw ServiceError("Truncated extended MP4 box.") }
                size = integer(offset + 8, 8); header = 16
            } else { size = small == 0 ? UInt64(data.count - offset) : small }
            guard size >= header, size <= data.count - offset else { throw ServiceError("Invalid MP4 box length.") }
            let base = data.startIndex
            if data[base + offset + 4..<base + offset + 8] == Data("uuid".utf8), size >= header + 16,
               data[base + offset + header..<base + offset + header + 16] == identifier {
                guard found == nil, size - UInt64(header + 16) <= VideoTagTimeline.maximumBytes else { throw ServiceError("Duplicate or oversized MP4 tags.") }
                let payload = data.subdata(in: base + offset + header + 16..<base + offset + Int(size))
                let value = try JSONDecoder().decode(VideoTagTimeline.self, from: payload)
                try value.validate(); found = value
            }
            offset += Int(size)
        }
        return found
    }
}

/// Frozen tag envelope travels through the existing spool/journal without
/// exposing encrypted footage's tag values in plaintext metadata sidecars.
/// It uses the same password/envelope as the shard, independently decryptable.
struct StoredVideoTags: Codable, Equatable, Sendable {
    let timeline: VideoTagTimeline?
    let encrypted: Data?
    var residentBytes: Int64 {
        if let encrypted { return Int64(encrypted.count) }
        guard let timeline else { return 0 }
        var total = 128
        for change in timeline.changes {
            total += 96
            for (key, value) in change.tags { total += key.utf8.count + value.utf8.count + 64 }
        }
        for edit in timeline.overrides ?? [] {
            total += 96 + edit.key.utf8.count + (edit.value?.utf8.count ?? 0)
        }
        return Int64(total)
    }
    static func freeze(_ timeline: VideoTagTimeline, password: String?) throws -> Self {
        try timeline.validate()
        if let password { return Self(timeline: nil, encrypted: try RecordingEncryption.encrypt(JSONEncoder().encode(timeline), password: password)) }
        return Self(timeline: timeline, encrypted: nil)
    }
    func validate() throws {
        guard (timeline == nil) != (encrypted == nil) else { throw ServiceError("Invalid stored tag envelope.") }
        try timeline?.validate()
        if let encrypted {
            guard encrypted.count <= VideoTagTimeline.maximumBytes + RecordingEncryption.overhead else { throw ServiceError("Oversized encrypted tags.") }
            try RecordingEncryption.validateEnvelopeHeader(Data(encrypted.prefix(RecordingEncryption.headerSize)), size: Int64(encrypted.count))
        }
    }
    func thaw(password: String?) throws -> VideoTagTimeline {
        try validate()
        if let timeline { return timeline }
        guard let password else { throw ServiceError("The original metadata encryption password is required.") }
        do {
            let data = try RecordingEncryption.decrypt(encrypted!, password: password)
            let value = try JSONDecoder().decode(VideoTagTimeline.self, from: data)
            try value.validate(); return value
        } catch { throw ServiceError("Tag metadata could not be decrypted with the supplied password.") }
    }
}
