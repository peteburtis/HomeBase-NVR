import Foundation
import Darwin
@preconcurrency import AVFoundation
import CoreMedia

/// Resolves only configured local stores and their identity-bound indexes. It
/// never adopts video, fetches S3 objects, consults file dates, or opens a path
/// supplied by an IPC client. Reader connections never mutate the manifest.
final class LocalMediaProvider {
    struct Source {
        let directory: LocalRecordingLayout.Directory
        let owner: uid_t
        let row: LocalRecordingManifest.Recording
        let range: MediaRange
        var growing: GrowingMediaFile.Snapshot? = nil
        var readableTicks: Int64? = nil
        var memory: RecordingRAMTail.Snapshot? = nil
        var activeTags: RecordingRAMTail.Tags? = nil
        var endTicks: Int64 { readableTicks ?? row.endTicks }
    }
    struct Piece { let source: Source; let range: MediaRange }
    let configurations: () throws -> [RecordingStoreConfiguration]
    let live: (String) -> RecordingTime?
    let now: () -> Double
    let ram: RecordingRAMCache?
    init(configurations: @escaping () throws -> [RecordingStoreConfiguration],
         live: @escaping (String) -> RecordingTime? = { _ in nil }, now: @escaping () -> Double = { Date().timeIntervalSince1970 },
         ram: RecordingRAMCache? = .shared) {
        self.configurations = configurations; self.live = live; self.now = now; self.ram = ram
    }
    func catalog(camera: String, range: MediaRange, timeline: MediaTimeline, work: MediaWork, includeTags: Bool = false, strictIdentity: Bool = false) throws -> [Source] {
        var result: [Source] = []
        try visitIndexes(camera: camera, work: work) { directory, config, index in
            for row in try index.playbackRecordings(from: range.start, to: range.end, timeline: timeline) {
                result += try sources(row: row, directory: directory, owner: config.ownerUID, timeline: timeline, work: work, includeTags: includeTags, strictIdentity: strictIdentity)
                    .filter { $0.range.end > range.start && $0.range.start < range.end }
                guard result.count <= MediaLimits.candidates else { throw ServiceError(.invalidMessage, "Too many recording shards; request a smaller time range.") }
            }
        }
        return result
    }
    func neighbors(camera: String, range: MediaRange, timeline: MediaTimeline, work: MediaWork, excludeTagKeys: [String] = []) throws -> MediaNeighbors {
        let filtering = !excludeTagKeys.isEmpty
        var result = MediaNeighbors()
        try visitIndexes(camera: camera, work: work) { directory, config, index in
            for previous in [true, false] {
                let point = previous ? range.start : range.end
                try index.visitNeighbors(at: point, previous: previous, timeline: timeline, work: work) { row in
                    // SQL orders whole recordings, not their filtered subranges.
                    // An overlapping recording may contain a closer matching run.
                    // Stop only when its unfiltered bound cannot beat our result.
                    if filtering, row.state == .complete, let anchor = timeline.anchor(row.timing.time) {
                        let end = anchor + Double(row.endTicks) / Double(row.timescale)
                        if previous, let best = result.previous, min(point, end) < best.end { return false }
                        if !previous, let best = result.next, max(point, anchor) > best.start { return false }
                    }
                    let candidates = try self.sources(row: row, directory: directory, owner: config.ownerUID,
                        timeline: timeline, work: work, includeTags: filtering, strictIdentity: filtering)
                    let intervals: [MediaRange]
                    if filtering {
                        let whole = MediaRange(start: candidates.map(\.range.start).min() ?? point,
                            end: candidates.map(\.range.end).max() ?? point)
                        // Match frame playback's precedence across ALL overlapping
                        // rows, not just disk/RAM copies of this row. In particular,
                        // an older same-epoch shard can mask this row's matching head.
                        let overlapping = whole.end > whole.start ? try self.catalog(camera: camera,
                            range: whole, timeline: timeline, work: work, includeTags: true, strictIdentity: true) : []
                        let pieces = try Self.plan(overlapping, range: whole, work: work).filter {
                            $0.source.row.id == row.id && $0.source.directory.path == directory.path
                        }
                        intervals = try MediaRange.merged(pieces.flatMap {
                            try LocalMediaReader.filteredIntervals($0, timeline: timeline, excludeTagKeys: excludeTagKeys, work: work)
                        })
                    } else { intervals = candidates.map(\.range) }
                    var found = false
                    for interval in intervals {
                        let clipped = MediaRange(start: previous ? interval.start : max(point, interval.start),
                            end: previous ? min(point, interval.end) : interval.end)
                        guard clipped.end > clipped.start else { continue }
                        found = true
                        if previous {
                            if result.previous == nil || (clipped.end, clipped.start) > (result.previous!.end, result.previous!.start) {
                                result.previous = clipped
                            }
                        } else if result.next == nil || (clipped.start, clipped.end) < (result.next!.start, result.next!.end) {
                            result.next = clipped
                        }
                    }
                    // Active rows are ordered ahead of completed ones regardless
                    // of their wall times. Always compare one readable complete row.
                    return filtering || row.state == .recording || !found
                }
            }
        }
        return result
    }
    private func sources(row: LocalRecordingManifest.Recording, directory: LocalRecordingLayout.Directory,
                         owner: uid_t, timeline: MediaTimeline, work: MediaWork, includeTags: Bool = false, strictIdentity: Bool = false) throws -> [Source] {
        try work.check()
        guard let anchor = timeline.anchor(row.timing.time) else { return [] }
        var info = stat(), result: [Source] = []
        let exists = fstatat(directory.fd, row.filename, &info, AT_SYMLINK_NOFOLLOW) == 0
        if !exists, errno != ENOENT { throw ServiceError.posix("Inspect indexed video") }
        if strictIdentity, exists, row.state == .complete, !Self.matches(info, row: row) {
            throw ServiceError(.unavailable, "Indexed recording changed or is inaccessible; retry neighbors.")
        }
        if row.state == .recording {
            // Metadata remains available even when RAM video is disabled for
            // this provider or evicted. Never infer current tags from SQLite.
            let tags = includeTags ? (ram ?? .shared).tagSnapshot(row: row) : nil
            if exists, let snapshot = try GrowingMediaFile.snapshot(row: row, info: info, work: work) {
                let provisional = Source(directory: directory, owner: owner, row: row,
                    range: MediaRange(start: anchor, end: anchor), growing: snapshot)
                var ticks = try LocalMediaReader.readableEnd(provisional, work: work)
                if includeTags {
                    guard let tags else { throw ServiceError(.unavailable, "Active tag snapshot changed; retry the video range.") }
                    ticks = min(ticks, tags.endTicks)
                }
                let end = anchor + Double(ticks) / Double(row.timescale)
                ram?.advanceDisk(shard: row.id, through: ticks)
                if ticks > 0 {
                    result.append(Source(directory: directory, owner: owner, row: row,
                        range: MediaRange(start: anchor, end: end), growing: snapshot, readableTicks: ticks, activeTags: tags))
                }
            }
            if let memory = ram?.snapshot(row: row) {
                let available = MediaRange(start: anchor + Double(memory.startTicks) / Double(row.timescale),
                    end: anchor + Double(memory.endTicks) / Double(row.timescale))
                result.append(Source(directory: directory, owner: owner, row: row,
                    range: available, readableTicks: memory.endTicks, memory: memory))
            }
        } else if exists, Self.matches(info, row: row), row.endTicks > 0 {
            result.append(Source(directory: directory, owner: owner, row: row,
                range: MediaRange(start: anchor, end: anchor + Double(row.endTicks) / Double(row.timescale))))
        }
        return result
    }
    func visitIndexes(camera: String?, work: MediaWork,
                              visit: (LocalRecordingLayout.Directory, RecordingStoreConfiguration, LocalRecordingManifest) throws -> Void) throws {
        let configs: [RecordingStoreConfiguration]
        // Matches playback discovery's first-discovered store policy. All media
        // operations (frames, availability, neighbors, thumbnails) use this one
        // root, even if another local store could satisfy the request.
        do { configs = Array(try configurations().filter { $0.type == "Local" }.sorted { $0.id < $1.id }.prefix(1)) }
        catch { throw ServiceError(.unavailable, "Recording configuration is unavailable.") }
        for config in configs {
            try work.check()
            let root = try StoreDirectory.openDirectory(config.directory); defer { close(root) }
            try StoreDirectory.validate(root, owner: config.ownerUID, daemon: geteuid())
            // Enumerate directory names via the pinned root, not a second pathname lookup.
            let copy = dup(root)
            guard copy >= 0 else { throw ServiceError.posix("Inspect local store") }
            guard let iterator = fdopendir(copy) else { close(copy); throw ServiceError.posix("Inspect local store") }
            defer { closedir(iterator) }
            var count = 0
            while let entry = readdir(iterator) {
                try work.check()
                let leaf = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
                }
                if leaf == "." || leaf == ".." { continue }
                count += 1
                guard count <= MediaLimits.directories else { throw ServiceError(.invalidMessage, "Too many entries in the local recording root.") }
                var info = stat()
                guard fstatat(root, leaf, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                    if errno == ENOENT { continue }; throw ServiceError.posix("Inspect camera directory")
                }
                guard info.st_mode & S_IFMT == S_IFDIR else { continue }
                let child = openat(root, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw ServiceError.posix("Open camera directory") }
                let directory = LocalRecordingLayout.Directory(path: config.directory + "/" + leaf, fd: child)
                guard let identity = try LocalRecordingLayout.identity(in: child),
                      identity.storeID == config.id, camera == nil || identity.cameraID == camera else { continue }
                if fstatat(child, LocalRecordingManifest.filename, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                    if errno == ENOENT { continue }; throw ServiceError.posix("Inspect local recording index")
                }
                let index = try LocalRecordingManifest(directory: directory, identity: identity, owner: config.ownerUID, readOnly: true)
                try visit(directory, config, index)
            }
        }
    }
    static func matches(_ info: stat, row: LocalRecordingManifest.Recording) -> Bool {
        info.st_mode & S_IFMT == S_IFREG && info.st_uid == geteuid() && info.st_mode & 0o777 == 0o600 && info.st_nlink == 1
            && Int64(info.st_dev) == row.device && Int64(bitPattern: info.st_ino) == row.inode && info.st_size == row.size
    }
    /// Overlapping RAM/disk sources of the same stream epoch fill holes rather
    /// than duplicate playback. Different epochs remain distinct even if their
    /// wall times overlap; only the selected Local store is inspected.
    static func plan(_ sources: [Source], range: MediaRange, work: MediaWork = MediaWork()) throws -> [Piece] {
        var covered: [String: [MediaRange]] = [:], pieces: [Piece] = []
        let ordered = sources.sorted {
            ($0.memory == nil ? 1 : 0, $0.range.start, $0.row.timing.storeID, $0.row.id)
                < ($1.memory == nil ? 1 : 0, $1.range.start, $1.row.timing.storeID, $1.row.id)
        }
        for source in ordered {
            try work.check()
            let clipped = MediaRange(start: max(range.start, source.range.start), end: min(range.end, source.range.end))
            let epoch = source.row.timing.time.epochID
            for remaining in clipped.subtracting(covered[epoch] ?? []) { pieces.append(Piece(source: source, range: remaining)) }
            guard pieces.count <= MediaLimits.candidates else { throw ServiceError(.invalidMessage, "Too many recording intervals; request a smaller range.") }
            covered[epoch] = MediaRange.merged((covered[epoch] ?? []) + [clipped])
        }
        return pieces.sorted { ($0.range.start, $0.source.row.timing.time.epochID, $0.source.row.id) < ($1.range.start, $1.source.row.timing.time.epochID, $1.source.row.id) }
    }
}

