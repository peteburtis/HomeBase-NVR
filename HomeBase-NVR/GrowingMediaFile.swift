import Foundation
import Darwin

/// Only currently owned writers can publish unfinished video. An interrupted
/// manifest row or a plausible-looking filename is not sufficient authority.
/// This registry contains descriptors/timing, never a second video buffer.
final class GrowingMediaFile: @unchecked Sendable {
    private static let registryLock = NSLock()
    private static var registry: [String: GrowingMediaFile] = [:]
    private let lock = NSLock()
    private var valid = true
    private let fd: Int32
    private let timing: ShardTimingMetadata

    struct Snapshot {
        let file: GrowingMediaFile
        let size: Int64
        func check() throws { try file.readLocked { _ in () } }
        func read(offset: Int64, count: Int) throws -> Data {
            guard offset >= 0, count >= 0, count <= MediaLimits.messageBytes,
                  offset <= size, Int64(count) <= size - offset else { throw ServiceError("Invalid recording snapshot read.") }
            return try file.readLocked { fd in try GrowingMediaFile.read(fd, offset: offset, count: count) }
        }
    }

    static func publish(fd: Int32, timing: ShardTimingMetadata) throws -> GrowingMediaFile {
        let file = try GrowingMediaFile(fd: fd, timing: timing)
        registryLock.lock(); defer { registryLock.unlock() }
        guard registry[timing.shardID] == nil else { throw ServiceError("Duplicate active recording identity.") }
        registry[timing.shardID] = file
        return file
    }
    private init(fd: Int32, timing: ShardTimingMetadata) throws {
        self.fd = fcntl(fd, F_DUPFD_CLOEXEC, 0); self.timing = timing
        guard self.fd >= 0 else { throw ServiceError.posix("Pin active recording") }
    }
    deinit { close(fd) }

    /// Invalidate BEFORE AVAssetWriter starts defragmenting the file. Never wait
    /// for a client, asset scan, or network send. The lock covers at most one
    /// bounded pread, so no read can overlap the subsequent layout rewrite.
    func invalidate() {
        lock.lock(); valid = false; lock.unlock()
        Self.registryLock.lock()
        if Self.registry[timing.shardID] === self { Self.registry[timing.shardID] = nil }
        Self.registryLock.unlock()
    }
    private func readLocked<T>(_ body: (Int32) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard valid else { throw ServiceError(.unavailable, "Recording shard is closing; retry the time range against its finalized file.") }
        return try body(fd)
    }

    static func snapshot(row: LocalRecordingManifest.Recording, info: stat, work: MediaWork) throws -> Snapshot? {
        registryLock.lock(); let file = registry[row.id]; registryLock.unlock()
        guard let file, file.timing == row.timing else { return nil }
        let size: Int64 = try file.readLocked { fd in
            var pinned = stat()
            guard fstat(fd, &pinned) == 0, pinned.st_dev == info.st_dev, pinned.st_ino == info.st_ino,
                  pinned.st_mode & S_IFMT == S_IFREG, pinned.st_mode & 0o777 == 0o600,
                  pinned.st_uid == geteuid(), pinned.st_nlink == 1 else {
                throw ServiceError(.unavailable, "Active recording was replaced or changed.")
            }
            return pinned.st_size
        }
        return try file.snapshot(size: size, work: work)
    }
    func snapshot(work: MediaWork) throws -> Snapshot? {
        let size = try readLocked { fd -> Int64 in
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == geteuid(), info.st_mode & 0o777 == 0o600, info.st_nlink == 1 else {
                throw ServiceError(.unavailable, "Active recording changed.")
            }
            return info.st_size
        }
        return try snapshot(size: size, work: work)
    }
    private func snapshot(size: Int64, work: MediaWork) throws -> Snapshot? {
        let view = Snapshot(file: self, size: size)
        let end = try Self.completePrefix(size: size, work: work) { try view.read(offset: $0, count: $1) }
        return end == 0 ? nil : Snapshot(file: self, size: end)
    }

    /// AVAssetWriter's file-output layout places media before its moov/moof
    /// checkpoint. Ignore its trailing open-ended/partial mdat and any incomplete
    /// metadata. The prefix is fixed for this request; subsequent requests see
    /// newly completed fragments. Parse box headers only, not the video payload.
    static func completePrefix(size: Int64, work: MediaWork, read: (Int64, Int) throws -> Data) throws -> Int64 {
        var offset: Int64 = 0, end: Int64 = 0, boxes = 0, initialized = false
        while size - offset >= 8 {
            try work.check(); boxes += 1
            guard boxes <= 100_000 else { throw ServiceError(.unavailable, "Too many MP4 boxes in active recording.") }
            let header = try read(offset, 8)
            guard header.count == 8 else { break }
            var length = header.prefix(4).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            let type = String(decoding: header.suffix(4), as: UTF8.self)
            var headerSize: UInt64 = 8
            if length == 1 {
                guard size - offset >= 16 else { break }
                let extended = try read(offset + 8, 8)
                guard extended.count == 8 else { break }
                length = extended.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }; headerSize = 16
            }
            // Size zero means "to EOF", not a published fragment boundary.
            guard length >= headerSize, length <= UInt64(size - offset) else { break }
            offset += Int64(length)
            if type == "moov" { initialized = true; end = offset }
            if type == "moof", initialized { end = offset }
        }
        return end
    }
    private static func read(_ fd: Int32, offset: Int64, count: Int) throws -> Data {
        var data = Data(count: count)
        var n: Int
        repeat { n = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, offset) } } while n < 0 && errno == EINTR
        guard n == count else { throw ServiceError(.unavailable, "Active recording became unreadable.") }
        return data
    }
}
