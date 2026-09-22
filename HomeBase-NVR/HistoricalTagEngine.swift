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
        let original: VideoTagTimeline?
        let revision: String
        var edited: VideoTagTimeline
        var ticks: [Int64]?
        var identity: String { config.id + "/" + timing.shardID }
        init(config: RecordingStoreConfiguration, local: LocalMediaProvider.Source?, remote: S3PlaybackShard?,
             tags: VideoTagTimeline?, revision: String) {
            self.config = config; self.local = local; self.remote = remote
            timing = local?.row.timing ?? remote!.timing; end = local?.row.endTicks ?? remote!.endTicks
            original = tags; edited = tags ?? .unknown; self.revision = revision
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
        guard nodes.count < 64 else { throw ServiceError("At most 64 shards can participate in one historical edit; split the batch.") }
        nodes[node.identity] = node; return node
    }
    private func find(in config: RecordingStoreConfiguration, camera: String? = nil, shard: String? = nil,
                      file: String? = nil, range: MediaRange? = nil, timeline: MediaTimeline = .canonical,
                      epoch: String? = nil, ignoreUnfinished: Bool = false) throws -> [Node] {
        try work.check()
        var result: [Node] = []
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
                    if ignoreUnfinished, row.state != .complete { continue }
                    guard row.state == .complete else { throw ServiceError("Historical editing requires finalized shards; the requested range includes an active or interrupted recording.") }
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
                let tags = try shard.tagMetadata?.thaw(password: encryptionPassword(config))
                result.append(try remember(Node(config: config, local: nil, remote: shard, tags: tags,
                    revision: S3PlaybackPublisher.tagRevision(shard))))
            }
        }
        return result.sorted { ($0.timing.time.canonicalUTC, $0.timing.shardID) < ($1.timing.time.canonicalUTC, $1.timing.shardID) }
    }
    private func frameTicks(_ node: Node) async throws -> [Int64] {
        if let ticks = node.ticks { return ticks }
        try work.check()
        let ticks: [Int64]
        if let local = node.local { ticks = try LocalMediaReader.frameTicks(local, work: work) }
        else {
            let shard = node.remote!, s3 = node.config.s3!
            guard shard.size <= 256 * 1024 * 1024, downloaded + shard.size <= 512 * 1024 * 1024 else {
                throw ServiceError("Exact frame inspection exceeds the 256 MiB object / 512 MiB job download limit.")
            }
            let keys: S3RepairCredentials
            if let credentials { keys = credentials }
            else if let saved = s3.credentials { keys = .init(accessKeyID: saved.accessKeyID, secretAccessKey: saved.secretAccessKey) }
            else { throw ServiceError("Exact remote frame selection needs temporary GetObject credentials; use --read-credentials.") }
            let wire: Data
            do { wire = try await factory(s3, keys).readIndexed(shard) }
            catch { throw ServiceError("Could not read the indexed S3 recording for exact frame addressing. Supply temporary GetObject credentials with --read-credentials, or use timestamp-only boundaries.") }
            downloaded += Int64(wire.count); try work.check()
            guard wire.count == shard.size, S3ObjectMetadata.hash(wire) == shard.sha256 else { throw ServiceError("S3 recording no longer matches its manifest.") }
            let data: Data
            if shard.encryption != nil {
                guard let password = encryptionPassword(node.config) else { throw ServiceError("The recording's original encryption password is required.") }
                do { data = try RecordingEncryption.decrypt(wire, password: password) }
                catch { throw ServiceError("Could not decrypt the recording; supply its original encryption password.") }
            } else { data = wire }
            ticks = try await HistoricalFrameIndex.remote(data, shard: shard, work: work)
        }
        frameCount += ticks.count
        guard frameCount <= 2_000_000 else { throw ServiceError("Frame-index memory limit reached; split this edit.") }
        node.ticks = ticks; return ticks
    }
    private func fileSource(_ selection: HistoricalTagRequest.Selection) throws -> Node {
        var found: [Node] = []
        for config in configs where selection.sourceStoreID == nil || config.id == selection.sourceStoreID {
            found += try find(in: config, camera: selection.cameraID, shard: selection.shardID, file: selection.file, epoch: selection.epochID)
        }
        guard found.count == 1, let node = found.first else { throw ServiceError("File/shard did not identify exactly one managed finalized recording.") }
        return node
    }
    /// Resolve a nonzero offset through real samples. No nominal-FPS arithmetic,
    /// no crossing clock epochs or coverage gaps, even between adjacent shards.
    private func boundary(_ value: HistoricalTagRequest.Boundary, config: RecordingStoreConfiguration,
                          camera: String, timeline: MediaTimeline, epoch: String?) async throws -> (Double, String?) {
        if value.frameOffset == 0 { return (value.timestamp, epoch) }
        var remaining = value.frameOffset, point = value.timestamp, previousEnd: Double?, selectedEpoch = epoch
        for _ in 0..<720 { // Scan short windows; at most 128 distinct shards / 24h.
            try work.check()
            let candidates = try find(in: config, camera: camera, range: .init(start: point, end: point + 120), timeline: timeline, epoch: selectedEpoch, ignoreUnfinished: true)
                .sorted { timeline.anchor($0.timing.time)! < timeline.anchor($1.timing.time)! }
            guard !candidates.isEmpty else { throw ServiceError("Frame offset encounters unavailable footage; use a timestamp or a different boundary.") }
            for node in candidates {
                let anchor = timeline.anchor(node.timing.time)!, end = anchor + Double(node.end) / Double(node.timing.timescale)
                if end <= point { continue }
                if let previousEnd, abs(anchor - previousEnd) > 2 / Double(node.timing.timescale) {
                    throw ServiceError("Frame offset crosses a gap or overlapping recordings.")
                }
                if let selectedEpoch, selectedEpoch != node.timing.time.epochID { throw ServiceError("Frame offset crosses a clock discontinuity.") }
                selectedEpoch = node.timing.time.epochID
                // Reject another epoch covering the same boundary before filtering.
                let overlaps = try find(in: config, camera: camera, range: .init(start: max(anchor, point), end: min(end, max(anchor, point) + 0.001)), timeline: timeline, epoch: epoch)
                guard overlaps.count == 1 else { throw ServiceError("Ambiguous timeline; provide epochID.") }
                let ticks = try await frameTicks(node)
                let lower = try HistoricalTags.ticks(point, anchor: anchor, timescale: node.timing.timescale, end: node.end)
                let first = ticks.firstIndex(where: { $0 >= lower }) ?? ticks.count
                if remaining < ticks.count - first { return (anchor + Double(ticks[first + remaining]) / Double(node.timing.timescale), selectedEpoch) }
                remaining -= ticks.count - first
                previousEnd = end; point = end
            }
        }
        throw ServiceError("Frame offset exceeds the bounded search window.")
    }
    func run(_ request: HistoricalTagRequest, progress: (HistoricalTagStatus) -> Void) async throws -> (HistoricalTagStatus, Data?) {
        try request.validate()
        var touched = Set<String>(), status = HistoricalTagStatus(jobID: request.jobID, state: "preparing")
        func gaps(_ values: [Node], store: String, camera: String, range: MediaRange, timeline: MediaTimeline) throws {
            let covered = values.compactMap { node -> MediaRange? in
                guard let start = timeline.anchor(node.timing.time) else { return nil }
                return .init(start: start, end: start + Double(node.end) / Double(node.timing.timescale))
            }
            status.gaps += range.subtracting(covered).map { .init(storeID: store, cameraID: camera, timeline: timeline, start: $0.start, end: $0.end) }
            guard status.gaps.count <= 64 else { throw ServiceError("Too many gaps to report; split the edit batch.") }
        }
        for edit in request.edits {
            try work.check()
            let s = edit.selection
            if s.file != nil || s.shardID != nil {
                let source = try fileSource(s)
                let start: Int64, end: Int64
                if s.allFrames { start = 0; end = source.end }
                else {
                    let ticks = try await frameTicks(source)
                    start = try HistoricalTags.frameBoundary(s.startFrame!, ticks: ticks, end: source.end)
                    end = try HistoricalTags.frameBoundary(s.endFrame!, ticks: ticks, end: source.end)
                }
                let from = source.timing.time.canonicalUTC + Double(start) / Double(source.timing.timescale)
                let to = source.timing.time.canonicalUTC + Double(end) / Double(source.timing.timescale)
                for id in request.storeIDs {
                    let values = id == source.config.id ? [source] : try find(in: config(id), camera: source.timing.cameraID,
                        range: .init(start: from, end: to), epoch: source.timing.time.epochID)
                    guard !values.isEmpty else { throw ServiceError("A target store has no matching source epoch; no edits were committed. Select only stores containing that footage.") }
                    try gaps(values, store: id, camera: source.timing.cameraID, range: .init(start: from, end: to), timeline: .canonical)
                    for node in values {
                        try apply(edit, to: node, start: from, end: to, timeline: .canonical, request: request)
                        touched.insert(node.identity)
                    }
                }
            } else {
                for id in request.storeIDs {
                    let config = try config(id)
                    let (start, firstEpoch) = try await boundary(s.start!, config: config, camera: s.cameraID!, timeline: s.timeline, epoch: s.epochID)
                    let (end, lastEpoch) = try await boundary(s.end!, config: config, camera: s.cameraID!, timeline: s.timeline, epoch: s.epochID)
                    guard start < end, s.start!.frameOffset == 0 || s.end!.frameOffset == 0 || firstEpoch == lastEpoch else {
                        throw ServiceError("Resolved frame range is empty or crosses clock epochs.")
                    }
                    let values = try find(in: config, camera: s.cameraID!, range: .init(start: start, end: end), timeline: s.timeline, epoch: s.epochID)
                    guard !values.isEmpty else { throw ServiceError("No finalized indexed footage matches this target store and time range.") }
                    try gaps(values, store: id, camera: s.cameraID!, range: .init(start: start, end: end), timeline: s.timeline)
                    let sorted = values.sorted { s.timeline.anchor($0.timing.time)! < s.timeline.anchor($1.timing.time)! }
                    for pair in zip(sorted, sorted.dropFirst()) {
                        let aEnd = s.timeline.anchor(pair.0.timing.time)! + Double(pair.0.end) / Double(pair.0.timing.timescale)
                        guard aEnd <= s.timeline.anchor(pair.1.timing.time)! + 0.00001 else { throw ServiceError("Overlapping timeline epochs; provide epochID or a shard reference.") }
                    }
                    for node in values {
                        try apply(edit, to: node, start: start, end: end, timeline: s.timeline, request: request)
                        touched.insert(node.identity)
                    }
                }
            }
        }
        let selected = touched.compactMap { nodes[$0] }.sorted { $0.identity < $1.identity }
        guard Set(request.expectedRevisions?.keys.map { $0 } ?? []).isSubset(of: touched) else {
            throw ServiceError("An expected revision names a shard outside the resolved selection.")
        }
        if request.inspect {
            let inspection = selected.map { node in
                HistoricalTagInspection(storeID: node.config.id, cameraID: node.timing.cameraID, shardID: node.timing.shardID,
                    revision: node.revision, timing: node.timing, endTicks: node.end,
                    frames: node.ticks?.count ?? node.local.map { Int($0.row.frames) }, tags: node.edited)
            }
            let data = try JSONEncoder().encode(inspection)
            guard data.count <= 16 * 1024 * 1024 else { throw ServiceError("Inspection exceeds 16 MiB; narrow the selection.") }
            status.state = "completed"; status.message = "Read-only inspection complete."
            return (status, data)
        }
        var local: [(Node, LocalTagFile.Pending)] = [], remote: [String: [S3PlaybackPublisher.TagReplacement]] = [:]
        var sizes: Int64 = 0, journalAttempted = false
        defer {
            // Once a commit is attempted, recovery may own any staged file.
            // Never delete it on an ambiguous SQLite/filesystem error.
            if !journalAttempted { for (node, staged) in local { _ = unlinkat(node.local!.directory.fd, staged.stagedName, 0) } }
        }
        for node in selected {
            try work.check()
            let changed = node.original != node.edited
            if changed, !request.dryRun {
                if let source = node.local {
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
        status.state = "applying"; status.message = "All edits validated. Committing per-store metadata; completed stores remain committed if another fails."
        progress(status)
        journalAttempted = true
        for id in request.storeIDs {
            try work.check()
            let config = try config(id)
            if config.type == "S3" {
                try manager.historicalS3(id).commitHistorical(remote[id] ?? [], expected: config)
            } else {
                let grouped = Dictionary(grouping: local.filter { $0.0.config.id == id }, by: { $0.0.local!.directory.path })
                for path in grouped.keys.sorted() {
                    let values = grouped[path]!
                    try manager.historicalLocal(id).commitHistorical(directory: values[0].0.local!.directory,
                        edits: values.map(\.1), revisions: Dictionary(uniqueKeysWithValues: values.map { ($0.0.timing.shardID, $0.0.revision) }))
                }
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
        status.state = "completed"; status.message = "Historical edits committed. S3 manifest delivery is asynchronous; embedded S3 media and live tags were not changed."
        return (status, nil)
    }
    private func apply(_ edit: HistoricalTagRequest.Edit, to node: Node, start: Double, end: Double,
                       timeline: MediaTimeline, request: HistoricalTagRequest) throws {
        if let expected = request.expectedRevisions?[node.identity], expected != node.revision { throw ServiceError("Tag revision conflict; inspect again before editing.") }
        guard let anchor = timeline.anchor(node.timing.time) else { throw ServiceError("This shard has no requested time base.") }
        let first = try HistoricalTags.ticks(start, anchor: anchor, timescale: node.timing.timescale, end: node.end)
        let last = try HistoricalTags.ticks(end, anchor: anchor, timescale: node.timing.timescale, end: node.end)
        guard last > first else { throw ServiceError("Empty resolved tag interval.") }
        if !request.inspect { try node.edited.apply(.init(start: first, end: last, key: edit.key, value: edit.value)) }
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
                        job.status.error = (error as? ServiceError)?.message ?? "Historical editing failed; committed metadata and pending recovery files were preserved."
                        job.status.message = "Inspect per-store results before retrying. No live tags changed."
                        job.task = nil
                    }
                }
            }
            return job.status
        }
    }
    func poll(_ id: String, uid: uid_t) throws -> HistoricalTagStatus {
        try locked { guard let job = jobs[id], job.uid == uid else { throw ServiceError("Historical job is unavailable; inspect durable shard metadata before retrying after a restart.") }; return job.status }
    }
    func read(_ id: String, offset: Int, uid: uid_t) throws -> Data {
        try locked {
            guard let job = jobs[id], job.uid == uid, let data = job.data, offset >= 0, offset <= data.count else { throw ServiceError("Inspection output is unavailable or offset is invalid.") }
            return data.subdata(in: offset..<min(offset + 32768, data.count))
        }
    }
    func stop() { locked { for job in jobs.values { job.cancellation.stop(); job.task?.cancel() } } }
}
