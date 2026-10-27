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
    func testSnapshotWaitsForMutationAndReturnsCommittedRevision() throws {
        let events = FootageTagEvents(instanceID: UUID().uuidString)
        defer { events.stop() }
        events.beginMutation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { events.endMutation(reset: true) }
        var reads = 0
        let (token, value) = try events.readSnapshot(work: MediaWork(deadline: ProcessInfo.processInfo.systemUptime + 2)) {
            reads += 1
            XCTAssertEqual(try events.snapshotToken().revision, 1, "Do not read partially committed metadata")
            return "committed"
        }
        XCTAssertEqual(reads, 1); XCTAssertEqual(token.revision, 1); XCTAssertEqual(value, "committed")
    }
    func testSnapshotDiscardsBothValuesAndErrorsFromOverlappingEdits() throws {
        for failFirst in [false, true] {
            let events = FootageTagEvents(instanceID: UUID().uuidString)
            defer { events.stop() }
            var reads = 0
            let (token, value) = try events.readSnapshot(work: MediaWork()) {
                reads += 1
                if reads == 1 {
                    // Writers can finish while a read is running. Its stale
                    // value or an error from mixed metadata must be discarded.
                    events.beginMutation(); events.endMutation(reset: true)
                    if failFirst { throw ServiceError("Inconsistent metadata during edit") }
                }
                return reads
            }
            XCTAssertEqual(reads, 2); XCTAssertEqual(value, 2); XCTAssertEqual(token.revision, 1)
        }
    }
    func testSnapshotDoesNotRetryStableStorageFailures() throws {
        let events = FootageTagEvents(instanceID: UUID().uuidString)
        defer { events.stop() }
        var reads = 0
        XCTAssertThrowsError(try events.readSnapshot(work: MediaWork()) { () -> Int in
            reads += 1; throw ServiceError(.permission, "Access denied")
        }) { error in
            XCTAssertEqual((error as? ServiceError)?.code, .permission)
        }
        XCTAssertEqual(reads, 1)
    }
    func testSnapshotWaitAndContinuousInvalidationRespectDeadline() throws {
        let events = FootageTagEvents(instanceID: UUID().uuidString)
        defer { events.stop() }
        events.beginMutation()
        XCTAssertThrowsError(try events.readSnapshot(work: MediaWork(deadline: ProcessInfo.processInfo.systemUptime + 0.03)) {
            XCTFail("Read during mutation"); return 0
        }) { XCTAssertEqual(($0 as? ServiceError)?.code, .timeout) }
        events.endMutation()
        XCTAssertThrowsError(try events.readSnapshot(work: MediaWork(deadline: ProcessInfo.processInfo.systemUptime + 0.03)) {
            events.beginMutation(); events.endMutation()
            return "stale"
        }) { XCTAssertEqual(($0 as? ServiceError)?.code, .timeout) }
    }
    func testSnapshotWaitRespondsToCancellationPeerClosureAndStop() throws {
        let events = FootageTagEvents(instanceID: UUID().uuidString)
        defer { events.stop() }
        events.beginMutation()
        let cancellation = Cancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { cancellation.stop() }
        XCTAssertThrowsError(try events.readSnapshot(work: MediaWork(cancellation: cancellation)) {
            XCTFail("Read after cancellation"); return 0
        }) { XCTAssertEqual(($0 as? ServiceError)?.message, "Media session closed.") }
        let pair = try sockets(); close(pair[0]); defer { close(pair[1]) }
        XCTAssertThrowsError(try events.readSnapshot(work: MediaWork(peer: pair[1])) {
            XCTFail("Read after peer closure"); return 0
        }) { XCTAssertEqual(($0 as? ServiceError)?.message, "Media peer disconnected.") }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { events.stop() }
        XCTAssertThrowsError(try events.readSnapshot(work: MediaWork()) {
            XCTFail("Read after stop"); return 0
        }) { XCTAssertEqual(($0 as? ServiceError)?.message, "Footage tag service stopped.") }
    }
    func testSubscriptionResetMutationConsistencyCoalescingAndNoop() throws {
        let events = FootageTagEvents(instanceID: UUID().uuidString), pair = try sockets()
        defer { events.stop(); close(pair[0]) }
        try events.subscribe(pair[1], authorize: { true })
        let initial = try read(pair[0]); XCTAssertTrue(initial.reset); XCTAssertEqual(initial.revision, 0)
        let token = try events.snapshotToken(), camera = UUID().uuidString, epoch = UUID().uuidString
        events.beginMutation(); XCTAssertThrowsError(try events.snapshotToken())
        events.beginMutation()
        events.endMutation(ranges: [.init(cameraID: camera, epochID: epoch, start: 10, end: 20)])
        XCTAssertThrowsError(try events.snapshotToken())
        events.endMutation(ranges: [.init(cameraID: camera, epochID: epoch, start: 15, end: 30)])
        let change = try read(pair[0]); XCTAssertFalse(change.reset); XCTAssertEqual(change.revision, 1)
        XCTAssertEqual(change.ranges, [.init(cameraID: camera, epochID: epoch, start: 10, end: 30)])
        XCTAssertThrowsError(try events.validate(token))
        let beforeNoop = try events.snapshotToken()
        events.beginMutation(); events.endMutation()
        XCTAssertEqual(try events.snapshotToken().revision, beforeNoop.revision)
        XCTAssertThrowsError(try events.validate(beforeNoop), "Even an overlapping failed/no-op edit invalidates an in-flight read")
        events.beginMutation(); events.endMutation(reset: true)
        XCTAssertTrue(try read(pair[0]).reset)
        let reconnect = try sockets(); defer { close(reconnect[0]) }
        try events.subscribe(reconnect[1], authorize: { true })
        let reset = try read(reconnect[0]); XCTAssertTrue(reset.reset); XCTAssertEqual(reset.revision, 2)
    }
    func testTooManyRangesBecomeOneResetAndSubscriberLimitIsBounded() throws {
        let events = FootageTagEvents(instanceID: UUID().uuidString)
        defer { events.stop() }
        var clients: [Int32] = []
        defer { clients.forEach { close($0) } }
        for _ in 0..<8 {
            let pair = try sockets(); clients.append(pair[0]); try events.subscribe(pair[1], authorize: { true }); _ = try read(pair[0])
        }
        let extra = try sockets(); defer { close(extra[0]); close(extra[1]) }
        XCTAssertThrowsError(try events.subscribe(extra[1], authorize: { true }))
        let camera = UUID().uuidString, epoch = UUID().uuidString
        events.beginMutation()
        events.endMutation(ranges: (0..<65).map { .init(cameraID: camera, epochID: epoch, start: Double($0 * 2), end: Double($0 * 2 + 1)) })
        let event = try read(clients[0]); XCTAssertTrue(event.reset); XCTAssertTrue(event.ranges.isEmpty)
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
        let oneCopy = HistoricalTagEngine(configs: [f.configs[0]], manager: f.manager,
            factory: { _, _ in throw ServiceError("Unexpected read") }, credentials: nil, password: nil, cancellation: Cancellation())
        _ = try await oneCopy.run(.init(jobID: UUID().uuidString,
            edits: [.init(selection: selection, key: "privacy", value: nil)])) { _ in }
        let conflicting = try f.engine().snapshot(query)
        XCTAssertFalse(conflicting.first?.tags.complete ?? true)
        XCTAssertNil(conflicting.first?.tags.values["privacy"])
        XCTAssertFalse(conflicting.first?.tags.knownAbsent.contains("privacy") ?? true)
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
    func testSuccessfulJobsNotifyAfterIdleAndResolvedTimesAreCanonical() async throws {
        let f = try HistoricalTagsTests().fixture()
        defer { _ = f.manager.stop(); try? FileManager.default.removeItem(atPath: f.root) }
        let (_, db) = try f.index(), row = try XCTUnwrap(db.recordings().first)
        let events = FootageTagEvents(instanceID: UUID().uuidString), jobs = HistoricalTagJobs(events: events), pair = try sockets()
        defer { jobs.stop(); events.stop(); close(pair[0]) }
        try events.subscribe(pair[1], authorize: { true }); _ = try read(pair[0])
        let anchor = row.timing.time.receivedUTC
        let request = HistoricalTagRequest(jobID: UUID().uuidString, edits: [.init(selection: .init(cameraID: f.camera,
            timeline: .received, start: .init(timestamp: anchor), end: .init(timestamp: anchor + 0.2)), key: "person", value: "yes")])
        _ = try jobs.start(request, uid: geteuid(), configs: f.configs, manager: f.manager,
            factory: { _, _ in throw ServiceError("Unexpected read") }, credentials: nil, password: nil)
        let event = try read(pair[0]); try jobs.requireIdle(); _ = try events.snapshotToken()
        XCTAssertEqual(event.ranges.count, 1)
        XCTAssertEqual(try XCTUnwrap(event.ranges.first).start, row.start, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(event.ranges.first).end, row.start + 0.2, accuracy: 0.000001)
    }
    func testDelayedS3RecoveryPublishesOneResetOnlyWhenMetadataChanges() throws {
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
        let recovered = try read(pair[0]); XCTAssertTrue(recovered.reset); XCTAssertEqual(recovered.revision, 1)
        XCTAssertEqual(publisher.entries[metadata.id]?.shard, next)
        publisher.tick()
        XCTAssertEqual(try events.snapshotToken().revision, 1, "An empty maintenance tick must not emit resets")
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
        XCTAssertTrue(accepted); XCTAssertNil(snapshot.error)
        XCTAssertEqual(snapshot.tagSnapshot?.instanceID, instance)
        XCTAssertEqual(snapshot.tagSnapshot?.cameraID, query.cameraID)
        XCTAssertEqual(snapshot.tagSnapshot?.spans, [])
        let (stale, rejected) = try exchange(.init(protocolVersion: 1, operation: "media.tags.snapshot", nvrInstanceID: UUID().uuidString, tagQuery: query))
        XCTAssertFalse(rejected); XCTAssertEqual(stale.code, .unavailable); XCTAssertNil(stale.tagSnapshot)
        let (status, ordinary) = try exchange(.init(protocolVersion: 1, operation: "status"))
        XCTAssertFalse(ordinary); XCTAssertTrue(status.status?.ready == true)
    }

}
