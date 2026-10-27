import XCTest
import Foundation
import Darwin

final class FootageTagWatchTests: XCTestCase {
    private func sockets() throws -> [Int32] {
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw ServiceError.posix("Test socket pair") }
        try SocketIO.configure(pair[0]); try SocketIO.configure(pair[1]); return pair
    }
    private func read(_ fd: Int32) throws -> FootageTagChange {
        let data = try SocketIO.read(fd: fd, deadline: ProcessInfo.processInfo.systemUptime + 3)
        return try XCTUnwrap(JSONDecoder().decode(Reply.self, from: data).tagChange)
    }
    private func beforeImage(storeID: String = UUID().uuidString) -> LocalTagReadSnapshot {
        let sample = EncodedMedia(codec: "H264", clockRate: 90_000, parameterSets: [],
            frame: .init(payload: Data(), timestamp: 0, keyFrame: true), receivedAt: Date(timeIntervalSince1970: 100),
            receivedUptime: 100, cameraUTC: 100, ssrc: 42)
        let timing = ShardTimingMetadata(storeID: storeID, cameraID: UUID().uuidString, media: sample,
            time: .init(cameraUTC: 100, receivedUTC: 100, canonicalUTC: 100, canonicalSource: .camera, epochID: UUID().uuidString))
        return .init(timing: timing, endTicks: 90000, tags: nil)
    }
    func testReadCompletesOnOldLayerDuringWriteAndNotificationObservesDroppedLayer() throws {
        let events = FootageTagEvents(instanceID: UUID().uuidString), old = beforeImage(), pair = try sockets()
        defer { events.stop(); close(pair[0]) }
        try events.subscribe(pair[1], authorize: { true }); _ = try read(pair[0])
        events.beginLocalEdit(storeID: old.timing.storeID, snapshot: old)
        let (token, count) = try events.readLocalSnapshot(storeID: old.timing.storeID,
            work: MediaWork(deadline: ProcessInfo.processInfo.systemUptime + 0.2)) { layer in
            XCTAssertEqual(layer[old.timing.shardID]?.endTicks, old.endTicks)
            XCTAssertNil(layer[old.timing.shardID]?.tags, "Unknown is a full before-image, not an absent cache entry")
            return layer.count
        }
        XCTAssertEqual(count, 1); XCTAssertEqual(token.revision, 0)
        // No event is sent while the old view is authoritative.
        var pending = pollfd(fd: pair[0], events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&pending, 1, 0), 0)
        events.finishLocalEdit(storeID: old.timing.storeID, shardID: old.timing.shardID, endTicks: 180000)
        let event = try read(pair[0])
        let (committed, empty) = try events.readLocalSnapshot(storeID: old.timing.storeID, work: MediaWork()) { $0.isEmpty }
        XCTAssertTrue(empty); XCTAssertEqual(event.revision, committed.revision); XCTAssertEqual(committed.revision, 1)
        XCTAssertEqual(event.ranges, [.init(cameraID: old.timing.cameraID, epochID: old.timing.time.epochID, start: 100, end: 102)])
        XCTAssertThrowsError(try events.validate(token))
        events.finishLocalEdit(storeID: old.timing.storeID, shardID: old.timing.shardID)
        XCTAssertEqual(try events.snapshotToken().revision, 1, "Recovery completion is idempotent")
    }
    func testRecoveryDoesNotReplaceBeforeImageWithPartialNewMetadata() throws {
        let events = FootageTagEvents(instanceID: UUID().uuidString), old = beforeImage()
        defer { events.stop() }
        events.beginLocalEdit(storeID: old.timing.storeID, snapshot: old)
        var newer = VideoTagTimeline.unknown
        try newer.apply(.init(start: 0, end: 90000, key: "privacy", value: "hidden"))
        events.beginLocalEdit(storeID: old.timing.storeID,
            snapshot: .init(timing: old.timing, endTicks: old.endTicks, tags: newer))
        let (_, tags) = try events.readLocalSnapshot(storeID: old.timing.storeID, work: MediaWork()) { $0[old.timing.shardID]?.tags }
        XCTAssertNil(tags)
    }
    func testSnapshotRetriesValuesAndErrorsOnlyAcrossLayerChanges() throws {
        for failFirst in [false, true] {
            let events = FootageTagEvents(instanceID: UUID().uuidString), old = beforeImage()
            defer { events.stop() }
            var reads = 0
            let (token, count) = try events.readLocalSnapshot(storeID: old.timing.storeID, work: MediaWork()) { layer in
                reads += 1
                if reads == 1 {
                    events.beginLocalEdit(storeID: old.timing.storeID, snapshot: old)
                    if failFirst { throw ServiceError("Mixed metadata") }
                }
                return layer.count
            }
            XCTAssertEqual(reads, 2); XCTAssertEqual(count, 1); XCTAssertEqual(token.revision, 0)
        }
    }
    func testSnapshotStableErrorsDeadlineCancellationPeerClosureAndStop() throws {
        let events = FootageTagEvents(instanceID: UUID().uuidString), old = beforeImage()
        defer { events.stop() }
        var reads = 0
        XCTAssertThrowsError(try events.readLocalSnapshot(storeID: old.timing.storeID, work: MediaWork()) { _ -> Int in
            reads += 1; throw ServiceError(.permission, "Access denied")
        }) { XCTAssertEqual(($0 as? ServiceError)?.code, .permission) }
        XCTAssertEqual(reads, 1)
        XCTAssertThrowsError(try events.readLocalSnapshot(storeID: old.timing.storeID,
            work: MediaWork(deadline: ProcessInfo.processInfo.systemUptime + 0.03)) { _ in
            events.beginLocalEdit(storeID: old.timing.storeID, snapshot: old)
            events.finishLocalEdit(storeID: old.timing.storeID, shardID: old.timing.shardID)
        }) { XCTAssertEqual(($0 as? ServiceError)?.code, .timeout) }
        let cancellation = Cancellation(); cancellation.stop()
        XCTAssertThrowsError(try events.readLocalSnapshot(storeID: old.timing.storeID, work: MediaWork(cancellation: cancellation)) { _ in XCTFail("Canceled read ran") })
        let pair = try sockets(); close(pair[0]); defer { close(pair[1]) }
        XCTAssertThrowsError(try events.readLocalSnapshot(storeID: old.timing.storeID, work: MediaWork(peer: pair[1])) { _ in XCTFail("Closed peer read ran") })
        events.stop()
        XCTAssertThrowsError(try events.readLocalSnapshot(storeID: old.timing.storeID, work: MediaWork()) { _ in XCTFail("Stopped read ran") })
    }
    func testSourceResetRejectsInFlightConfigurationAndRecoversFromNoLocalStore() throws {
        let events = FootageTagEvents(instanceID: UUID().uuidString), pair = try sockets()
        defer { events.stop(); close(pair[0]) }
        try events.subscribe(pair[1], authorize: { true }); _ = try read(pair[0])
        events.selectLocalStore([])
        let config = try StoreTests().config("/private/tmp/unused-tag-source")
        events.selectLocalStore([config])
        XCTAssertTrue(try read(pair[0]).reset)
        let stale = beforeImage(storeID: config.id)
        events.beginLocalEdit(storeID: config.id, snapshot: stale)
        var replacement = config; replacement.directory += "-replacement"
        XCTAssertThrowsError(try events.readLocalSnapshot(storeID: config.id, configuration: config, work: MediaWork()) { _ in
            events.selectLocalStore([replacement])
        }) { XCTAssertEqual(($0 as? ServiceError)?.code, .unavailable) }
        XCTAssertTrue(try read(pair[0]).reset)
        let (_, empty) = try events.readLocalSnapshot(storeID: config.id, configuration: replacement, work: MediaWork()) { $0.isEmpty }
        XCTAssertTrue(empty, "A failed edit in the old directory cannot shadow the replacement store")
        events.selectLocalStore([])
        XCTAssertTrue(try read(pair[0]).reset)
        XCTAssertThrowsError(try events.readLocalSnapshot(storeID: config.id, work: MediaWork()) { _ in XCTFail("Removed source read ran") })
    }
    func testSubscriberLimitIsBoundedAndRangesCoalesce() throws {
        let events = FootageTagEvents(instanceID: UUID().uuidString)
        defer { events.stop() }
        var clients: [Int32] = []
        defer { clients.forEach { close($0) } }
        for _ in 0..<8 {
            let pair = try sockets(); clients.append(pair[0]); try events.subscribe(pair[1], authorize: { true }); _ = try read(pair[0])
        }
        let extra = try sockets(); defer { close(extra[0]); close(extra[1]) }
        XCTAssertThrowsError(try events.subscribe(extra[1], authorize: { true }))
        XCTAssertEqual(FootageTagEvents.coalesced([.init(cameraID: "camera", epochID: "epoch", start: 10, end: 20),
            .init(cameraID: "camera", epochID: "epoch", start: 15, end: 30)]),
            [.init(cameraID: "camera", epochID: "epoch", start: 10, end: 30)])
    }
    func testSnapshotReadAdmissionIsEightWorkersWithoutQueue() throws {
        let readers = FootageTagReads(), gate = DispatchSemaphore(value: 0)
        defer { readers.stop() }
        var clients: [Int32] = []
        defer { clients.forEach { close($0) } }
        for _ in 0..<8 {
            let pair = try sockets(); clients.append(pair[0])
            try readers.open(pair[1], authorize: { true }) { _ in
                _ = gate.wait(timeout: .now() + 3)
                return Reply(protocolVersion: 1, status: nil, error: nil, code: nil)
            }
        }
        let extra = try sockets(); defer { close(extra[0]); close(extra[1]) }
        XCTAssertThrowsError(try readers.open(extra[1], authorize: { true }) { _ in XCTFail("Rejected work ran"); return Reply(protocolVersion: 1, status: nil, error: nil, code: nil) })
        for _ in 0..<8 { gate.signal() }
        for client in clients {
            let reply = try JSONDecoder().decode(Reply.self, from: SocketIO.read(fd: client, deadline: ProcessInfo.processInfo.systemUptime + 3))
            XCTAssertNil(reply.error)
        }
    }
    func testQueryValidationAndWireStorageSelectorsAreRejected() throws {
        let camera = UUID().uuidString
        let valid = FootageTagQuery(cameraID: camera, ranges: [.init(start: 100, end: 110)], keys: ["privacy", "arbitrary.opaque"])
        try valid.validate()
        try FootageTagQuery(cameraID: camera, ranges: [.init(start: 100, end: 110, epochID: "legacy-camera-epoch")],
            keys: ["opaque\nkey"]).validate()
        for epoch in ["", "invalid\nepoch", String(repeating: "e", count: 129)] {
            XCTAssertThrowsError(try FootageTagQuery(cameraID: camera,
                ranges: [.init(start: 100, end: 110, epochID: epoch)], keys: ["privacy"]).validate())
        }
        for query in [
            FootageTagQuery(cameraID: camera, ranges: [], keys: ["privacy"]),
            FootageTagQuery(cameraID: camera, ranges: [.init(start: 100, end: 401)], keys: ["privacy"]),
            FootageTagQuery(cameraID: camera, ranges: [.init(start: 100, end: 110)], keys: ["privacy", "privacy"]),
            FootageTagQuery(cameraID: camera, ranges: Array(repeating: .init(start: 0, end: 300), count: 13), keys: ["privacy"])
        ] { XCTAssertThrowsError(try query.validate()) }
        let request = Request(protocolVersion: 1, operation: "media.tags.snapshot", nvrInstanceID: UUID().uuidString, tagQuery: valid)
        XCTAssertEqual(try JSONDecoder().decode(Request.self, from: JSONEncoder().encode(request)).tagQuery, valid)
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        fields["storeID"] = UUID().uuidString
        XCTAssertThrowsError(try JSONDecoder().decode(FootageTagQuery.self, from: JSONSerialization.data(withJSONObject: fields)))
    }
    func testSnapshotProjectsKeysCoalescesQueriesAndReadsCurrentLocalOverrides() async throws {
        let f = try HistoricalTagsTests().fixture(stores: 2)
        defer { _ = f.manager.stop(); try? FileManager.default.removeItem(atPath: f.root) }
        let (_, db) = try f.index(), row = try XCTUnwrap(db.recordings().first)
        let query = FootageTagQuery(cameraID: f.camera, ranges: [.init(start: row.start, end: row.end),
            .init(start: row.start, end: row.end, epochID: row.timing.time.epochID)], keys: ["original", "privacy"])
        let before = try f.engine().snapshot(query)
        XCTAssertEqual(before.count, 1); XCTAssertEqual(before.first?.tags.values, ["original": "yes"])
        XCTAssertEqual(before.first?.tags.knownAbsent, ["privacy"]); XCTAssertTrue(before.first?.tags.complete == true)
        let selection = HistoricalTagRequest.Selection(cameraID: f.camera,
            start: .init(timestamp: row.start), end: .init(timestamp: row.end))
        _ = try await f.engine().run(.init(jobID: UUID().uuidString,
            edits: [.init(selection: selection, key: "privacy", value: "hidden")])) { _ in }
        let after = try f.engine().snapshot(query)
        XCTAssertEqual(after.count, 1); XCTAssertEqual(after.first?.tags.values["privacy"], "hidden")
        let filtered = try f.engine().snapshot(.init(cameraID: f.camera, ranges: query.ranges, keys: ["privacy"]))
        XCTAssertEqual(filtered.first?.tags.values, ["privacy": "hidden"])
        let primary = try XCTUnwrap(HistoricalTagEngine.clientStore(f.configs))
        let oneCopy = HistoricalTagEngine(configs: [primary], manager: f.manager,
            factory: { _, _ in throw ServiceError("Unexpected read") }, credentials: nil, password: nil, cancellation: Cancellation())
        _ = try await oneCopy.run(.init(jobID: UUID().uuidString,
            edits: [.init(selection: selection, key: "privacy", value: nil)])) { _ in }
        let conflicting = try f.engine().snapshot(query)
        XCTAssertTrue(conflicting.first?.tags.complete == true)
        XCTAssertNil(conflicting.first?.tags.values["privacy"])
        XCTAssertTrue(conflicting.first?.tags.knownAbsent.contains("privacy") == true)
        XCTAssertEqual(conflicting.first?.tags.values["original"], "yes")
        _ = try await f.engine().run(.init(jobID: UUID().uuidString,
            edits: [.init(selection: selection, key: "privacy", value: nil)])) { _ in }
        let removed = try f.engine().snapshot(query)
        XCTAssertEqual(removed.first?.tags.knownAbsent, ["privacy"])
        XCTAssertTrue(removed.first?.tags.complete == true)
        let expired = HistoricalTagEngine(configs: f.configs, manager: f.manager,
            factory: { _, _ in XCTFail("Snapshot tried media access"); throw ServiceError("Unexpected read") },
            credentials: nil, password: nil, cancellation: Cancellation(), work: MediaWork(deadline: 0))
        XCTAssertThrowsError(try expired.snapshot(query))
    }
    func testS3OnlySnapshotIsUnsupportedWithoutReadingCloudTags() throws {
        let config = try S3PlaybackManifestTests().config()
        let manager = RecordingStoreManager(spoolRoot: "/private/tmp/unused-tag-projection-spool")
        defer { _ = manager.stop() }
        let engine = HistoricalTagEngine(configs: [config], manager: manager,
            factory: { _, _ in XCTFail("Client projection touched S3"); throw ServiceError("Unexpected S3 read") },
            credentials: nil, password: nil, cancellation: Cancellation())
        XCTAssertThrowsError(try engine.snapshot(.init(cameraID: UUID().uuidString,
            ranges: [.init(start: 100, end: 110)], keys: ["privacy"]))) {
            XCTAssertEqual(($0 as? ServiceError)?.code, .incompatible)
        }
    }
    func testSuccessfulJobsNotifyAfterLocalCommitAndResolvedTimesAreCanonical() async throws {
        let events = FootageTagEvents(instanceID: UUID().uuidString)
        let f = try HistoricalTagsTests().fixture(tagEvents: events)
        defer { _ = f.manager.stop(); try? FileManager.default.removeItem(atPath: f.root) }
        let (_, db) = try f.index(), row = try XCTUnwrap(db.recordings().first)
        let jobs = HistoricalTagJobs(), pair = try sockets()
        defer { jobs.stop(); events.stop(); close(pair[0]) }
        try events.subscribe(pair[1], authorize: { true }); _ = try read(pair[0])
        let anchor = row.timing.time.receivedUTC
        let request = HistoricalTagRequest(jobID: UUID().uuidString, edits: [.init(selection: .init(cameraID: f.camera,
            timeline: .received, start: .init(timestamp: anchor), end: .init(timestamp: anchor + 0.2)), key: "person", value: "yes")])
        _ = try jobs.start(request, uid: geteuid(), configs: f.configs, manager: f.manager,
            factory: { _, _ in throw ServiceError("Unexpected read") }, credentials: nil, password: nil)
        let event = try read(pair[0])
        let (_, overlayEmpty) = try events.readLocalSnapshot(storeID: f.configs[0].id, work: MediaWork()) { $0.isEmpty }
        XCTAssertTrue(overlayEmpty)
        XCTAssertEqual(try db.historicalTags(id: row.id)?.state(at: 0).values["person"], "yes")
        for _ in 0..<500 {
            if (try? jobs.requireIdle()) != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try jobs.requireIdle()
        XCTAssertEqual(event.ranges.count, 1)
        XCTAssertEqual(try XCTUnwrap(event.ranges.first).start, row.start, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(event.ranges.first).end, row.end, accuracy: 0.000001)
    }
    func testDelayedS3RecoveryDoesNotInvalidateLocalClientView() throws {
        let helper = S3PlaybackManifestTests(), config = try helper.config(), root = try helper.root()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let events = FootageTagEvents(instanceID: UUID().uuidString), pair = try sockets()
        defer { events.stop(); close(pair[0]) }
        try events.subscribe(pair[1], authorize: { true }); _ = try read(pair[0])
        let publisher = S3PlaybackPublisher(configuration: config, path: root + "/index", queue: DispatchQueue(label: "tag-watch-recovery"),
            factory: { _ in ManifestTransport() }, tagEvents: events)
        let metadata = helper.shard(config, camera: UUID().uuidString, at: Date().timeIntervalSince1970 - 120)
        try publisher.record(metadata)
        XCTAssertEqual(try events.snapshotToken().revision, 0, "Normal recording publication does not emit tag changes")
        let old = try XCTUnwrap(publisher.entries[metadata.id]?.shard)
        var tags = VideoTagTimeline.unknown
        try tags.apply(.init(start: 0, end: 90000, key: "privacy", value: "hidden"))
        var next = old; next.tagMetadata = try .freeze(tags, password: nil); next.tagRevision = UUID().uuidString
        publisher.checkpoint = { if $0 == "tag-record" { throw ServiceError("Injected durable recovery interruption") } }
        XCTAssertThrowsError(try publisher.editTags([.init(expected: old, replacement: next)]))
        XCTAssertEqual(try events.snapshotToken().revision, 0)
        publisher.checkpoint = { _ in }
        publisher.tick()
        XCTAssertEqual(try events.snapshotToken().revision, 0)
        var pending = pollfd(fd: pair[0], events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&pending, 1, 0), 0)
        XCTAssertEqual(publisher.entries[metadata.id]?.shard, next)
        publisher.tick()
        XCTAssertEqual(try events.snapshotToken().revision, 0, "Cloud recovery is independent of the local tag view")
    }

    func testControlSocketSnapshotUsesCurrentInstanceAndTransfersOnlyAcceptedReads() throws {
        let root = "/private/tmp/hbnvr-tag-snapshot-ipc-" + UUID().uuidString
        try SecureFiles.ensureDirectory(root, owner: geteuid(), mode: 0o700)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let server = AgentServer(directory: root, authorization: .local(geteuid()), system: false)
        func exchange(_ request: Request) throws -> (Reply, Bool) {
            let pair = try sockets()
            defer { close(pair[0]) }
            try SocketIO.write(JSONEncoder().encode(request), fd: pair[0], deadline: ProcessInfo.processInfo.systemUptime + 3)
            let transferred = server.handle(pair[1], started: ProcessInfo.processInfo.systemUptime)
            defer { if !transferred { close(pair[1]) } }
            let reply = try JSONDecoder().decode(Reply.self, from: SocketIO.read(fd: pair[0], deadline: ProcessInfo.processInfo.systemUptime + 3))
            return (reply, transferred)
        }
        let (cameras, _) = try exchange(.init(protocolVersion: 1, operation: "cameras.snapshot"))
        let instance = try XCTUnwrap(cameras.cameraSnapshot?.instanceID)
        let query = FootageTagQuery(cameraID: UUID().uuidString, ranges: [.init(start: 100, end: 110)], keys: ["privacy"])
        let (snapshot, accepted) = try exchange(.init(protocolVersion: 1, operation: "media.tags.snapshot", nvrInstanceID: instance, tagQuery: query))
        XCTAssertFalse(accepted); XCTAssertEqual(snapshot.code, .incompatible)
        XCTAssertNil(snapshot.tagSnapshot, "No local source is unsupported, never an empty visible tag set")
        let (stale, rejected) = try exchange(.init(protocolVersion: 1, operation: "media.tags.snapshot", nvrInstanceID: UUID().uuidString, tagQuery: query))
        XCTAssertFalse(rejected); XCTAssertEqual(stale.code, .unavailable); XCTAssertNil(stale.tagSnapshot)
        let (status, ordinary) = try exchange(.init(protocolVersion: 1, operation: "status"))
        XCTAssertFalse(ordinary); XCTAssertTrue(status.status?.ready == true)
    }

}
