import Foundation
import CoreMedia

/// A bounded bridge to readable disk, not a rolling playback history. Payloads
/// are the very same CMBlockBuffers appended to AVAssetWriter. Reader snapshots
/// retain only metadata/weak handles; a slow client can pin at most one sample.
final class RecordingRAMCache: @unchecked Sendable {
    static let shared = RecordingRAMCache()
    struct Limits {
        var totalBytes = 64 * 1024 * 1024
        var tailBytes = 16 * 1024 * 1024
        var tailFrames = 4096
        var tailSeconds: Double = 30
    }
    fileprivate let lock = NSLock()
    private let limits: Limits
    private var tails: [String: RecordingRAMTail] = [:]
    private var bytes = 0
    private var pressured = false
    private var ordinal: UInt64 = 0
    private var timer: DispatchSourceTimer?
    private var pressure: DispatchSourceMemoryPressure?
    init(limits: Limits = Limits(), maintenance: Bool = true) {
        self.limits = limits
        if maintenance {
            let queue = DispatchQueue(label: "hbnvr.media.ram-maintenance", qos: .utility)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.maintain() }; timer.resume(); self.timer = timer
            let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical],
                queue: DispatchQueue(label: "hbnvr.media.ram-pressure", qos: .utility))
            pressure.setEventHandler { [weak self, weak pressure] in
                let event = pressure?.data ?? .critical
                self?.memoryPressure(event.contains(.warning) || event.contains(.critical) || !event.contains(.normal))
            }
            pressure.resume(); self.pressure = pressure
        }
    }
    deinit { timer?.cancel(); pressure?.cancel() }
    func open(timing: ShardTimingMetadata, codec: String, sets: [Data]) -> RecordingRAMTail {
        let tail = RecordingRAMTail(cache: self, timing: timing, codec: codec, sets: sets)
        lock.lock()
        if let previous = tails[timing.shardID] { previous.closed = true; drop(previous, count: previous.frames.count) }
        tails[timing.shardID] = tail; lock.unlock()
        return tail
    }
    var retainedBytes: Int { lock.lock(); defer { lock.unlock() }; return bytes }
    func retainedBytes(store: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return tails.values.filter { $0.timing.storeID == store }.reduce(0) { $0 + $1.bytes }
    }
    func memoryPressure(_ warning: Bool) {
        lock.lock(); defer { lock.unlock() }
        pressured = warning
        if warning { for tail in tails.values { drop(tail, count: tail.frames.count) } }
    }
    fileprivate func append(_ tail: RecordingRAMTail, block: CMBlockBuffer, pts: Int64, duration: Int64, key: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard !tail.closed, !pressured, key || !tail.frames.isEmpty else { return }
        let size = CMBlockBufferGetDataLength(block)
        guard size > 0, size <= limits.tailBytes, size <= limits.totalBytes else {
            drop(tail, count: tail.frames.count); return
        }
        ordinal &+= 1
        tail.frames.append(RecordingRAMTail.Sample(block: block, pts: pts, duration: duration, key: key, bytes: size, ordinal: ordinal))
        tail.bytes += size; bytes += size
        while let first = tail.frames.first,
              tail.bytes > limits.tailBytes || tail.frames.count > limits.tailFrames
                || Double(pts - first.pts) / Double(tail.timing.timescale) > limits.tailSeconds {
            dropGOP(tail)
        }
        while bytes > limits.totalBytes {
            guard let oldest = tails.values.filter({ !$0.frames.isEmpty })
                .min(by: { $0.frames[0].ordinal < $1.frames[0].ordinal }) else { break }
            dropGOP(oldest)
        }
    }
    private func dropGOP(_ tail: RecordingRAMTail) {
        drop(tail, count: tail.frames.dropFirst().firstIndex(where: \.key) ?? tail.frames.count)
    }
    private func drop(_ tail: RecordingRAMTail, count: Int) {
        guard count > 0 else { return }
        let released = tail.frames.prefix(count).reduce(0) { $0 + $1.bytes }
        tail.frames.removeFirst(count); tail.bytes -= released; bytes -= released
    }
    fileprivate func close(_ tail: RecordingRAMTail) {
        lock.lock(); defer { lock.unlock() }
        tail.closed = true; drop(tail, count: tail.frames.count)
        if tails[tail.timing.shardID] === tail { tails[tail.timing.shardID] = nil }
    }
    func snapshot(row: LocalRecordingManifest.Recording) -> RecordingRAMTail.Snapshot? {
        lock.lock(); defer { lock.unlock() }
        guard let tail = tails[row.id], tail.timing == row.timing, !tail.closed,
              !tail.frames.isEmpty else { return nil }
        return RecordingRAMTail.Snapshot(timing: tail.timing, codec: tail.codec, sets: tail.sets,
            frames: tail.frames.enumerated().map { index, sample in
                // The next PTS settles the preceding sample duration, just as the
                // MP4 sample table does. Only the newest duration is provisional.
                let duration = index + 1 < tail.frames.count ? tail.frames[index + 1].pts - sample.pts : sample.duration
                return .init(sample: sample, pts: sample.pts, duration: duration, key: sample.key, bytes: sample.bytes)
            })
    }
    func advanceDisk(shard: String, through ticks: Int64) {
        lock.lock(); defer { lock.unlock() }
        guard let tail = tails[shard] else { return }
        // Retain just the keyframe-aligned overlap required to decode the tail.
        if let key = tail.frames.lastIndex(where: { $0.key && $0.pts <= ticks }) { drop(tail, count: key) }
    }
    func maintain() {
        lock.lock(); let values = Array(tails.values); lock.unlock()
        // Never inspect AVFoundation or perform file I/O while holding the cache
        // lock, on a reception queue, or on a store's recording queue.
        for value in values { value.inspectDisk() }
    }
}

