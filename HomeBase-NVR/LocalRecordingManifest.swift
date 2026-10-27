import Foundation
import Darwin
import SQLite3

/// Prospective recording metadata, never reconstructed from filenames or file dates.
/// Owned by one local-store worker. Readers use separate read-only connections.
final class LocalRecordingManifest {
    static let filename = ".hbnvr-manifest.sqlite"
    static let schemaVersion: Int64 = 4
    private static let applicationID: Int64 = 0x48424e4d // HBNM
    enum State: String { case recording, complete, interrupted }
    /// Last recorded identity, independent of configuration and directory names.
    struct CameraMetadata: Equatable {
        let name: String
        let homebaseDeviceID: String?
        var updatedAt: Double = Date().timeIntervalSince1970
        func validate() throws {
            guard CameraConfiguration.printable(name, limit: 80),
                  !name.trimmingCharacters(in: .whitespaces).isEmpty, updatedAt.isFinite,
                  homebaseDeviceID.map({ CameraConfiguration.printable($0, limit: 512) && $0.hasPrefix("camera-") }) ?? true else {
                throw ServiceError("Invalid manifest camera metadata.")
            }
        }
    }
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
    /// Facts retained by the current writer, not reconstructed from files later.
    struct Seed {
        let temporaryName: String
        let finalName: String
        let timing: ShardTimingMetadata
        let camera: CameraMetadata
    }
    struct FileIdentity: Codable, Equatable {
        let device: Int64
        let inode: Int64
        let size: Int64
        init(_ info: stat) {
            device = Int64(info.st_dev); inode = Int64(bitPattern: info.st_ino); size = info.st_size
        }
    }
    struct Completion {
        let seed: Seed
        let endTicks: Int64
        let frames: Int64
        let file: FileIdentity
        var tags: VideoTagTimeline? = nil
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
    private let tagEvents: FootageTagEvents?
    private var databaseDevice: dev_t = 0
    private var databaseInode: ino_t = 0

