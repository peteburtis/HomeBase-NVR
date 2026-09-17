import Foundation
import Darwin

enum StoreAdvancedOptions {
    static func hint(_ key: S3Tuning.CodingKeys) -> String? {
        switch key {
        case .concurrentUploads: return "total concurrent uploads, 2...64"
        case .reservedLiveSlots: return "live slots, 1..<ConcurrentUploads"
        case .transientFailureCount: return "failures before spooling, 1...1000"
        case .transientFailureWindow: return "failure window, 1s...1h"
        case .retryMaximumDelay: return "retry backoff ceiling, 1s...10m"
        case .probeInterval: return "recovery probe interval, 1s...1h"
        case .requestTimeout: return "individual HTTP deadline, 1s...1h"
        case .finalizedShardFloor: return "resident shard threshold floor, 2...10000"
        case .finalizedShardsPerCamera: return "resident shard threshold per camera, 1...100"
        case .queueAgeFloor: return "ready queue age floor, 1s...1d"
        case .spoolLimitBytes: return "per-store quota in bytes, positive"
        case .minimumFreeBytes: return "free target-volume reserve in bytes, zero or greater"
        case .spoolDirectory: return "default to reset"
        case .forceSpooling: return "hold new uploads and probes, yes/no"
        }
    }
    static func edit(_ current: S3Tuning, prompt: (String, String) throws -> String) throws -> S3Tuning {
        var values = try JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as! [String: Any]
        for key in S3Tuning.CodingKeys.allCases {
            let fallback: String
            if key == .spoolDirectory { fallback = current.spoolDirectory ?? "default" }
            else if key == .forceSpooling { fallback = current.forceSpooling ? "yes" : "no" }
            else { fallback = (values[key.rawValue] as! NSNumber).stringValue }
            let answer = try prompt(key.rawValue + (hint(key).map { " (" + $0 + ")" } ?? ""), fallback)
            let text = answer.isEmpty ? fallback : answer
            switch key {
            case .spoolDirectory:
                if text.lowercased() == "default" { values.removeValue(forKey: key.rawValue) }
                else { values[key.rawValue] = (text as NSString).expandingTildeInPath }
            case .forceSpooling:
                guard ["yes", "y", "no", "n"].contains(text.lowercased()) else { throw ServiceError("ForceSpooling must be yes or no.") }
                values[key.rawValue] = ["yes", "y"].contains(text.lowercased())
            case .transientFailureWindow, .retryMaximumDelay, .probeInterval, .requestTimeout, .queueAgeFloor:
                let seconds = try Double(text) ?? Double(IntervalText.seconds(text))
                guard seconds.isFinite else { throw ServiceError("\(key.rawValue) must be a finite duration.") }
                values[key.rawValue] = seconds
            default:
                guard let number = Int64(text) else { throw ServiceError("\(key.rawValue) must be an integer; byte sizes are expressed in bytes.") }
                values[key.rawValue] = number
            }
        }
        let result = try JSONDecoder().decode(S3Tuning.self, from: JSONSerialization.data(withJSONObject: values))
        try result.validate(); return result
    }
}

struct S3Credentials: Codable, Equatable, Sendable {
    var accessKeyID: String
    var secretAccessKey: String
    enum CodingKeys: String, CodingKey { case accessKeyID = "AccessKeyID", secretAccessKey = "SecretAccessKey" }
}

