import ArgumentParser
import Foundation

struct Media: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Inspect and annotate recorded media without changing live tags.", subcommands: [MediaTag.self])
}
struct MediaTag: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "tag", abstract: "Edit finalized history. Local MP4/index updates; S3 manifests only.",
        subcommands: [MediaTagSet.self, MediaTagRemove.self, MediaTagInspect.self, MediaTagApply.self, MediaTagStatus.self])
}
struct HistoricalTagOptions: ParsableArguments {
    @Option(help: "Local agent runtime directory; omit for the installed service.") var runtimeDir: String?
    @Option(help: "Target store name/UUID; repeat to explicitly edit matching footage in more stores. Omit for a picker.") var store: [String] = []
    @Option(help: "Managed local recording file; absolute path. Not an arbitrary MP4 import.") var file: String?
    @Option(help: "Shard UUID; requires --source-store.") var shard: String?
    @Option(help: "Source store name/UUID for the shard reference.") var sourceStore: String?
    @Option(help: "Camera name/UUID for time addressing. Removed cameras may be addressed by UUID.") var camera: String?
    @Option(help: "canonical (default), camera, or received.") var timeline: String = "canonical"
    @Option(help: "Clock epoch UUID to disambiguate overlapping wall-clock ranges.") var epoch: String?
    @Option(help: "Start timestamp: Unix seconds or ISO 8601 with an explicit timezone.") var from: String?
    @Option(help: "Exclusive end timestamp: Unix seconds or ISO 8601 with an explicit timezone.") var to: String?
    @Option(help: "Advance start by this many actual frames; never crosses a recording gap or clock discontinuity.") var fromFrame: Int = 0
    @Option(help: "Advance end by this many actual frames.") var toFrame: Int = 0
    @Option(help: "Zero-based start:end frame range within --file or --shard; end is exclusive.") var frames: String?
    @Flag(help: "Select the entire finalized file/shard.") var allFrames = false
    @Flag(help: "Validate and report revisions without changing anything.") var dryRun = false
    @Option(help: "Optional expected revision; valid only when editing one selected shard in one store.") var expectedRevision: String?
    @Option(help: "Optional job UUID for safe retries within this daemon session.") var jobID: String?
    @Flag(help: "Prompt for temporary GetObject credentials if exact remote frame addressing needs them. Never saved.") var readCredentials = false
    @Flag(help: "Prompt for the original metadata/media encryption password. Never saved.") var encryptionPassword = false

