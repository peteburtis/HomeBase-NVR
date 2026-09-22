import Foundation
import CryptoKit
import AWSS3
import AWSSDKIdentity
import Smithy
import SmithyIdentity
import SmithyHTTPAPI
import SmithyHTTPClientAPI
import ClientRuntime

/// Ephemeral repair credentials, never part of persisted store configuration.
struct S3RepairCredentials: Codable, Sendable {
    let accessKeyID: String
    let secretAccessKey: String
    var sessionToken: String? = nil
    func validate() throws {
        guard CameraConfiguration.printable(accessKeyID, limit: 256), !accessKeyID.isEmpty,
              CameraConfiguration.printable(secretAccessKey, limit: 1024), !secretAccessKey.isEmpty,
              sessionToken.map({ !$0.isEmpty && CameraConfiguration.printable($0, limit: 16384) }) ?? true else {
            throw ServiceError("Invalid repair credentials.")
        }
    }
}
struct S3RepairObject: Equatable, Sendable {
    let key: String
    let size: Int64
    let etag: String
}
struct S3RepairPage: Sendable { let objects: [S3RepairObject]; let next: String? }
protocol S3RepairReading: Sendable {
    func list(after: String?) async throws -> S3RepairPage
    func read(_ object: S3RepairObject) async throws -> Data
    func readIndexed(_ shard: S3PlaybackShard) async throws -> Data
}
extension S3RepairReading {
    func readIndexed(_ shard: S3PlaybackShard) async throws -> Data { throw S3RepairFailure.unavailable }
}
typealias S3RepairReaderFactory = @Sendable (S3Configuration, S3RepairCredentials) async throws -> any S3RepairReading

/// Only constructed from fixed messages, numeric counts and hashed ETags.
/// Safe to return over authenticated IPC and include in daemon diagnostics.
struct S3RepairReadFailure: Error, LocalizedError, Sendable {
    enum Reason: String, Sendable { case notFound, preconditionFailed, sizeMismatch, etagMissing, etagMismatch }
    let reason: Reason
    let detail: String
    var errorDescription: String? { detail }

    static func http(_ response: HTTPURLResponse) -> Self? {
        let reason: Reason
        switch response.statusCode {
        case 404: reason = .notFound
        case 412: reason = .preconditionFailed
        default: return nil
        }
        let explanation = reason == .notFound ? "S3 could not find the requested object." : "S3 rejected If-Match for the ETag from the listing."
        return .init(reason: reason, detail: "GetObject returned HTTP \(response.statusCode). \(explanation)")
    }

    static func size(expected: Int64, actual: Int) -> Self {
        .init(reason: .sizeMismatch, detail: "Media inspection received \(actual) bytes; the listing reported \(expected) bytes.")
    }

    static func validate(_ data: Data, object: S3RepairObject, etag: String?, contentLength: Int?) throws {
        let reason: Reason
        if Int64(data.count) != object.size { reason = .sizeMismatch }
        else if etag == nil { reason = .etagMissing }
        else if etag != object.etag { reason = .etagMismatch }
        else { return }
        let length = contentLength.map(String.init) ?? "absent"
        let tags = "listed ETag [\(describeETag(object.etag))]; returned ETag [\(describeETag(etag))]"
        let match = etag.map { $0 == object.etag ? "yes" : "no" } ?? "absent"
        throw Self(reason: reason, detail: "GetObject succeeded (HTTP 200), but validation failed: listed bytes=\(object.size), received bytes=\(data.count), Content-Length=\(length); ETags equal=\(match); \(tags).")
    }