    init(directory: LocalRecordingLayout.Directory, identity: LocalRecordingLayout.Identity,
         owner: uid_t, readOnly: Bool = false, recoverInterrupted: Bool = true, tagEvents: FootageTagEvents? = nil) throws {
        self.directory = directory; self.owner = owner; self.readOnly = readOnly
        self.identity = identity
        self.tagEvents = tagEvents
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
                            timing_json TEXT NOT NULL, tags_json TEXT)
                        """)
                    try execute("CREATE INDEX recording_time ON recordings(start_utc)")
                    try createCameraMetadata()
                }
                guard fsync(directory.fd) == 0 else { throw ServiceError.posix("Persist local manifest directory entry") }
            }
            let version = try scalar("PRAGMA user_version")
            guard try scalar("PRAGMA application_id") == Self.applicationID,
                  [1, 2, 3, Self.schemaVersion].contains(version) else {
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
                if version < Self.schemaVersion {
                    // Add identity only; never infer or backfill recording times.
                    try transaction {
                        if version == 1 { try createCameraMetadata() }
                        if version < 3 { try execute("ALTER TABLE recordings ADD COLUMN tags_json TEXT") }
                        try execute("PRAGMA user_version=\(Self.schemaVersion)")
                    }
                }
                try execute("CREATE TABLE IF NOT EXISTS tag_edits (shard_id TEXT PRIMARY KEY, pending_json TEXT NOT NULL)")
                try recoverTagEdits()
                // A previous process's accepted frames are not proof of a safely
                // finalized container. Never promote them by inspecting old media.
                if recoverInterrupted {
                    try execute("UPDATE recordings SET state='interrupted' WHERE state='recording'")
                }
            }
        } catch {
            if let database { sqlite3_close_v2(database) }; database = nil
            throw error
        }
    }
    deinit { if let database { sqlite3_close_v2(database) } }

    private func createCameraMetadata() throws {
        try execute("CREATE TABLE camera_metadata (singleton INTEGER PRIMARY KEY CHECK(singleton=1), name TEXT NOT NULL, homebase_device_id TEXT, updated_utc REAL NOT NULL)")
    }
    func cameraMetadata() throws -> CameraMetadata? {
        try checkFiles()
        guard try scalar("PRAGMA user_version") >= 2 else { return nil }
        let statement = try prepare("SELECT name,homebase_device_id,updated_utc FROM camera_metadata WHERE singleton=1")
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW else { throw failure("read camera identity", code) }
        let value = CameraMetadata(name: string(statement, 0),
            homebaseDeviceID: sqlite3_column_type(statement, 1) == SQLITE_NULL ? nil : string(statement, 1),
            updatedAt: sqlite3_column_double(statement, 2))
        try value.validate(); return value
    }
    func hasIndexedRecordings() throws -> Bool {
        try checkFiles()
        return try scalar("SELECT EXISTS(SELECT 1 FROM recordings LIMIT 1)") != 0
    }

    func begin(id: String, temporaryName: String, finalName: String, start: Date,
               timescale: UInt32, sourceTimestamp: UInt32, timing: ShardTimingMetadata,
               cameraMetadata: CameraMetadata? = nil) throws {
        guard UUID(uuidString: id) != nil, validLeaf(temporaryName), validLeaf(finalName),
              temporaryName == finalName + ".recording", timescale > 0,
              start.timeIntervalSince1970.isFinite else { throw ServiceError("Invalid local recording metadata.") }
        try timing.validate()
        try cameraMetadata?.validate()
        guard timing.shardID == id, timing.storeID == identity.storeID, timing.cameraID == identity.cameraID,
              timing.timescale == timescale, timing.rtpTimestamp == sourceTimestamp,
              timing.time.canonicalUTC == start.timeIntervalSince1970 else { throw ServiceError("Shard timing does not match its manifest row.") }
        try transaction {
            if let cameraMetadata {
                try execute("""
                    INSERT INTO camera_metadata VALUES (1,?,?,?) ON CONFLICT(singleton) DO UPDATE SET
                    name=excluded.name,homebase_device_id=excluded.homebase_device_id,updated_utc=excluded.updated_utc
                    WHERE name!=excluded.name OR homebase_device_id IS NOT excluded.homebase_device_id
                    """, [.text(cameraMetadata.name), cameraMetadata.homebaseDeviceID.map(Value.text) ?? .null,
                          .real(cameraMetadata.updatedAt)])
            }
            try execute("INSERT INTO recordings (id,filename,final_filename,start_utc,timescale,source_timestamp,state,camera_utc,received_utc,canonical_source,timing_json) VALUES (?,?,?,?,?,?,'recording',?,?,?,?)",
                [.text(id), .text(temporaryName), .text(finalName), .real(start.timeIntervalSince1970),
                 .integer(Int64(timescale)), .integer(Int64(sourceTimestamp)),
                 timing.time.cameraUTC.map(Value.real) ?? .null, .real(timing.time.receivedUTC),
                 .text(timing.time.canonicalSource.rawValue), .text(try timing.json())])
        }
    }

    /// Batched accepted-frame progress; recording rows are NOT advertised as
    /// readable coverage. AVAssetWriter may still hold these samples in memory.
    func progress(id: String, endTicks: Int64, frames: Int64, tags: VideoTagTimeline? = nil) throws {
        try transaction {
            try updateProgress(id: id, endTicks: endTicks, frames: frames)
            try updateTags(id: id, tags: tags)
        }
    }
    private func updateTags(id: String, tags: VideoTagTimeline?) throws {
        guard let tags else { return }
        try tags.validate()
        try execute("UPDATE recordings SET tags_json=? WHERE id=?",
            [.text(String(decoding: try JSONEncoder().encode(tags), as: UTF8.self)), .text(id)])
    }
    private func updateProgress(id: String, endTicks: Int64, frames: Int64) throws {
        guard endTicks > 0, frames > 0 else { throw ServiceError("Invalid local recording progress.") }
        // The provisional end can shrink when the last sample's estimated
        // duration changes on a variable-rate stream; accepted frame count cannot.
        try execute("UPDATE recordings SET end_ticks=?,frames=? WHERE id=? AND state='recording' AND frames<=?",
                    [.integer(endTicks), .integer(frames), .text(id), .integer(frames)])
        guard sqlite3_changes(database) == 1 else { throw ServiceError("Local manifest recording state changed; recording was not indexed.") }
    }
    func complete(id: String, filename: String, endTicks: Int64, frames: Int64, tags: VideoTagTimeline? = nil) throws {
        guard validLeaf(filename) else { throw ServiceError("Invalid local recording filename.") }
        var info = stat()
        guard fstatat(directory.fd, filename, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw ServiceError.posix("Inspect finalized recording") }
        try validate(info, name: filename)
        guard info.st_size > 0 else { throw ServiceError("Finalized recording is empty.") }
        try transaction {
            try updateProgress(id: id, endTicks: endTicks, frames: frames)
            try updateTags(id: id, tags: tags)
            try execute("UPDATE recordings SET filename=final_filename,state='complete',file_device=?,file_inode=?,file_size=? WHERE id=? AND final_filename=?",
                        [.integer(Int64(info.st_dev)), .integer(Int64(bitPattern: info.st_ino)), .integer(info.st_size), .text(id), .text(filename)])
            guard sqlite3_changes(database) == 1 else { throw ServiceError("Finalized filename does not match the local manifest.") }
        }
    }
    func interrupt(id: String) throws {
        try transaction { try execute("UPDATE recordings SET state='interrupted' WHERE id=? AND state='recording'", [.text(id)]) }
    }
    /// Idempotent retry of an in-process writer's confirmed finalization. A fresh
    /// connection must not mark another, currently recording shard interrupted.
    /// Never overwrite conflicting rows or adopt a replaced/truncated video.
    func completeRetained(_ value: Completion) throws {
        let seed = value.seed, timing = seed.timing
        try timing.validate(); try seed.camera.validate()
        guard validLeaf(seed.finalName), seed.temporaryName == seed.finalName + ".recording",
              timing.storeID == identity.storeID, timing.cameraID == identity.cameraID,
              value.endTicks > 0, value.frames > 0, value.file.size > 0 else {
            throw ServiceError("Invalid retained manifest completion.")
        }
        var info = stat()
        guard fstatat(directory.fd, seed.finalName, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw ServiceError.posix("Inspect retained finalized recording")
        }
        try validate(info, name: seed.finalName)
        guard FileIdentity(info) == value.file else {
            throw ServiceError("Finalized recording changed before manifest retry; file and index were preserved.")
        }
        try transaction {
            var existing: Recording?
            try visitRecordings(Self.recordingSelect + " WHERE id=?", [.text(timing.shardID)], limit: 1) {
                existing = $0; return true
            }
            if let row = existing {
                guard row.finalFilename == seed.finalName, row.timing == timing,
                      [seed.temporaryName, seed.finalName].contains(row.filename), row.frames <= value.frames else {
                    throw ServiceError("Manifest retry conflicts with an existing recording; index was preserved.")
                }
                if row.state == .complete {
                    guard row.filename == seed.finalName, row.frames == value.frames, row.endTicks == value.endTicks,
                          row.device == value.file.device, row.inode == value.file.inode, row.size == value.file.size else {
                        throw ServiceError("Manifest retry conflicts with a completed recording; index was preserved.")
                    }
                    // The earlier commit succeeded, including its tag transaction.
                    if let tags = value.tags {
                        let statement = try prepare("SELECT tags_json FROM recordings WHERE id=?", [.text(timing.shardID)])
                        defer { sqlite3_finalize(statement) }
                        guard sqlite3_step(statement) == SQLITE_ROW,
                              let old = try? JSONDecoder().decode(VideoTagTimeline.self, from: Data(string(statement, 0).utf8)), old == tags else {
                            throw ServiceError("Manifest retry conflicts with completed tags; index was preserved.")
                        }
                    }
                    return
                }
                try execute("UPDATE recordings SET filename=final_filename,state='complete',end_ticks=?,frames=?,file_device=?,file_inode=?,file_size=? WHERE id=?",
                    [.integer(value.endTicks), .integer(value.frames), .integer(value.file.device),
                     .integer(value.file.inode), .integer(value.file.size), .text(timing.shardID)])
            } else {
                try execute("""
                    INSERT INTO recordings (id,filename,final_filename,start_utc,timescale,source_timestamp,
                        end_ticks,frames,state,file_device,file_inode,file_size,camera_utc,received_utc,canonical_source,timing_json)
                    VALUES (?,?,?,?,?,?,?,?,'complete',?,?,?,?,?,?,?)
                    """, [.text(timing.shardID), .text(seed.finalName), .text(seed.finalName), .real(timing.time.canonicalUTC),
                          .integer(Int64(timing.timescale)), .integer(Int64(timing.rtpTimestamp)),
                          .integer(value.endTicks), .integer(value.frames), .integer(value.file.device),
                          .integer(value.file.inode), .integer(value.file.size), timing.time.cameraUTC.map(Value.real) ?? .null,
                          .real(timing.time.receivedUTC), .text(timing.time.canonicalSource.rawValue), .text(try timing.json())])
            }
            try updateTags(id: timing.shardID, tags: value.tags)
            // Replaying an older shard must not undo a newer camera rename/binding.
            try execute("""
                INSERT INTO camera_metadata VALUES (1,?,?,?) ON CONFLICT(singleton) DO UPDATE SET
                name=excluded.name,homebase_device_id=excluded.homebase_device_id,updated_utc=excluded.updated_utc
                WHERE excluded.updated_utc>=camera_metadata.updated_utc AND
                    (name!=excluded.name OR homebase_device_id IS NOT excluded.homebase_device_id)
                """, [.text(seed.camera.name), seed.camera.homebaseDeviceID.map(Value.text) ?? .null, .real(seed.camera.updatedAt)])
        }
    }
    /// Called only AFTER a successful retention unlink. A crash between the two
    /// leaves a stale row, which availability queries exclude by checking the file.
    func remove(filename: String) throws {
        var removed: [String] = []
        try transaction {
            let values: [Value] = [.text(filename), .text(filename)]
            let statement = try prepare("SELECT id FROM recordings WHERE filename=? OR final_filename=? LIMIT 129", values)
            do {
                defer { sqlite3_finalize(statement) }
                while true {
                    let code = sqlite3_step(statement)
                    if code == SQLITE_DONE { break }
                    guard code == SQLITE_ROW else { throw failure("read expired tag metadata", code) }
                    guard removed.count < 128 else { throw ServiceError("Too many recording rows share an expired filename.") }
                    removed.append(string(statement, 0))
                }
            }
            try execute("DELETE FROM recordings WHERE filename=? OR final_filename=?", values)
        }
        // Retention can remove a shard whose tag publication previously failed.
        // Once the manifest deletion commits, its before-image must disappear
        // too; consumers should now observe the absent source row.
        for id in removed { tagEvents?.finishLocalEdit(storeID: identity.storeID, shardID: id) }
    }
    func recordings() throws -> [Recording] { try readRecordings() }
    func historicalRecordings(id: String? = nil, filename: String? = nil, range: MediaRange? = nil,
                              timeline: MediaTimeline = .canonical) throws -> [Recording] {
        var predicates: [String] = [], values: [Value] = []
        if let id { predicates.append("id=?"); values.append(.text(id)) }
        if let filename { predicates.append("filename=?"); values.append(.text(filename)) }
        if let range {
            predicates.append("\(timeline.column) IS NOT NULL AND \(timeline.column)<? AND (state='recording' OR \(timeline.column)+CAST(end_ticks AS REAL)/timescale>?)")
            values += [.real(range.end), .real(range.start)]
        }
        var rows: [Recording] = []
        try visitRecordings(Self.recordingSelect + (predicates.isEmpty ? "" : " WHERE " + predicates.joined(separator: " AND ")),
                            values, limit: 129) { rows.append($0); return true }
        return rows
    }
    func historicalTags(id: String) throws -> VideoTagTimeline? {
        try checkFiles()
        guard try scalar("PRAGMA user_version") >= 3 else { return nil }
        let statement = try prepare("SELECT tags_json FROM recordings WHERE id=?", [.text(id)])
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw ServiceError("Recording no longer exists in manifest.") }
        if sqlite3_column_type(statement, 0) == SQLITE_NULL { return nil }
        let value = try JSONDecoder().decode(VideoTagTimeline.self, from: Data(string(statement, 0).utf8))
        try value.validate(); return value
    }
    /// Client tag reads use a single SQLite snapshot of the metadata, including
    /// the accepted-frame checkpoint of an active recording. They neither wait
    /// for the recording worker nor depend on the media file's rename state.
    func localTagSnapshots(range: MediaRange) throws -> [LocalTagReadSnapshot] {
        guard range.start.isFinite, range.end.isFinite, range.start < range.end else {
            throw ServiceError("A tag range must have a finite start before its end.")
        }
        try checkFiles()
        let column = try scalar("PRAGMA user_version") >= 3 ? "tags_json" : "NULL"
        let statement = try prepare("""
            SELECT id,timing_json,start_utc,timescale,end_ticks,source_timestamp,\(column)
            FROM recordings WHERE state IN ('complete','recording') AND end_ticks>0
                AND start_utc<? AND start_utc+CAST(end_ticks AS REAL)/timescale>?
            ORDER BY start_utc,id LIMIT 129
            """, [.real(range.end), .real(range.start)])
        defer { sqlite3_finalize(statement) }
        var result: [LocalTagReadSnapshot] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW else { throw failure("read tag metadata", code) }
            guard result.count < 128 else { throw ServiceError(.invalidMessage, "Too many recording shards to inspect safely.") }
            let timing = try JSONDecoder().decode(ShardTimingMetadata.self, from: Data(string(statement, 1).utf8))
            try timing.validate()
            let start = sqlite3_column_double(statement, 2), scale = sqlite3_column_int64(statement, 3)
            let end = sqlite3_column_int64(statement, 4)
            guard timing.shardID == string(statement, 0), timing.storeID == identity.storeID,
                  timing.cameraID == identity.cameraID, timing.time.canonicalUTC == start,
                  Int64(timing.timescale) == scale, Int64(timing.rtpTimestamp) == sqlite3_column_int64(statement, 5),
                  start.isFinite, scale > 0, end > 0, (start + Double(end) / Double(scale)).isFinite else {
                throw ServiceError("Inconsistent local manifest timing.")
            }
            let tags: VideoTagTimeline?
            if sqlite3_column_type(statement, 6) == SQLITE_NULL { tags = nil }
            else {
                guard sqlite3_column_bytes(statement, 6) <= VideoTagTimeline.maximumBytes else { throw ServiceError("Oversized playback tags.") }
                tags = try JSONDecoder().decode(VideoTagTimeline.self, from: Data(string(statement, 6).utf8))
                try tags?.validate()
            }
            result.append(.init(timing: timing, endTicks: end, tags: tags))
        }
    }
    /// A single SQLite snapshot couples the tag value to the exact finalized
    /// inode already pinned by the reader. A concurrent replacement is retried,
    /// never paired with tags from another revision. Legacy rows mean no values.
    func playbackTags(matching row: Recording) throws -> VideoTagTimeline? {
        try checkFiles()
        let column = try scalar("PRAGMA user_version") >= 3 ? "tags_json" : "NULL"
        let statement = try prepare("SELECT file_device,file_inode,file_size,state,\(column) FROM recordings WHERE id=?", [.text(row.id)])
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        guard code == SQLITE_ROW else {
            if code != SQLITE_DONE { throw failure("read playback tags", code) }
            throw ServiceError(.unavailable, "Recording disappeared before its tags were captured.")
        }
        guard row.state == .complete, string(statement, 3) == State.complete.rawValue,
              row.device == sqlite3_column_int64(statement, 0), row.inode == sqlite3_column_int64(statement, 1),
              row.size == sqlite3_column_int64(statement, 2) else {
            throw ServiceError(.unavailable, "Recording tag revision changed; retry the range.")
        }
        if sqlite3_column_type(statement, 4) == SQLITE_NULL { return nil }
        guard sqlite3_column_bytes(statement, 4) <= VideoTagTimeline.maximumBytes else { throw ServiceError("Oversized playback tags.") }
        let value = try JSONDecoder().decode(VideoTagTimeline.self, from: Data(string(statement, 4).utf8))
        try value.validate(); return value
    }
    /// Commit the intent before any rename. Recovery handles crashes on either
    /// side of rename without ever adopting a replaced or unrelated file.
    func commitTagEdits(_ pending: [LocalTagFile.Pending], revisions: [String: String]) throws {
        try transaction {
            for edit in pending {
                guard let row = try historicalRecordings(id: edit.shardID).first, row.state == .complete,
                      row.filename == edit.filename,
                      row.device == edit.oldFile.device, row.inode == edit.oldFile.inode, row.size == edit.oldFile.size,
                      try HistoricalTags.revision(historicalTags(id: edit.shardID)) == revisions[edit.shardID] else {
                    throw ServiceError("Recording or tags changed before commit; retry with a fresh revision.")
                }
                try execute("INSERT INTO tag_edits VALUES (?,?)", [.text(edit.shardID), .text(String(decoding: try JSONEncoder().encode(edit), as: UTF8.self))])
            }
        }
        try recoverTagEdits()
    }
    func recoverTagEdits() throws {
        guard !readOnly else { return }
        try checkFiles()
        let statement = try prepare("SELECT pending_json FROM tag_edits LIMIT 129")
        var edits: [LocalTagFile.Pending] = []
        do {
            defer { sqlite3_finalize(statement) }
            var code = sqlite3_step(statement)
            while code == SQLITE_ROW {
                edits.append(try JSONDecoder().decode(LocalTagFile.Pending.self, from: Data(string(statement, 0).utf8)))
                code = sqlite3_step(statement)
            }
            guard code == SQLITE_DONE else { throw failure("read pending tags", code) }
        }
        guard edits.count <= 128 else { throw ServiceError("Too many pending local tag edits; files preserved.") }
        for edit in edits {
            try checkFiles()
            try edit.tags.validate()
            guard validLeaf(edit.filename), edit.stagedName.range(of: "^\\.hbnvr-tags-[A-Fa-f0-9-]{36}-[A-Fa-f0-9-]{36}-[A-Fa-f0-9-]{36}\\.tmp$", options: .regularExpression) != nil,
                  UUID(uuidString: edit.shardID) != nil else { throw ServiceError("Invalid pending tag edit.") }
            guard let row = try historicalRecordings(id: edit.shardID).first, row.state == .complete,
                  row.filename == edit.filename,
                  (row.device == edit.oldFile.device && row.inode == edit.oldFile.inode && row.size == edit.oldFile.size)
                    || (row.device == edit.newFile.device && row.inode == edit.newFile.inode && row.size == edit.newFile.size) else {
                throw ServiceError("Pending tag edit manifest identity changed; files preserved.")
            }
            try LocalRecordingLayout.verify(path: directory.path, fd: directory.fd, owner: owner)
            var current = stat(), staged = stat()
            guard fstatat(directory.fd, edit.filename, &current, AT_SYMLINK_NOFOLLOW) == 0 else { throw ServiceError("Pending tag edit recording is missing; files preserved.") }
            // Recovery retries preserve an already-installed before-image. The
            // layer survives a failed rename/fsync/transaction until this shard
            // has reached the durable manifest state below.
            if let tagEvents {
                let previous = try historicalTags(id: row.id)
                tagEvents.beginLocalEdit(storeID: identity.storeID,
                    snapshot: .init(timing: row.timing, endTicks: row.endTicks, tags: previous))
            }
            if !LocalTagFile.matches(current, edit.newFile) {
                guard LocalTagFile.matches(current, edit.oldFile),
                      fstatat(directory.fd, edit.stagedName, &staged, AT_SYMLINK_NOFOLLOW) == 0,
                      LocalTagFile.matches(staged, edit.newFile) else { throw ServiceError("Pending tag edit file identity changed; files preserved.") }
                guard renameat(directory.fd, edit.stagedName, directory.fd, edit.filename) == 0 else { throw ServiceError.posix("Publish edited recording") }
            }
            guard fsync(directory.fd) == 0 else { throw ServiceError.posix("Persist edited recording") }
            try transaction {
                try execute("UPDATE recordings SET file_device=?,file_inode=?,file_size=?,tags_json=? WHERE id=? AND state='complete' AND filename=?",
                    [.integer(edit.newFile.device), .integer(edit.newFile.inode), .integer(edit.newFile.size),
                     .text(String(decoding: try JSONEncoder().encode(edit.tags), as: UTF8.self)), .text(edit.shardID), .text(edit.filename)])
                guard sqlite3_changes(database) == 1 else { throw ServiceError("Pending tag edit lost its manifest row; file preserved.") }
                try execute("DELETE FROM tag_edits WHERE shard_id=?", [.text(edit.shardID)])
            }
            tagEvents?.finishLocalEdit(storeID: identity.storeID, shardID: row.id)
        }
    }
    func playbackRecordings(from start: Double, to end: Double, timeline: MediaTimeline) throws -> [Recording] {
        try readRecordings(from: start, to: end, timeline: timeline, limit: MediaLimits.candidates)
    }
    /// Walk nearest-first without loading the archive or guessing from filenames.
    /// Continue past expired/replaced files. Hitting a bound is an error, never
    /// evidence that we reached the beginning or end of retained history.
    func visitNeighbors(at point: Double, previous: Bool, timeline: MediaTimeline, work: MediaWork,
                        visit: (Recording) throws -> Bool) throws {
        let column = timeline.column
        let end = "\(column)+CAST(end_ticks AS REAL)/timescale"
        let predicate = previous ? "\(column)<?" : "(state='recording' OR \(end)>?)"
        // Active rows' checkpoint durations are not their readable frontier.
        // Inspect them first; the provider compares actual ranges with complete rows.
        let order = previous ? "MIN(\(end),?) DESC,\(column) DESC,id" : "\(column),id"
        let sql = Self.recordingSelect + " WHERE state IN ('complete','recording') AND \(column) IS NOT NULL AND \(predicate) ORDER BY (state='recording') DESC,\(order)"
        try visitRecordings(sql, [.real(point)] + (previous ? [.real(point)] : []), limit: MediaLimits.candidates, work: work, visit: visit)
    }
    private static let recordingSelect = "SELECT id,filename,final_filename,start_utc,timescale,source_timestamp,end_ticks,frames,state,file_device,file_inode,file_size,timing_json FROM recordings"
    private func readRecordings(from start: Double? = nil, to end: Double? = nil,
                               timeline: MediaTimeline = .canonical, limit: Int? = nil) throws -> [Recording] {
        var sql = Self.recordingSelect
        var values: [Value] = []
        if let start, let end {
            // Active rows identify a writer, NOT readable coverage. Their
            // accepted-frame checkpoint may lag or lead actual on-disk media;
            // the media provider determines the readable prefix independently.
            sql += " WHERE state IN ('complete','recording') AND \(timeline.column)<? AND (state='recording' OR \(timeline.column)+CAST(end_ticks AS REAL)/timescale>?)"
            values = [.real(end), .real(start)]
        }
        var result: [Recording] = []
        try visitRecordings(sql + " ORDER BY \(timeline.column),id", values, limit: limit) { row in
            result.append(row); return true
        }
        return result
    }
    private func visitRecordings(_ sql: String, _ values: [Value], limit: Int?, work: MediaWork? = nil,
                                 visit: (Recording) throws -> Bool) throws {
        try checkFiles()
        let statement = try prepare(sql + (limit.map { " LIMIT \($0 + 1)" } ?? ""), values)
        defer { sqlite3_finalize(statement) }
        var count = 0
        while true {
            try work?.check()
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return }
            guard code == SQLITE_ROW else { throw failure("read", code) }
            count += 1
            if let limit, count > limit { throw ServiceError(.invalidMessage, "Too many recording shards to inspect safely.") }
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
            if try !visit(row) { return }
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
                throw ServiceError("Local manifest disappeared or is inaccessible; the writer must reopen it before indexing new shards. Old video will not be backfilled.")
            }
            try validate(info, name: Self.filename + suffix)
            if suffix.isEmpty, info.st_dev != databaseDevice || info.st_ino != databaseInode {
                throw ServiceError("Local manifest was replaced while recording; the writer must reopen and validate it before indexing new shards. Old video will not be backfilled.")
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
        guard code == SQLITE_DONE else {
            // Only the operation verb, never SQL values or the full statement.
            throw failure(String(sql.prefix { !$0.isWhitespace }).lowercased(), code)
        }
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
        // Capture before rollback/finalize can replace the connection's diagnostic.
        // Codes/strerror contain no SQL, credentials, or recording metadata.
        let extended = sqlite3_extended_errcode(database), system = sqlite3_system_errno(database)
        let detail = system == 0 ? "" : "; OS \(system): \(String(cString: strerror(system)))"
        return ServiceError("Local manifest \(operation) failed (SQLite \(code), extended \(extended)\(detail)). Existing video/database files were preserved; no scan or backfill is attempted.")
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