/// Optional JSON overrides deliberately stay out of the ordinary setup prompts.
struct S3Tuning: Codable, Equatable, Sendable {
    var concurrentUploads: Int = 5
    var reservedLiveSlots: Int = 1
    var transientFailureCount: Int = 3
    var transientFailureWindow: Double = 30
    var retryMaximumDelay: Double = 30
    var probeInterval: Double = 60
    var requestTimeout: Double = 600
    var finalizedShardFloor: Int = 10
    var finalizedShardsPerCamera: Int = 2
    var queueAgeFloor: Double = 120
    var spoolLimitBytes: Int64 = 10 * 1024 * 1024 * 1024
    var minimumFreeBytes: Int64 = 2 * 1024 * 1024 * 1024
    var spoolDirectory: String?
    var forceSpooling = false
    enum CodingKeys: String, CodingKey, CaseIterable {
        case concurrentUploads = "ConcurrentUploads", reservedLiveSlots = "ReservedLiveSlots"
        case transientFailureCount = "TransientFailureCount", transientFailureWindow = "TransientFailureWindowSeconds"
        case retryMaximumDelay = "RetryMaximumDelaySeconds", probeInterval = "ProbeIntervalSeconds", requestTimeout = "RequestTimeoutSeconds"
        case finalizedShardFloor = "FinalizedShardFloor", finalizedShardsPerCamera = "FinalizedShardsPerCamera", queueAgeFloor = "QueueAgeFloorSeconds"
        case spoolLimitBytes = "SpoolLimitBytes", minimumFreeBytes = "MinimumFreeBytes"
        case spoolDirectory = "SpoolDirectory"
        case forceSpooling = "ForceSpooling"
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        concurrentUploads = try c.decodeIfPresent(Int.self, forKey: .concurrentUploads) ?? 5
        reservedLiveSlots = try c.decodeIfPresent(Int.self, forKey: .reservedLiveSlots) ?? 1
        transientFailureCount = try c.decodeIfPresent(Int.self, forKey: .transientFailureCount) ?? 3
        transientFailureWindow = try c.decodeIfPresent(Double.self, forKey: .transientFailureWindow) ?? 30
        retryMaximumDelay = try c.decodeIfPresent(Double.self, forKey: .retryMaximumDelay) ?? 30
        probeInterval = try c.decodeIfPresent(Double.self, forKey: .probeInterval) ?? 60
        requestTimeout = try c.decodeIfPresent(Double.self, forKey: .requestTimeout) ?? 600
        finalizedShardFloor = try c.decodeIfPresent(Int.self, forKey: .finalizedShardFloor) ?? 10
        finalizedShardsPerCamera = try c.decodeIfPresent(Int.self, forKey: .finalizedShardsPerCamera) ?? 2
        queueAgeFloor = try c.decodeIfPresent(Double.self, forKey: .queueAgeFloor) ?? 120
        spoolLimitBytes = try c.decodeIfPresent(Int64.self, forKey: .spoolLimitBytes) ?? 10 * 1024 * 1024 * 1024
        minimumFreeBytes = try c.decodeIfPresent(Int64.self, forKey: .minimumFreeBytes) ?? 2 * 1024 * 1024 * 1024
        spoolDirectory = try c.decodeIfPresent(String.self, forKey: .spoolDirectory)
        forceSpooling = try c.decodeIfPresent(Bool.self, forKey: .forceSpooling) ?? false
    }
    func validate() throws {
        if let path = spoolDirectory {
            guard path.hasPrefix("/"), path != "/", CameraConfiguration.printable(path, limit: 1024),
                  path == "/" + path.split(separator: "/").joined(separator: "/"),
                  !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
                throw ServiceError("SpoolDirectory must be an absolute directory path without ~, dot components, or a trailing slash.")
            }
        }
        guard (2...64).contains(concurrentUploads), (1..<concurrentUploads).contains(reservedLiveSlots),
              (1...1000).contains(transientFailureCount), (1...3600).contains(transientFailureWindow),
              (1...600).contains(retryMaximumDelay), (1...3600).contains(probeInterval), (1...3600).contains(requestTimeout),
              (2...10000).contains(finalizedShardFloor), (1...100).contains(finalizedShardsPerCamera),
              (1...86400).contains(queueAgeFloor), spoolLimitBytes > 0, minimumFreeBytes >= 0 else {
            throw ServiceError(.invalidMessage, "Invalid S3 advanced tuning values.")
        }
    }
}