    private static func describeETag(_ value: String?) -> String {
        guard let value else { return "absent" }
        // Never print raw header values: they are remote, untrusted text.
        let fingerprint = SHA256.hash(data: Data(value.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let quoted = value.hasPrefix("\"") && value.hasSuffix("\"")
        return "utf8=\(value.utf8.count), quoted=\(quoted), sha256-prefix=\(fingerprint)"
    }
}

enum S3RepairFailure: Error, LocalizedError {
    case credentials, password, changed, unavailable, tooLarge, invalidResponse
    var errorDescription: String? {
        switch self {
        case .credentials: "S3 denied repair access. Supply temporary ListBucket/GetObject credentials for this store."
        case .password: "An encrypted recording could not be authenticated. Supply its original encryption password, or skip it."
        case .changed: "The object changed or disappeared during repair; it was left untouched."
        case .unavailable: "S3 repair could not reach the configured destination. Check the network, region, and expected owner; retry later."
        case .tooLarge: "The object exceeds the 256 MiB repair limit; it was left untouched."
        case .invalidResponse: "S3 returned an invalid or oversized repair response."
        }
    }
    static func sanitize(_ error: Error) -> Error {
        if error is CancellationError { return CancellationError() }
        if let known = error as? Self { return known }
        if let read = error as? S3RepairReadFailure { return read }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return CancellationError() }
        return Self.unavailable // Never expose SDK descriptions, keys, headers, URLs or secrets.
    }
}

struct AWSS3RepairReader: S3RepairReading {
    static let maximumObjectBytes = 256 * 1024 * 1024
    static let make: S3RepairReaderFactory = { config, keys in
        try config.validate(); try keys.validate()
        return AWSS3RepairReader(configuration: config, credentials: keys)
    }
    let configuration: S3Configuration
    let credentials: S3RepairCredentials
    var httpFactory: @Sendable (S3Configuration, String?, Int) -> any HTTPClient = {
        S3RepairHTTP(configuration: $0, key: $1, maximumBytes: $2)
    }