/// AVFoundation reads through a pinned, validated descriptor. No /dev/fd URL
/// reopening, pathname race, temporary copy, or decoded pixels are involved.
private final class PinnedMediaAsset: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let asset: AVURLAsset
    private let fd: Int32
    private let size: Int64
    private let work: MediaWork
    private let growing: GrowingMediaFile.Snapshot?
    private let queue = DispatchQueue(label: "hbnvr.media.file")
    init(snapshot: GrowingMediaFile.Snapshot, work: MediaWork) throws {
        try snapshot.check(); growing = snapshot; size = snapshot.size; fd = -1; self.work = work
        asset = AVURLAsset(url: URL(string: "hbnvr-media://recording/" + UUID().uuidString + ".mp4")!)
        super.init(); asset.resourceLoader.setDelegate(self, queue: queue)
    }
    init(source: LocalMediaProvider.Source, work: MediaWork) throws {
        try work.check()
        try LocalRecordingLayout.verify(path: source.directory.path, fd: source.directory.fd, owner: source.owner)
        growing = source.growing
        if let growing {
            try growing.check(); fd = -1; size = growing.size
        } else {
            fd = openat(source.directory.fd, source.row.filename, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw ServiceError(.unavailable, "Recording is no longer available.") }
            var info = stat()
            guard fstat(fd, &info) == 0, LocalMediaProvider.matches(info, row: source.row) else {
                close(fd); throw ServiceError(.unavailable, "Recording was replaced or changed.")
            }
            size = info.st_size
        }
        self.work = work
        asset = AVURLAsset(url: URL(string: "hbnvr-media://recording/" + UUID().uuidString + ".mp4")!)
        super.init()
        asset.resourceLoader.setDelegate(self, queue: queue)
    }
    deinit { asset.cancelLoading(); if fd >= 0 { close(fd) } }
    func check() throws { try work.check(); try growing?.check() }
    func inspect() throws -> (AVAssetTrack, ShardTimingMetadata?, CMTimeRange) {
        do { return try MediaAssetInspection().inspect(asset, work: work) }
        catch { try check(); throw error } // Preserve the retryable rotation error.
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        do {
            try check()
            if let content = request.contentInformationRequest {
                content.contentType = AVFileType.mp4.rawValue; content.contentLength = size; content.isByteRangeAccessSupported = true
            }
            if let data = request.dataRequest {
                var offset = max(data.requestedOffset, data.currentOffset)
                guard offset >= 0, offset <= size, data.requestedLength >= 0,
                      data.requestedOffset <= Int64.max - Int64(data.requestedLength) else { throw ServiceError("Invalid video read range.") }
                let end = data.requestsAllDataToEndOfResource ? size : min(size, data.requestedOffset + Int64(data.requestedLength))
                while offset < end, !request.isCancelled {
                    try check()
                    var bytes = Data(count: Int(min(Int64(MediaLimits.messageBytes), end - offset)))
                    let n: Int
                    if let growing { bytes = try growing.read(offset: offset, count: bytes.count); n = bytes.count }
                    else { n = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, offset) } }
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { throw ServiceError("Recording became unreadable.") }
                    bytes.count = n; data.respond(with: bytes); offset += Int64(n)
                }
            }
            if !request.isCancelled { request.finishLoading() }
        } catch { request.finishLoading(with: NSError(domain: "HBNVRMedia", code: 1, userInfo: nil)) }
        return true
    }
}

