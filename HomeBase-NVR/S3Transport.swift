import Foundation
import CryptoKit
import AWSS3
import AWSSDKIdentity
import Smithy
import SmithyStreams
import SmithyHTTPAPI
import SmithyHTTPClientAPI
import SmithyIdentity
import ClientRuntime
import enum AwsCommonRuntimeKit.CommonRunTimeError
import struct AwsCommonRuntimeKit.CRTError

protocol S3Transport: Sendable {
    func validate(_ configuration: S3Configuration) async throws
    func upload(_ metadata: S3ShardMetadata, payload: S3Payload) async throws
    func reconcile(_ configuration: RecordingStoreConfiguration) async throws
}
typealias S3TransportFactory = @Sendable (S3Configuration) async throws -> any S3Transport

/// A guard ahead of SDK deserialization: unknown XML must not disappear in a
/// read/merge/write lifecycle round trip. No object data is ever fetched here.
enum S3LifecycleXML {
    static let children: [String: Set<String>] = [
        "LifecycleConfiguration": ["Rule"],
        "Rule": ["ID", "Status", "Prefix", "Filter", "Expiration", "Transition", "NoncurrentVersionExpiration", "NoncurrentVersionTransition", "AbortIncompleteMultipartUpload"],
        "Filter": ["Prefix", "Tag", "And", "ObjectSizeGreaterThan", "ObjectSizeLessThan"],
        "And": ["Prefix", "Tag", "ObjectSizeGreaterThan", "ObjectSizeLessThan"], "Tag": ["Key", "Value"],
        "Expiration": ["Days", "Date", "ExpiredObjectDeleteMarker"], "Transition": ["Days", "Date", "StorageClass"],
        "NoncurrentVersionExpiration": ["NoncurrentDays", "NewerNoncurrentVersions"],
        "NoncurrentVersionTransition": ["NoncurrentDays", "NewerNoncurrentVersions", "StorageClass"],
        "AbortIncompleteMultipartUpload": ["DaysAfterInitiation"]
    ]
    static func validate(_ data: Data) throws {
        guard data.count <= 2 * 1024 * 1024, !String(decoding: data, as: UTF8.self).contains("<!DOCTYPE") else { throw ServiceError("Unsupported lifecycle XML; refusing to rewrite it.") }
        let doc = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        guard let root = doc.rootElement(), root.name == "LifecycleConfiguration" else { throw ServiceError("Unexpected lifecycle configuration.") }
        func visit(_ node: XMLElement) throws {
            guard (node.attributes ?? []).isEmpty else { throw ServiceError("Unsupported lifecycle attributes; refusing to rewrite them.") }
            for child in (node.children ?? []).compactMap({ $0 as? XMLElement }) {
                guard children[node.name ?? "", default: []].contains(child.name ?? "") else { throw ServiceError("Unsupported lifecycle setting; configure retention externally.") }
                try visit(child)
            }
        }
        try visit(root)
    }
}

private struct S3GuardedHTTP: HTTPClient {
    let underlying: any HTTPClient
    let timeout: Double
    let region: String
    func send(request: HTTPRequest) async throws -> HTTPResponse {
        try await withThrowingTaskGroup(of: HTTPResponse.self) { group in
            group.addTask {
                let response = try await underlying.send(request: request)
                // These APIs return only metadata, never object bodies. Include
                // response consumption in the request deadline, with a hard bound.
                var data = Data()
                switch response.body {
                case .data(let body): data = body ?? Data()
                case .stream(let stream):
                    while let chunk = try await stream.readAsync(upToCount: 65536), !chunk.isEmpty {
                        data.append(chunk)
                        guard data.count <= 2 * 1024 * 1024 else { throw S3Failure(kind: .transient, message: "Oversized S3 metadata response; will retry.") }
                    }
                case .noStream: break
                }
                guard data.count <= 2 * 1024 * 1024 else { throw S3Failure(kind: .transient, message: "Oversized S3 metadata response; will retry.") }
                response.body = .data(data)
                return response
            }
            group.addTask { try await Task.sleep(for: .seconds(timeout)); throw S3Failure(kind: .transient, message: "S3 HTTP request deadline exceeded.") }
            defer { group.cancelAll() }
            let response = try await group.next()!
            if let actual = response.headers.value(for: "x-amz-bucket-region"), actual != region {
                throw S3Failure(kind: .destination, message: "Bucket region differs from configured region.")
            }
            if request.method == .get, request.queryItems?.contains(where: { $0.name == "lifecycle" }) == true,
               response.statusCode.rawValue == 200 {
                let data = try await response.body.readData() ?? Data()
                try S3LifecycleXML.validate(data); response.body = .data(data)
            }
            return response
        }
    }
}