final class RecordingRAMTail: @unchecked Sendable {
    final class Sample {
        let block: CMBlockBuffer
        let pts: Int64, duration: Int64
        let key: Bool
        let bytes: Int
        let ordinal: UInt64
        init(block: CMBlockBuffer, pts: Int64, duration: Int64, key: Bool, bytes: Int, ordinal: UInt64) {
            self.block = block; self.pts = pts; self.duration = duration; self.key = key; self.bytes = bytes; self.ordinal = ordinal
        }
    }
    struct Frame {
        weak var sample: Sample?
        let pts: Int64, duration: Int64
        let key: Bool
        let bytes: Int
    }
    struct Snapshot {
        let timing: ShardTimingMetadata
        let codec: String
        let sets: [Data]
        let frames: [Frame]
        var startTicks: Int64 { frames[0].pts }
        var endTicks: Int64 { frames.last!.pts + frames.last!.duration }
    }
    fileprivate let cache: RecordingRAMCache
    fileprivate let timing: ShardTimingMetadata
    fileprivate let codec: String
    fileprivate let sets: [Data]
    fileprivate var frames: [Sample] = []
    fileprivate var bytes = 0
    fileprivate var closed = false
    private weak var file: GrowingMediaFile?
    private var lastPrefix: Int64 = 0
    fileprivate init(cache: RecordingRAMCache, timing: ShardTimingMetadata, codec: String, sets: [Data]) {
        self.cache = cache; self.timing = timing; self.codec = codec; self.sets = sets
    }
    // The writer closes its registration explicitly after manifest publication
    // (also on destruction/failure). Reader snapshots never retain this owner.
    func close() { cache.close(self) }
    func append(block: CMBlockBuffer, pts: Int64, duration: Int64, key: Bool) {
        cache.append(self, block: block, pts: pts, duration: duration, key: key)
    }
    func attach(_ file: GrowingMediaFile) { cache.lock.lock(); self.file = file; cache.lock.unlock() }
    fileprivate func inspectDisk() {
        cache.lock.lock(); let file = closed || frames.isEmpty ? nil : self.file, previous = lastPrefix; cache.lock.unlock()
        guard let file else { return }
        do {
            let work = MediaWork(deadline: ProcessInfo.processInfo.systemUptime + 1)
            guard let snapshot = try file.snapshot(work: work), snapshot.size != previous else { return }
            let ticks = try LocalMediaReader.readableEnd(snapshot: snapshot, timing: timing, work: work)
            cache.advanceDisk(shard: timing.shardID, through: ticks)
            cache.lock.lock(); lastPrefix = snapshot.size; cache.lock.unlock()
        } catch {
            // Playback maintenance is best effort. Its independent bounds/pressure
            // policy release RAM even when disk inspection fails; recording wins.
        }
    }
}