struct S3Configuration: Codable, Equatable, Sendable {
    var bucket: String
    var region: String
    var prefix: String
    var expectedOwner: String?
    var lifecycle = "Managed"
    var credentials: S3Credentials?
    var clientEncryption: S3ClientEncryption?
    var tuning: S3Tuning?
    var settings: S3Tuning { tuning ?? S3Tuning() }
    var partition: String { region.hasPrefix("cn-") ? "aws-cn" : (region.hasPrefix("us-gov-") ? "aws-us-gov" : "aws") }
    enum CodingKeys: String, CodingKey {
        case bucket = "Bucket", region = "Region", prefix = "Prefix", expectedOwner = "ExpectedOwner"
        case lifecycle = "Lifecycle", credentials = "Credentials", tuning = "Advanced"
        case clientEncryption = "ClientEncryption"
    }
    func sameDestination(as other: Self) -> Bool { bucket == other.bucket && region == other.region && prefix == other.prefix && expectedOwner == other.expectedOwner }
    func validate(requireCredentials: Bool = false) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard (3...63).contains(bucket.count), bucket.unicodeScalars.allSatisfy(allowed.contains),
              bucket.first?.isLetter == true || bucket.first?.isNumber == true else { throw ServiceError("Invalid S3 bucket name.") }
        guard bucket.last?.isLetter == true || bucket.last?.isNumber == true,
              !bucket.contains(".."), !bucket.hasSuffix("--x-s3"), !bucket.hasSuffix("--table-s3"),
              !bucket.hasPrefix("xn--"), !bucket.hasSuffix("-s3alias"), !bucket.hasSuffix("--ol-s3"),
              bucket.split(separator: ".").count != 4 || bucket.split(separator: ".").contains(where: { Int($0) == nil }),
              region.range(of: "^(?:[a-z]{2}-[a-z]+-[0-9]+|us-gov-[a-z]+-[0-9]+)$", options: .regularExpression) != nil,
              !prefix.isEmpty, prefix.utf8.count <= 512, prefix.hasSuffix("/"), !prefix.hasPrefix("/"),
              CameraConfiguration.printable(prefix, limit: 512), !prefix.contains("*"), !prefix.contains("?"), !prefix.contains("${"),
              !prefix.split(separator: "/", omittingEmptySubsequences: false).dropLast().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              ["Managed", "External"].contains(lifecycle),
              expectedOwner == nil || expectedOwner!.range(of: "^[0-9]{12}$", options: .regularExpression) != nil else {
            throw ServiceError(.invalidMessage, "S3 requires a general-purpose AWS bucket, a relative prefix ending in /, and Managed or External lifecycle.")
        }
        if let credentials {
            guard (16...128).contains(credentials.accessKeyID.count), credentials.accessKeyID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
                  (16...256).contains(credentials.secretAccessKey.count), !credentials.secretAccessKey.contains(where: { $0.isWhitespace || $0.isNewline }) else {
                throw ServiceError(.invalidMessage, "Invalid AWS access key or secret.")
            }
        } else if requireCredentials { throw ServiceError("S3 credentials are required.") }
        try clientEncryption?.validate(requirePassword: requireCredentials)
        try settings.validate()
    }
    mutating func preservePrivateSettings(from previous: Self) {
        if credentials == nil { credentials = previous.credentials }
        if clientEncryption == nil { clientEncryption = previous.clientEncryption }
        else if clientEncryption?.enabled == true, clientEncryption?.password == nil {
            clientEncryption?.password = previous.clientEncryption?.password
        }
    }
    func iamPolicy() throws -> String {
        var bucketActions = ["s3:GetBucketVersioning", "s3:GetEncryptionConfiguration"]
        if lifecycle == "Managed" { bucketActions += ["s3:GetLifecycleConfiguration", "s3:PutLifecycleConfiguration"] }
        return try Self.json(["Version": "2012-10-17", "Statement": [
            ["Effect": "Allow", "Action": ["s3:PutObject", "s3:AbortMultipartUpload"], "Resource": "arn:\(partition):s3:::\(bucket)/\(prefix)*"],
            ["Effect": "Allow", "Action": bucketActions, "Resource": "arn:\(partition):s3:::\(bucket)"]
        ]])
    }
    static func json(_ object: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
    static func ruleID(_ id: String) -> String { "hbnvr-" + id.lowercased() }
    func lifecycleJSON(id: String, days: Int) throws -> String {
        try Self.json(["Rules": [["ID": Self.ruleID(id), "Status": "Enabled", "Filter": ["Prefix": prefix],
                                 "Expiration": ["Days": days], "AbortIncompleteMultipartUpload": ["DaysAfterInitiation": 1]]]])
    }
}

