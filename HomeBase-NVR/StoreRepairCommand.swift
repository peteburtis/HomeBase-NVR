import ArgumentParser
import Foundation
import Darwin

struct StoreRepairMetadata: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "repair-metadata",
        abstract: "Recover missing S3 playback metadata and 20-minute thumbnails for configured cameras. Unexpected, legacy, or unreadable objects are left untouched. No sudo.",
        discussion: "Lists first, then asks before downloading up to 256 MiB per object. Uses embedded timing, never filename/size guesses. Temporary ListBucket/GetObject keys and optional session token stay in agent memory; they do not replace the recorder's write-only keys. No video objects are changed or deleted. Indexed videos are downloaded only when a 20-minute midpoint thumbnail is missing; existing thumbnail names and pending uploads are preserved. New thumbnails use the shared upload/spool pool and current encryption setting. Ctrl-C cancels; accepted metadata and thumbnails remain. Install a matching agent before use.")
    @OptionGroup var target: StoreTarget
    @Flag(help: "List candidates and estimated download bytes only; do not download footage, decrypt, or repair metadata.") var dryRun = false
    func run() throws { try command {
        let (connection, store) = try target.selected()
        guard let s3 = store.s3, store.type == "S3" else { throw ServiceError("Metadata repair applies only to S3 stores.") }
        let first: Reply
        do { first = try connection.send(Request(protocolVersion: 1, operation: "stores.repair.start.v2", storeID: store.id, repairDryRun: dryRun)) }
        catch let error as ServiceError where error.code == .invalidMessage && error.message.hasPrefix("Unknown operation.") {
            throw ServiceError(.incompatible, "Install hbnvr 0.18.0 or newer before running metadata and thumbnail repair.")
        }
        guard var progress = first.repair else { throw ServiceError("The agent omitted repair progress.") }
        let id = progress.id, cancellation = Cancellation()
        let oldSignal = signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        interrupt.setEventHandler {
            cancellation.stop()
            _ = try? connection.send(Request(protocolVersion: 1, operation: "stores.repair.cancel", repairID: id))
        }
        interrupt.resume()
        var finished = false
        defer {
            interrupt.cancel(); signal(SIGINT, oldSignal)
            if !finished { _ = try? connection.send(Request(protocolVersion: 1, operation: "stores.repair.cancel", repairID: id)) }
        }
        print("Repairing metadata for \(store.name). Video objects are never modified. Ctrl-C cancels.")
        var lastState = "", lastPrinted = Date.distantPast, printedDiagnostics = 0
        func resume(credentials: S3RepairCredentials? = nil, password: String? = nil,
                    skipEncrypted: Bool = false, begin: Bool = false) throws -> S3RepairStatus {
            guard !cancellation.isStopped else { throw ServiceError("Repair cancelled; previously merged metadata was preserved.") }
            guard let result = try connection.send(Request(protocolVersion: 1, operation: "stores.repair.resume",
                repairID: id, repairCredentials: credentials, repairPassword: password,
                repairSkipEncrypted: skipEncrypted, repairBegin: begin)).repair else { throw ServiceError("Agent omitted repair progress.") }
            return result
        }
        while true {
            if cancellation.isStopped { throw ServiceError("Repair cancelled; previously merged metadata was preserved.") }
            let diagnostics = progress.diagnostics ?? []
            for diagnostic in diagnostics.dropFirst(printedDiagnostics) { print(diagnostic.description) }
            printedDiagnostics = diagnostics.count
            if progress.state != lastState || Date().timeIntervalSince(lastPrinted) >= 5 {
                print(progress.message)
                print("\(progress.scanned) listed; \(progress.candidates) candidates / \(progress.candidateBytes) bytes; \(progress.alreadyIndexed) already indexed or pending; \(progress.recovered) repaired; \(progress.skipped.values.reduce(0, +)) skipped.")
                print("Thumbnails: \(progress.thumbnailsPresent) present; \(progress.thumbnailsQueued) submitted for upload during this repair.")
                lastState = progress.state; lastPrinted = Date()
            }
            switch progress.state {
            case "credentials":
                print("Temporary repair policy (read/list only; the saved recorder keys publish manifests and thumbnails):")
                print(try AWSS3RepairReader.iamPolicy(s3))
                print("Keys are not saved. A network failure is not a reason to supply different keys. Expected-owner or bucket-policy denials also require checking the destination.")
                let accessKey = try CameraPrompt.line("Repair access key ID")
                let secret = try CameraPrompt.line("Repair secret access key", secret: true)
                let token = try CameraPrompt.line("Session token (optional)", secret: true)
                progress = try resume(credentials: .init(accessKeyID: accessKey, secretAccessKey: secret, sessionToken: token.isEmpty ? nil : token))
            case "password":
                let choice = try CameraPrompt.choose(["Enter another encryption password", "Skip unreadable encrypted recordings"], title: "Encrypted recording recovery")
                if choice == 0 { progress = try resume(password: CameraPrompt.line("Original encryption password", secret: true)) }
                else { progress = try resume(skipEncrypted: true) }
            case "ready":
                guard try CameraPrompt.confirm("Download up to \(progress.candidateBytes) bytes to repair metadata and missing thumbnails? Unsupported recordings will be skipped.") else {
                    _ = try connection.send(Request(protocolVersion: 1, operation: "stores.repair.cancel", repairID: id))
                    print("Cancelled; no repair was started."); finished = true; return
                }
                progress = try resume(begin: true)
            case "completed":
                for reason in progress.skipped.keys.sorted() { print("  Skipped \(reason): \(progress.skipped[reason]!)") }
                finished = true; return
            case "failed", "cancelled": finished = true; throw ServiceError(progress.message)
            case "scanning", "repairing":
                Thread.sleep(forTimeInterval: 0.25)
                guard let value = try connection.send(Request(protocolVersion: 1, operation: "stores.repair.poll", repairID: id)).repair else { throw ServiceError("Agent omitted repair progress.") }
                progress = value
            default: throw ServiceError("Unknown repair state; update the CLI and agent together.")
            }
        }
    } }
}
