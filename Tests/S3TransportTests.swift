import XCTest
import Foundation
import CryptoKit
import AWSS3
import SmithyHTTPAPI
import Smithy
@_spi(SmithyChecksums) import SmithyChecksums

/// Exercises the real SDK serialization/signing/checksum pipeline while replacing
/// only its HTTP engine. It cannot contact AWS or any other network destination.
actor S3HTTPFixture: HTTPClient {
    var calls: [(String, String)] = []
    var requestPaths: [String] = []
    var failureCode: String?
    var failureStatus: HTTPStatusCode = .forbidden
    var failPart = false
    var versioning = ""
    var lifecycle = "<LifecycleConfiguration xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Rule><ID>unrelated</ID><Status>Enabled</Status><Filter><Prefix>other/</Prefix></Filter><Expiration><Days>90</Days></Expiration></Rule></LifecycleConfiguration>"
    var lifecyclePuts = 0
    var missingLifecycle = false
    func setMissingLifecycle(_ missing: Bool) { missingLifecycle = missing }
    var ownerHeaders: [String?] = []
    var objectBodies: [Data] = []
    var objectTypes: [String?] = []
    var objectChecksums: [String?] = []
    var objectTrailers: [String?] = []
    var objectFraming: [String] = []
    var objectPaths: [String] = []
    var delay = 0.0
    func setDelay(_ delay: Double) { self.delay = delay }
    func setFailure(_ code: String?, status: HTTPStatusCode = .forbidden) { failureCode = code; failureStatus = status }
    func setFailPart(_ fail: Bool) { failPart = fail }
    func setVersioning(_ value: String) { versioning = value }
    func setLifecycle(_ value: String) { lifecycle = value }
    func send(request: HTTPRequest) async throws -> HTTPResponse {
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        let query = request.queryItems?.map(\.name).sorted().joined(separator: ",") ?? ""
        calls.append((request.method.rawValue, query))
        requestPaths.append(request.destination.path)
        ownerHeaders.append(request.headers.value(for: "x-amz-expected-bucket-owner"))
        if request.method == .put, !query.contains("lifecycle"), !query.contains("partNumber") {
            // Pull like a real HTTP engine, then validate framing before acting
            // like S3. Merely decoding ChunkedStream used to hide missing headers.
            var body = Data(), chunked = false
            switch request.body {
            case .data(let data): body = data ?? Data()
            case .stream(let stream):
                chunked = stream is ChunkedStream
                while let data = try await stream.readAsync(upToCount: 65536), !data.isEmpty { body.append(data) }
            case .noStream: break
            }
            let wireCount = body.count
            let encoding = request.headers.value(for: "content-encoding")
            let length = request.headers.value(for: "content-length").flatMap(Int.init)
            let transfer = request.headers.value(for: "transfer-encoding")
            let decodedLength = request.headers.value(for: "x-amz-decoded-content-length").flatMap(Int.init)
            var trailerChecksum: String?
            if chunked || encoding?.contains("aws-chunked") == true {
                var decoded = Data(), offset = 0, terminated = false
                while let end = body.range(of: Data([13, 10]), in: offset..<body.count) {
                    let header = String(decoding: body[offset..<end.lowerBound], as: UTF8.self).split(separator: ";")[0]
                    guard let size = Int(header, radix: 16), size >= 0 else { throw ServiceError("Invalid test HTTP chunk header.") }
                    offset = end.upperBound
                    if size == 0 {
                        terminated = true
                        for line in String(decoding: body[offset...], as: UTF8.self).components(separatedBy: "\r\n") {
                            let fields = line.split(separator: ":", maxSplits: 1)
                            if fields.count == 2, fields[0].lowercased() == "x-amz-checksum-sha256" { trailerChecksum = fields[1].trimmingCharacters(in: .whitespaces) }
                        }
                        break
                    }
                    guard size <= body.count - offset - 2 else { throw ServiceError("Truncated test HTTP chunk.") }
                    decoded.append(body[offset..<(offset + size)]); offset += size + 2
                }
                let valid = terminated && encoding?.contains("aws-chunked") == true && decodedLength == decoded.count &&
                    ((transfer?.lowercased() == "chunked" && length == nil) || (transfer == nil && length == wireCount))
                objectFraming.append("chunked: \(valid), length=\(String(describing: length)), transfer=\(transfer ?? "none"), decoded=\(String(describing: decodedLength))")
                guard valid else { return response("<Error><Code>MissingContentLength</Code></Error>", status: .lengthRequired) }
                body = decoded
            } else {
                objectFraming.append("fixed: \(length == wireCount && transfer == nil)")
                guard length == wireCount, transfer == nil else { return response("<Error><Code>MissingContentLength</Code></Error>", status: .lengthRequired) }
            }
            let checksum = request.headers.value(for: "x-amz-checksum-sha256") ?? trailerChecksum
            if checksum != Data(SHA256.hash(data: body)).base64EncodedString() {
                return response("<Error><Code>BadDigest</Code></Error>", status: .badRequest)
            }
            objectBodies.append(body)
            objectTypes.append(request.headers.value(for: "content-type"))
            objectChecksums.append(request.headers.value(for: "x-amz-checksum-sha256"))
            objectTrailers.append(trailerChecksum)
            objectPaths.append(request.endpoint.path)
        }
        if let failureCode { return response("<Error><Code>\(failureCode)</Code><Message>Test rejection</Message></Error>", status: failureStatus) }
        if query == "versioning" { return response("<VersioningConfiguration xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">\(versioning)</VersioningConfiguration>") }
        if query == "encryption" { return response("<ServerSideEncryptionConfiguration xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Rule><ApplyServerSideEncryptionByDefault><SSEAlgorithm>AES256</SSEAlgorithm></ApplyServerSideEncryptionByDefault></Rule></ServerSideEncryptionConfiguration>") }
        if query == "lifecycle" {
            if request.method == .put {
                lifecycle = String(decoding: try await request.body.readData() ?? Data(), as: UTF8.self)
                missingLifecycle = false
                lifecyclePuts += 1; return response("")
            }
            if missingLifecycle { return response("<Error><Code>NoSuchLifecycleConfiguration</Code><Message>Not configured</Message></Error>", status: .notFound) }
            let result = response(lifecycle)
            result.headers.add(name: "x-amz-transition-default-minimum-object-size", value: "varies_by_storage_class")
            return result
        }
        if query == "uploads" { return response("<InitiateMultipartUploadResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><UploadId>test-upload</UploadId></InitiateMultipartUploadResult>") }
        if query.contains("partNumber") {
            if failPart { return response("<Error><Code>InternalError</Code><Message>Part failed</Message></Error>", status: .internalServerError) }
            return response("")
        }
        if query == "uploadId", request.method == .post { return response("<CompleteMultipartUploadResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><ETag>test-etag</ETag></CompleteMultipartUploadResult>") }
        return response("")
    }
    private func response(_ xml: String, status: HTTPStatusCode = .ok) -> HTTPResponse {
        var headers = Headers(); headers.add(name: "etag", value: "test-etag"); headers.add(name: "x-amz-bucket-region", value: "us-west-2")
        return HTTPResponse(headers: headers, statusCode: status, body: .data(Data(xml.utf8)))
    }
}

final class S3TransportTests: XCTestCase {
    func testS3RejectionsRetainDiagnosticCodeAndRemainRetryable() async throws {
        let c = try config(), engine = S3HTTPFixture(), transport = try await AWSS3Transport(configuration: c.s3!, httpClient: engine)
        let data = Data("synthetic recording".utf8), metadata = S3ShardMetadata.make(store: c, camera: UUID().uuidString, name: "Test", capturedAt: Date(), data: data)
        for code in ["BadDigest", "InvalidRequest", "EntityTooSmall", "InvalidArgument"] {
            await engine.setFailure(code, status: .badRequest)
            do { try await transport.upload(metadata, payload: .memory(data)); XCTFail("Expected rejection") }
            catch {
                let failure = AWSS3Transport.classify(error)
                XCTAssertEqual(failure.kind, .transient)
                XCTAssertTrue(failure.message.contains(code), failure.message)
                XCTAssertTrue(failure.message.contains("400"), failure.message)
            }
        }
    }
    func config() throws -> RecordingStoreConfiguration { var c = try S3Tests().config(); c.s3?.expectedOwner = "123456789012"; return c }
    func testSDKPreservesRawKeysAcrossUploadReplayAndManifestPublication() async throws {
        var c = try config(); c.s3?.prefix = "Entrée + %20 &/"
        let engine = S3HTTPFixture(), transport = try await AWSS3Transport(configuration: c.s3!, httpClient: engine)
        let bytes = Data("synthetic encoded-key fixture".utf8), camera = UUID().uuidString
        let m = S3ShardMetadata.make(store: c, camera: camera, name: "Room + %2B #?", capturedAt: Date(), data: bytes)
        let root = "/private/tmp/hbnvr-key-spool-" + UUID().uuidString
        try SecureFiles.ensureDirectory(root, owner: geteuid(), mode: 0o700)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let spool = try S3Spool(path: root + "/spool", storeID: c.id, settings: c.s3!.settings)
        _ = try spool.publish(m, data: bytes)
        let restarted = try S3Spool(path: root + "/spool", storeID: c.id, settings: c.s3!.settings)
        let recovered = try XCTUnwrap(restarted.entries[m.id])
        XCTAssertEqual(recovered.metadata.key, m.key)
        try await transport.upload(m, payload: .memory(bytes))
        try await transport.upload(recovered.metadata, payload: recovered.payload)
        let key = S3PlaybackPublisher.root(prefix: c.s3!.prefix, camera: camera) + "catalog.json"
        try await transport.publishManifest(key: key, data: Data("{}".utf8), storeID: c.id, cameraID: camera)
        let paths = await engine.requestPaths
        XCTAssertEqual(paths, [m.key, m.key, key].map { "/" + S3RepairHTTP.encoded($0) })
        XCTAssertTrue(m.key.contains("Room + %2B #?"))
    }
    func testSDKUploadsFrozenCiphertextAndChecksumFromRAMAndDisk() async throws {
        // Current settings have no password: replay of an older encrypted shard
        // must still deliver its original body without decoding/re-encrypting it.
        let c = try config(), engine = S3HTTPFixture(), transport = try await AWSS3Transport(configuration: c.s3!, httpClient: engine)
        let bytes = try RecordingEncryption.encrypt(Data("synthetic footage".utf8), password: "old test password")
        let m = S3ShardMetadata.make(store: c, camera: UUID().uuidString, name: "Test", capturedAt: Date(), data: bytes, encrypted: true)
        let path = "/private/tmp/hbnvr-encrypted-transport-" + UUID().uuidString
        try SecureFiles.atomicWrite(bytes, to: path, mode: 0o600)
        defer { try? SecureFiles.removeFile(path) }
        try await transport.upload(m, payload: .memory(bytes))
        do { try await transport.upload(m, payload: .file(path, Int64(bytes.count))) }
        catch { let framing = await engine.objectFraming; XCTFail("Disk upload failed: \(error); framing: \(framing)"); throw error }
        let bodies = await engine.objectBodies, types = await engine.objectTypes, checksums = await engine.objectChecksums
        XCTAssertEqual(bodies, [bytes, bytes])
        XCTAssertEqual(types, ["application/octet-stream", "application/octet-stream"])
        let checksum = Data(SHA256.hash(data: bytes)).base64EncodedString()
        XCTAssertEqual(checksums, [checksum, nil])
        let trailers = await engine.objectTrailers; XCTAssertEqual(trailers, [nil, checksum])
    }
    func testSDKChecksBucketCompatibilityAndExpectedOwner() async throws {
        let c = try config(), engine = S3HTTPFixture(), transport = try await AWSS3Transport(configuration: c.s3!, httpClient: engine)
        try await transport.validate(c.s3!)
        let calls = await engine.calls; XCTAssertEqual(calls.map(\.1), ["versioning", "encryption"])
        let headers = await engine.ownerHeaders; XCTAssertTrue(headers.allSatisfy { $0 == "123456789012" })
        await engine.setVersioning("<Status>Suspended</Status>")
        do { try await transport.validate(c.s3!); XCTFail("Suspended bucket accepted") } catch { XCTAssertEqual(AWSS3Transport.classify(error).kind, .destination) }
    }
    func testDiskReplayFramingAtChunkBoundariesAndStableRetry() async throws {
        let c = try config()
        for size in [1, 65_535, 65_536, 65_537, 196_625] {
            let engine = S3HTTPFixture(), transport = try await AWSS3Transport(configuration: c.s3!, httpClient: engine)
            let bytes = Data((0..<size).map { UInt8($0 % 251) })
            let m = S3ShardMetadata.make(store: c, camera: UUID().uuidString, name: "Test", capturedAt: Date(), data: bytes)
            let path = "/private/tmp/hbnvr-framing-" + UUID().uuidString
            try SecureFiles.atomicWrite(bytes, to: path, mode: 0o600)
            defer { try? SecureFiles.removeFile(path) }
            await engine.setFailure("InternalError", status: .internalServerError)
            do { try await transport.upload(m, payload: .file(path, Int64(size))); XCTFail("Expected injected upload failure") }
            catch { XCTAssertTrue(AWSS3Transport.classify(error).message.contains("InternalError")) }
            await engine.setFailure(nil)
            try await transport.upload(m, payload: .file(path, Int64(size)))
            let bodies = await engine.objectBodies, trailers = await engine.objectTrailers, framing = await engine.objectFraming, paths = await engine.objectPaths
            XCTAssertEqual(bodies, [bytes, bytes])
            XCTAssertEqual(trailers, Array(repeating: Data(SHA256.hash(data: bytes)).base64EncodedString(), count: 2))
            XCTAssertEqual(framing.count, 2); XCTAssertTrue(framing.allSatisfy { $0.hasPrefix("chunked: true") }, framing.description)
            XCTAssertEqual(paths, Array(repeating: "/" + m.key, count: 2))
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes)
        }
    }
    func testSDKMultipartFailureAbortsWithoutAutonomousRetries() async throws {
        let c = try config(), engine = S3HTTPFixture(), transport = try await AWSS3Transport(configuration: c.s3!, httpClient: engine)
        await engine.setFailPart(true)
        let data = Data(repeating: 0, count: 64 * 1024 * 1024)
        let m = S3ShardMetadata.make(store: c, camera: UUID().uuidString, name: "Entrée + %20", capturedAt: Date(), data: data)
        do { try await transport.upload(m, payload: .memory(data)); XCTFail("Failure was swallowed") } catch { XCTAssertEqual(AWSS3Transport.classify(error).kind, .transient) }
        for _ in 0..<100 { if await engine.calls.count >= 3 { break }; try await Task.sleep(for: .milliseconds(10)) }
        let calls = await engine.calls
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls[0].1, "uploads"); XCTAssertTrue(calls[1].1.contains("partNumber")); XCTAssertEqual(calls[2].0, "DELETE")
        let abortedPaths = await engine.requestPaths
        XCTAssertEqual(abortedPaths, Array(repeating: "/" + S3RepairHTTP.encoded(m.key), count: 3))
        await engine.setFailPart(false)
        try await transport.upload(m, payload: .memory(data))
        let completedPaths = await engine.requestPaths, completedCalls = await engine.calls
        XCTAssertTrue(completedPaths.allSatisfy { $0 == "/" + S3RepairHTTP.encoded(m.key) })
        XCTAssertEqual(completedCalls.last?.0, "POST"); XCTAssertEqual(completedCalls.last?.1, "uploadId")
    }
    func testSDKLifecyclePreservesUnrelatedRuleAndVerifies() async throws {
        var c = try config(); c.s3?.lifecycle = "Managed"; c.s3?.prefix = "Entrée + %20 &/"
        let engine = S3HTTPFixture(), transport = try await AWSS3Transport(configuration: c.s3!, httpClient: engine)
        try await transport.reconcile(c)
        let xml = await engine.lifecycle
        XCTAssertTrue(xml.contains("unrelated")); XCTAssertTrue(xml.contains("other/")); XCTAssertTrue(xml.contains("<Days>90</Days>"))
        XCTAssertTrue(xml.contains("<Days>7</Days>")); XCTAssertTrue(xml.contains("<DaysAfterInitiation>1</DaysAfterInitiation>"))
        let document = try XMLDocument(xmlString: xml)
        let prefixes = try document.nodes(forXPath: "//*[local-name()='Prefix']").compactMap(\.stringValue)
        XCTAssertTrue(prefixes.contains(c.s3!.prefix), "Lifecycle XML must preserve the raw prefix, not URL/form-decode it")
        let puts = await engine.lifecyclePuts; XCTAssertEqual(puts, 1)
        try await transport.reconcile(c)
        let putsAgain = await engine.lifecyclePuts; XCTAssertEqual(putsAgain, 1)
        await engine.setLifecycle("<LifecycleConfiguration><Rule><FutureUnknownSetting>1</FutureUnknownSetting></Rule></LifecycleConfiguration>")
        do { try await transport.reconcile(c); XCTFail("Unsafe XML was rewritten") } catch { }
        let finalPuts = await engine.lifecyclePuts; XCTAssertEqual(finalPuts, 1)
    }
    func testExternalLifecycleMakesNoRequestsAndDeniedAccessIsClassified() async throws {
        let c = try config(), engine = S3HTTPFixture(), transport = try await AWSS3Transport(configuration: c.s3!, httpClient: engine)
        try await transport.reconcile(c)
        let calls = await engine.calls; XCTAssertTrue(calls.isEmpty)
        await engine.setFailure("AccessDenied")
        do { try await transport.validate(c.s3!); XCTFail("Denial accepted") } catch { XCTAssertEqual(AWSS3Transport.classify(error).kind, .destination) }
    }
    func testHTTPRequestDeadlineIsIndependentOfSDKRetries() async throws {
        var c = try config(); var tuning = S3Tuning(); tuning.requestTimeout = 1; c.s3?.tuning = tuning
        let engine = S3HTTPFixture(); await engine.setDelay(10)
        let transport = try await AWSS3Transport(configuration: c.s3!, httpClient: engine), started = Date()
        do { try await transport.validate(c.s3!); XCTFail("Expected timeout") } catch { XCTAssertEqual(AWSS3Transport.classify(error).kind, .transient) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }
    func testSDKCreatesMissingLifecycleAndRefusesVersionedBucket() async throws {
        var c = try config(); c.s3?.lifecycle = "Managed"
        let engine = S3HTTPFixture(); await engine.setMissingLifecycle(true)
        let transport = try await AWSS3Transport(configuration: c.s3!, httpClient: engine)
        try await transport.reconcile(c)
        let puts = await engine.lifecyclePuts; XCTAssertEqual(puts, 1)
        await engine.setVersioning("<Status>Enabled</Status>")
        do { try await transport.reconcile(c); XCTFail("Lifecycle was changed on an unsupported bucket") } catch { }
        let after = await engine.lifecyclePuts; XCTAssertEqual(after, 1)
    }
}
