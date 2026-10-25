import Foundation
import Darwin

/// A single bounded editor, independent of recording and the control socket.
/// No job ever owns video RAM beyond the one shard currently being inspected.
final class HistoricalTagEngine: @unchecked Sendable {
    final class Node {
        let config: RecordingStoreConfiguration
        let timing: ShardTimingMetadata
        let end: Int64
        let local: LocalMediaProvider.Source?
        let remote: S3PlaybackShard?
        let pending: RecordingTagSnapshot?
        let original: VideoTagTimeline?
        let revision: String
        var edited: VideoTagTimeline
        var ticks: [Int64]?
        var tickRounding: Double = 0
        var overrides: [VideoTagTimeline.Override] = []
        var identity: String { config.id + "/" + timing.shardID }
        init(config: RecordingStoreConfiguration, local: LocalMediaProvider.Source?, remote: S3PlaybackShard?,
             tags: VideoTagTimeline?, revision: String) {
            self.config = config; self.local = local; self.remote = remote; pending = nil
            timing = local?.row.timing ?? remote!.timing; end = local?.row.endTicks ?? remote!.endTicks
            original = tags; edited = tags ?? .unknown; self.revision = revision
        }
        init(config: RecordingStoreConfiguration, pending: RecordingTagSnapshot) throws {
            self.config = config; self.pending = pending; local = nil; remote = nil
            timing = pending.timing; end = pending.endTicks; original = pending.tags; edited = pending.tags
            revision = try HistoricalTags.revision(pending.tags)
            ticks = pending.frameTicks.isEmpty ? nil : pending.frameTicks
        }
    }
    let configs: [RecordingStoreConfiguration]
    let manager: RecordingStoreManager
    let factory: S3RepairReaderFactory
    let credentials: S3RepairCredentials?
    let password: String?
    let work: MediaWork
    private var nodes: [String: Node] = [:]
    private var downloaded: Int64 = 0
    private var frameCount = 0
    init(configs: [RecordingStoreConfiguration], manager: RecordingStoreManager, factory: @escaping S3RepairReaderFactory,
         credentials: S3RepairCredentials?, password: String?, cancellation: Cancellation) {
        self.configs = configs; self.manager = manager; self.factory = factory
        self.credentials = credentials; self.password = password
        work = MediaWork(cancellation: cancellation, deadline: ProcessInfo.processInfo.systemUptime + 300)
    }
    private func config(_ id: String) throws -> RecordingStoreConfiguration {
        guard let value = configs.first(where: { $0.id == id }) else { throw ServiceError("Unknown recording store UUID.") }
        return value
    }
    private func encryptionPassword(_ config: RecordingStoreConfiguration) -> String? { password ?? config.s3?.clientEncryption?.password }
    private func remember(_ node: Node) throws -> Node {
        if let existing = nodes[node.identity] { return existing }
        guard nodes.count < 64 else { throw ServiceError("The footage selection exceeds the bounded work limit; narrow the range or split the batch.") }
        if let pending = node.pending {
            frameCount += pending.frameTicks.count
            guard frameCount <= 2_000_000 else { throw ServiceError("Frame-index memory limit reached; split this edit.") }
        }
        nodes[node.identity] = node; return node
    }
    private func find(in config: RecordingStoreConfiguration, camera: String? = nil, shard: String? = nil,
                      file: String? = nil, range: MediaRange? = nil, timeline: MediaTimeline = .canonical,
                      epoch: String? = nil) throws -> [Node] {
        try work.check()
        var result: [Node] = []
        // Capture pending before confirmed: a rollover/upload may advance
        // between reads, but cannot make a recording disappear from both.
        let snapshots = config.type == "Local"
            ? try manager.historicalLocal(config.id).pendingTagSnapshots()
            : try manager.historicalS3(config.id).pendingTagSnapshots(password: password, cameraID: camera,
                shardID: shard, range: range, timeline: timeline, epochID: epoch)
        let pending = snapshots.filter { value in
            if let camera, value.timing.cameraID != camera { return false }
            if let shard, value.timing.shardID != shard { return false }
            if let epoch, value.timing.time.epochID != epoch { return false }
            guard let anchor = timeline.anchor(value.timing.time) else { return false }
            return range.map { anchor < $0.end && anchor + Double(value.endTicks) / Double(value.timing.timescale) > $0.start } ?? true
        }
        if file == nil {
            for snapshot in pending { result.append(try remember(Node(config: config, pending: snapshot))) }
        }
        if config.type == "Local" {
            let provider = LocalMediaProvider(configurations: { [config] }, ram: nil)
            try provider.visitIndexes(camera: camera, work: work) { directory, _, index in
                let filename: String?
                if let file {
                    let parts = file.split(separator: "/")
                    guard "/" + parts.dropLast().joined(separator: "/") == directory.path else { return }
                    filename = parts.last.map(String.init)
                } else { filename = nil }
                for row in try index.historicalRecordings(id: shard, filename: filename, range: range, timeline: timeline) {
                    if let epoch, row.timing.time.epochID != epoch { continue }
                    if let snapshot = pending.first(where: { $0.timing.shardID == row.id }) {
                        if file != nil { result.append(try remember(Node(config: config, pending: snapshot))) }
                        continue
                    }
                    guard row.state == .complete else { continue }
                    var info = stat()
                    guard fstatat(directory.fd, row.filename, &info, AT_SYMLINK_NOFOLLOW) == 0,
                          LocalMediaProvider.matches(info, row: row) else { throw ServiceError("An indexed recording is missing or changed; no edits were committed.") }
                    let tags = try index.historicalTags(id: row.id)
                    let source = LocalMediaProvider.Source(directory: directory, owner: config.ownerUID, row: row,
                        range: .init(start: row.start, end: row.end))
                    result.append(try remember(Node(config: config, local: source, remote: nil, tags: tags,
                        revision: HistoricalTags.revision(tags))))
                }
            }
        } else if file == nil {
            let values = try manager.historicalS3(config.id).historicalShards().filter { value in
                if let camera, value.timing.cameraID != camera { return false }
                if let shard, value.id != shard { return false }
                if let epoch, value.timing.time.epochID != epoch { return false }
                if let range {
                    guard let anchor = timeline.anchor(value.timing.time) else { return false }
                    return anchor < range.end && anchor + Double(value.endTicks) / Double(value.timing.timescale) > range.start
                }
                return true
            }
            guard values.count <= 128 else { throw ServiceError("Too many S3 shards; narrow the historical edit range.") }
            for shard in values {
                if result.contains(where: { $0.timing.shardID == shard.id }) { continue }
                let tags = try shard.tagMetadata?.thaw(password: encryptionPassword(config))
                result.append(try remember(Node(config: config, local: nil, remote: shard, tags: tags,
                    revision: S3PlaybackPublisher.tagRevision(shard))))
            }
        }
        return result.sorted { ($0.timing.time.canonicalUTC, $0.timing.shardID) < ($1.timing.time.canonicalUTC, $1.timing.shardID) }
    }
    private func frameTicks(_ node: Node) async throws -> [Int64] {
        if let ticks = node.ticks { return ticks }
        guard node.pending == nil else { throw ServiceError(.unavailable, "Exact frame offsets are unavailable for this footage; use timestamps.") }
        try work.check()
        let index: HistoricalFrameIndex.Index
        if let local = node.local { index = try LocalMediaReader.frameIndex(local, work: work) }
        else {
            let shard = node.remote!, s3 = node.config.s3!
            guard shard.size <= 256 * 1024 * 1024, downloaded + shard.size <= 512 * 1024 * 1024 else {
                throw ServiceError("Exact frame inspection exceeds the 256 MiB object / 512 MiB job download limit.")
            }
            let keys: S3RepairCredentials
            if let credentials { keys = credentials }
            else if let saved = s3.credentials { keys = .init(accessKeyID: saved.accessKeyID, secretAccessKey: saved.secretAccessKey) }
            else { throw ServiceError("Remote frame selection or overlapping-boundary verification needs GetObject credentials; use --read-credentials.") }
            let wire: Data
            do { wire = try await factory(s3, keys).readIndexed(shard) }
            catch { throw ServiceError("Could not read the indexed S3 recording for frame or overlapping-boundary verification. Supply temporary GetObject credentials with --read-credentials.") }
            downloaded += Int64(wire.count); try work.check()
            guard wire.count == shard.size, S3ObjectMetadata.hash(wire) == shard.sha256 else { throw ServiceError("S3 recording no longer matches its manifest.") }
            let data: Data
            if shard.encryption != nil {
                guard let password = encryptionPassword(node.config) else { throw ServiceError("The recording's original encryption password is required.") }
                do { data = try RecordingEncryption.decrypt(wire, password: password) }
                catch { throw ServiceError("Could not decrypt the recording; supply its original encryption password.") }
            } else { data = wire }
            index = try await HistoricalFrameIndex.remoteIndex(data, shard: shard, work: work)
        }
        let ticks = index.ticks
        frameCount += ticks.count
        guard frameCount <= 2_000_000 else { throw ServiceError("Frame-index memory limit reached; split this edit.") }
        node.ticks = ticks; node.tickRounding = index.rounding; return ticks
    }
    private func fileSource(_ selection: HistoricalTagRequest.Selection) throws -> Node {
        var found: [Node] = []
        for config in configs where selection.sourceStoreID == nil || config.id == selection.sourceStoreID {
            if selection.file != nil, config.type != "Local" { continue }
            found += try find(in: config, camera: selection.cameraID, shard: selection.shardID, file: selection.file, epoch: selection.epochID)
        }
        guard found.count == 1, let node = found.first else { throw ServiceError("File/shard did not identify exactly one managed recording.") }
        return node
    }
    private struct Span {
        let node: Node
        let start: Double
        var end: Double
    }
    /// Only a proven, empty extrapolated tail may yield to the next shard.
    /// Epoch identity alone is insufficient: overlapping actual samples, duplicate
    /// shards and inconsistent clock mappings must still fail closed.
    private func spans(_ values: [Node], timeline: MediaTimeline, through: Double? = nil) async throws -> [Span] {
        var result = values.map { node in
            let start = timeline.anchor(node.timing.time)!
            return Span(node: node, start: start, end: start + Double(node.end) / Double(node.timing.timescale))
        }.sorted { ($0.start, $0.node.identity) < ($1.start, $1.node.identity) }
        for i in result.indices.dropLast() {
            let a = result[i], b = result[i + 1]
            if let through, b.start > through { break }
            // This is floating-point cancellation allowance, not frame tolerance.
            let rounding = max(a.end.ulp, b.start.ulp) * 2
            if abs(a.end - b.start) <= rounding {
                result[i].end = b.start
                continue
            }
            guard a.end > b.start + rounding else { continue }
            let x = a.node.timing, y = b.node.timing, scale = Double(x.timescale)
            let offset = (b.start - a.start) * scale
            let cut = offset.rounded()
            func agrees(_ from: Double, _ to: Double) -> Bool {
                abs((to - from) * scale - cut) <= max(from.ulp, to.ulp) * scale * 4
            }
            guard x.time.epochID == y.time.epochID, x.timescale == y.timescale, x.ssrc == y.ssrc,
                  x.time.canonicalSource == y.time.canonicalSource, x.time.cameraClock == y.time.cameraClock,
                  cut > 0, cut < Double(Int64.max), agrees(a.start, b.start),
                  agrees(x.time.canonicalUTC, y.time.canonicalUTC), agrees(x.time.receivedUTC, y.time.receivedUTC),
                  (x.time.cameraUTC == nil) == (y.time.cameraUTC == nil),
                  x.time.cameraUTC.map({ agrees($0, y.time.cameraUTC!) }) ?? true,
                  y.rtpTimestamp &- x.rtpTimestamp == UInt32(truncatingIfNeeded: Int64(cut)) else {
                throw ServiceError("Overlapping timeline epochs or inconsistent recording clocks; provide epochID or a shard reference.")
            }
            let ticks = try await frameTicks(a.node)
            _ = try await frameTicks(b.node) // verifies its embedded identity and first PTS == 0
            let last = ticks.last!
            let estimate = ticks.count > 1 ? last - ticks[ticks.count - 2] : max(1, Int64(x.timescale) / 15)
            // Legacy MP4s may quantize PTS to AVFoundation's default track
            // timescale. The inferred end is 2*lastPTS - previousPTS, so its
            // uncertainty is at most three measured PTS rounding bounds. Never
            // allow that uncertainty to straddle the successor's first sample.
            let uncertainty = a.node.tickRounding
            guard Double(last) + uncertainty < cut,
                  abs(Double(a.node.end - last - estimate)) <= 3 * uncertainty else {
                throw ServiceError("Overlapping recording samples; provide a shard reference.")
            }
            result[i].end = b.start
        }
        return result
    }
    private func selectedSpans(_ values: [Node], range: MediaRange, timeline: MediaTimeline) async throws -> [Span] {
        try await spans(values, timeline: timeline).filter { $0.start < range.end && $0.end > range.start }
    }
    /// Resolve a nonzero offset through real samples. No nominal-FPS arithmetic,
    /// no crossing clock epochs or coverage gaps, even between adjacent shards.
    private func boundary(_ value: HistoricalTagRequest.Boundary, config: RecordingStoreConfiguration,
                          camera: String, timeline: MediaTimeline, epoch: String?) async throws -> (Double, String?) {
        if value.frameOffset == 0 { return (value.timestamp, epoch) }
        var remaining = value.frameOffset, point = value.timestamp, previousEnd: Double?, selectedEpoch = epoch
        for _ in 0..<720 { // Scan short windows; at most 128 distinct shards / 24h.
            try work.check()
            var candidates = try find(in: config, camera: camera, range: .init(start: point, end: point + 120), timeline: timeline, epoch: epoch)
            guard !candidates.isEmpty else { throw ServiceError(.unavailable, "Frame offset encounters unavailable footage; use a timestamp or a different boundary.") }
            // Include the successor of a long shard even if its boundary lies
            // beyond this search window. Otherwise its estimated tail would skip
            // the successor's first sample when advancing the next window.
            if let last = candidates.max(by: { timeline.anchor($0.timing.time)! < timeline.anchor($1.timing.time)! }) {
                let end = timeline.anchor(last.timing.time)! + Double(last.end) / Double(last.timing.timescale)
                let neighbors = try find(in: config, camera: camera,
                    range: .init(start: max(point, timeline.anchor(last.timing.time)!), end: end + 1 / Double(last.timing.timescale)),
                    timeline: timeline, epoch: epoch)
                let known = Set(candidates.map(\.identity))
                candidates += neighbors.filter { !known.contains($0.identity) }
            }
            let ordered = candidates.sorted { timeline.anchor($0.timing.time)! < timeline.anchor($1.timing.time)! }
            for (position, node) in ordered.enumerated() {
                let anchor = timeline.anchor(node.timing.time)!
                let rawEnd = anchor + Double(node.end) / Double(node.timing.timescale)
                if rawEnd <= point { continue }
                let ticks = try await frameTicks(node)
                let lower = try HistoricalTags.ticks(point, anchor: anchor, timescale: node.timing.timescale, end: node.end)
                let first = ticks.firstIndex(where: { $0 >= lower }) ?? ticks.count
                let successorStart = position + 1 < ordered.count ? timeline.anchor(ordered[position + 1].timing.time)! : rawEnd
                let target = remaining < ticks.count - first
                    ? anchor + Double(ticks[first + remaining]) / Double(node.timing.timescale) : min(rawEnd, successorStart)
                // Validate only the path actually traversed by this offset; an
                // unrelated ambiguity later in the lookahead is not selected.
                let resolved = try await spans(candidates, timeline: timeline, through: max(point, target))
                let end = resolved.first { $0.node.identity == node.identity }!.end
                if end <= point { continue }
                if let previousEnd, abs(anchor - previousEnd) > 2 / Double(node.timing.timescale) {
                    if anchor > previousEnd { throw ServiceError(.unavailable, "Frame offset crosses unavailable footage.") }
                    throw ServiceError("Frame offset crosses overlapping recordings.")
                }
                if let selectedEpoch, selectedEpoch != node.timing.time.epochID { throw ServiceError("Frame offset crosses a clock discontinuity.") }
                selectedEpoch = node.timing.time.epochID
                if remaining < ticks.count - first { return (target, selectedEpoch) }
                remaining -= ticks.count - first
                previousEnd = end; point = end
            }
        }
        throw ServiceError("Frame offset exceeds the bounded search window.")
    }
    private struct Selection {
        let camera: String
        let timeline: MediaTimeline
        let range: MediaRange
        let spans: [Span]
    }
    /// Resolve convenience offsets against one available copy, then apply its
    /// footage coordinates everywhere. Destination stores are never selectors.
    private func resolve(_ value: HistoricalTagRequest.Boundary, camera: String,
                         timeline: MediaTimeline, epoch: String?) async throws -> (Double, String?) {
        if value.frameOffset == 0 { return (value.timestamp, epoch) }
        for config in configs {
            let nearby = try find(in: config, camera: camera,
                range: .init(start: value.timestamp, end: value.timestamp + 120), timeline: timeline, epoch: epoch)
            if !nearby.isEmpty {
                do { return try await boundary(value, config: config, camera: camera, timeline: timeline, epoch: epoch) }
                catch let error as ServiceError where error.code == .unavailable { continue }
            }
        }
        throw ServiceError("Frame offset encounters unavailable footage; use a timestamp or a different boundary.")
    }
    private func validateEpochs(_ values: [Span]) throws {
        let ordered = values.sorted { $0.start < $1.start }
        for (i, a) in ordered.enumerated() {
            for b in ordered.dropFirst(i + 1) {
                if b.start >= a.end { break }
                guard a.node.timing.time.epochID == b.node.timing.time.epochID else {
                    throw ServiceError("Overlapping timeline epochs; provide epochID or a source reference.")
                }
            }
        }
    }
    /// Flatten storage copies into one time-based view. A disagreement is
    /// unknown; verification must never succeed merely because one copy agrees.
    private func inspect(_ selections: [Selection]) throws -> [FootageTagInspection] {
        var output: [FootageTagInspection] = []
        for selection in selections {
            let epochs = Dictionary(grouping: selection.spans, by: { $0.node.timing.time.epochID })
            for epoch in epochs.keys.sorted() {
                let spans = epochs[epoch]!
                var boundaries = [selection.range.start, selection.range.end]
                for span in spans {
                    boundaries += [max(span.start, selection.range.start), min(span.end, selection.range.end)]
                    let tags = span.node.edited
                    let ticks = tags.changes.map(\.ticks) + (tags.overrides ?? []).flatMap { [$0.start, $0.end] }
                        + (tags.unknownFromTicks.map { [$0] } ?? [])
                    for tick in ticks {
                        let t = span.start + Double(tick) / Double(span.node.timing.timescale)
                        let startTolerance = max(t.ulp, selection.range.start.ulp) * 2
                        let endTolerance = max(t.ulp, selection.range.end.ulp) * 2
                        if t > selection.range.start + startTolerance,
                           t < selection.range.end - endTolerance, t < span.end { boundaries.append(t) }
                    }
                }
                let points = Set(boundaries).sorted()
                guard points.count <= 16384 else { throw ServiceError("Too many tag boundaries; narrow the selection.") }
                for (start, end) in zip(points, points.dropFirst()) where end > start {
                    try work.check()
                    let midpoint = start + (end - start) / 2
                    let covering = spans.filter { $0.start <= midpoint && $0.end > midpoint }
                    if covering.isEmpty { continue }
                    let states = try covering.map { span in
                        // The API's time boundary selects the first representable
                        // tick at/after it, exactly as apply() does. Tiny partial
                        // ticks must not invent an unedited leading interval.
                        let tick = try HistoricalTags.ticks(start, anchor: span.start,
                            timescale: span.node.timing.timescale, end: span.node.end)
                        return span.node.edited.state(at: min(tick, span.node.end - 1))
                    }
                    let keys = Set(states.flatMap { Array($0.values.keys) + $0.knownAbsent })
                    var values: [String: String] = [:], absent: [String] = []
                    for key in keys {
                        if let value = states[0].values[key], states.allSatisfy({ $0.values[key] == value }) { values[key] = value }
                        else if states.allSatisfy({ $0.values[key] == nil && ($0.complete || $0.knownAbsent.contains(key)) }) { absent.append(key) }
                    }
                    let state = VideoTagTimeline.State(values: values, knownAbsent: absent.sorted(),
                        complete: states.allSatisfy { $0.complete && $0.values == states[0].values })
                    output.append(.init(cameraID: selection.camera, timeline: selection.timeline, epochID: epoch,
                        start: start, end: end, tags: state))
                    guard output.count <= 16384 else { throw ServiceError("Inspection exceeds its boundary limit; split the request.") }
                }
            }
        }
        output.sort { ($0.cameraID, $0.timeline.rawValue, $0.start, $0.epochID) < ($1.cameraID, $1.timeline.rawValue, $1.start, $1.epochID) }
        var merged: [FootageTagInspection] = []
        for item in output {
            if let last = merged.last, last.cameraID == item.cameraID, last.timeline == item.timeline,
               last.epochID == item.epochID, last.tags == item.tags,
               item.start <= last.end + max(item.start.ulp, last.end.ulp) * 2 {
                merged[merged.count - 1].end = max(last.end, item.end)
            } else { merged.append(item) }
        }
        return merged
    }
    private func footageResults(_ selections: [Selection]) -> [HistoricalTagResult] {
        let rows = selections.flatMap { selection in selection.spans.map { span in
            HistoricalTagResult(storeID: "", cameraID: selection.camera, shardID: "", revision: "",
                changed: span.node.original != span.node.edited, publication: "", timeline: selection.timeline,
                epochID: span.node.timing.time.epochID, start: max(selection.range.start, span.start), end: min(selection.range.end, span.end))
        }}.sorted { ($0.cameraID, $0.timeline.rawValue, $0.start, $0.epochID) < ($1.cameraID, $1.timeline.rawValue, $1.start, $1.epochID) }
        var merged: [HistoricalTagResult] = []
        for item in rows {
            if let last = merged.last, last.cameraID == item.cameraID, last.timeline == item.timeline,
               last.epochID == item.epochID, item.start <= last.end + max(item.start.ulp, last.end.ulp) * 2 {
                merged[merged.count - 1] = .init(storeID: "", cameraID: item.cameraID, shardID: "", revision: "",
                    changed: last.changed || item.changed, publication: "", timeline: item.timeline, epochID: item.epochID,
                    start: last.start, end: max(last.end, item.end))
            } else { merged.append(item) }
        }
        return merged
    }
    func run(_ request: HistoricalTagRequest, progress: (HistoricalTagStatus) -> Void) async throws -> (HistoricalTagStatus, Data?) {
        try request.validate()
        var touched = Set<String>(), selections: [Selection] = []
        var status = HistoricalTagStatus(jobID: request.jobID, state: "preparing")
        for edit in request.edits {
            try work.check()
            let s = edit.selection
            let camera: String, timeline: MediaTimeline, range: MediaRange
            var values: [Span] = []
            if s.file != nil || s.shardID != nil {
                let source = try fileSource(s)
                let start: Int64, end: Int64
                if s.allFrames { start = 0; end = source.end }
                else {
                    let ticks = try await frameTicks(source)
                    start = try HistoricalTags.frameBoundary(s.startFrame!, ticks: ticks, end: source.end)
                    end = try HistoricalTags.frameBoundary(s.endFrame!, ticks: ticks, end: source.end)
                }
                camera = source.timing.cameraID; timeline = .canonical
                let from = source.timing.time.canonicalUTC + Double(start) / Double(source.timing.timescale)
                let to = source.timing.time.canonicalUTC + Double(end) / Double(source.timing.timescale)
                range = .init(start: from, end: to)
                var mappedEnd = to
                if end == source.end, configs.count > 1 {
                    let neighbors = try find(in: source.config, camera: camera,
                        range: .init(start: source.timing.time.canonicalUTC, end: to), epoch: source.timing.time.epochID)
                    mappedEnd = try await spans(neighbors, timeline: .canonical)
                        .first { $0.node.identity == source.identity }?.end ?? to
                }
                for config in configs {
                    if config.id == source.config.id {
                        values.append(Span(node: source, start: source.timing.time.canonicalUTC, end: to))
                    } else {
                        let mapped = MediaRange(start: from, end: mappedEnd)
                        values += try await selectedSpans(find(in: config, camera: camera, range: mapped,
                            epoch: source.timing.time.epochID), range: mapped, timeline: timeline)
                            .map { Span(node: $0.node, start: $0.start, end: min($0.end, mappedEnd)) }
                    }
                }
            } else {
                camera = s.cameraID!; timeline = s.timeline
                let (start, firstEpoch) = try await resolve(s.start!, camera: camera, timeline: timeline, epoch: s.epochID)
                let (end, lastEpoch) = try await resolve(s.end!, camera: camera, timeline: timeline, epoch: s.epochID)
                guard start < end, s.start!.frameOffset == 0 || s.end!.frameOffset == 0 || firstEpoch == lastEpoch else {
                    throw ServiceError("Resolved frame range is empty or crosses clock epochs.")
                }
                range = .init(start: start, end: end)
                for config in configs {
                    values += try await selectedSpans(find(in: config, camera: camera, range: range,
                        timeline: timeline, epoch: s.epochID), range: range, timeline: timeline)
                }
            }
            guard !values.isEmpty else { throw ServiceError("No retained footage matches the requested range.") }
            try validateEpochs(values)
            status.gaps += range.subtracting(values.map { .init(start: $0.start, end: $0.end) })
                .map { .init(cameraID: camera, timeline: timeline, start: $0.start, end: $0.end) }
            guard status.gaps.count <= 64 else { throw ServiceError("Too many gaps to report; split the edit batch.") }
            selections.append(.init(camera: camera, timeline: timeline, range: range, spans: values))
            for span in values {
                try apply(edit, to: span.node, start: max(range.start, span.start), end: min(range.end, span.end), timeline: timeline, request: request)
                touched.insert(span.node.identity)
            }
        }
        let selected = touched.compactMap { nodes[$0] }.sorted { $0.identity < $1.identity }
        guard Set(request.expectedRevisions?.keys.map { $0 } ?? []).isSubset(of: touched) else {
            throw ServiceError("An internal revision names footage outside the resolved selection.")
        }
        status.footageResults = footageResults(selections)
        if request.inspect {
            let data = try JSONEncoder().encode(inspect(selections))
            guard data.count <= 16 * 1024 * 1024 else { throw ServiceError("Inspection exceeds 16 MiB; narrow the selection.") }
            status.state = "completed"; status.message = "Read-only footage inspection complete."
            return (status, data)
        }
        var local: [(Node, LocalTagFile.Pending)] = [], remote: [String: [S3PlaybackPublisher.TagReplacement]] = [:]
        var pending: [String: [RecordingTagEdit]] = [:]
        var sizes: Int64 = 0, journalAttempted = false
        defer {
            if !journalAttempted { for (node, staged) in local { _ = unlinkat(node.local!.directory.fd, staged.stagedName, 0) } }
        }
        for node in selected {
            try work.check()
            let changed = node.original != node.edited
            if changed, !request.dryRun {
                if let snapshot = node.pending {
                    pending[node.config.id, default: []].append(.init(snapshot: snapshot, overrides: node.overrides))
                } else if let source = node.local {
                    sizes += source.row.size
                    guard sizes <= 512 * 1024 * 1024 else { throw ServiceError("Local rewrite staging exceeds 512 MiB; split the batch.") }
                    local.append((node, try LocalTagFile.stage(source: source, tags: node.edited, jobID: request.jobID, work: work)))
                } else {
                    var replacement = node.remote!
                    let encrypted = replacement.encryption != nil || replacement.tagMetadata?.encrypted != nil || node.config.s3?.clientEncryption?.enabled == true
                    let password = encryptionPassword(node.config)
                    guard !encrypted || password != nil else { throw ServiceError("Encrypted tag updates require an encryption password; refusing plaintext.") }
                    replacement.tagMetadata = try StoredVideoTags.freeze(node.edited, password: encrypted ? password : nil)
                    replacement.tagRevision = UUID().uuidString
                    remote[node.config.id, default: []].append(.init(expected: node.remote!, replacement: replacement))
                }
            }
            status.results.append(.init(storeID: node.config.id, cameraID: node.timing.cameraID, shardID: node.timing.shardID,
                revision: node.revision, changed: changed, publication: request.dryRun ? "preview" : "prepared"))
        }
        if request.dryRun { status.state = "completed"; status.message = "Preview complete; nothing changed."; return (status, nil) }
        status.state = "applying"; status.message = "Applying footage tags to all retained copies."
        progress(status)
        journalAttempted = true
        for config in configs {
            let id = config.id
            if !selected.contains(where: { $0.config.id == id }) { continue }
            try work.check()
            if config.type == "S3" {
                let store = try manager.historicalS3(id)
                try store.commitHistorical(remote[id] ?? [], expected: config)
                try store.commitPendingTags(pending[id] ?? [], work: work, password: password)
            } else {
                let store = try manager.historicalLocal(id)
                let grouped = Dictionary(grouping: local.filter { $0.0.config.id == id }, by: { $0.0.local!.directory.path })
                for path in grouped.keys.sorted() {
                    let values = grouped[path]!
                    try store.commitHistorical(directory: values[0].0.local!.directory,
                        edits: values.map(\.1), revisions: Dictionary(uniqueKeysWithValues: values.map { ($0.0.timing.shardID, $0.0.revision) }))
                }
                try store.commitPendingTags(pending[id] ?? [], work: work)
            }
            for index in status.results.indices where status.results[index].storeID == id {
                let node = nodes[id + "/" + status.results[index].shardID]!
                let revision = config.type == "S3"
                    ? (remote[id]?.first { $0.replacement.id == node.timing.shardID }?.replacement.tagRevision ?? node.revision)
                    : try HistoricalTags.revision(node.edited)
                status.results[index] = .init(storeID: id, cameraID: node.timing.cameraID, shardID: node.timing.shardID,
                    revision: revision, changed: node.original != node.edited,
                    publication: config.type == "S3" ? "s3-queued" : "local-complete")
            }
            progress(status)
        }
        status.state = "completed"; status.message = "Footage tags committed to all matching copies. Cloud delivery remains asynchronous."
        return (status, nil)
    }
    private func apply(_ edit: HistoricalTagRequest.Edit, to node: Node, start: Double, end: Double,
                       timeline: MediaTimeline, request: HistoricalTagRequest) throws {
        if let expected = request.expectedRevisions?[node.identity], expected != node.revision { throw ServiceError("Tag revision conflict; inspect again before editing.") }
        guard let anchor = timeline.anchor(node.timing.time) else { throw ServiceError("This shard has no requested time base.") }
        let first = try HistoricalTags.ticks(start, anchor: anchor, timescale: node.timing.timescale, end: node.end)
        let last = try HistoricalTags.ticks(end, anchor: anchor, timescale: node.timing.timescale, end: node.end)
        guard last > first else { throw ServiceError("Empty resolved tag interval.") }
        if !request.inspect {
            let override = VideoTagTimeline.Override(start: first, end: last, key: edit.key, value: edit.value)
            try node.edited.apply(override); node.overrides.append(override)
        }
    }
}

