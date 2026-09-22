import Foundation
import Darwin

/// Staging is beside already-plaintext local media, with its existing ACL policy.
/// S3 edits never call this. Only verified managed recordings can be replaced.
enum LocalTagFile {
    struct Pending: Codable {
        let shardID: String
        let filename: String
        let stagedName: String
        let oldFile: LocalRecordingManifest.FileIdentity
        let newFile: LocalRecordingManifest.FileIdentity
        let tags: VideoTagTimeline
    }
    static func matches(_ info: stat, _ identity: LocalRecordingManifest.FileIdentity) -> Bool {
        info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1 && info.st_uid == geteuid()
            && info.st_mode & 0o777 == 0o600 && LocalRecordingManifest.FileIdentity(info) == identity
    }
    static func stage(source: LocalMediaProvider.Source, tags: VideoTagTimeline, jobID: String, work: MediaWork) throws -> Pending {
        try tags.validate(); try work.check()
        let dir = source.directory, row = source.row
        try LocalRecordingLayout.verify(path: dir.path, fd: dir.fd, owner: source.owner)
        let input = openat(dir.fd, row.filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard input >= 0 else { throw ServiceError.posix("Open recording for tag edit") }
        defer { close(input) }
        var old = stat()
        guard fstat(input, &old) == 0, LocalMediaProvider.matches(old, row: row) else { throw ServiceError("Recording changed before tag edit.") }
        var volume = statfs()
        guard fstatfs(dir.fd, &volume) == 0 else { throw ServiceError.posix("Inspect local tag staging volume") }
        let (available, overflow) = UInt64(volume.f_bavail).multipliedReportingOverflow(by: UInt64(volume.f_bsize))
        guard !overflow, available >= UInt64(row.size) + UInt64(VideoTagTimeline.maximumBytes) + 64 * 1024 * 1024 else {
            throw ServiceError("Insufficient space for a safe local tag rewrite plus a 64 MiB recording reserve; original footage preserved.")
        }
        let leaf = ".hbnvr-tags-" + jobID + "-" + row.id + "-" + UUID().uuidString + ".tmp"
        let output = openat(dir.fd, leaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw ServiceError.posix("Stage recording tag edit") }
        var ready = false
        defer { close(output); if !ready { _ = unlinkat(dir.fd, leaf, 0) } }
        try StoreDirectory.restrict(output, owner: source.owner, daemon: geteuid(), directory: false)
        func read(_ offset: Int64, _ length: Int) throws -> Data {
            var data = Data(count: length), done = 0
            while done < length {
                try work.check()
                let n = data.withUnsafeMutableBytes { pread(input, $0.baseAddress!.advanced(by: done), length - done, offset + Int64(done)) }
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw ServiceError("Recording became unreadable during tag edit.") }
                done += n
            }
            return data
        }
        func write(_ data: Data) throws {
            try data.withUnsafeBytes { bytes in
                var done = 0
                while done < bytes.count {
                    try work.check()
                    let n = Darwin.write(output, bytes.baseAddress!.advanced(by: done), bytes.count - done)
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { throw ServiceError.posix("Write recording tag edit") }
                    done += n
                }
            }
        }
        var offset: Int64 = 0, found = false
        while offset < row.size {
            guard row.size - offset >= 8 else { throw ServiceError("Truncated MP4 box; recording preserved.") }
            let header = try read(offset, 8)
            let small = header.prefix(4).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let headerSize: Int64 = small == 1 ? 16 : 8
            let length: UInt64
            if small == 1 {
                guard row.size - offset >= 16 else { throw ServiceError("Truncated extended MP4 box.") }
                length = try read(offset + 8, 8).reduce(0) { ($0 << 8) | UInt64($1) }
            } else { length = small == 0 ? UInt64(row.size - offset) : small }
            guard length >= headerSize, length <= row.size - offset else { throw ServiceError("Invalid MP4 box length.") }
            let isTags = try header.suffix(4) == Data("uuid".utf8) && length >= headerSize + 16
                && read(offset + headerSize, 16) == VideoTagMP4.identifier
            if isTags {
                guard !found, length <= VideoTagTimeline.maximumBytes + 32,
                      offset + Int64(length) == row.size else { throw ServiceError("Tags must be a single trailing MP4 box; recording preserved.") }
                found = true
            } else {
                // A size-zero final box would otherwise swallow the appended
                // metadata. Refuse rather than relocate samples or fabricate it.
                guard small != 0 else { throw ServiceError("Cannot append tags after a size-zero MP4 box; recording preserved.") }
                var copied: Int64 = 0
                while copied < length {
                    let count = Int(min(1_048_576, Int64(length) - copied))
                    try write(read(offset + copied, count)); copied += Int64(count)
                }
            }
            offset += Int64(length)
        }
        try write(VideoTagMP4.box(tags))
        var latest = stat(), new = stat()
        guard fstat(input, &latest) == 0, matches(latest, .init(old)),
              fstat(output, &new) == 0, fsync(output) == 0, fsync(dir.fd) == 0 else { throw ServiceError("Could not persist tag edit; original recording preserved.") }
        ready = true
        return Pending(shardID: row.id, filename: row.filename, stagedName: leaf, oldFile: .init(old), newFile: .init(new), tags: tags)
    }
}
