import XCTest
import AVFoundation
import AWSS3
import Smithy
import SmithyHTTPAPI

private actor RepairReader: S3RepairReading {
    var objects: [S3RepairObject]
    var reads = 0
    var listCalls = 0
    var failure: S3RepairFailure?
    var readFailure: S3RepairReadFailure?
    var delay = false
    var delayListing = false
    init(_ objects: [S3RepairObject], failure: S3RepairFailure? = nil) { self.objects = objects; self.failure = failure }
    func setDelay() { delay = true }
    func holdListing() { delayListing = true }
    func failReads(_ failure: S3RepairReadFailure) { readFailure = failure }
    func list(after: String?) async throws -> S3RepairPage {
        listCalls += 1
        if delayListing { try await Task.sleep(for: .seconds(60)) }
        if let failure { throw failure }
        return .init(objects: objects, next: nil)
    }
    func read(_ object: S3RepairObject) async throws -> Data {
        reads += 1
        if let readFailure { throw readFailure }
        if delay { try? await Task.sleep(for: .milliseconds(150)) } // Intentionally ignore cancellation.
        if let failure { throw failure }
        return Data([1, 2, 3])
    }
}
private actor RepairSink {
    var entries: [S3ShardMetadata] = []
    var known = Set<String>()
    var publishes = 0
    var fail = false
    func addKnown(_ key: String) { known.insert(key) }
    func setFailure() { fail = true }
    func merge(_ metadata: S3ShardMetadata, _ cancellation: Cancellation) throws -> Bool {
        guard !cancellation.isStopped else { throw CancellationError() }
        if fail { throw ServiceError("Synthetic journal write failure") }
        if entries.contains(where: { $0.id == metadata.id }) { return false }
        entries.append(metadata); return true
    }
    func publish() { publishes += 1 }
    nonisolated var sink: S3RepairSink {
        .init(knownKeys: { await self.known }, merge: { try await self.merge($0, $1) },
              publish: { cancellation in guard !cancellation.isStopped else { throw CancellationError() }; await self.publish() })
    }
}
private actor RepairHTTPFixture: HTTPClient {
    let config: S3Configuration
    let object: S3RepairObject
    var requests: [URLRequest] = []
    var rejection: S3RepairFailure?
    var getETag: String?
    var getBody = Data([1, 2, 3])
    var listedKey: String?
    var nextToken: String?
    func listing(key: String, next: String? = nil) { listedKey = key; nextToken = next }
    func reject(_ failure: S3RepairFailure) { rejection = failure }
    func respond(etag: String?, body: Data) { getETag = etag; getBody = body }
    init(_ config: S3Configuration, _ object: S3RepairObject) { self.config = config; self.object = object; getETag = object.etag }
    func send(request: HTTPRequest) async throws -> HTTPResponse {
        let list = request.queryItems?.contains { $0.name == "list-type" } == true
        let outgoing: URLRequest
        do { outgoing = try S3RepairHTTP(configuration: config, key: list ? nil : object.key, maximumBytes: 1024).urlRequest(request) }
        catch {
            XCTFail("Synthetic SDK request rejected: path=\(request.destination.path) query=\(String(describing: request.queryItems)) host=\(request.destination.host)")
            throw error
        }
        requests.append(outgoing)
        if let rejection { throw rejection }
        var headers = Headers()
        if let etag = list ? object.etag : getETag { headers.add(name: "etag", value: etag) }
        let data: Data
        if list {
            let wireKey = listedKey ?? S3RepairHTTP.encoded(object.key).replacingOccurrences(of: "%20", with: "+")
            let pagination = nextToken.map { "<NextContinuationToken>\($0)</NextContinuationToken>" } ?? ""
            data = Data("""
                <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><EncodingType>url</EncodingType><IsTruncated>\(nextToken != nil)</IsTruncated>\(pagination)<Contents><Key>\(wireKey)</Key><Size>3</Size><ETag>&quot;example&quot;</ETag></Contents></ListBucketResult>
                """.utf8)
        } else { data = getBody }
        headers.add(name: "Content-Length", value: String(data.count))
        return HTTPResponse(headers: headers, body: .data(data), statusCode: .ok)
    }
}