extension RecordingStoreConfiguration {
    mutating func updateS3ReaderVersion() {
        if s3?.clientEncryption?.enabled == true { schemaVersion = max(schemaVersion, 2) }
        if s3?.settings.spoolDirectory != nil { schemaVersion = max(schemaVersion, 3) }
        if s3?.settings.forceSpooling == true { schemaVersion = max(schemaVersion, 4) }
    }
    /// Operational settings can be changed offline, never used to bypass AWS
    /// validation of credentials, encryption, destination, or recording enablement.
    func differsOnlyInAdvancedSettings(from other: Self) -> Bool {
        guard type == "S3", other.type == "S3" else { return false }
        var lhs = summary, rhs = other.summary
        lhs.s3?.tuning = nil; rhs.s3?.tuning = nil
        lhs.schemaVersion = 1; rhs.schemaVersion = 1
        return lhs == rhs && s3?.credentials == other.s3?.credentials && s3?.clientEncryption == other.s3?.clientEncryption
    }
    var summary: Self { var copy = self; copy.s3?.credentials = nil; copy.s3?.clientEncryption?.password = nil; return copy }
    var destinationLabel: String { s3.map { "s3://\($0.bucket)/\($0.prefix)" } ?? directory }
    var retentionDays: Int { (try? Int(IntervalText.seconds(retentionPeriod) / 86400)) ?? 0 }
}

struct S3StoreStatus: Codable {
    var spoolDirectory: String?
    var spoolVolume: String?
    var spoolVolumeUUID: String?
    var spoolVolumeCapacityBytes: Int64?
    var spoolVolumeAvailableBytes: Int64?
    var spoolLimitBytes: Int64?
    var spoolMinimumFreeBytes: Int64?
    var clientEncrypted: Bool?
    var acceptingRecording = true
    var spooling = false
    var reasons: [String] = []
    var queued = 0
    var active = 0
    var retrying = 0
    var assemblingBytes: Int64 = 0
    var residentBytes: Int64 = 0
    var volatileShards = 0
    var spoolBytes: Int64 = 0
    var spoolCount = 0
    var unreadableSpoolCount: Int? = 0
    // Compatibility with existing protocol-v1 clients, which require this key.
    // New agents always report zero; it no longer represents scheduling state.
    var quarantinedCount: Int? = 0
    var oldestBacklogSeconds: Double?
    var confirmedUploads: UInt64 = 0
    var nextProbeSeconds: Double?
    var nextReadRetrySeconds: Double?
    var desiredRetentionDays = 0
    var appliedRetentionDays: Int?
    var lifecycleState = "unverified"
    var lifecycleWarning: String?
}

enum S3FailureKind: String, Codable, Sendable { case transient, network, destination, localRead }
struct S3Failure: Error, Sendable {
    let kind: S3FailureKind
    let message: String
}

/// Pure scheduling policy; monotonic time and jitter are supplied by the manager.
struct S3UploadPolicy {
    var settings: S3Tuning
    var reasons = Set<String>()
    var failures: [Double] = []
    var retryAttempt = 0
    var retryAt = 0.0
    var nextProbe = 0.0
    var memoryPressure = false
    var spooling: Bool { settings.forceSpooling || !reasons.isEmpty }
    mutating func failed(_ kind: S3FailureKind, now: Double, jitter: Double) {
        if kind == .network || kind == .destination { reasons.insert("upload-error") }
        if kind == .transient || kind == .localRead {
            failures = failures.filter { now - $0 <= settings.transientFailureWindow }; failures.append(now)
            if failures.count >= settings.transientFailureCount { reasons.insert("upload-error") }
        }
        retryAttempt = min(retryAttempt + 1, 20)
        retryAt = now + max(0, min(1, jitter)) * min(settings.retryMaximumDelay, pow(2, Double(retryAttempt - 1)))
        if spooling { nextProbe = now + settings.probeInterval }
    }
    mutating func succeeded(probe: Bool) {
        failures.removeAll(); retryAttempt = 0; retryAt = 0
        if probe { reasons.remove("upload-error") }
    }
    mutating func pressure(count: Int, cameras: Int, oldestAge: Double, duration: Double) {
        let limit = max(settings.finalizedShardFloor, settings.finalizedShardsPerCamera * cameras)
        let old = oldestAge > max(settings.queueAgeFloor, duration * 2)
        if count > limit || old || memoryPressure { reasons.insert("pressure") }
        else if count < max(1, limit / 2) && !old { reasons.remove("pressure") }
    }
}
