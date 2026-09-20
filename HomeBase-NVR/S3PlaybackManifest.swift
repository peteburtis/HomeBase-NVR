import Foundation
import Darwin

/// Public, credential-free cloud index. Dates are Unix seconds; periods use UTC.
struct S3PlaybackShard: Codable, Equatable, Sendable {
    let id: String
    let key: String
    let size: Int64
    let sha256: String
    let encryption: String?
    let timing: ShardTimingMetadata
    let endTicks: Int64
    var start: Double { timing.time.canonicalUTC }
    var end: Double { start + Double(endTicks) / Double(timing.timescale) }
    func validate(store: RecordingStoreConfiguration) throws {
        try timing.validate()
        guard id == timing.shardID, timing.storeID == store.id, key.hasPrefix(store.s3!.prefix),
              key.utf8.count <= 1024, size > 0, sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              encryption == nil || encryption == RecordingEncryption.format,
              endTicks > 0, end.isFinite, start >= 0, end < 253402300799,
              end - start <= 31 * 86400 else { throw ServiceError("Invalid S3 playback shard metadata; footage retained.") }
    }
}

struct S3PlaybackDocument: Codable, Sendable {
    struct Day: Codable, Sendable { let day: String; let start: Double; let end: Double }
    var format = "hbnvr-s3-playback"
    var schemaVersion = 1
    let storeID: String
    let cameraID: String
    let generatedAt: Double
    var period: String?
    var shards: [S3PlaybackShard]?
    var days: [Day]?
}

/// A durable metadata journal, independent of the recovery spool. All entry
/// mutations and publication decisions run on the store worker, never per frame.
/// One cloud PUT at a time prevents out-of-order acknowledgments from regressing
/// a camera's index. A changed revision remains dirty while an old PUT finishes.
final class S3PlaybackPublisher: @unchecked Sendable {
    struct Record: Codable {
        var schemaVersion = 1
        let bucket: String, region: String, prefix: String
        let expectedOwner: String?
        let confirmedAt: Double
        let shard: S3PlaybackShard
    }
    struct Target: Hashable, Sendable {
        let camera: String
        let period: String? // nil: catalog; YYYY-MM: month; YYYY-MM-DD: day
        var relativeKey: String {
            if let period { return (period.count == 7 ? "months/" : "days/") + period + ".json" }
            return "catalog.json"
        }
    }
    let path: String
    private let queue: DispatchQueue
    private let factory: S3TransportFactory
    private let now: () -> Date
    private let changed: () -> Void
    private var configuration: RecordingStoreConfiguration
    private(set) var entries: [String: Record] = [:]
    private var dirty: [Target: UInt64] = [:]
    private var revision: UInt64 = 0
    private var loaded = false
    private var directoryAncestryDurable = false
    private var today = ""
    private var task: Task<Void, Never>?
    private var token: UUID?
    private var batch: [(Target, UInt64)] = []
    private var batchEntries: [String: Record] = [:]
    private var batchDate = Date.distantPast
    private var batchConfiguration: RecordingStoreConfiguration?
    private var invalidateBatch = false
    private var retryAt = Date.distantPast
    private var stopped = false
    private(set) var warning: String?
    // Fault injection at the durable journal boundary, not at the cloud boundary.
    var checkpoint: (String) throws -> Void = { _ in }
    var pendingPublications: Int { dirty.count }