    func client(engine: any HTTPClient) async throws -> S3Client {
        let identity = AWSCredentialIdentity(accessKey: credentials.accessKeyID, secret: credentials.secretAccessKey,
                                             sessionToken: credentials.sessionToken)
        var config = try await S3Client.S3ClientConfig(useFIPS: false, useDualStack: false,
            awsCredentialIdentityResolver: StaticAWSCredentialIdentityResolver(identity), maxAttempts: 1,
            ignoreConfiguredEndpointURLs: true, region: configuration.region, forcePathStyle: true, useArnRegion: false,
            disableMultiRegionAccessPoints: true, accelerate: false, disableS3ExpressSessionAuth: true,
            useGlobalEndpoint: false, clientLogMode: ClientLogMode.none, httpClientEngine: engine,
            httpClientConfiguration: HttpClientConfiguration(connectTimeout: 15, socketTimeout: 60))
        config.logger = S3RepairSilentLogger()
        return S3Client(config: config)
    }
    func list(after: String?) async throws -> S3RepairPage {
        // URL encoding makes arbitrary unexpected S3 keys safe for XML parsing.
        // 1,000 maximum-length percent-encoded keys can exceed 3 MiB.
        let engine = httpFactory(configuration, nil, 4 * 1024 * 1024)
        defer { (engine as? S3RepairHTTP)?.close() }
        do {
            let output = try await client(engine: engine).listObjectsV2(input: .init(bucket: configuration.bucket,
                continuationToken: after, encodingType: .url, expectedBucketOwner: configuration.expectedOwner, maxKeys: 1000, prefix: configuration.prefix))
            try Task.checkCancellation()
            guard output.encodingType == .url, (output.contents?.count ?? 0) <= 1000,
                  output.isTruncated != true || output.nextContinuationToken?.isEmpty == false,
                  (output.nextContinuationToken?.utf8.count ?? 0) <= 16384 else { throw S3RepairFailure.invalidResponse }
            let objects = try (output.contents ?? []).map { value -> S3RepairObject in
                guard let key = value.key.flatMap(Self.decodeListedKey), let size = value.size, let etag = value.eTag,
                      key.utf8.count <= 1024, key.utf8.starts(with: configuration.prefix.utf8), size >= 0,
                      !etag.isEmpty, etag.utf8.count <= 256,
                      etag.rangeOfCharacter(from: .controlCharacters) == nil else { throw S3RepairFailure.invalidResponse }
                return .init(key: key, size: Int64(size), etag: etag)
            }
            return .init(objects: objects, next: output.isTruncated == true ? output.nextContinuationToken : nil)
        } catch { throw S3RepairFailure.sanitize(error) }
    }
    /// Only ListObjectsV2's EncodingType=url response uses this form-style
    /// decoding. Replace bare '+' BEFORE percent decoding so literal %2B stays
    /// '+', and decode exactly once so a literal %20 in an object name survives.
    /// SDK request paths/queries and keys in JSON are NOT form-encoded.
    static func decodeListedKey(_ value: String) -> String? {
        value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }
    func read(_ object: S3RepairObject) async throws -> Data {
        guard object.size > 0, object.size <= Self.maximumObjectBytes else { throw S3RepairFailure.tooLarge }
        guard object.key.utf8.starts(with: configuration.prefix.utf8), object.key.utf8.count <= 1024,
              !object.key.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw S3RepairFailure.invalidResponse }
        let engine = httpFactory(configuration, object.key, Int(object.size))
        defer { (engine as? S3RepairHTTP)?.close() }
        do {
            let output = try await client(engine: engine).getObject(input: .init(bucket: configuration.bucket,
                expectedBucketOwner: configuration.expectedOwner, ifMatch: object.etag, key: object.key))
            let data = try await output.body?.readData() ?? Data()
            try Task.checkCancellation()
            try S3RepairReadFailure.validate(data, object: object, etag: output.eTag, contentLength: output.contentLength)
            return data
        } catch { throw S3RepairFailure.sanitize(error) }
    }
    /// Manifest-bound GET for exact frame addressing; no ListBucket needed.
    func readIndexed(_ shard: S3PlaybackShard) async throws -> Data {
        guard shard.size > 0, shard.size <= Self.maximumObjectBytes,
              shard.key.hasPrefix(configuration.prefix), shard.key.utf8.count <= 1024,
              !shard.key.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw S3RepairFailure.tooLarge }
        let engine = httpFactory(configuration, shard.key, Int(shard.size))
        defer { (engine as? S3RepairHTTP)?.close() }
        do {
            let output = try await client(engine: engine).getObject(input: .init(bucket: configuration.bucket,
                expectedBucketOwner: configuration.expectedOwner, key: shard.key))
            let data = try await output.body?.readData() ?? Data()
            guard data.count == shard.size, S3ObjectMetadata.hash(data) == shard.sha256 else { throw S3RepairFailure.changed }
            return data
        } catch { throw S3RepairFailure.sanitize(error) }
    }
    static func iamPolicy(_ config: S3Configuration) throws -> String {
        let policy: [String: Any] = ["Version": "2012-10-17", "Statement": [
            ["Effect": "Allow", "Action": ["s3:ListBucket"], "Resource": "arn:" + config.partition + ":s3:::" + config.bucket,
             "Condition": ["StringEquals": ["s3:prefix": config.prefix]]] as [String: Any],
            ["Effect": "Allow", "Action": ["s3:GetObject"], "Resource": "arn:" + config.partition + ":s3:::" + config.bucket + "/" + config.prefix + "*"]
        ]]
        return String(decoding: try JSONSerialization.data(withJSONObject: policy, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
    }
}

/// Scoped GET-only adapter for SDK signing. No redirects, ambient credentials,
/// disk caches or request logs. Limits apply before SDK XML/body deserialization.
final class S3RepairHTTP: NSObject, HTTPClient, URLSessionDataDelegate, @unchecked Sendable {
    let configuration: S3Configuration
    let key: String?
    let maximumBytes: Int
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HTTPResponse, Error>?
    private var session: URLSession?
    private var response: HTTPURLResponse?
    private var bytes = Data()
    private var finished = false
    init(configuration: S3Configuration, key: String?, maximumBytes: Int) {
        self.configuration = configuration; self.key = key; self.maximumBytes = maximumBytes
    }
    static func encoded(_ value: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~/".utf8)
        return value.utf8.map { allowed.contains($0) ? String(UnicodeScalar($0)) : String(format: "%%%02X", $0) }.joined()
    }
    func urlRequest(_ request: HTTPRequest) throws -> URLRequest {
        let host = "s3.\(configuration.region).amazonaws.com" + (configuration.region.hasPrefix("cn-") ? ".cn" : "")
        let expectedPath = "/" + configuration.bucket + (key.map { "/" + Self.encoded($0) } ?? "")
        let query = request.queryItems ?? []
        guard request.method == .get, request.destination.scheme == .https,
              request.destination.host == host, request.destination.port == nil || request.destination.port == 443,
              request.destination.path == expectedPath else { throw S3RepairFailure.invalidResponse }
        if key != nil {
            guard query.count == 1, query[0].name == "x-id", query[0].value == "GetObject" else { throw S3RepairFailure.invalidResponse }
        } else {
            guard Set(query.map(\.name)).count == query.count,
                  query.allSatisfy({ ["list-type", "encoding-type", "prefix", "max-keys", "continuation-token", "x-id"].contains($0.name) }),
                  query.contains(where: { $0.name == "list-type" && $0.value == "2" }),
                  query.contains(where: { $0.name == "encoding-type" && $0.value == "url" }),
                  query.first(where: { $0.name == "prefix" })?.value?.removingPercentEncoding == configuration.prefix else { throw S3RepairFailure.invalidResponse }
        }
        var components = URLComponents(); components.scheme = "https"; components.host = host
        components.percentEncodedPath = request.destination.path
        components.percentEncodedQueryItems = query.map { URLQueryItem(name: $0.name, value: $0.value) }
        guard let url = components.url else { throw S3RepairFailure.invalidResponse }
        var result = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        result.httpMethod = "GET"
        for header in request.headers.headers { for value in header.value { result.addValue(value, forHTTPHeaderField: header.name) } }
        return result
    }
    func send(request: HTTPRequest) async throws -> HTTPResponse {
        let outgoing = try urlRequest(request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !finished, self.continuation == nil else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let config = URLSessionConfiguration.ephemeral
                config.urlCache = nil; config.urlCredentialStorage = nil; config.httpCookieStorage = nil
                config.requestCachePolicy = .reloadIgnoringLocalCacheData
                config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 60
                config.waitsForConnectivity = false
                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.dataTask(with: outgoing); lock.unlock(); task.resume()
            }
        } onCancel: { self.close() }
    }
    func close() { finish(.failure(CancellationError())) }
    private func finish(_ result: Result<HTTPResponse, Error>) {
        lock.lock(); guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation, session = self.session
        self.continuation = nil; self.session = nil; bytes = Data()
        lock.unlock(); session?.invalidateAndCancel(); continuation?.resume(with: result)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil); finish(.failure(S3RepairFailure.unavailable))
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else { completionHandler(.cancel); finish(.failure(S3RepairFailure.invalidResponse)); return }
        let failure: Error?
        if let region = response.value(forHTTPHeaderField: "x-amz-bucket-region"), region != configuration.region { failure = S3RepairFailure.unavailable }
        else {
            switch response.statusCode {
            case 200: failure = response.expectedContentLength > Int64(maximumBytes) ? S3RepairFailure.tooLarge : nil
            case 401, 403: failure = S3RepairFailure.credentials
            case 404, 412: failure = key == nil ? S3RepairFailure.changed : S3RepairReadFailure.http(response)
            default: failure = S3RepairFailure.unavailable
            }
        }
        if let failure { completionHandler(.cancel); finish(.failure(failure)); return }
        lock.lock(); self.response = response; lock.unlock(); completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); guard !finished else { lock.unlock(); return }
        guard data.count <= maximumBytes - bytes.count else { lock.unlock(); finish(.failure(S3RepairFailure.tooLarge)); return }
        bytes.append(data); lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(S3RepairFailure.sanitize(error))); return }
        lock.lock(); let response = self.response, data = bytes; lock.unlock()
        guard let response else { finish(.failure(S3RepairFailure.invalidResponse)); return }
        var headers = Headers()
        for (key, value) in response.allHeaderFields { if let key = key as? String { headers.add(name: key, value: String(describing: value)) } }
        finish(.success(HTTPResponse(headers: headers, body: .data(data), statusCode: .ok)))
    }
}
private struct S3RepairSilentLogger: LogAgent {
    let name = "S3Repair"
    func log(level: LogAgentLevel, message: @autoclosure () -> String, metadata: @autoclosure () -> [String: String]?,
             source: @autoclosure () -> String, file: String, function: String, line: UInt) {}
}