/// A dedicated media worker can wait for modern async AVAsset inspection without
/// occupying Swift's cooperative executor with blocking socket reads or disk scans.
private final class MediaAssetInspection: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<(AVAssetTrack, ShardTimingMetadata?, CMTimeRange), Error>?
    func inspect(_ asset: AVAsset, work: MediaWork) throws -> (AVAssetTrack, ShardTimingMetadata?, CMTimeRange) {
        let task = Task.detached { [self] in
            let value: Result<(AVAssetTrack, ShardTimingMetadata?, CMTimeRange), Error>
            do {
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard tracks.count == 1, let track = tracks.first else { throw ServiceError("Recording must have one video track.") }
                value = .success((track, try await ShardTimingMetadata.read(from: asset), try await track.load(.timeRange)))
            } catch { value = .failure(error) }
            set(value)
        }
        let deadline = min(work.deadline, ProcessInfo.processInfo.systemUptime + 15)
        do {
            while true {
                try work.check()
                lock.lock(); let value = result; lock.unlock()
                if let value { return try value.get() }
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw ServiceError(.timeout, "Timed out opening recording.") }
                Thread.sleep(forTimeInterval: 0.01)
            }
        } catch { task.cancel(); asset.cancelLoading(); throw error }
    }
    private func set(_ value: Result<(AVAssetTrack, ShardTimingMetadata?, CMTimeRange), Error>) { lock.lock(); result = value; lock.unlock() }
}

