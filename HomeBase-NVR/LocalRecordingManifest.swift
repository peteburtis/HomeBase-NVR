import Foundation
import Darwin
import SQLite3

/// Prospective recording metadata, never reconstructed from filenames or file dates.
/// Owned by one local-store worker. Readers use separate read-only connections.
final class LocalRecordingManifest {
    static let filename = ".hbnvr-manifest.sqlite"
    static let schemaVersion: Int64 = 1
    private static let applicationID: Int64 = 0x48424e4d // HBNM
    enum State: String { case recording, complete, interrupted }
    struct Recording {
        let id: String
        let filename: String
        let finalFilename: String
        let start: Double // Canonical UTC, Unix seconds; never filesystem time.
        let timescale: Int64
        let sourceTimestamp: Int64
        let endTicks: Int64
        let frames: Int64
        let state: State
        let device: Int64
        let inode: Int64
        let size: Int64
        let timing: ShardTimingMetadata
        var end: Double { start + Double(endTicks) / Double(timescale) }
    }
    struct Interval: Equatable {
        let start: Double
        let end: Double // exclusive
    }
    struct Coverage {
        let recordings: [Recording]
        let available: [Interval]
        /// Unavailable in this index, not proof that footage never existed.
        let gaps: [Interval]
    }
    private enum Value { case text(String), integer(Int64), real(Double), null }
    private var database: OpaquePointer?
    private let directory: LocalRecordingLayout.Directory
    private let owner: uid_t
    private let readOnly: Bool
    private let identity: LocalRecordingLayout.Identity
    private var databaseDevice: dev_t = 0
    private var databaseInode: ino_t = 0

