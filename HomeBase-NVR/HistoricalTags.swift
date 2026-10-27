import Foundation
import CryptoKit

/// Mutating history is separate from camera tags and never changes live state.
/// All ranges are half open. Every matching storage copy reflects the edit.
struct HistoricalTagRequest: Codable, Equatable, Sendable {
    struct Boundary: Codable, Equatable, Sendable {
        let timestamp: Double
        var frameOffset: Int = 0
    }
    struct Selection: Codable, Equatable, Sendable {
        var file: String? = nil
        var shardID: String? = nil
        var sourceStoreID: String? = nil
        var cameraID: String? = nil
        var timeline: MediaTimeline = .canonical
        var epochID: String? = nil
        var start: Boundary? = nil
        var end: Boundary? = nil
        var startFrame: Int? = nil
        var endFrame: Int? = nil
        var allFrames: Bool = false
    }
    struct Edit: Codable, Equatable, Sendable {
        let selection: Selection
        let key: String
        var value: String? = nil // nil removes; empty string is a value.
    }
    let jobID: String
    let edits: [Edit]
    // Internal optimistic checks; never accepted from the public footage API.
    var expectedRevisions: [String: String]? = nil
    var dryRun: Bool = false
    var inspect: Bool = false
    enum CodingKeys: String, CodingKey { case jobID, edits, dryRun, inspect }
    func validate() throws {
        guard UUID(uuidString: jobID) != nil, (1...64).contains(edits.count),
              (expectedRevisions?.count ?? 0) <= 128 else {
            throw ServiceError("Footage edits require a job UUID and 1–64 edits.")
        }
        for edit in edits {
            if !inspect { try VideoTags.validate([edit.key: edit.value ?? ""]) }
            let s = edit.selection
            for id in [s.shardID, s.sourceStoreID, s.cameraID, s.epochID].compactMap({ $0 }) {
                guard UUID(uuidString: id) != nil else { throw ServiceError("Invalid historical media identity.") }
            }
            if s.file != nil || s.shardID != nil {
                guard (s.file == nil) != (s.shardID == nil), s.start == nil, s.end == nil,
                      s.file.map({ $0.hasPrefix("/") && $0.utf8.count <= 4096 && !$0.utf8.contains(0)
                          && !$0.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) }) ?? true,
                      s.shardID == nil || s.sourceStoreID != nil else { throw ServiceError("Use an absolute managed file, or sourceStoreID plus shardID, without timestamp boundaries.") }
                guard (s.allFrames && s.startFrame == nil && s.endFrame == nil)
                        || (!s.allFrames && (s.startFrame ?? -1) >= 0 && (s.endFrame ?? -1) > s.startFrame!) else {
                    throw ServiceError("Specify allFrames or a nonempty zero-based [startFrame,endFrame) range.")
                }
            } else {
                guard s.cameraID != nil, s.sourceStoreID == nil, !s.allFrames, s.startFrame == nil, s.endFrame == nil,
                      let start = s.start, let end = s.end,
                      start.timestamp.isFinite, end.timestamp.isFinite,
                      start.timestamp >= 0, end.timestamp >= start.timestamp,
                      end.timestamp - start.timestamp <= 86400,
                      end.timestamp < 253402300799,
                      (0...1_000_000).contains(start.frameOffset), (0...1_000_000).contains(end.frameOffset),
                      end.timestamp > start.timestamp || end.frameOffset > start.frameOffset else {
                    throw ServiceError("Time selection requires a camera UUID, finite boundaries up to 24 hours apart, and nonnegative frame offsets.")
                }
            }
        }
    }
}

struct HistoricalTagResult: Codable, Equatable, Sendable {
    let storeID: String
    let cameraID: String
    let shardID: String
    let revision: String
    let changed: Bool
    var publication: String // internal storage result, not exposed on the wire
    var timeline: MediaTimeline = .canonical
    var epochID: String = ""
    var start: Double = 0
    var end: Double = 0