/// No SDK retries and no ambient credential resolution. Error diagnostics never
/// interpolate SDK request/response descriptions (which can include secrets).
struct AWSS3Transport: S3Transport {
    let client: S3Client
    let configuration: S3Configuration
    static let make: S3TransportFactory = {
        do { return try await AWSS3Transport(configuration: $0) }
        catch { throw S3Failure(kind: .destination, message: "Cannot initialize the S3 client; check the stored destination and credentials.") }
    }
    init(configuration: S3Configuration, httpClient: (any HTTPClient)? = nil) async throws {
        try configuration.validate(requireCredentials: true)
        let keys = configuration.credentials!
        let identity = AWSCredentialIdentity(accessKey: keys.accessKeyID, secret: keys.secretAccessKey)
        let resolver = StaticAWSCredentialIdentityResolver(identity)
        let http = HttpClientConfiguration(connectTimeout: min(30, configuration.settings.requestTimeout), socketTimeout: configuration.settings.requestTimeout)
        var config = try await S3Client.S3ClientConfig(awsCredentialIdentityResolver: resolver, maxAttempts: 1,
            ignoreConfiguredEndpointURLs: true, region: configuration.region, useGlobalEndpoint: false,
            clientLogMode: ClientLogMode.none, httpClientEngine: httpClient, httpClientConfiguration: http)
        config.httpClientEngine = S3GuardedHTTP(underlying: config.httpClientEngine, timeout: configuration.settings.requestTimeout, region: configuration.region)
        client = S3Client(config: config); self.configuration = configuration
    }
    func validate(_ config: S3Configuration) async throws {
        do {
            let versioning = try await client.getBucketVersioning(input: .init(bucket: config.bucket, expectedBucketOwner: config.expectedOwner))
            guard versioning.status == nil, versioning.mfaDelete == nil else { throw S3Failure(kind: .destination, message: "S3 store requires a never-versioned bucket (Suspended is not supported).") }
            let encryption = try await client.getBucketEncryption(input: .init(bucket: config.bucket, expectedBucketOwner: config.expectedOwner))
            guard let rules = encryption.serverSideEncryptionConfiguration?.rules, rules.count == 1,
                  rules[0].applyServerSideEncryptionByDefault?.sseAlgorithm == .aes256,
                  rules[0].applyServerSideEncryptionByDefault?.kmsMasterKeyID == nil else {
                throw S3Failure(kind: .destination, message: "S3 store requires bucket-default SSE-S3 (AES256), not KMS.")
            }
        } catch { throw Self.classify(error) }
    }
    static func partSize(_ size: Int64) -> Int { Int(max(16 * 1024 * 1024, (size + 9999) / 10000)) }
    func upload(_ m: S3ShardMetadata, payload: S3Payload) async throws {
        guard m.bucket == configuration.bucket, m.region == configuration.region, m.expectedOwner == configuration.expectedOwner,
              m.prefix == configuration.prefix, m.key.hasPrefix(configuration.prefix), m.size == payload.size else { throw S3Failure(kind: .localRead, message: "Frozen shard destination or size does not match this store; retained for retry after repair.") }
        do {
            if m.size < 64 * 1024 * 1024 {
                let body: ByteStream
                let checksum: String?
                let algorithm: S3ClientTypes.ChecksumAlgorithm?
                switch payload {
                case .memory(let data):
                    body = .data(data)
                    let hashBytes = stride(from: 0, to: m.sha256.count, by: 2).compactMap { i -> UInt8? in
                        let start = m.sha256.index(m.sha256.startIndex, offsetBy: i)
                        return UInt8(m.sha256[start..<m.sha256.index(start, offsetBy: 2)], radix: 16)
                    }
                    checksum = Data(hashBytes).base64EncodedString()
                    algorithm = nil
                case .file(let path, _, let identity):
                    body = .stream(FileStream(fileHandle: FileHandle(fileDescriptor: try S3Spool.openFile(path, expectedIdentity: identity), closeOnDealloc: true)))
                    // In SDK 1.7.78, a supplied checksum header skips the middleware
                    // that installs aws-chunked framing, while file signing still
                    // wraps the body in chunks. Ask the SDK to calculate SHA-256
                    // incrementally and send its trailer so framing/signing agree.
                    // Do not buffer the file or patch signed headers after signing.
                    checksum = nil
                    algorithm = .sha256
                }
                _ = try await client.putObject(input: .init(body: body, bucket: m.bucket, checksumAlgorithm: algorithm, checksumSHA256: checksum,
                    contentLength: Int(m.size), contentType: m.contentType, expectedBucketOwner: m.expectedOwner, key: m.key,
                    serverSideEncryption: .aes256, storageClass: .standard))
                return
            }
            let created = try await client.createMultipartUpload(input: .init(bucket: m.bucket, checksumAlgorithm: .sha256,
                contentType: m.contentType, expectedBucketOwner: m.expectedOwner, key: m.key, serverSideEncryption: .aes256, storageClass: .standard))
            guard let uploadID = created.uploadId else { throw S3Failure(kind: .transient, message: "S3 omitted multipart upload identity.") }
            do {
                var parts: [S3ClientTypes.CompletedPart] = [], offset: Int64 = 0
                let partSize = Self.partSize(m.size)
                while offset < m.size {
                    try Task.checkCancellation()
                    let data = try payload.read(offset: offset, count: Int(min(Int64(partSize), m.size - offset)))
                    let checksum = Data(SHA256.hash(data: data)).base64EncodedString()
                    let number = parts.count + 1
                    let output = try await client.uploadPart(input: .init(body: .data(data), bucket: m.bucket, checksumSHA256: checksum,
                        contentLength: data.count, expectedBucketOwner: m.expectedOwner, key: m.key, partNumber: number, uploadId: uploadID))
                    guard let etag = output.eTag else { throw S3Failure(kind: .transient, message: "S3 omitted part acknowledgment.") }
                    parts.append(.init(checksumSHA256: checksum, eTag: etag, partNumber: number)); offset += Int64(data.count)
                }
                _ = try await client.completeMultipartUpload(input: .init(bucket: m.bucket, expectedBucketOwner: m.expectedOwner,
                    key: m.key, multipartUpload: .init(parts: parts), uploadId: uploadID))
            } catch {
                // Do not hide the original outage behind a slow cleanup request.
                // Cleanup has no video body, is best effort, and doesn't delay
                // spooling or shutdown; lifecycle is the crash/failure fallback.
                let abort = AbortMultipartUploadInput(bucket: m.bucket, expectedBucketOwner: m.expectedOwner, key: m.key, uploadId: uploadID)
                Task { [client] in _ = try? await client.abortMultipartUpload(input: abort) }
                throw error
            }
        } catch { throw Self.classify(error) }
    }
    func reconcile(_ store: RecordingStoreConfiguration) async throws {
        guard let s3 = store.s3, s3.lifecycle == "Managed" else { return }
        // A failed draft can be saved disabled, and an administrator can change a
        // bucket later. Never rewrite lifecycle on an incompatible destination.
        try await validate(s3)
        try Task.checkCancellation()
        let before: GetBucketLifecycleConfigurationOutput
        do { before = try await client.getBucketLifecycleConfiguration(input: .init(bucket: s3.bucket, expectedBucketOwner: s3.expectedOwner)) }
        catch {
            guard (error as? ClientRuntime.ServiceError)?.typeName == "NoSuchLifecycleConfiguration" else { throw Self.classify(error) }
            before = .init(rules: [])
        }
        let id = S3Configuration.ruleID(store.id)
        var rules = before.rules ?? []
        guard rules.count < 1000 || rules.contains(where: { $0.id == id }) else { throw ServiceError("Bucket lifecycle rule limit reached.") }
        // Unknown enum cases cannot be safely interpreted during a merge.
        guard !String(reflecting: before).contains("sdkUnknown") else { throw ServiceError("Unsupported lifecycle values; configure retention externally.") }
        if let existing = rules.first(where: { $0.id == id }), existing.filter?.prefix != s3.prefix {
            throw ServiceError("Lifecycle rule ID belongs to another prefix; refusing to replace it.")
        }
        let desired = S3ClientTypes.LifecycleRule(abortIncompleteMultipartUpload: .init(daysAfterInitiation: 1),
            expiration: .init(days: store.retentionDays), filter: .init(prefix: s3.prefix), id: id, status: .enabled)
        rules.removeAll { $0.id == id }; rules.append(desired)
        try Task.checkCancellation()
        if String(reflecting: before.rules ?? []) != String(reflecting: rules) {
            _ = try await client.putBucketLifecycleConfiguration(input: .init(bucket: s3.bucket, expectedBucketOwner: s3.expectedOwner,
                lifecycleConfiguration: .init(rules: rules), transitionDefaultMinimumObjectSize: before.transitionDefaultMinimumObjectSize))
        }
        try Task.checkCancellation()
        let after = try await client.getBucketLifecycleConfiguration(input: .init(bucket: s3.bucket, expectedBucketOwner: s3.expectedOwner))
        guard String(reflecting: after.rules ?? []) == String(reflecting: rules),
              before.transitionDefaultMinimumObjectSize == nil || before.transitionDefaultMinimumObjectSize == after.transitionDefaultMinimumObjectSize else {
            throw ServiceError("Lifecycle verification differed; an external administrator may have changed the bucket. Retention is unverified.")
        }
    }
    static func classify(_ error: Error) -> S3Failure {
        if let failure = error as? S3Failure { return failure }
        if let failure = error as? ServiceError { return S3Failure(kind: .localRead, message: failure.message) }
        let rawCode = (error as? ClientRuntime.ServiceError)?.typeName ?? ""
        // Preserve actionable AWS codes, never arbitrary response text/headers.
        let code = rawCode.count <= 80 && rawCode.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) ? rawCode : ""
        let redline = ["AccessDenied", "InvalidAccessKeyId", "SignatureDoesNotMatch", "ExpiredToken", "InvalidToken", "NoSuchBucket", "PermanentRedirect", "AuthorizationHeaderMalformed", "InvalidBucketState", "AllAccessDisabled"]
        if redline.contains(code) { return S3Failure(kind: .destination, message: "S3 rejected the destination or credentials (\(code)).") }
        let transient = ["InternalError", "ServiceUnavailable", "SlowDown", "RequestTimeout", "OperationAborted", "NoSuchUpload"]
        if transient.contains(code) { return S3Failure(kind: .transient, message: "S3 temporarily failed (\(code)).") }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain || ns.domain == NSPOSIXErrorDomain {
            return S3Failure(kind: .localRead, message: "Local upload read failed (\(ns.domain) \(ns.code)); file retained for retry.")
        }
        if case CommonRunTimeError.crtError(let crt) = error,
           ["AWS_IO_SOCKET_NETWORK_DOWN", "AWS_IO_SOCKET_NO_ROUTE_TO_HOST", "AWS_IO_SOCKET_NOT_CONNECTED", "AWS_IO_SOCKET_CONNECTION_REFUSED", "AWS_IO_DNS_QUERY_FAILED"].contains(crt.name) {
            return S3Failure(kind: .network, message: "S3 network is unavailable (\(crt.name)).")
        }
        if ns.domain == NSURLErrorDomain, [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost].contains(ns.code) {
            return S3Failure(kind: .network, message: "S3 network is unavailable.")
        }
        if let http = error as? HTTPError {
            let status = http.httpResponse.statusCode.rawValue
            let detail = code.isEmpty ? "HTTP \(status)" : "\(code), HTTP \(status)"
            if status == 403 || status == 401 { return S3Failure(kind: .destination, message: "S3 denied this upload (\(detail)); check bucket and credential permissions. Will retry.") }
            return S3Failure(kind: .transient, message: "S3 request failed (\(detail)); footage retained and will retry.")
        }
        if !code.isEmpty { return S3Failure(kind: .transient, message: "S3 request failed (\(code)); footage retained and will retry.") }
        return S3Failure(kind: .transient, message: "S3 request failed; delivery is unconfirmed and footage is retained.")
    }
}

/// Actor reentrancy alone is not a lock across await. Explicit bucket gates
/// serialize whole read/merge/write/verify transactions within this daemon.
actor S3LifecycleCoordinator {
    static let shared = S3LifecycleCoordinator()
    private var busy = Set<String>()
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    func reconcile(_ config: RecordingStoreConfiguration, transport: any S3Transport) async throws {
        guard config.s3?.lifecycle == "Managed", let bucket = config.s3?.bucket else { return }
        if busy.contains(bucket) { await withCheckedContinuation { waiters[bucket, default: []].append($0) } }
        else { busy.insert(bucket) }
        defer {
            if var queue = waiters[bucket], !queue.isEmpty { let next = queue.removeFirst(); waiters[bucket] = queue; next.resume() }
            else { busy.remove(bucket) }
        }
        try Task.checkCancellation()
        try await transport.reconcile(config)
    }
}