final class HistoricalTagJobs: @unchecked Sendable {
    private final class Job {
        let request: HistoricalTagRequest, uid: uid_t
        var status: HistoricalTagStatus
        var data: Data? = nil
        var task: Task<Void, Never>?
        let cancellation = Cancellation()
        init(_ request: HistoricalTagRequest, uid: uid_t) { self.request = request; self.uid = uid; status = .init(jobID: request.jobID, state: "preparing") }
        var active: Bool { ["preparing", "applying"].contains(status.state) }
    }
    private let lock = NSLock()
    private var jobs: [String: Job] = [:]
    private var order: [String] = []
    private func locked<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }
    func requireIdle() throws { try locked { if jobs.values.contains(where: { $0.active }) { throw ServiceError("A historical tag job is active; wait before changing recording configuration or repairing metadata.") } } }
    func start(_ request: HistoricalTagRequest, uid: uid_t, configs: [RecordingStoreConfiguration], manager: RecordingStoreManager,
               factory: @escaping S3RepairReaderFactory, credentials: S3RepairCredentials?, password: String?) throws -> HistoricalTagStatus {
        try request.validate(); try credentials?.validate()
        return try locked {
            if let old = jobs[request.jobID] {
                guard old.uid == uid, old.request == request else { throw ServiceError("Job UUID was already used for a different request.") }
                return old.status
            }
            guard !jobs.values.contains(where: { $0.active }) else { throw ServiceError("Another historical tag job is active; retry when it finishes.") }
            while order.count >= 8 { jobs.removeValue(forKey: order.removeFirst()) }
            let job = Job(request, uid: uid); jobs[request.jobID] = job; order.append(request.jobID)
            let engine = HistoricalTagEngine(configs: configs, manager: manager, factory: factory,
                credentials: credentials, password: password, cancellation: job.cancellation)
            job.task = Task.detached(priority: .utility) { [self, job] in
                do {
                    let (status, data) = try await engine.run(request) { status in self.locked { job.status = status } }
                    locked { job.status = status; job.data = data; job.task = nil }
                } catch {
                    locked {
                        job.status.state = "failed"
                        job.status.footageResults = []
                        job.status.error = (error as? ServiceError)?.message ?? "Historical editing failed; committed metadata and pending recovery files were preserved."
                        job.status.message = "Some footage copies may already be updated. Inspect the footage range before retrying."
                        job.task = nil
                    }
                }
            }
            return job.status
        }
    }
    func poll(_ id: String, uid: uid_t) throws -> HistoricalTagStatus {
        try locked { guard let job = jobs[id], job.uid == uid else { throw ServiceError("Historical job is unavailable; inspect footage tags before retrying after a restart.") }; return job.status }
    }
    func read(_ id: String, offset: Int, uid: uid_t) throws -> Data {
        try locked {
            guard let job = jobs[id], job.uid == uid, let data = job.data, offset >= 0, offset <= data.count else { throw ServiceError("Inspection output is unavailable or offset is invalid.") }
            return data.subdata(in: offset..<min(offset + 32768, data.count))
        }
    }
    func stop() { locked { for job in jobs.values { job.cancellation.stop(); job.task?.cancel() } } }
}