    init(directory: LocalRecordingLayout.Directory, identity: LocalRecordingLayout.Identity,
         owner: uid_t, readOnly: Bool = false) throws {
        self.directory = directory; self.owner = owner; self.readOnly = readOnly
        self.identity = identity
        try LocalRecordingLayout.verify(path: directory.path, fd: directory.fd, owner: owner)
        var info = stat()
        let exists = fstatat(directory.fd, Self.filename, &info, AT_SYMLINK_NOFOLLOW) == 0
        guard exists || errno == ENOENT else { throw ServiceError.posix("Inspect local manifest") }
        if !exists {
            guard !readOnly else { throw ServiceError(.unavailable, "No local manifest exists; older recordings are not indexed.") }
            // SQLite inherits this mode for its rollback journal. The directory's
            // existing requester/daemon ACLs are inherited as for the video files.
            let fd = openat(directory.fd, Self.filename, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw ServiceError.posix("Create local manifest") }
            defer { close(fd) }
            guard fstat(fd, &info) == 0 else { throw ServiceError.posix("Inspect new local manifest") }
        }
        try validate(info, name: Self.filename)
        databaseDevice = info.st_dev; databaseInode = info.st_ino
        try checkFiles()
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE) | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW
        let result = sqlite3_open_v2(directory.path + "/" + Self.filename, &database, flags, nil)
        do {
            guard result == SQLITE_OK else { throw failure("open", result) }
            sqlite3_busy_timeout(database, 250)
            sqlite3_limit(database, SQLITE_LIMIT_LENGTH, 1_048_576)
            try execute("PRAGMA trusted_schema=OFF")
            try execute("PRAGMA foreign_keys=ON")
            if !readOnly {
                // A single writer with short, batched transactions needs no WAL.
                // DELETE mode also avoids persistent shared-memory sidecars.
                try execute("PRAGMA journal_mode=DELETE")
                try execute("PRAGMA synchronous=FULL")
                try execute("PRAGMA fullfsync=ON")
            }
            if !exists {
                try transaction {
                    try execute("PRAGMA application_id=\(Self.applicationID)")
                    try execute("PRAGMA user_version=\(Self.schemaVersion)")
                    try execute("CREATE TABLE identity (singleton INTEGER PRIMARY KEY CHECK(singleton=1), store_id TEXT NOT NULL, camera_id TEXT NOT NULL)")
                    try execute("INSERT INTO identity VALUES (1, ?, ?)", [.text(identity.storeID), .text(identity.cameraID)])
                    try execute("""
                        CREATE TABLE recordings (
                            id TEXT PRIMARY KEY, filename TEXT NOT NULL UNIQUE, final_filename TEXT NOT NULL UNIQUE,
                            start_utc REAL NOT NULL, timescale INTEGER NOT NULL CHECK(timescale>0),
                            source_timestamp INTEGER NOT NULL, end_ticks INTEGER NOT NULL DEFAULT 0 CHECK(end_ticks>=0),
                            frames INTEGER NOT NULL DEFAULT 0 CHECK(frames>=0),
                            state TEXT NOT NULL CHECK(state IN ('recording','complete','interrupted')),
                            file_device INTEGER NOT NULL DEFAULT 0, file_inode INTEGER NOT NULL DEFAULT 0,
                            file_size INTEGER NOT NULL DEFAULT 0,
                            camera_utc REAL, received_utc REAL NOT NULL,
                            canonical_source TEXT NOT NULL CHECK(canonical_source IN ('camera','received')),
                            timing_json TEXT NOT NULL)
                        """)
                    try execute("CREATE INDEX recording_time ON recordings(start_utc)")
                }
                guard fsync(directory.fd) == 0 else { throw ServiceError.posix("Persist local manifest directory entry") }
            }
            guard try scalar("PRAGMA application_id") == Self.applicationID,
                  try scalar("PRAGMA user_version") == Self.schemaVersion else {
                throw ServiceError("Unsupported local manifest format; existing database and recordings were preserved.")
            }
            let identityStatement = try prepare("SELECT store_id, camera_id FROM identity WHERE singleton=1")
            defer { sqlite3_finalize(identityStatement) }
            guard sqlite3_step(identityStatement) == SQLITE_ROW,
                  string(identityStatement, 0) == identity.storeID,
                  string(identityStatement, 1) == identity.cameraID else {
                throw ServiceError("Local manifest belongs to a different camera or store; it was not changed.")
            }
            if !readOnly {
                // A previous process's accepted frames are not proof of a safely
                // finalized container. Never promote them by inspecting old media.
                try execute("UPDATE recordings SET state='interrupted' WHERE state='recording'")
            }
        } catch {
            if let database { sqlite3_close_v2(database) }; database = nil
            throw error
        }
    }
    deinit { if let database { sqlite3_close_v2(database) } }

    func begin(id: String, temporaryName: String, finalName: String, start: Date,
               timescale: UInt32, sourceTimestamp: UInt32, timing: ShardTimingMetadata) throws {
        guard UUID(uuidString: id) != nil, validLeaf(temporaryName), validLeaf(finalName),
              temporaryName == finalName + ".recording", timescale > 0,
              start.timeIntervalSince1970.isFinite else { throw ServiceError("Invalid local recording metadata.") }
        try timing.validate()
        guard timing.shardID == id, timing.storeID == identity.storeID, timing.cameraID == identity.cameraID,
              timing.timescale == timescale, timing.rtpTimestamp == sourceTimestamp,
              timing.time.canonicalUTC == start.timeIntervalSince1970 else { throw ServiceError("Shard timing does not match its manifest row.") }
        try transaction {
            try execute("INSERT INTO recordings (id,filename,final_filename,start_utc,timescale,source_timestamp,state,camera_utc,received_utc,canonical_source,timing_json) VALUES (?,?,?,?,?,?,'recording',?,?,?,?)",
                [.text(id), .text(temporaryName), .text(finalName), .real(start.timeIntervalSince1970),
                 .integer(Int64(timescale)), .integer(Int64(sourceTimestamp)),
                 timing.time.cameraUTC.map(Value.real) ?? .null, .real(timing.time.receivedUTC),
                 .text(timing.time.canonicalSource.rawValue), .text(try timing.json())])
        }
    }

    /// Batched accepted-frame progress; recording rows are NOT advertised as
    /// readable coverage. AVAssetWriter may still hold these samples in memory.
    func progress(id: String, endTicks: Int64, frames: Int64) throws {
        try transaction { try updateProgress(id: id, endTicks: endTicks, frames: frames) }
    }
    private func updateProgress(id: String, endTicks: Int64, frames: Int64) throws {
        guard endTicks > 0, frames > 0 else { throw ServiceError("Invalid local recording progress.") }
        // The provisional end can shrink when the last sample's estimated
        // duration changes on a variable-rate stream; accepted frame count cannot.
        try execute("UPDATE recordings SET end_ticks=?,frames=? WHERE id=? AND state='recording' AND frames<=?",
                    [.integer(endTicks), .integer(frames), .text(id), .integer(frames)])
        guard sqlite3_changes(database) == 1 else { throw ServiceError("Local manifest recording state changed; recording was not indexed.") }
    }
    func complete(id: String, filename: String, endTicks: Int64, frames: Int64) throws {
        guard validLeaf(filename) else { throw ServiceError("Invalid local recording filename.") }
        var info = stat()
        guard fstatat(directory.fd, filename, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw ServiceError.posix("Inspect finalized recording") }
        try validate(info, name: filename)
        guard info.st_size > 0 else { throw ServiceError("Finalized recording is empty.") }
        try transaction {
            try updateProgress(id: id, endTicks: endTicks, frames: frames)
            try execute("UPDATE recordings SET filename=final_filename,state='complete',file_device=?,file_inode=?,file_size=? WHERE id=? AND final_filename=?",
                        [.integer(Int64(info.st_dev)), .integer(Int64(bitPattern: info.st_ino)), .integer(info.st_size), .text(id), .text(filename)])
            guard sqlite3_changes(database) == 1 else { throw ServiceError("Finalized filename does not match the local manifest.") }
        }
    }
    func interrupt(id: String) throws {
        try transaction { try execute("UPDATE recordings SET state='interrupted' WHERE id=? AND state='recording'", [.text(id)]) }
    }
    /// Called only AFTER a successful retention unlink. A crash between the two
    /// leaves a stale row, which availability queries exclude by checking the file.
    func remove(filename: String) throws {
        try transaction { try execute("DELETE FROM recordings WHERE filename=? OR final_filename=?", [.text(filename), .text(filename)]) }
    }
    func recordings() throws -> [Recording] { try readRecordings() }
    private func readRecordings(from start: Double? = nil, to end: Double? = nil) throws -> [Recording] {
        try checkFiles()
        var sql = "SELECT id,filename,final_filename,start_utc,timescale,source_timestamp,end_ticks,frames,state,file_device,file_inode,file_size,timing_json FROM recordings"
        var values: [Value] = []
        if let start, let end {
            sql += " WHERE state='complete' AND start_utc<? AND start_utc+CAST(end_ticks AS REAL)/timescale>?"
            values = [.real(end), .real(start)]
        }
        let statement = try prepare(sql + " ORDER BY start_utc,id", values)
        defer { sqlite3_finalize(statement) }
        var result: [Recording] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW else { throw failure("read", code) }
            guard let state = State(rawValue: string(statement, 8)) else { throw ServiceError("Invalid local manifest recording state.") }
            let timing = try JSONDecoder().decode(ShardTimingMetadata.self, from: Data(string(statement, 12).utf8))
            try timing.validate()
            let row = Recording(id: string(statement, 0), filename: string(statement, 1), finalFilename: string(statement, 2),
                start: sqlite3_column_double(statement, 3), timescale: sqlite3_column_int64(statement, 4),
                sourceTimestamp: sqlite3_column_int64(statement, 5), endTicks: sqlite3_column_int64(statement, 6),
                frames: sqlite3_column_int64(statement, 7), state: state, device: sqlite3_column_int64(statement, 9),
                inode: sqlite3_column_int64(statement, 10), size: sqlite3_column_int64(statement, 11), timing: timing)
            guard UUID(uuidString: row.id) != nil, validLeaf(row.filename), validLeaf(row.finalFilename),
                  row.start.isFinite, row.timescale > 0, row.endTicks >= 0, row.frames >= 0,
                  row.end.isFinite else { throw ServiceError("Invalid local manifest row; no filenames or times were inferred.") }
            guard timing.shardID == row.id, timing.storeID == identity.storeID, timing.cameraID == identity.cameraID,
                  timing.time.canonicalUTC == row.start, Int64(timing.timescale) == row.timescale,
                  Int64(timing.rtpTimestamp) == row.sourceTimestamp else { throw ServiceError("Inconsistent local manifest timing.") }
            result.append(row)
        }
    }
    func coverage(from start: Double, to end: Double) throws -> Coverage {
        guard start.isFinite, end.isFinite, start < end else { throw ServiceError("A recording range must have a finite start before its end.") }
        let rows = try readRecordings(from: start, to: end).filter { row in
            guard row.state == .complete, row.end > start, row.start < end else { return false }
            var info = stat()
            guard fstatat(directory.fd, row.filename, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { return false }
                throw ServiceError.posix("Inspect indexed recording")
            }
            // A deleted/replaced/truncated file is not available just because its
            // old row remains. Never follow links or consult filesystem dates.
            return info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1 && info.st_uid == geteuid()
                && Int64(info.st_dev) == row.device && Int64(bitPattern: info.st_ino) == row.inode && info.st_size == row.size
        }
        var available: [Interval] = []
        for row in rows {
            let interval = Interval(start: max(start, row.start), end: min(end, row.end))
            if let last = available.last, interval.start <= last.end {
                available[available.count - 1] = Interval(start: last.start, end: max(last.end, interval.end))
            } else { available.append(interval) }
        }
        var gaps: [Interval] = [], cursor = start
        for interval in available {
            if cursor < interval.start { gaps.append(Interval(start: cursor, end: interval.start)) }
            cursor = interval.end
        }
        if cursor < end { gaps.append(Interval(start: cursor, end: end)) }
        return Coverage(recordings: rows, available: available, gaps: gaps)
    }

    private func validLeaf(_ name: String) -> Bool { LocalRecordingLayout.isShard(name) && !name.contains("/") && !name.contains("\0") }
    private func validate(_ info: stat, name: String) throws {
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_uid == geteuid(), info.st_mode & 0o777 == 0o600 else {
            throw ServiceError(.permission, "\(name) must be a regular, single-link, daemon-owned file with mode 0600 and inherited recording-directory access. It was not changed.")
        }
    }
    private func checkFiles() throws {
        try LocalRecordingLayout.verify(path: directory.path, fd: directory.fd, owner: owner)
        for suffix in ["", "-journal", "-wal", "-shm"] {
            var info = stat()
            if fstatat(directory.fd, Self.filename + suffix, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                if suffix != "", errno == ENOENT { continue }
                throw ServiceError("Local manifest disappeared or is inaccessible. Stop/restart the store to begin a new manifest; old video will not be backfilled.")
            }
            try validate(info, name: Self.filename + suffix)
            if suffix.isEmpty, info.st_dev != databaseDevice || info.st_ino != databaseInode {
                throw ServiceError("Local manifest was replaced while recording. Stop/restart the store; old video will not be backfilled.")
            }
        }
    }
    private func transaction(_ body: () throws -> Void) throws {
        guard !readOnly else { throw ServiceError("Local manifest connection is read-only.") }
        try checkFiles()
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func prepare(_ sql: String, _ values: [Value] = []) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else { throw failure("prepare", code) }
        do {
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1), result: Int32
                switch value {
                case .text(let value): result = sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                case .integer(let value): result = sqlite3_bind_int64(statement, index, value)
                case .real(let value): result = sqlite3_bind_double(statement, index, value)
                case .null: result = sqlite3_bind_null(statement, index)
                }
                guard result == SQLITE_OK else { throw failure("bind", result) }
            }
            return statement
        } catch { sqlite3_finalize(statement); throw error }
    }
    private func execute(_ sql: String, _ values: [Value] = []) throws {
        let statement = try prepare(sql, values); defer { sqlite3_finalize(statement) }
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW { code = sqlite3_step(statement) }
        guard code == SQLITE_DONE else { throw failure("write", code) }
    }
    private func scalar(_ sql: String) throws -> Int64 {
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        guard code == SQLITE_ROW else { throw failure("read header", code) }
        return sqlite3_column_int64(statement, 0)
    }
    private func string(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }
    private func failure(_ operation: String, _ code: Int32) -> ServiceError {
        ServiceError("Local manifest \(operation) failed (SQLite \(code)). Existing video/database files were preserved; no scan or backfill is attempted.")
    }
}

/// Store-side epoch boundary detection. Production uses the shared reception
/// mapping; the fallback also supports isolated stores and synthetic media tests.
struct LocalRecordingClock {
    private var fallback = RecordingTimeline()
    private var epoch: String?
    mutating func observe(_ media: EncodedMedia) throws -> (time: Date, discontinuity: Bool, timing: RecordingTime) {
        let timing = try media.time ?? fallback.observe(media)
        let discontinuity = epoch != nil && epoch != timing.epochID
        epoch = timing.epochID
        return (Date(timeIntervalSince1970: timing.canonicalUTC), discontinuity, timing)
    }
}