    func selection(_ connection: CameraConnection, stores: [RecordingStoreConfiguration]) throws -> HistoricalTagRequest.Selection {
        guard let basis = MediaTimeline(rawValue: timeline) else { throw ServiceError("Timeline must be canonical, camera, or received.") }
        var value = HistoricalTagRequest.Selection(file: file, shardID: shard, timeline: basis, epochID: epoch, allFrames: allFrames)
        if let sourceStore { value.sourceStoreID = try HistoricalTagCLI.store(sourceStore, stores: stores).id }
        if let camera {
            if UUID(uuidString: camera) != nil { value.cameraID = camera }
            else { value.cameraID = try ResourceSelection.select(connection.list(), selector: camera, id: { $0.id }, name: { $0.name }, label: { $0.name }, kind: "camera").id }
        }
        if let from { value.start = .init(timestamp: try HistoricalTagCLI.timestamp(from), frameOffset: fromFrame) }
        if let to { value.end = .init(timestamp: try HistoricalTagCLI.timestamp(to), frameOffset: toFrame) }
        guard from != nil || fromFrame == 0, to != nil || toFrame == 0 else { throw ServiceError("Frame offsets require timestamp boundaries.") }
        if let frames {
            let parts = frames.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]) else { throw ServiceError("Use --frames START:END (zero-based, exclusive end).") }
            value.startFrame = a; value.endFrame = b
        }
        return value
    }
    func execute(key: String, value: String?, inspect: Bool = false) throws {
        let connection = try CameraConnection(runtimeDir: runtimeDir), stores = try StoreUI.list(connection)
        let ids = try store.isEmpty ? [HistoricalTagCLI.store(nil, stores: stores).id] : store.map { try HistoricalTagCLI.store($0, stores: stores).id }
        let selection = try selection(connection, stores: stores)
        var request = HistoricalTagRequest(jobID: jobID ?? UUID().uuidString, storeIDs: ids,
            edits: [.init(selection: selection, key: key, value: value)], dryRun: dryRun, inspect: inspect)
        let secrets = try HistoricalTagCLI.secrets(read: readCredentials, encryption: encryptionPassword)
        if let expectedRevision {
            // Resolve a file's identity with read-only inspection, never by its name.
            let probe = HistoricalTagRequest(jobID: UUID().uuidString, storeIDs: ids, edits: request.edits, inspect: true)
            let data = try HistoricalTagCLI.run(probe, connection: connection, credentials: secrets.0, password: secrets.1, printResult: false)
            let values = try JSONDecoder().decode([HistoricalTagInspection].self, from: data ?? Data())
            guard values.count == 1, let item = values.first else { throw ServiceError("--expected-revision requires exactly one shard; use batch JSON for per-shard revisions.") }
            request.expectedRevisions = [item.storeID + "/" + item.shardID: expectedRevision]
        }
        _ = try HistoricalTagCLI.run(request, connection: connection, credentials: secrets.0, password: secrets.1)
    }
}
struct MediaTagSet: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Set one opaque tag within a finite recorded range.")
    @OptionGroup var options: HistoricalTagOptions
    @Option var key: String
    @Option var value: String
    func run() throws { try command { try options.execute(key: key, value: value) } }
}
struct MediaTagRemove: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Explicitly remove a tag only within the selected recorded range.")
    @OptionGroup var options: HistoricalTagOptions
    @Option var key: String
    func run() throws { try command { try options.execute(key: key, value: nil) } }
}
struct MediaTagInspect: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "inspect", abstract: "Print shard identities, revisions, timing, and authoritative tag timelines as JSON.")
    @OptionGroup var options: HistoricalTagOptions
    func run() throws { try command { try options.execute(key: "", value: nil, inspect: true) } }
}
struct MediaTagApply: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "apply", abstract: "Apply a bounded HistoricalTagRequest JSON batch from a file or stdin (-). Store/camera references in JSON are UUIDs.")
    @Argument var input: String = "-"
    @Option var runtimeDir: String?
    @Flag var dryRun = false
    @Flag var readCredentials = false
    @Flag var encryptionPassword = false
    func run() throws {
        try command {
            let handle = try input == "-" ? FileHandle.standardInput : FileHandle(forReadingFrom: URL(fileURLWithPath: input))
            defer { if input != "-" { try? handle.close() } }
            let data = try handle.read(upToCount: 60001) ?? Data()
            guard data.count <= 60000 else { throw ServiceError("Tag batch JSON exceeds 60,000 bytes.") }
            var request = try JSONDecoder().decode(HistoricalTagRequest.self, from: data)
            request.dryRun = request.dryRun || dryRun
            let secrets = try HistoricalTagCLI.secrets(read: readCredentials, encryption: encryptionPassword)
            _ = try HistoricalTagCLI.run(request, connection: CameraConnection(runtimeDir: runtimeDir), credentials: secrets.0, password: secrets.1)
        }
    }
}
struct MediaTagStatus: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Read a recent historical-edit job's result. Jobs are retained for this daemon session (last eight jobs).")
    @Argument var jobID: String
    @Option var runtimeDir: String?
    func run() throws { try command {
        guard let job = try CameraConnection(runtimeDir: runtimeDir).send(Request(protocolVersion: 1, operation: "media.tags.poll", tagJobID: jobID)).tagJob else { throw ServiceError("Agent omitted job status.") }
        try HistoricalTagCLI.printJSON(job)
    } }
}
enum HistoricalTagCLI {
    static func store(_ selector: String?, stores: [RecordingStoreConfiguration]) throws -> RecordingStoreConfiguration {
        try ResourceSelection.select(stores, selector: selector, id: { $0.id }, name: { $0.name }, label: { "\($0.name) [\($0.id)]" }, kind: "store")
    }
    static func timestamp(_ value: String) throws -> Double {
        if let seconds = Double(value), seconds.isFinite { return seconds }
        let formatter = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
            formatter.formatOptions = options
            if let date = formatter.date(from: value) { return date.timeIntervalSince1970 }
        }
        throw ServiceError("Timestamp must be Unix seconds or ISO 8601 with a timezone, for example 2026-09-21T14:30:00-07:00.")
    }
    static func secrets(read: Bool, encryption: Bool) throws -> (S3RepairCredentials?, String?) {
        var keys: S3RepairCredentials?
        if read {
            keys = .init(accessKeyID: try CameraPrompt.line("Temporary access key ID"), secretAccessKey: try CameraPrompt.line("Temporary secret access key", secret: true))
            let token = try CameraPrompt.line("Session token (optional)", secret: true)
            keys?.sessionToken = token.isEmpty ? nil : token
        }
        return (keys, try encryption ? CameraPrompt.line("Original encryption password", secret: true) : nil)
    }
    static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }
    @discardableResult static func run(_ request: HistoricalTagRequest, connection: CameraConnection,
                                      credentials: S3RepairCredentials?, password: String?, printResult: Bool = true) throws -> Data? {
        try request.validate()
        guard var job = try connection.send(Request(protocolVersion: 1, operation: "media.tags.start",
            repairCredentials: credentials, repairPassword: password, historicalTags: request)).tagJob else { throw ServiceError("Update HBNVR to use historical tags.") }
        if printResult { FileHandle.standardError.write(Data("Historical tag job \(job.jobID)\n".utf8)) }
        while ["preparing", "applying"].contains(job.state) {
            Thread.sleep(forTimeInterval: 0.25)
            guard let next = try connection.send(Request(protocolVersion: 1, operation: "media.tags.poll", tagJobID: job.jobID)).tagJob else { throw ServiceError("Job status unavailable.") }
            job = next
        }
        if job.state == "failed" {
            if printResult { try printJSON(job) }
            throw ServiceError(job.error ?? "Historical tag job failed.")
        }
        if request.inspect {
            var data = Data()
            while true {
                guard let chunk = try connection.send(Request(protocolVersion: 1, operation: "media.tags.read", tagJobID: job.jobID, tagOffset: data.count)).tagData else { throw ServiceError("Inspection output unavailable.") }
                data.append(chunk)
                guard data.count <= 16 * 1024 * 1024 else { throw ServiceError("Inspection output too large.") }
                if chunk.count < 32768 { break }
            }
            if printResult {
                let value = try JSONSerialization.jsonObject(with: data)
                print(String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
            }
            return data
        }
        if printResult { try printJSON(job) }
        return nil
    }
}