    init(configuration: RecordingStoreConfiguration, path: String, queue: DispatchQueue,
         factory: @escaping S3TransportFactory, now: @escaping () -> Date = Date.init,
         changed: @escaping () -> Void = {}, checkpoint: @escaping (String) throws -> Void = { _ in }) {
        self.configuration = configuration; self.path = path; self.queue = queue
        self.factory = factory; self.now = now; self.changed = changed
        self.checkpoint = checkpoint
        today = Self.day(now().timeIntervalSince1970)
        do { try load() } catch { warning = Self.localWarning(error) }
    }
    static func root(prefix: String, camera: String) -> String {
        prefix + ".hbnvr/playback/v1/" + camera.lowercased() + "/"
    }
    static func day(_ seconds: Double) -> String {
        let parts = utcCalendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: seconds))
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
    private static let utcCalendar: Calendar = { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value }()
    static func intersectedDays(_ shard: S3PlaybackShard) -> [String] {
        var point = floor(shard.start / 86400) * 86400, result: [String] = []
        while point < shard.end { result.append(day(point)); point += 86400 }
        return result
    }
    private static func localWarning(_ error: Error) -> String {
        "Playback index persistence unavailable; confirmed footage is retained for retry. " +
            ((error as? ServiceError)?.message ?? "Cannot read or write private playback metadata.")
    }
    private func ensureDirectory() throws {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        let ancestor = parent.deletingLastPathComponent()
        // The runtime/private root is provisioned before this publisher. Do
        // not create an unbounded chain of intermediate directories whose
        // containing entries would also require synchronization.
        guard let root = try SecureFiles.info(ancestor.path), root.st_mode & S_IFMT == S_IFDIR else {
            throw ServiceError("Playback journal's containing state directory is unavailable.")
        }
        if try SecureFiles.info(parent.path) == nil || SecureFiles.info(path) == nil {
            directoryAncestryDurable = false
        }
        try SecureFiles.ensureDirectory(parent.path, owner: geteuid(), mode: 0o700)
        try SecureFiles.ensureDirectory(path, owner: geteuid(), mode: 0o700)
        if !directoryAncestryDurable {
            // Sync leaf-to-root: persisting the record directory alone does not
            // durably publish that directory's name in its parent. A failure
            // must retry this entire barrier even when all directories now
            // exist; no confirmed shard can be discarded before it succeeds.
            for (phase, directory) in [("leaf", path), ("parent", parent.path), ("ancestor", ancestor.path)] {
                try checkpoint("sync-ancestry-" + phase)
                try syncDirectory(directory)
            }
            directoryAncestryDurable = true
        }
    }
    private func syncDirectory(_ directory: String? = nil) throws {
        let fd = open(directory ?? path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ServiceError.posix("Open playback journal") }; defer { close(fd) }
        guard fsync(fd) == 0 else { throw ServiceError.posix("Sync playback journal") }
    }
    private func load() throws {
        try ensureDirectory()
        var recovered: [String: Record] = [:]
        for leaf in try FileManager.default.contentsOfDirectory(atPath: path) where leaf.hasSuffix(".json") {
            guard UUID(uuidString: String(leaf.dropLast(5))) != nil else { throw ServiceError("Unexpected playback journal record; preserved for inspection.") }
            let fd = open(path + "/" + leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw ServiceError.posix("Open playback journal record") }; defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
                  info.st_mode & 0o777 == 0o600, info.st_nlink == 1, (1...65536).contains(info.st_size) else {
                throw ServiceError("Unsafe playback journal record; preserved for inspection.")
            }
            let record = try JSONDecoder().decode(Record.self, from: FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data())
            try validate(record)
            guard leaf == record.shard.id + ".json" else { throw ServiceError("Playback journal identity mismatch.") }
            recovered[record.shard.id] = record
        }
        entries = recovered; loaded = true
        dirtyAll()
    }
    private func validate(_ record: Record) throws {
        let s3 = configuration.s3!
        guard record.schemaVersion == 1, record.bucket == s3.bucket, record.region == s3.region,
              record.prefix == s3.prefix, record.expectedOwner == s3.expectedOwner, record.confirmedAt.isFinite else {
            throw ServiceError("Playback journal destination mismatch; no cloud index was rewritten.")
        }
        try record.shard.validate(store: configuration)
    }
    /// Must finish before a confirmed shard's last spool/RAM metadata is dropped.
    /// Old pre-index spool entries lack timing and remain uploadable, unindexed.
    func record(_ metadata: S3ShardMetadata) throws {
        guard metadata.thumbnail == nil, metadata.timing != nil || metadata.endTicks != nil else { return }
        do {
            guard let timing = metadata.timing, let endTicks = metadata.endTicks else { throw ServiceError("Incomplete frozen playback timing; footage retained.") }
            if !loaded { try load() }
            let shard = S3PlaybackShard(id: metadata.id, key: metadata.key, size: metadata.size,
                sha256: metadata.sha256, encryption: metadata.encryption, timing: timing, endTicks: endTicks)
            try shard.validate(store: configuration)
            if let existing = entries[shard.id] {
                guard existing.shard == shard else { throw ServiceError("Conflicting confirmed shard identity in playback journal.") }
                return
            }
            let s3 = configuration.s3!
            let record = Record(bucket: s3.bucket, region: s3.region, prefix: s3.prefix, expectedOwner: s3.expectedOwner,
                confirmedAt: now().timeIntervalSince1970, shard: shard)
            try ensureDirectory(); try checkpoint("write")
            try SecureFiles.atomicWrite(try JSONEncoder().encode(record), to: path + "/" + shard.id + ".json", mode: 0o600)
            try checkpoint("sync"); try syncDirectory()
            entries[shard.id] = record
            mark(shard); warning = nil
        } catch { warning = Self.localWarning(error); throw error }
    }
    private func mark(_ shard: S3PlaybackShard) {
        revision &+= 1
        let camera = shard.timing.cameraID
        dirty[Target(camera: camera, period: nil)] = revision
        for day in Self.intersectedDays(shard) {
            dirty[Target(camera: camera, period: day)] = revision
            if day < today { dirty[Target(camera: camera, period: String(day.prefix(7)))] = revision }
        }
    }
    private func dirtyAll() { for entry in entries.values { mark(entry.shard) } }
    func repairKnownKeys() throws -> Set<String> {
        if !loaded { try load() }
        return Set(entries.values.map { $0.shard.key })
    }
    func repairRepublish(cameras: Set<String>) throws {
        if !loaded { try load() }
        for entry in entries.values where cameras.contains(entry.shard.timing.cameraID) { mark(entry.shard) }
        tick()
    }
    func update(_ configuration: RecordingStoreConfiguration) {
        let changedEncryption = self.configuration.s3?.clientEncryption != configuration.s3?.clientEncryption
        if self.configuration != configuration {
            if task == nil { batch.removeAll(); batchEntries.removeAll() }
            else { invalidateBatch = true }
        }
        self.configuration = configuration
        // Finish any old-credential/password PUT before newer revisions. An old
        // callback never clears a newly dirtied revision.
        if changedEncryption { dirtyAll() }
        retryAt = .distantPast
    }
    func document(_ target: Target, at date: Date) -> S3PlaybackDocument {
        document(target, at: date, entries: entries)
    }
    private func document(_ target: Target, at date: Date, entries: [String: Record]) -> S3PlaybackDocument {
        let shards = entries.values.map(\.shard).filter { $0.timing.cameraID == target.camera }
            .sorted { ($0.start, $0.id) < ($1.start, $1.id) }
        var document = S3PlaybackDocument(storeID: configuration.id, cameraID: target.camera, generatedAt: date.timeIntervalSince1970)
        if let period = target.period {
            document.period = period
            let components = period.split(separator: "-").compactMap { Int($0) }
            let start = Self.utcCalendar.date(from: DateComponents(year: components[0], month: components[1], day: components.count == 3 ? components[2] : 1))!
            let end = components.count == 3 ? start.addingTimeInterval(86400) : Self.utcCalendar.date(byAdding: .month, value: 1, to: start)!
            let upper = components.count == 3 ? end.timeIntervalSince1970 : min(end.timeIntervalSince1970, floor(date.timeIntervalSince1970 / 86400) * 86400)
            document.shards = shards.filter { shard in
                shard.start < upper && shard.end > start.timeIntervalSince1970
            }
        } else {
            var bounds: [Double: (Double, Double)] = [:]
            for shard in shards {
                var start = floor(shard.start / 86400) * 86400
                while start < shard.end {
                    let lower = max(start, shard.start), upper = min(start + 86400, shard.end)
                    let old = bounds[start]; bounds[start] = (min(old?.0 ?? lower, lower), max(old?.1 ?? upper, upper)); start += 86400
                }
            }
            document.days = bounds.keys.sorted().map { .init(day: Self.day($0), start: bounds[$0]!.0, end: bounds[$0]!.1) }
        }
        return document
    }
    func tick() {
        guard !stopped, configuration.s3?.settings.forceSpooling != true, task == nil, now() >= retryAt else { return }
        do { if !loaded { try load() } } catch { warning = Self.localWarning(error); retryAt = now().addingTimeInterval(60); return }
        let day = Self.day(now().timeIntervalSince1970)
        if today != day {
            let previous = today; today = day
            // Only newly closed days affect a month. Don't rewrite every old
            // daily/monthly object each midnight (which would renew expiration).
            revision &+= 1
            for entry in entries.values {
                for closed in Self.intersectedDays(entry.shard) where closed >= previous && closed < day {
                    dirty[Target(camera: entry.shard.timing.cameraID, period: String(closed.prefix(7)))] = revision
                    dirty[Target(camera: entry.shard.timing.cameraID, period: nil)] = revision
                }
            }
        }
        // Freeze one round. New completions dirty the NEXT round, rather than
        // repeatedly jumping ahead of catalogs and starving discovery forever.
        // Catalog and period objects in a round describe the same snapshot.
        if batch.isEmpty {
            batchEntries = entries; batchDate = now(); batchConfiguration = configuration
            batch = dirty.keys.sorted(by: {
                if ($0.period == nil) != ($1.period == nil) { return $0.period != nil }
                return ($0.camera, $0.relativeKey) < ($1.camera, $1.relativeKey)
            }).map { ($0, dirty[$0]!) }
        }
        guard let (target, version) = batch.first else { batchEntries.removeAll(); return }
        let document = document(target, at: batchDate, entries: batchEntries), config = batchConfiguration!, token = UUID()
        self.token = token
        task = Task { [weak self, queue, factory] in
            let result: Result<Void, Error>
            do {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                var bytes = try encoder.encode(document)
                if config.s3?.clientEncryption?.enabled == true {
                    guard let password = config.s3?.clientEncryption?.password else { throw ServiceError("Playback encryption password unavailable.") }
                    bytes = try RecordingEncryption.encrypt(bytes, password: password)
                }
                try Task.checkCancellation()
                let transport = try await factory(config.s3!)
                try await transport.publishManifest(key: Self.root(prefix: config.s3!.prefix, camera: target.camera) + target.relativeKey,
                    data: bytes, storeID: config.id, cameraID: target.camera)
                result = .success(())
            } catch { result = .failure(error) }
            queue.async { [weak self] in
                guard let self, self.token == token else { return }
                self.task = nil; self.token = nil
                guard !self.stopped else { return }
                if self.invalidateBatch {
                    self.invalidateBatch = false; self.batch.removeAll(); self.batchEntries.removeAll()
                    self.retryAt = .distantPast; self.tick(); return
                }
                switch result {
                case .success:
                    if self.dirty[target] == version { self.dirty[target] = nil }
                    self.batch.removeFirst()
                    if self.batch.isEmpty { self.batchEntries.removeAll() }
                    self.warning = nil; self.retryAt = .distantPast
                case .failure(let error):
                    self.warning = "Playback manifest upload will retry: " + AWSS3Transport.classify(error).message
                    self.retryAt = self.now().addingTimeInterval(60)
                }
                self.changed(); self.tick()
            }
        }
    }
    func stop() { stopped = true; task?.cancel() }
}