    enum CodingKeys: String, CodingKey { case cameraID, timeline, epochID, start, end, changed }
    init(storeID: String, cameraID: String, shardID: String, revision: String, changed: Bool,
         publication: String, timeline: MediaTimeline = .canonical, epochID: String = "", start: Double = 0, end: Double = 0) {
        self.storeID=storeID; self.cameraID=cameraID; self.shardID=shardID; self.revision=revision
        self.changed=changed; self.publication=publication; self.timeline=timeline; self.epochID=epochID
        self.start=start; self.end=end
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(storeID: "", cameraID: try c.decode(String.self, forKey: .cameraID), shardID: "", revision: "",
            changed: try c.decode(Bool.self, forKey: .changed), publication: "",
            timeline: try c.decode(MediaTimeline.self, forKey: .timeline), epochID: try c.decode(String.self, forKey: .epochID),
            start: try c.decode(Double.self, forKey: .start), end: try c.decode(Double.self, forKey: .end))
    }
}
struct HistoricalTagStatus: Codable, Sendable {
    struct Gap: Codable, Sendable {
        let cameraID: String
        let timeline: MediaTimeline
        let start: Double
        let end: Double
    }
    let jobID: String
    var state: String // preparing | applying | completed | failed
    var results: [HistoricalTagResult] = []
    // Internal storage rows support commit diagnostics; only logical footage
    // ranges are serialized across the API.
    var footageResults: [HistoricalTagResult]? = nil
    var gaps: [Gap] = []
    var error: String? = nil
    var message: String = "Validating footage edits; no changes committed yet."
    enum CodingKeys: String, CodingKey { case jobID, state, results, gaps, error, message }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(jobID, forKey: .jobID); try c.encode(state, forKey: .state)
        try c.encode(footageResults ?? results, forKey: .results)
        try c.encode(gaps, forKey: .gaps); try c.encodeIfPresent(error, forKey: .error)
        try c.encode(message, forKey: .message)
    }
}
enum HistoricalTags {
    static func revision(_ tags: VideoTagTimeline?) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(tags)).map { String(format: "%02x", $0) }.joined()
    }
    static func ticks(_ value: Double, anchor: Double, timescale: UInt32, end: Int64) throws -> Int64 {
        let ticks = (value - anchor) * Double(timescale)
        guard ticks.isFinite else { throw ServiceError("Invalid tag boundary.") }
        // A time boundary lies before the first sample whose PTS is >= it.
        // Account only for floating-point cancellation at Unix-time magnitude.
        let tolerance = max(value.ulp, anchor.ulp) * Double(timescale) * 2
        return Int64(max(0, min(Double(end), ceil(ticks - tolerance))))
    }
    static func frameBoundary(_ frame: Int, ticks: [Int64], end: Int64) throws -> Int64 {
        guard frame >= 0, frame <= ticks.count else { throw ServiceError("Frame boundary is outside the available source footage.") }
        return frame == ticks.count ? end : ticks[frame]
    }
}