private final class RepairLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.lock(); defer { lock.unlock() }; lines.append(line) }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return lines }
}

final class S3RepairTests: XCTestCase {
    func config() throws -> RecordingStoreConfiguration { try S3Tests().config() }
    func metadata(_ config: RecordingStoreConfiguration, camera: String) -> S3ShardMetadata {
        S3PlaybackManifestTests().shard(config, camera: camera, at: 1_789_732_810)
    }
    func object(_ metadata: S3ShardMetadata) -> S3RepairObject { .init(key: metadata.key, size: metadata.size, etag: "\"example\"") }
    func wait(_ jobs: S3RepairJobs, _ id: String, for state: String) async throws -> S3RepairStatus {
        for _ in 0..<500 {
            let status = try jobs.poll(id, uid: geteuid())
            if status.state == state { return status }
            if ["failed", "cancelled", "completed"].contains(status.state) {
                throw ServiceError("Expected \(state), got \(status.state): \(status.message)")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ServiceError("Repair test deadline")
    }
    func begin(_ jobs: S3RepairJobs, _ id: String) throws {
        _ = try jobs.resume(id, uid: geteuid(), credentials: nil, password: nil, skipEncrypted: false, begin: true)
    }
    func testCandidateDiscoveryIgnoresUnknownObjectsAndAllowsRenamedCameraFolder() throws {
        let c = try config(), camera = UUID().uuidString, m = metadata(c, camera: camera), o = object(m)
        XCTAssertNotNil(S3RepairCandidate.parse(o, prefix: c.s3!.prefix, cameras: [camera]))
        let renamed = o.key.replacingOccurrences(of: "Camera--", with: "Previous Name--")
        XCTAssertNotNil(S3RepairCandidate.parse(.init(key: renamed, size: 3, etag: o.etag), prefix: c.s3!.prefix, cameras: [camera]))
        for key in ["test/.hbnvr/playback/v1/catalog.json", "test/setup-object", "test/old.mp4", "test/strange\nname", o.key + ".tmp", "other/" + o.key, o.key.replacingOccurrences(of: "2026-", with: "garbage-")] {
            XCTAssertNil(S3RepairCandidate.parse(.init(key: key, size: 3, etag: o.etag), prefix: c.s3!.prefix, cameras: [camera]), key)
        }
        XCTAssertNil(S3RepairCandidate.parse(o, prefix: c.s3!.prefix, cameras: [UUID().uuidString]))
    }
    func testDryRunOnlyListsAndNeverDownloadsOrPublishes() async throws {
        let c = try config(), camera = UUID().uuidString, m = metadata(c, camera: camera)
        let reader = RepairReader([object(m), .init(key: "test/unknown", size: 99, etag: "x")]), sink = RepairSink()
        let jobs = S3RepairJobs(factory: { _, _ in reader }); defer { jobs.stop() }
        let job = try jobs.start(config: c, cameras: [camera], sink: sink.sink, uid: geteuid(), dryRun: true)
        let done = try await wait(jobs, job.id, for: "completed")
        XCTAssertEqual(done.candidates, 1); XCTAssertEqual(done.candidateBytes, 3)
        XCTAssertEqual(done.skipped["unexpected"], 1)
        let reads = await reader.reads, publications = await sink.publishes
        XCTAssertEqual(reads, 0); XCTAssertEqual(publications, 0)
        XCTAssertFalse(jobs.isBusy(c.id))
        XCTAssertThrowsError(try begin(jobs, job.id))
    }
    func testTemporaryCredentialsResumeWithoutReplacingWriterKeys() async throws {
        let c = try config(), camera = UUID().uuidString, m = metadata(c, camera: camera)
        let denied = RepairReader([], failure: .credentials), reader = RepairReader([object(m)]), sink = RepairSink()
        let jobs = S3RepairJobs(factory: { _, keys in keys.accessKeyID == "repair" ? reader : denied },
            inspect: { _, _, _, _ in m }); defer { jobs.stop() }
        let job = try jobs.start(config: c, cameras: [camera], sink: sink.sink, uid: geteuid(), dryRun: false)
        _ = try await wait(jobs, job.id, for: "credentials")
        XCTAssertThrowsError(try jobs.requireIdle(c.id))
        XCTAssertThrowsError(try jobs.poll(job.id, uid: geteuid() + 1))
        let keys = S3RepairCredentials(accessKeyID: "repair", secretAccessKey: "never-persist-this", sessionToken: "temporary-session")
        _ = try jobs.resume(job.id, uid: geteuid(), credentials: keys, password: nil, skipEncrypted: false, begin: false)
        let preview = try await wait(jobs, job.id, for: "ready")
        let readsBeforeConfirmation = await reader.reads; XCTAssertEqual(readsBeforeConfirmation, 0)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(preview), as: UTF8.self).contains(keys.secretAccessKey))
        try begin(jobs, job.id)
        let done = try await wait(jobs, job.id, for: "completed")
        XCTAssertEqual(done.recovered, 1)
        let merged = await sink.entries, published = await sink.publishes
        XCTAssertEqual(merged.map(\.key), [m.key]); XCTAssertEqual(published, 1)
        XCTAssertEqual(c.s3?.credentials?.accessKeyID, "AKIAUNITTEST000000000")
    }
    func testLegacyFilesAreSkippedAndKnownKeysAreNotDownloaded() async throws {
        let c = try config(), camera = UUID().uuidString
        let known = metadata(c, camera: camera), legacy = metadata(c, camera: camera)
        let reader = RepairReader([object(known), object(legacy)]), sink = RepairSink()
        await sink.addKnown(known.key)
        let jobs = S3RepairJobs(factory: { _, _ in reader }, inspect: { _, _, _, _ in throw S3RepairSkip.legacyOrInvalidTiming })
        defer { jobs.stop() }
        let job = try jobs.start(config: c, cameras: [camera], sink: sink.sink, uid: geteuid(), dryRun: false)
        _ = try await wait(jobs, job.id, for: "ready"); try begin(jobs, job.id)
        let done = try await wait(jobs, job.id, for: "completed")
        XCTAssertEqual(done.alreadyIndexed, 1); XCTAssertEqual(done.skipped["legacyOrInvalidTiming"], 1)
        let reads = await reader.reads, merged = await sink.entries
        XCTAssertEqual(reads, 1); XCTAssertTrue(merged.isEmpty)
    }
    func testCancellationStopsLateCallbackFromMerging() async throws {
        let c = try config(), camera = UUID().uuidString, m = metadata(c, camera: camera)
        let reader = RepairReader([object(m)]), sink = RepairSink(); await reader.setDelay()
        let jobs = S3RepairJobs(factory: { _, _ in reader }, inspect: { _, _, _, _ in m }); defer { jobs.stop() }
        let job = try jobs.start(config: c, cameras: [camera], sink: sink.sink, uid: geteuid(), dryRun: false)
        _ = try await wait(jobs, job.id, for: "ready"); try begin(jobs, job.id)
        while await reader.reads == 0 { try await Task.sleep(for: .milliseconds(5)) }
        let cancelled = try jobs.cancel(job.id, uid: geteuid()); XCTAssertEqual(cancelled.state, "cancelled")
        try await Task.sleep(for: .milliseconds(200))
        let merged = await sink.entries, published = await sink.publishes
        XCTAssertTrue(merged.isEmpty); XCTAssertEqual(published, 0); XCTAssertFalse(jobs.isBusy(c.id))
    }
    func testNetworkFailureDoesNotAskForNewCredentials() async throws {
        let c = try config(), sink = RepairSink(), reader = RepairReader([], failure: .unavailable)
        let jobs = S3RepairJobs(factory: { _, _ in reader }); defer { jobs.stop() }
        let job = try jobs.start(config: c, cameras: [UUID().uuidString], sink: sink.sink, uid: geteuid(), dryRun: false)
        let done = try await wait(jobs, job.id, for: "failed")
        XCTAssertTrue(done.message.contains("network")); XCTAssertFalse(jobs.isBusy(c.id))
    }
    func testWrongPasswordCanBeReplacedOrExplicitlySkipped() async throws {
        for skip in [false, true] {
            let c = try config(), camera = UUID().uuidString, m = metadata(c, camera: camera)
            let reader = RepairReader([object(m)]), sink = RepairSink()
            let jobs = S3RepairJobs(factory: { _, _ in reader }, inspect: { _, _, _, passwords in
                guard passwords.contains("old-password") else { throw S3RepairFailure.password }; return m
            }); defer { jobs.stop() }
            let job = try jobs.start(config: c, cameras: [camera], sink: sink.sink, uid: geteuid(), dryRun: false)
            _ = try await wait(jobs, job.id, for: "ready"); try begin(jobs, job.id)
            _ = try await wait(jobs, job.id, for: "password")
            _ = try jobs.resume(job.id, uid: geteuid(), credentials: nil, password: skip ? nil : "old-password", skipEncrypted: skip, begin: false)
            let done = try await wait(jobs, job.id, for: "completed")
            XCTAssertEqual(done.recovered, skip ? 0 : 1)
            if skip { XCTAssertEqual(done.skipped["unreadableEncrypted"], 1) }
        }
    }
    func testJournalFailureIsNotReportedAsSuccess() async throws {
        let c = try config(), camera = UUID().uuidString, m = metadata(c, camera: camera)
        let reader = RepairReader([object(m)]), sink = RepairSink(); await sink.setFailure()
        let jobs = S3RepairJobs(factory: { _, _ in reader }, inspect: { _, _, _, _ in m }); defer { jobs.stop() }
        let job = try jobs.start(config: c, cameras: [camera], sink: sink.sink, uid: geteuid(), dryRun: false)
        _ = try await wait(jobs, job.id, for: "ready"); try begin(jobs, job.id)
        let done = try await wait(jobs, job.id, for: "failed")
        XCTAssertEqual(done.recovered, 0); XCTAssertTrue(done.message.contains("journal"))
    }
    func testOwnerIdentityAndExpiry() async throws {
        final class Clock: @unchecked Sendable { var time = 0.0 }
        let c = try config(), clock = Clock(), reader = RepairReader([]), sink = RepairSink()
        let jobs = S3RepairJobs(factory: { _, _ in reader }, now: { clock.time }); defer { jobs.stop() }
        var other = c; other.ownerUUID = UUID()
        XCTAssertThrowsError(try jobs.start(config: other, cameras: [UUID().uuidString], sink: sink.sink, uid: geteuid(), dryRun: true))
        let job = try jobs.start(config: c, cameras: [UUID().uuidString], sink: sink.sink, uid: geteuid(), dryRun: false)
        _ = try await wait(jobs, job.id, for: "ready")
        clock.time = 901
        XCTAssertThrowsError(try jobs.poll(job.id, uid: geteuid()))
        XCTAssertFalse(jobs.isBusy(c.id))
    }
    func testSDKListAndGetAreReadOnlyScopedAndSignedWithTemporaryToken() async throws {
        var c = try config(); c.s3?.prefix = "repair folder/"; c.s3?.expectedOwner = "123456789012"
        let o = S3RepairObject(key: "repair folder/test.mp4", size: 3, etag: "\"example\"")
        let engine = RepairHTTPFixture(c.s3!, o)
        var reader = AWSS3RepairReader(configuration: c.s3!, credentials: .init(accessKeyID: "repair", secretAccessKey: "secret", sessionToken: "session-token"))
        reader.httpFactory = { _, _, _ in engine }
        let page = try await reader.list(after: nil); XCTAssertEqual(page.objects, [o])
        let bytes = try await reader.read(o); XCTAssertEqual(bytes, Data([1, 2, 3]))
        let requests = await engine.requests
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-amz-security-token"), "session-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-amz-expected-bucket-owner"), "123456789012")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.contains("AWS4-HMAC-SHA256") == true)
        }
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "If-Match"), o.etag)
        await engine.reject(.credentials)
        do { _ = try await reader.list(after: nil); XCTFail("Expected access denial") }
        catch { XCTAssertEqual(error as? S3RepairFailure, .credentials) }
        let policy = try AWSS3RepairReader.iamPolicy(c.s3!)
        XCTAssertTrue(policy.contains("s3:ListBucket")); XCTAssertTrue(policy.contains("s3:GetObject"))
        for forbidden in ["PutObject", "DeleteObject", "Lifecycle", "ListAllMyBuckets"] { XCTAssertFalse(policy.contains(forbidden)) }
    }
    func testSDKListingDecodesSpacesButPreservesLiteralPlusAndPercentThroughGet() async throws {
        // Explicit wire fixtures, not a round trip through our own encoder.
        let cases = [
            ("Bedroom Camera", "Bedroom+Camera"),
            ("Bedroom Camera", "Bedroom%20Camera"),
            ("Bedroom+Camera", "Bedroom%2BCamera"),
            ("Bedroom + Camera", "Bedroom+%2B+Camera"),
            ("Bedroom%20Camera", "Bedroom%2520Camera"),
            ("Bedroom%2BCamera", "Bedroom%252BCamera"),
            ("Entrée Camera", "Entr%C3%A9e+Camera"),
            ("Camera &?#%", "Camera+%26%3F%23%25")
        ]
        let c = try config()
        for (raw, wire) in cases {
            let object = S3RepairObject(key: c.s3!.prefix + raw + "/video.mp4.hbnvr", size: 3, etag: "\"example\"")
            let engine = RepairHTTPFixture(c.s3!, object)
            await engine.listing(key: "test/" + wire + "/video.mp4.hbnvr")
            var reader = AWSS3RepairReader(configuration: c.s3!, credentials: .init(accessKeyID: "repair", secretAccessKey: "secret"))
            reader.httpFactory = { _, _, _ in engine }
            let page = try await reader.list(after: nil)
            XCTAssertEqual(page.objects, [object], wire)
            let body = try await reader.read(XCTUnwrap(page.objects.first))
            XCTAssertEqual(body, Data([1, 2, 3]))
            let requests = await engine.requests
            let url = try XCTUnwrap(requests.last?.url)
            XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath.removingPercentEncoding,
                           "/" + c.s3!.bucket + "/" + object.key)
        }
        XCTAssertNil(AWSS3RepairReader.decodeListedKey("bad%2"))
        XCTAssertNil(AWSS3RepairReader.decodeListedKey("bad%GG"))
    }
    func testSDKListingPreservesRawPrefixAndOpaquePaginationToken() async throws {
        var c = try config(); c.s3?.prefix = "Entrée + %20 &/"
        let object = S3RepairObject(key: c.s3!.prefix + "video.mp4", size: 3, etag: "\"example\"")
        let engine = RepairHTTPFixture(c.s3!, object), token = "opaque+/%20=token"
        await engine.listing(key: "Entr%C3%A9e+%2B+%2520+%26/video.mp4", next: token)
        var reader = AWSS3RepairReader(configuration: c.s3!, credentials: .init(accessKeyID: "repair", secretAccessKey: "secret"))
        reader.httpFactory = { _, _, _ in engine }
        let first = try await reader.list(after: nil)
        XCTAssertEqual(first.objects, [object]); XCTAssertEqual(first.next, token)
        _ = try await reader.list(after: first.next)
        let requests = await engine.requests
        let query = try XCTUnwrap(URLComponents(url: XCTUnwrap(requests.last?.url), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "prefix" }?.value, c.s3!.prefix)
        XCTAssertEqual(query.first { $0.name == "continuation-token" }?.value, token)
    }
    func testSDKDownloadDiagnosticsSeparateSizeAndETagFailuresWithoutLeakingHeaders() async throws {
        let c = try config(), expected = S3RepairObject(key: c.s3!.prefix + "test.mp4", size: 3, etag: "\"expected\"")
        let engine = RepairHTTPFixture(c.s3!, expected)
        var reader = AWSS3RepairReader(configuration: c.s3!, credentials: .init(accessKeyID: "repair", secretAccessKey: "secret"))
        reader.httpFactory = { _, _, _ in engine }
        let cases: [(String?, Data, S3RepairReadFailure.Reason)] = [
            (expected.etag, Data([1, 2]), .sizeMismatch),
            (nil, Data([1, 2, 3]), .etagMissing),
            ("expected", Data([1, 2, 3]), .etagMismatch),
            ("untrusted-secret\nheader", Data([1, 2, 3]), .etagMismatch)
        ]
        for (etag, body, reason) in cases {
            await engine.respond(etag: etag, body: body)
            do { _ = try await reader.read(expected); XCTFail("Expected diagnostic") }
            catch {
                let failure = try XCTUnwrap(error as? S3RepairReadFailure)
                XCTAssertEqual(failure.reason, reason)
                XCTAssertTrue(failure.detail.contains("HTTP 200"))
                XCTAssertTrue(failure.detail.contains("listed bytes=3"))
                XCTAssertTrue(failure.detail.contains("received bytes=\(body.count)"))
                XCTAssertTrue(failure.detail.contains("Content-Length=\(body.count)"))
                for forbidden in ["untrusted-secret", "header\n", expected.etag, expected.key] {
                    XCTAssertFalse(failure.detail.contains(forbidden))
                }
                if etag == nil { XCTAssertTrue(failure.detail.contains("returned ETag [absent]")) }
                if etag == "expected" { XCTAssertTrue(failure.detail.contains("quoted=false")) }
            }
        }
        await engine.respond(etag: expected.etag, body: Data([1, 2, 3]))
        let data = try await reader.read(expected)
        XCTAssertEqual(data, Data([1, 2, 3]))
    }
    func testHTTPDownloadFailuresAreDistinctAndSanitized() throws {
        for (status, reason) in [(404, S3RepairReadFailure.Reason.notFound), (412, .preconditionFailed)] {
            let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://example.invalid/secret-object")!,
                statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["ETag": "secret-header"]))
            let failure = try XCTUnwrap(S3RepairReadFailure.http(response))
            XCTAssertEqual(failure.reason, reason)
            XCTAssertTrue(failure.detail.contains("HTTP \(status)"))
            XCTAssertFalse(failure.detail.contains("secret"))
            XCTAssertEqual((S3RepairFailure.sanitize(failure) as? S3RepairReadFailure)?.reason, reason)
        }
        let failure = S3RepairFailure.sanitize(NSError(domain: "secret-domain", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "secret-password"]))
        XCTAssertEqual(failure as? S3RepairFailure, .unavailable)
    }
    func testDownloadDiagnosticsAreBoundedLoggedAndDoNotClaimEmptyRepairSucceeded() async throws {
        let c = try config(), camera = UUID().uuidString
        let objects = (0..<8).map { _ in object(metadata(c, camera: camera)) }
        let reader = RepairReader(objects), sink = RepairSink(), logs = RepairLog()
        await reader.failReads(.size(expected: 3, actual: 0))
        let jobs = S3RepairJobs(factory: { _, _ in reader }, inspect: { _, _, _, _ in
            XCTFail("A rejected download must never reach the media inspector"); throw S3RepairSkip.invalidMedia
        }, log: { logs.append($0) }); defer { jobs.stop() }
        let job = try jobs.start(config: c, cameras: [camera], sink: sink.sink, uid: geteuid(), dryRun: false)
        _ = try await wait(jobs, job.id, for: "ready"); try begin(jobs, job.id)
        let done = try await wait(jobs, job.id, for: "completed")
        XCTAssertEqual(done.recovered, 0); XCTAssertEqual(done.thumbnailsQueued, 0)
        XCTAssertEqual(done.skipped["sizeMismatch"], 8); XCTAssertNil(done.skipped["changed"])
        XCTAssertEqual(done.diagnostics?.count, 3)
        XCTAssertEqual(done.diagnostics?.map(\.candidate), [1, 2, 3])
        XCTAssertTrue(done.message.contains("no new metadata was recovered"))
        XCTAssertFalse(done.message.contains("merged durably"))
        // The summary is logged just after the terminal status is set.
        for _ in 0..<100 where logs.snapshot().count < 4 { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(logs.snapshot().count, 4)
        XCTAssertTrue(logs.snapshot().last?.contains("sizeMismatch=8") == true)
        let encoded = try JSONEncoder().encode(done), text = String(decoding: encoded, as: UTF8.self)
        XCTAssertLessThan(encoded.count, 64 * 1024)
        XCTAssertFalse(text.contains(objects[0].key)); XCTAssertFalse(text.contains(c.s3!.credentials!.accessKeyID))
        XCTAssertEqual(try JSONDecoder().decode(S3RepairStatus.self, from: encoded).diagnostics?.count, 3)
        var oldStatus = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        oldStatus.removeValue(forKey: "diagnostics")
        XCTAssertNil(try JSONDecoder().decode(S3RepairStatus.self, from: JSONSerialization.data(withJSONObject: oldStatus)).diagnostics)
        let publications = await sink.publishes
        XCTAssertEqual(publications, 1) // Existing journal republication remains unchanged.
    }
    func testRepairMergesAndRepublishesOnTheExistingStoreQueue() async throws {
        let helper = S3Tests(), root = try helper.root()
        defer { try? FileManager.default.removeItem(atPath: root) }
        var c = try config(); c.enabled = false
        let camera = UUID().uuidString, transport = ManifestTransport()
        let store = try S3RecordingStore(configuration: c, spoolRoot: root + "/spool", factory: { _ in transport }, log: { _ in })
        defer { _ = store.finish(timeout: 5) }
        let sink = store.repairSink(expected: c, cameras: [camera], cameraStillExists: { _ in true }), cancellation = Cancellation()
        let first = metadata(c, camera: camera), second = metadata(c, camera: camera)
        let insertedFirst = try await sink.merge(first, cancellation)
        let insertedSecond = try await sink.merge(second, cancellation)
        let insertedAgain = try await sink.merge(first, cancellation)
        XCTAssertTrue(insertedFirst); XCTAssertTrue(insertedSecond); XCTAssertFalse(insertedAgain)
        let keys = try await sink.knownKeys(); XCTAssertEqual(keys, [first.key, second.key])
        try await sink.publish(cancellation)
        try await helper.eventually { store.snapshot().s3?.pendingPlaybackManifests == 0 }
        let puts = await transport.puts
        let catalog = try XCTUnwrap(puts.last(where: { $0.key.hasSuffix("catalog.json") }))
        XCTAssertFalse(catalog.data.isEmpty)
        let day = try XCTUnwrap(puts.last(where: { $0.key.contains("/days/") }))
        let document = try JSONDecoder().decode(S3PlaybackDocument.self, from: day.data)
        XCTAssertEqual(Set(document.shards!.map(\.id)), [first.id, second.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/playback/" + c.id + "/" + first.id + ".json"))
        let removed = store.repairSink(expected: c, cameras: [camera], cameraStillExists: { _ in false })
        do { _ = try await removed.merge(metadata(c, camera: camera), cancellation); XCTFail("Removed camera must not merge") }
        catch { XCTAssertEqual(error as? S3RepairSkip, .identityMismatch) }
        var changed = c; changed.name = "Changed during repair"; try store.update(changed)
        do { _ = try await sink.merge(metadata(c, camera: camera), cancellation); XCTFail("Changed configuration must not merge") }
        catch { XCTAssertTrue((error as? ServiceError)?.message.contains("changed") == true) }
    }
    func testIPCRemainsResponsiveDuringRepairAndBlocksStoreChanges() async throws {
        let helper = S3Tests(), root = try helper.root(), network = FakeS3(), reader = RepairReader([])
        defer { try? FileManager.default.removeItem(atPath: root) }
        await network.configure(automatic: true); await reader.holdListing()
        var c = try config(); c.enabled = false
        let server = AgentServer(directory: root, authorization: .local(geteuid()), system: false,
                                 transportFactory: { _ in network }, repairFactory: { _, _ in reader })
        func exchange(_ request: Request) throws -> Reply {
            var pair: [Int32] = [-1, -1]
            XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
            defer { close(pair[0]); close(pair[1]) }
            try SocketIO.configure(pair[0]); try SocketIO.configure(pair[1])
            try SocketIO.write(JSONEncoder().encode(request), fd: pair[0], deadline: ProcessInfo.processInfo.systemUptime + 1)
            server.handle(pair[1], started: ProcessInfo.processInfo.systemUptime)
            return try JSONDecoder().decode(Reply.self, from: SocketIO.read(fd: pair[0], deadline: ProcessInfo.processInfo.systemUptime + 1))
        }
        var camera = CameraTests().camera(); camera.enabled = false
        _ = try server.cameras.add(camera)
        let setup = try XCTUnwrap(exchange(.init(protocolVersion: 1, operation: S3SetupJobs.startOperation, store: c)).setup)
        try await helper.eventually {
            try exchange(.init(protocolVersion: 1, operation: "stores.setup.poll", setupID: setup.id)).setup?.state == "validated"
        }
        let committed = try exchange(.init(protocolVersion: 1, operation: "stores.setup.commit", setupID: setup.id))
        XCTAssertNil(committed.error)
        let job = try XCTUnwrap(exchange(.init(protocolVersion: 1, operation: "stores.repair.start.v1", storeID: c.id)).repair)
        try await helper.eventually { await reader.listCalls == 1 }
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<10 {
            XCTAssertTrue(try exchange(.init(protocolVersion: 1, operation: "status")).status?.ready == true)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        for operation in ["stores.disable", "stores.remove", "stores.spool.on"] {
            XCTAssertTrue(try exchange(.init(protocolVersion: 1, operation: operation, storeID: c.id)).error?.contains("repair is active") == true)
        }
        let cancelled = try exchange(.init(protocolVersion: 1, operation: "stores.repair.cancel", repairID: job.id))
        XCTAssertEqual(cancelled.repair?.state, "cancelled")
        XCTAssertNil(try exchange(.init(protocolVersion: 1, operation: "stores.disable", storeID: c.id)).error)
        XCTAssertEqual(try server.stores.list().first?.s3?.credentials, c.s3?.credentials)
    }
    func testRecoverRealH264HEVCFullAndShortShardsIncludingEncrypted() async throws {
        for codec in [kCMVideoCodecType_H264, kCMVideoCodecType_HEVC] {
            for count in [1, 45] {
                let c = try config(), camera = UUID().uuidString
                let samples = try StoreTests.video(codec: codec, count: count), first = try XCTUnwrap(samples.first)
                let timing = metadata(c, camera: camera).timing!
                let writer = try MemoryMP4Shard(codec: first.codec, sets: first.parameterSets, clock: first.clockRate,
                    timestamp: first.frame.timestamp, timing: timing)
                for sample in samples { try writer.append(sample.frame) }
                let data = try writer.finish()
                let encrypted = count == 1
                let bytes = try encrypted ? RecordingEncryption.encrypt(data, password: "repair-password") : data
                let m = S3ShardMetadata.make(store: c, camera: camera, name: "Previous Name",
                    capturedAt: Date(timeIntervalSince1970: timing.time.canonicalUTC), data: bytes, encrypted: encrypted, id: timing.shardID)
                let candidate = try XCTUnwrap(S3RepairCandidate.parse(object(m), prefix: c.s3!.prefix, cameras: [camera]))
                let repaired = try await S3RepairMedia.inspect(bytes, candidate: candidate, store: c, passwords: ["wrong", "repair-password"])
                XCTAssertEqual(repaired.timing, timing); XCTAssertEqual(repaired.key, m.key)
                XCTAssertEqual(repaired.sha256, S3ShardMetadata.hash(bytes))
                XCTAssertEqual(try XCTUnwrap(repaired.endTicks), writer.endTicks, accuracy: 1)
            }
        }
    }
    func testLegacyAndMismatchedMediaHaveNoRepairMetadata() async throws {
        let c = try config(), camera = UUID().uuidString, samples = try StoreTests.video(count: 2)
        let first = try XCTUnwrap(samples.first)
        for timing in [nil, metadata(c, camera: UUID().uuidString).timing] {
            let writer = try MemoryMP4Shard(codec: first.codec, sets: first.parameterSets, clock: first.clockRate, timestamp: first.frame.timestamp, timing: timing)
            for sample in samples { try writer.append(sample.frame) }
            let bytes = try writer.finish(), m = S3ShardMetadata.make(store: c, camera: camera, name: "Camera", capturedAt: Date(), data: bytes)
            let candidate = try XCTUnwrap(S3RepairCandidate.parse(object(m), prefix: c.s3!.prefix, cameras: [camera]))
            do { _ = try await S3RepairMedia.inspect(bytes, candidate: candidate, store: c, passwords: []); XCTFail("Must not fabricate timing") }
            catch let reason as S3RepairSkip { XCTAssertEqual(reason, timing == nil ? .legacyOrInvalidTiming : .identityMismatch) }
        }
    }
}