enum LocalMediaReader {
    /// Inspect sample-table timing only: no AVAssetReader, sample buffers, video
    /// payloads, or decode. The same effective tag projection as frame playback
    /// maps prospective sample ordinals and historical PTS overrides exactly.
    static func filteredIntervals(_ piece: LocalMediaProvider.Piece, timeline: MediaTimeline,
                                  excludeTagKeys: [String], work: MediaWork) throws -> [MediaRange] {
        let source = piece.source, row = source.row
        guard let anchor = timeline.anchor(row.timing.time) else { return [] }
        let scale = Double(row.timescale)
        var points: [MediaTagRanges.Point] = []
        let tags: VideoTagTimeline?
        if let memory = source.memory {
            tags = memory.tags
            points = memory.frames.map { .init(ticks: $0.pts, frame: $0.frame) }
        } else {
            let pinned = try PinnedMediaAsset(source: source, work: work)
            defer { withExtendedLifetime(pinned) {} }
            let (track, embedded, _) = try pinned.inspect()
            guard embedded == row.timing else { throw ServiceError(.unavailable, "Recording timing does not match its index.") }
            if row.state == .complete {
                let index = try LocalRecordingManifest(directory: source.directory,
                    identity: .init(storeID: row.timing.storeID, cameraID: row.timing.cameraID), owner: source.owner, readOnly: true)
                tags = try index.playbackTags(matching: row)
            } else {
                guard let snapshot = source.activeTags else { throw ServiceError(.unavailable, "Active tag snapshot is unavailable; retry neighbors.") }
                tags = snapshot.timeline
            }
            guard let cursor = track.makeSampleCursorAtFirstSampleInDecodeOrder() else {
                throw ServiceError(.unavailable, "Recording sample timing is unavailable.")
            }
            repeat {
                try pinned.check()
                let time = cursor.presentationTimeStamp
                let converted = CMTimeConvertScale(time, timescale: Int32(row.timescale), method: .default)
                guard time.isNumeric, converted.isNumeric, converted.value >= 0 else {
                    throw ServiceError(.unavailable, "Invalid recording sample time.")
                }
                if converted.value >= source.endTicks { break }
                if let frontier = source.activeTags, points.count >= frontier.frames { break }
                guard points.count < MediaLimits.taggedFrames,
                      points.last.map({ converted.value > $0.ticks }) ?? true else {
                    throw ServiceError(.unavailable, "Recording sample timing is unordered or exceeds the metadata limit.")
                }
                points.append(.init(ticks: converted.value, frame: Int64(points.count)))
            } while cursor.stepInDecodeOrder(byCount: 1) == 1
            try pinned.check()
            guard row.state != .complete || points.count == row.frames else {
                throw ServiceError(.unavailable, "Recording sample count does not match its manifest.")
            }
        }
        guard let first = points.first else { throw ServiceError(.unavailable, "Recording has no readable sample timing.") }
        let effectiveTags = try MediaTagRanges.build(tags, points: points, work: work)
        let excludedSpans = excludeTagKeys.flatMap { effectiveTags[$0] ?? [] }
        // A transition begins at its sample PTS, even when an override falls
        // between samples. The final sample ends at the captured readable frontier.
        let coverage = MediaRange(start: max(piece.range.start, anchor + Double(first.ticks) / scale), end: piece.range.end)
        let excluded = excludedSpans.map { span in
            MediaRange(start: anchor + Double(points[span.startFrame].ticks) / scale,
                end: span.endFrame < points.count ? anchor + Double(points[span.endFrame].ticks) / scale : source.range.end)
        }
        try work.check()
        return coverage.subtracting(excluded)
    }
    static func frameTicks(_ source: LocalMediaProvider.Source, work: MediaWork) throws -> [Int64] {
        try frameIndex(source, work: work).ticks
    }
    static func frameIndex(_ source: LocalMediaProvider.Source, work: MediaWork) throws -> HistoricalFrameIndex.Index {
        let pinned = try PinnedMediaAsset(source: source, work: work)
        let (track, timing, _) = try pinned.inspect()
        guard timing == source.row.timing, source.row.state == .complete else { throw ServiceError("Frame editing requires a finalized recording with matching embedded timing.") }
        let reader = try AVAssetReader(asset: pinned.asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output); guard reader.startReading() else { throw ServiceError("Cannot inspect recording frames.") }
        defer { reader.cancelReading(); withExtendedLifetime(pinned) {} }
        let index = try HistoricalFrameIndex.readIndex(output, reader: reader, timescale: source.row.timing.timescale, end: source.row.endTicks, work: work)
        guard index.ticks.count == source.row.frames else { throw ServiceError("Recording frame count does not match its manifest.") }
        return index
    }
    struct Result { let coverage: [MediaRange]; let frames: UInt64 }
    static func readableEnd(snapshot: GrowingMediaFile.Snapshot, timing: ShardTimingMetadata, work: MediaWork) throws -> Int64 {
        let pinned = try PinnedMediaAsset(snapshot: snapshot, work: work)
        return try readableEnd(pinned, timing: timing)
    }
    static func readableEnd(_ source: LocalMediaProvider.Source, work: MediaWork) throws -> Int64 {
        let pinned = try PinnedMediaAsset(source: source, work: work)
        return try readableEnd(pinned, timing: source.row.timing)
    }
    private static func readableEnd(_ pinned: PinnedMediaAsset, timing expected: ShardTimingMetadata) throws -> Int64 {
        defer { withExtendedLifetime(pinned) {} }
        let (_, timing, range) = try pinned.inspect()
        try pinned.check()
        guard timing == expected, range.start == .zero, range.end.isNumeric else {
            throw ServiceError(.unavailable, "Active recording timing does not match its index.")
        }
        let end = CMTimeConvertScale(range.end, timescale: Int32(expected.timescale), method: .default)
        guard end.isNumeric, end.value >= 0 else { throw ServiceError(.unavailable, "Invalid active recording duration.") }
        return end.value
    }
    /// Metadata and small binary chunks are emitted synchronously: a slow client
    /// applies backpressure only here, never to camera reception or store writers.
    static func read(_ piece: LocalMediaProvider.Piece, number: Int, request: MediaRequest, work: MediaWork,
                     emit: (MediaMessage) throws -> Void, bytes: (Data) throws -> Void,
                     keyframe: ((CMSampleBuffer, MediaSegment, [String: String]) throws -> Void)? = nil) throws -> Result {
        if let memory = piece.source.memory {
            return try readRAM(memory, range: piece.range, number: number, request: request, work: work, emit: emit, bytes: bytes, keyframe: keyframe)
        }
        let source = piece.source, row = source.row
        let pinned = try PinnedMediaAsset(source: source, work: work)
        defer { withExtendedLifetime(pinned) {} }
        let (track, embedded, _) = try pinned.inspect()
        try pinned.check()
        guard embedded == row.timing else { throw ServiceError(.unavailable, "Recording timing does not match its index.") }
        let includeTags = request.includeTags
        let tagTimeline: VideoTagTimeline?
        if includeTags, row.state == .complete {
            let index = try LocalRecordingManifest(directory: source.directory,
                identity: .init(storeID: row.timing.storeID, cameraID: row.timing.cameraID), owner: source.owner, readOnly: true)
            tagTimeline = try index.playbackTags(matching: row)
        } else if includeTags {
            guard let snapshot = source.activeTags else { throw ServiceError(.unavailable, "Active tag snapshot is unavailable; retry the range.") }
            tagTimeline = snapshot.timeline
        } else { tagTimeline = nil }
        let scale = Int32(row.timescale), anchor = source.range.start
        func reader(start: CMTime = .zero) throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
            let reader = try AVAssetReader(asset: pinned.asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw ServiceError("Cannot read encoded recording.") }
            reader.add(output)
            reader.timeRange = CMTimeRange(start: start, end: CMTime(value: source.endTicks, timescale: scale))
            guard reader.startReading() else { try pinned.check(); throw ServiceError("Cannot begin reading recording.") }
            return (reader, output)
        }
        func ticks(_ time: CMTime) throws -> Int64 {
            guard time.isNumeric, time.seconds.isFinite else { throw ServiceError("Invalid recording sample time.") }
            let converted = CMTimeConvertScale(time, timescale: scale, method: .default)
            guard converted.isNumeric else { throw ServiceError("Recording sample time overflows its timescale.") }
            return converted.value
        }
        func key(_ sample: CMSampleBuffer) -> Bool {
            let a = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]]
            return !(a?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool ?? false)
        }
        // Find the nearest preceding keyframe without buffering a GOP or relying
        // on undocumented seek preroll. A second reader starts at that exact point.
        let (scan, scanOutput) = try reader()
        var keyTicks: Int64?, scanFrame: Int64 = 0, points: [MediaTagRanges.Point] = []
        do {
            while let sample = scanOutput.copyNextSampleBuffer() {
                try pinned.check()
                // AVAssetReader also vends zero-sample edit/empty-media markers.
                // They are not video frames or random-access points.
                if CMSampleBufferGetNumSamples(sample) == 0 { continue }
                let pts = try ticks(CMSampleBufferGetPresentationTimeStamp(sample))
                let time = anchor + Double(pts) / Double(scale)
                if includeTags {
                    guard CMSampleBufferGetNumSamples(sample) == 1 else { throw ServiceError("Unsupported tag sample sequence.") }
                    if let frontier = source.activeTags, scanFrame >= frontier.frames { break }
                    if pts >= source.endTicks || time >= piece.range.end { break }
                }
                if key(sample), time <= piece.range.start {
                    keyTicks = pts
                    if includeTags { points.removeAll(keepingCapacity: true) }
                }
                if time >= piece.range.start {
                    if keyTicks == nil, key(sample), time < piece.range.end { keyTicks = pts }
                    if !includeTags, keyTicks != nil || time >= piece.range.end { break }
                }
                if includeTags, keyTicks != nil {
                    guard points.count < MediaLimits.taggedFrames else { throw ServiceError(.invalidMessage, "Too many frames for segment tags; request a smaller range.") }
                    points.append(.init(ticks: pts, frame: scanFrame))
                }
                scanFrame += 1
            }
            try pinned.check()
            if scan.status == .failed { throw ServiceError("Could not scan recording keyframes.") }
        } catch { scan.cancelReading(); throw error }
        scan.cancelReading()
        guard let startTicks = keyTicks else { return Result(coverage: [], frames: 0) }
        let tagPayload = includeTags ? try MediaTagRanges.encode(tagTimeline, points: points, work: work) : nil
        let (video, output) = try reader(start: CMTime(value: startTicks, timescale: scale))
        defer { video.cancelReading() }
        var count: UInt64 = 0, coverage: [MediaRange] = [], previous: Int64?, format: CMFormatDescription?
        while let sample = output.copyNextSampleBuffer() {
            try pinned.check()
            if CMSampleBufferGetNumSamples(sample) == 0 { continue }
            let pts = try ticks(CMSampleBufferGetPresentationTimeStamp(sample))
            if pts < startTicks { continue }
            if includeTags {
                if count == UInt64(points.count) { break }
                guard points[Int(count)].ticks == pts else { throw ServiceError("Frame sequence changed after its tags were captured.") }
            }
            let time = anchor + Double(pts) / Double(scale)
            if time >= piece.range.end { break }
            let sampleDuration = CMSampleBufferGetDuration(sample)
            let rawDuration = try ticks(sampleDuration)
            // MP4's track clock can be coarser than the manifest's RTP clock
            // (commonly 600 versus 90,000 Hz). AVAssetReader can round the final
            // sample end slightly past our exact indexed boundary even with a
            // bounded timeRange. Accept at most one source tick of rounding;
            // never advertise frames beyond the manifest/snapshot frontier.
            let duration = try boundedDuration(rawDuration, presentation: pts, end: source.endTicks,
                                              sourceScale: sampleDuration.timescale, outputScale: scale)
            guard pts >= 0, pts < source.endTicks, duration > 0,
                  previous.map({ pts > $0 }) ?? true,
                  let description = CMSampleBufferGetFormatDescription(sample),
                  let block = CMSampleBufferGetDataBuffer(sample), CMSampleBufferGetNumSamples(sample) == 1 else {
                throw ServiceError("Unsupported recording sample (PTS \(pts), duration \(duration), end \(source.endTicks), samples \(CMSampleBufferGetNumSamples(sample))).")
            }
            if count == 0 {
                guard key(sample), pts == startTicks else { throw ServiceError("Recording seek did not begin on a keyframe.") }
                let codec = try configuration(description)
                let segment = MediaSegment(number: number,
                    range: MediaRange(start: time, end: piece.range.end), time: row.timing.time,
                    timescale: UInt32(scale), codec: codec.name, parameterSets: codec.sets, nalUnitLengthBytes: codec.length)
                if let keyframe {
                    let decode = CMSampleBufferGetDecodeTimeStamp(sample)
                    if decode.isNumeric, try ticks(decode) != pts { throw ServiceError("Reordered video is not supported.") }
                    let tags = try MediaTagRanges.build(tagTimeline, points: Array(points.prefix(1)), work: work)
                    try keyframe(sample, segment, tags.compactMapValues { $0.first?.value })
                    return Result(coverage: [], frames: 1)
                }
                try MediaTagRanges.emit(segment, tags: tagPayload, frameCount: points.count, requestID: request.requestID,
                                        work: work, emit: emit, bytes: bytes)
                format = description
            } else if let format, !CMFormatDescriptionEqual(format, otherFormatDescription: description) {
                throw ServiceError("Codec changed within a recording segment.")
            }
            let size = CMBlockBufferGetDataLength(block)
            guard size > 0 else { throw ServiceError("Empty encoded video frame.") }
            let decode = CMSampleBufferGetDecodeTimeStamp(sample)
            let dts = decode.isNumeric ? try ticks(decode) : nil
            guard dts == nil || dts == pts else { throw ServiceError("Reordered video is not supported by media protocol v1.") }
            let frame = MediaFrame(segment: number, presentationTicks: pts, decodeTicks: dts, durationTicks: duration,
                keyFrame: key(sample), preroll: time < piece.range.start, byteCount: size)
            var message = MediaMessage(type: "frame", requestID: request.requestID); message.frame = frame
            try emit(message)
            var offset = 0
            while offset < size {
                try work.check()
                var chunk = Data(count: min(MediaLimits.messageBytes, size - offset))
                let status = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: offset, dataLength: $0.count, destination: $0.baseAddress!) }
                guard status == noErr else { throw ServiceError("Could not read encoded frame bytes.") }
                try bytes(chunk); offset += chunk.count
            }
            count += 1; previous = pts
            let interval = MediaRange(start: max(time, piece.range.start),
                end: min(piece.range.end, anchor + Double(pts + duration) / Double(scale)))
            if interval.end > interval.start {
                if let last = coverage.last, interval.start <= last.end {
                    coverage[coverage.count - 1] = MediaRange(start: last.start, end: max(last.end, interval.end))
                } else {
                    guard coverage.count < MediaLimits.candidates else { throw ServiceError(.invalidMessage, "Too many recording gaps; request a smaller range.") }
                    coverage.append(interval)
                }
            }
        }
        try pinned.check()
        guard video.status != .failed else { throw ServiceError("Recording read failed.") }
        guard !includeTags || count == UInt64(points.count) else { throw ServiceError("Video ended before its advertised tag frame range.") }
        return Result(coverage: coverage, frames: count)
    }
    static func boundedDuration(_ duration: Int64, presentation: Int64, end: Int64,
                                sourceScale: Int32, outputScale: Int32) throws -> Int64 {
        guard presentation >= 0, presentation < end, duration > 0, sourceScale > 0, outputScale > 0 else {
            throw ServiceError("Invalid recording sample duration.")
        }
        let remaining = end - presentation
        if duration <= remaining { return duration }
        let rounding = (Int64(outputScale) + Int64(sourceScale) - 1) / Int64(sourceScale)
        guard duration - remaining <= rounding else {
            throw ServiceError("Recording sample extends beyond its indexed duration.")
        }
        return remaining
    }
    private static func readRAM(_ memory: RecordingRAMTail.Snapshot, range: MediaRange, number: Int,
                                request: MediaRequest, work: MediaWork,
                                emit: (MediaMessage) throws -> Void, bytes: (Data) throws -> Void,
                                keyframe: ((CMSampleBuffer, MediaSegment, [String: String]) throws -> Void)?) throws -> Result {
        guard let anchor = request.timeline.anchor(memory.timing.time) else { return Result(coverage: [], frames: 0) }
        let scale = Double(memory.timing.timescale)
        let key = memory.frames.lastIndex { $0.key && anchor + Double($0.pts) / scale <= range.start }
            ?? memory.frames.firstIndex { $0.key && anchor + Double($0.pts) / scale < range.end }
        guard let key else { return Result(coverage: [], frames: 0) }
        let includeTags = request.includeTags
        let points = includeTags ? memory.frames[key...].prefix { anchor + Double($0.pts) / scale < range.end }
            .map { MediaTagRanges.Point(ticks: $0.pts, frame: $0.frame) } : []
        let tagPayload = includeTags ? try MediaTagRanges.encode(memory.tags, points: points, work: work) : nil
        var count: UInt64 = 0, coverage: [MediaRange] = []
        for index in key..<memory.frames.count {
            try work.check()
            let frame = memory.frames[index], time = anchor + Double(frame.pts) / scale
            if time >= range.end { break }
            // One strong lease, released after this frame. Neither the request nor
            // a blocked socket can keep an evicted GOP/shard resident.
            guard let sample = frame.sample else {
                throw ServiceError(.unavailable, "RAM frames moved to disk or were released under playback memory pressure; retry the time range.")
            }
            if count == 0 {
                var message = MediaMessage(type: "segment", requestID: request.requestID)
                message.segment = MediaSegment(number: number, range: .init(start: time, end: range.end),
                    time: memory.timing.time, timescale: memory.timing.timescale, codec: memory.codec,
                    parameterSets: memory.sets, nalUnitLengthBytes: 4)
                if let keyframe {
                    let format = try MP4Shard.format(codec: memory.codec, sets: memory.sets)
                    var timing = CMSampleTimingInfo(duration: CMTime(value: frame.duration, timescale: Int32(memory.timing.timescale)),
                        presentationTimeStamp: CMTime(value: frame.pts, timescale: Int32(memory.timing.timescale)), decodeTimeStamp: .invalid)
                    var size = frame.bytes, buffer: CMSampleBuffer?
                    guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: sample.block,
                        formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &buffer) == noErr,
                        let buffer else { throw ServiceError("Cannot read resident keyframe.") }
                    let tags = try MediaTagRanges.build(memory.tags, points: [.init(ticks: frame.pts, frame: frame.frame)], work: work)
                    try keyframe(buffer, message.segment!, tags.compactMapValues { $0.first?.value })
                    return Result(coverage: [], frames: 1)
                }
                try MediaTagRanges.emit(message.segment!, tags: tagPayload, frameCount: points.count, requestID: request.requestID,
                                        work: work, emit: emit, bytes: bytes)
            }
            var message = MediaMessage(type: "frame", requestID: request.requestID)
            message.frame = MediaFrame(segment: number, presentationTicks: frame.pts, decodeTicks: nil,
                durationTicks: frame.duration, keyFrame: frame.key, preroll: time < range.start, byteCount: frame.bytes)
            try emit(message)
            var offset = 0
            while offset < frame.bytes {
                try work.check()
                var chunk = Data(count: min(MediaLimits.messageBytes, frame.bytes - offset))
                let status = chunk.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(sample.block, atOffset: offset, dataLength: $0.count, destination: $0.baseAddress!)
                }
                guard status == noErr else { throw ServiceError(.unavailable, "Cannot read resident encoded frame.") }
                try bytes(chunk); offset += chunk.count
            }
            count += 1
            let interval = MediaRange(start: max(time, range.start), end: min(range.end, anchor + Double(frame.pts + frame.duration) / scale))
            coverage = MediaRange.merged(coverage + [interval])
            withExtendedLifetime(sample) {}
        }
        return Result(coverage: coverage, frames: count)
    }
    static func configuration(_ format: CMFormatDescription) throws -> (name: String, sets: [Data], length: Int) {
        let type = CMFormatDescriptionGetMediaSubType(format), hevc = type == kCMVideoCodecType_HEVC
        guard hevc || type == kCMVideoCodecType_H264 else { throw ServiceError("Only H.264 and H.265 are supported.") }
        var sets: [Data] = [], count = 0, length: Int32 = 0
        for i in 0..<(hevc ? 3 : 2) {
            var pointer: UnsafePointer<UInt8>?, size = 0
            let status = hevc
                ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &length)
                : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &length)
            guard status == noErr, let pointer, size > 0, size <= 8192 else { throw ServiceError("Invalid codec parameter sets.") }
            sets.append(Data(bytes: pointer, count: size))
        }
        guard [1, 2, 4].contains(length) else { throw ServiceError("Unsupported NAL length field.") }
        return (hevc ? "H265" : "H264", sets, Int(length))
    }
}