// Explicit defaults are part of the IPC/JSON contract (synthesized Decodable
// does not apply stored-property defaults when a JSON field is absent).
extension HistoricalTagRequest.Boundary {
    init(from decoder: Decoder) throws {
        try FootageJSON.rejectUnknown(decoder, allowed: ["timestamp", "frameOffset"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try c.decode(Double.self, forKey: .timestamp)
        frameOffset = try c.decodeIfPresent(Int.self, forKey: .frameOffset) ?? 0
    }
}
extension HistoricalTagRequest.Selection {
    init(from decoder: Decoder) throws {
        try FootageJSON.rejectUnknown(decoder, allowed: ["file", "shardID", "sourceStoreID", "cameraID", "timeline", "epochID", "start", "end", "startFrame", "endFrame", "allFrames"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        file = try c.decodeIfPresent(String.self, forKey: .file)
        shardID = try c.decodeIfPresent(String.self, forKey: .shardID)
        sourceStoreID = try c.decodeIfPresent(String.self, forKey: .sourceStoreID)
        cameraID = try c.decodeIfPresent(String.self, forKey: .cameraID)
        timeline = try c.decodeIfPresent(MediaTimeline.self, forKey: .timeline) ?? .canonical
        epochID = try c.decodeIfPresent(String.self, forKey: .epochID)
        start = try c.decodeIfPresent(HistoricalTagRequest.Boundary.self, forKey: .start)
        end = try c.decodeIfPresent(HistoricalTagRequest.Boundary.self, forKey: .end)
        startFrame = try c.decodeIfPresent(Int.self, forKey: .startFrame)
        endFrame = try c.decodeIfPresent(Int.self, forKey: .endFrame)
        allFrames = try c.decodeIfPresent(Bool.self, forKey: .allFrames) ?? false
    }
}
extension HistoricalTagRequest {
    init(from decoder: Decoder) throws {
        try FootageJSON.rejectUnknown(decoder, allowed: ["jobID", "edits", "dryRun", "inspect"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jobID = try c.decode(String.self, forKey: .jobID)
        edits = try c.decode([Edit].self, forKey: .edits)
        dryRun = try c.decodeIfPresent(Bool.self, forKey: .dryRun) ?? false
        inspect = try c.decodeIfPresent(Bool.self, forKey: .inspect) ?? false
    }
}

// Storage identities remain internal. Public requests describe footage and the
// recorder resolves every matching copy; a source-store reference only locates
// the optional shard convenience selector.
struct RecordingTagSnapshot {
    let timing: ShardTimingMetadata
    let endTicks: Int64
    let frames: Int
    let tags: VideoTagTimeline
    let frameTicks: [Int64]
}
struct RecordingTagEdit {
    let snapshot: RecordingTagSnapshot
    let overrides: [VideoTagTimeline.Override]
}
struct FootageTagInspection: Codable, Equatable {
    let cameraID: String
    let timeline: MediaTimeline
    let epochID: String
    let start: Double
    var end: Double
    let tags: VideoTagTimeline.State
}

/// Short authoritative reads of metadata already held by the recorder. These
/// requests never download footage, create jobs, or target a storage copy.
struct FootageTagQuery: Codable, Equatable {
    struct Range: Codable, Equatable {
        let start: Double
        var end: Double
        var epochID: String? = nil
    }
    let cameraID: String
    let ranges: [Range]
    let keys: [String]
    func validate() throws {
        guard UUID(uuidString: cameraID) != nil, (1...64).contains(ranges.count),
              (1...32).contains(keys.count), Set(keys).count == keys.count,
              ranges.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0
                  && $0.end > $0.start && $0.end - $0.start <= 300 && $0.end < 253402300799
                  && ($0.epochID.map { !$0.isEmpty && $0.utf8.count <= 128
                      && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) } ?? true) }),
              ranges.reduce(0, { $0 + $1.end - $1.start }) <= 3600 else {
            throw ServiceError(.invalidMessage, "Tag snapshots require a camera UUID, 1–64 ranges of at most 300 seconds (3600 total), and 1–32 distinct keys.")
        }
        try VideoTags.validate(Dictionary(uniqueKeysWithValues: keys.map { ($0, "") }))
    }
}
struct FootageTagRange: Codable, Equatable {
    let cameraID: String
    let epochID: String
    let start: Double
    var end: Double
}
struct FootageTagChange: Codable, Equatable {
    var version = 1
    let instanceID: String
    let revision: UInt64
    let reset: Bool
    let ranges: [FootageTagRange]
}
struct FootageTagSnapshot: Codable {
    var version = 1
    let instanceID: String
    let revision: UInt64
    let cameraID: String
    let spans: [FootageTagInspection]
}
extension FootageTagQuery {
    init(from decoder: Decoder) throws {
        try FootageJSON.rejectUnknown(decoder, allowed: ["cameraID", "ranges", "keys"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cameraID = try c.decode(String.self, forKey: .cameraID)
        ranges = try c.decode([Range].self, forKey: .ranges)
        keys = try c.decode([String].self, forKey: .keys)
    }
}
extension FootageTagQuery.Range {
    init(from decoder: Decoder) throws {
        try FootageJSON.rejectUnknown(decoder, allowed: ["start", "end", "epochID"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        epochID = try c.decodeIfPresent(String.self, forKey: .epochID)
    }
}
private enum FootageJSON {
    struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    static func rejectUnknown(_ decoder: Decoder, allowed: Set<String>) throws {
        let keys = try decoder.container(keyedBy: Key.self).allKeys.map(\.stringValue)
        if let key = keys.first(where: { !allowed.contains($0) }) {
            throw ServiceError("Unsupported footage tag field '\(key)'. Destination stores cannot be selected.")
        }
    }
}
