import ArgumentParser
import Foundation
import Darwin

struct Store: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Configure recording stores. Enabled stores receive enabled cameras whose recording state is started.", subcommands: [StoreAdd.self, StoreList.self, StoreChange.self, StoreEnable.self, StoreDisable.self, StoreRemove.self, StoreSpool.self])
}
struct StoreTarget: ParsableArguments {
    @Option(help: "Local agent runtime directory; omit for the installed service.") var runtimeDir: String?
    @Argument(help: "Store name or UUID. Omit for an interactive picker.") var selector: String?
    func selected() throws -> (CameraConnection, RecordingStoreConfiguration) {
        let connection = try CameraConnection(runtimeDir: runtimeDir)
        let stores = try StoreUI.list(connection)
        let selected = try ResourceSelection.select(stores, selector: selector, id: { $0.id }, name: { $0.name },
            label: { "\($0.name) [\($0.id)] — \($0.destinationLabel)" }, kind: "store")
        return (connection, selected)
    }
}
enum StoreUI {
    static func list(_ connection: CameraConnection) throws -> [RecordingStoreConfiguration] {
        guard let stores = try connection.send(Request(protocolVersion: 1, operation: "stores.list")).stores else {
            throw ServiceError("Agent does not support stores; install hbnvr 0.5.0 or newer.")
        }
        return stores
    }
    static func edit(_ current: RecordingStoreConfiguration, isNew: Bool = false, advanced: Bool = false) throws -> RecordingStoreConfiguration {
        var draft = current
        draft.name = try CameraPrompt.line("Store name", default: current.name)
        if draft.type == "Local" { draft.directory = try StoreDirectory.expanded(CameraPrompt.line("Local directory", default: current.directory)) }
        else if isNew {
            var s3 = draft.s3!
            s3.bucket = try CameraPrompt.line("Existing S3 bucket")
            s3.region = try CameraPrompt.line("AWS region", default: "us-west-2")
            s3.prefix = try CameraPrompt.line("Object prefix (ending in /)", default: s3.prefix)
            let owner = try CameraPrompt.line("Expected bucket owner account ID (optional)")
            s3.expectedOwner = owner.isEmpty ? nil : owner; draft.s3 = s3
        } else { print("Destination (fixed): \(draft.destinationLabel) in \(draft.s3!.region)") }
        draft.shardDuration = try CameraPrompt.line("Shard duration", default: current.shardDuration)
        draft.retentionPeriod = try CameraPrompt.line("Retention period", default: current.retentionPeriod)
        if draft.type == "S3" {
            let choice = try CameraPrompt.choose(["Managed — HBNVR reconciles bucket lifecycle", "External — administrator manages lifecycle"], title: "Retention management", defaultIndex: draft.s3?.lifecycle == "External" ? 1 : 0)
            draft.s3?.lifecycle = choice == 0 ? "Managed" : "External"
        }
        let enabled = try CameraPrompt.line("Enable recording to this store? (yes/no)", default: current.enabled ? "yes" : "no").lowercased()
        guard ["yes", "y", "no", "n"].contains(enabled) else { throw ServiceError("Answer yes or no.") }
        draft.enabled = ["yes", "y"].contains(enabled)
        if advanced {
            print("Identity, owner, store type, and destination are fixed. Credentials and encryption are offered separately; stored secrets are never displayed.")
            if draft.type == "S3" {
                print("Advanced S3 options — Enter keeps each value. Spool relocation requires a disabled, drained store and a pre-created private directory; no footage is moved.")
                draft.s3?.tuning = try StoreAdvancedOptions.edit(current.s3!.settings) { try CameraPrompt.line($0, default: $1) }
                draft.updateS3ReaderVersion()
            } else { print("Local stores have no additional advanced options; directory, shard duration, retention, name, and enablement are the complete editable settings.") }
        }
        try draft.validate()
        print("\(draft.name) — \(draft.destinationLabel)")
        print("Shard: \(draft.shardDuration) (\(try IntervalText.seconds(draft.shardDuration)) seconds); retention: \(draft.retentionPeriod) (\(try IntervalText.seconds(draft.retentionPeriod)) seconds)")
        if draft.enabled { print("Enabled cameras whose recording state is started will record to this store automatically.") }
        // Tuning an existing store offline must not require key entry or AWS
        // validation. If common options are unchanged, offer secret replacement
        // explicitly and otherwise preserve them without showing their values.
        if !isNew, draft.type == "S3", draft.differsOnlyInAdvancedSettings(from: current),
           !(try CameraPrompt.confirm("Change AWS credentials or client-side encryption options?")) {
            return draft
        }
        if let s3 = draft.s3 {
            print("\nCreate a dedicated IAM user without console access, with this identity policy. Generate an access key for HBNVR; console usernames/passwords are not used.")
            print(try s3.iamPolicy())
            print("This is a write-only object key, not immutable-storage protection. It can overwrite objects within the prefix.")
            if s3.lifecycle == "Managed" { print("WARNING: lifecycle-management permission can indirectly cause deletion throughout this bucket, not just this prefix. Denied lifecycle access is a warning, not an upload failure.") }
            else {
                print("Apply this lifecycle configuration yourself, merging it with existing rules. HBNVR will make no lifecycle API calls:")
                print(try s3.lifecycleJSON(id: draft.id, days: draft.retentionDays))
            }
            if try isNew || CameraPrompt.confirm("Replace the stored AWS credentials?") {
                draft.s3?.credentials = S3Credentials(accessKeyID: try CameraPrompt.line("Access key ID"), secretAccessKey: try CameraPrompt.line("Secret access key", secret: true))
            }
            let encryption = try encryptionOptions(current: draft.s3?.clientEncryption)
            draft.s3?.clientEncryption = encryption
            if encryption.enabled { draft.schemaVersion = max(draft.schemaVersion, 2) }
            try draft.validate()
            print("Validation writes a small setup object. Cancellation may leave it behind; lifecycle expiration removes it. S3 expiration is asynchronous and ages from upload time.")
        }
        return draft
    }
    static func encryptionOptions(current: S3ClientEncryption?) throws -> S3ClientEncryption {
        print("Client-side encryption is optional and separate from AWS credentials. Use a strong, unique passphrase and keep a separate backup: lost passwords cannot be reset to recover footage.")
        print("The daemon keeps the password in its private configuration for unattended operation; it is never sent to AWS. Camera names and capture times in object keys remain visible.")
        let replacing = current?.enabled == true
        if replacing {
            let choice = try CameraPrompt.choose(["Keep the existing encryption password", "Set a new password for future shards", "Disable encryption for future shards"], title: "Client-side encryption", defaultIndex: 0)
            if choice == 0 { return current! }
            print("Existing recordings and queued shards keep their original encryption. Keep their old password until those recordings expire.")
            if choice == 2 {
                guard try CameraPrompt.confirm("Upload future recordings without client-side encryption?") else { return current! }
                return S3ClientEncryption(enabled: false)
            }
        }
        let password = try CameraPrompt.line(replacing ? "New encryption password" : "Encryption password (optional; blank for none)", secret: true)
        if !replacing && password.isEmpty { return S3ClientEncryption(enabled: false) }
        try RecordingEncryption.validatePassword(password)
        let confirmation = try CameraPrompt.line("Confirm encryption password", secret: true)
        guard password.utf8.elementsEqual(confirmation.utf8) else { throw ServiceError("Encryption passwords did not match; no changes were saved.") }
        print("New recordings will be encrypted .mp4.hbnvr files. Recover downloaded recordings with hbnvr decrypt INPUT OUTPUT.")
        return S3ClientEncryption(password: password)
    }
    static func setup(_ config: RecordingStoreConfiguration, connection: CameraConnection) throws {
        let reply: Reply
        do { reply = try connection.send(Request(protocolVersion: 1, operation: S3SetupJobs.startOperation, store: config)) }
        catch let error as ServiceError where error.code == .invalidMessage && error.message.hasPrefix("Unknown operation.") {
            throw ServiceError(.incompatible, "The running agent does not support this S3 setup protocol. Install this version before configuring the store; older agents may ignore encryption or spooling controls.")
        }
        guard var progress = reply.setup else { throw ServiceError("Agent did not create the setup job.") }
        let cancelled = Cancellation()
        let oldSignal = signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        interrupt.setEventHandler { cancelled.stop() }; interrupt.resume()
        defer { interrupt.cancel(); signal(SIGINT, oldSignal) }
        print("Validating S3 access (Ctrl-C cancels)…")
        while progress.state == "validating" {
            if cancelled.isStopped {
                _ = try connection.send(Request(protocolVersion: 1, operation: "stores.setup.cancel", setupID: progress.id))
                print("Cancelled; configuration was not saved. A setup object may remain."); return
            }
            Thread.sleep(forTimeInterval: 0.25)
            guard let next = try connection.send(Request(protocolVersion: 1, operation: "stores.setup.poll", setupID: progress.id)).setup else { throw ServiceError("Agent omitted setup progress.") }
            progress = next
        }
        print(progress.message)
        if cancelled.isStopped {
            _ = try connection.send(Request(protocolVersion: 1, operation: "stores.setup.cancel", setupID: progress.id))
            print("Cancelled; configuration was not saved."); return
        }
        var saveDisabled = false
        if progress.state == "failed" {
            guard try CameraPrompt.confirm("Save this configuration disabled? Enabling later requires successful validation.") else {
                _ = try connection.send(Request(protocolVersion: 1, operation: "stores.setup.cancel", setupID: progress.id)); print("Cancelled; no configuration saved."); return
            }
            saveDisabled = true
        } else if progress.state != "validated" { throw ServiceError("Setup did not complete; no configuration saved.") }
        guard let saved = try connection.send(Request(protocolVersion: 1, operation: "stores.setup.commit", setupID: progress.id, saveDisabled: saveDisabled)).store else { throw ServiceError("Save acknowledgment missing; inspect store list before retrying.") }
        print("Saved \(saved.name) [\(saved.id)] — \(saved.enabled ? "enabled" : "disabled"). Check status for independent lifecycle reconciliation.")
    }
    static func action(_ operation: String, target: StoreTarget) throws {
        let (connection, store) = try target.selected()
        if operation == "enable", store.type == "S3", !store.enabled {
            var draft = store; draft.enabled = true
            guard try CameraPrompt.confirm("Validate S3 access and enable \(store.name)? This writes a small setup object.") else { print("Cancelled."); return }
            try setup(draft, connection: connection); return
        }
        let reply = try connection.send(Request(protocolVersion: 1, operation: "stores." + operation, storeID: store.id))
        guard reply.store?.id == store.id else { throw ServiceError("Agent did not confirm store operation; check status before retrying.") }
        print("\(store.name): \(operation == "enable" ? "enabled" : "disabled").")
    }
}
struct StoreAdd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Add a Local or S3 store. S3 setup generates scoped IAM, offers optional client-side password encryption, and validates access asynchronously. No sudo.")
    @Option(help: "Local agent runtime directory; omit for the installed service.") var runtimeDir: String?
    func run() throws { try command {
        guard geteuid() != 0 else { throw ServiceError(.permission, "Run store add without sudo, as the requesting user.") }
        let connection = try CameraConnection(runtimeDir: runtimeDir)
        let existing = try StoreUI.list(connection)
        let kind = try CameraPrompt.choose(["Local", "S3"], title: "Add a recording store")
        var initial = RecordingStoreConfiguration(directory: kind == 0 ? "~/NVR" : "", ownerUID: geteuid(), ownerUUID: try StoreDirectory.identity(geteuid()))
        if kind == 1 { initial.type = "S3"; initial.name = "S3 recordings"; initial.s3 = S3Configuration(bucket: "", region: "", prefix: "hbnvr/" + initial.id.lowercased() + "/") }
        let config = try StoreUI.edit(initial, isNew: true)
        guard !existing.contains(where: { RecordingStoreRepository.overlap($0, config) }) else { throw ServiceError("Store destinations must not overlap.") }
        if config.type == "S3" {
            guard try CameraPrompt.confirm("Validate access and save this S3 store?") else { print("Cancelled; no changes made."); return }
            try StoreUI.setup(config, connection: connection); return
        }
        print("New directory access: this user and the agent only. Existing unrelated permissions and parent directories will not be changed.")
        guard try CameraPrompt.confirm("Create the directory and save this store?") else { print("Cancelled; no changes made."); return }
        try StoreDirectory.create(config.directory, owner: geteuid(), daemon: connection.uid)
        do {
            guard let saved = try connection.send(Request(protocolVersion: 1, operation: "stores.add", store: config)).store else { throw ServiceError("Agent did not confirm the store; check store list before retrying.") }
            print("Added \(saved.name) [\(saved.id)] — \(saved.enabled ? "enabled" : "disabled").")
        } catch {
            print("The private directory was preserved at \(config.directory). Check agent access and store list before retrying.")
            throw error
        }
    } }
}
struct StoreList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List store configuration without secrets.")
    @Option var runtimeDir: String?
    @Flag(help: "Print JSON.") var json = false
    func run() throws { try command {
        let stores = try StoreUI.list(CameraConnection(runtimeDir: runtimeDir))
        if json { print(String(decoding: try CameraJSON.encode(stores), as: UTF8.self)) }
        else if stores.isEmpty { print("No recording stores configured.") }
        else { for store in stores { print("\(store.name) [\(store.id)] — \(store.enabled ? "enabled" : "disabled"), \(store.destinationLabel), shard \(store.shardDuration), retention \(store.retentionPeriod)\(store.s3.map { ", " + $0.lifecycle + " lifecycle" } ?? "")") } }
    } }
}
struct StoreChange: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "change", abstract: "Edit store options using the add workflow. --advanced includes all upload, retry, pressure, and spool settings. S3 destinations remain fixed; spool relocation requires disabled and drained.")
    @OptionGroup var target: StoreTarget
    @Flag(help: "Show all applicable settings, including S3 upload limits, retry intervals, pressure thresholds, spool directory/quota/reserve, and forced spooling. Operational-only edits work offline.") var advanced = false
    func run() throws { try command {
        let (connection, current) = try target.selected()
        let changed = try StoreUI.edit(current, advanced: advanced)
        guard current.directory == changed.directory else { throw ServiceError("To relocate a store, remove it and add a new one. Existing recordings will be preserved.") }
        if try IntervalText.seconds(changed.retentionPeriod) < IntervalText.seconds(current.retentionPeriod) { print("Warning: reducing retention may delete older recordings immediately.") }
        let operationalOnly = changed.differsOnlyInAdvancedSettings(from: current)
        guard try CameraPrompt.confirm(operationalOnly ? "Save these operational options without an AWS validation request?" : "Save these store options? Active shards will be finalized.") else { print("Cancelled; no changes made."); return }
        if changed.type == "S3" {
            if operationalOnly {
                let reply = try connection.send(Request(protocolVersion: 1, operation: "stores.advanced.change", store: changed, storeOriginal: current))
                guard reply.store?.id == current.id else { throw ServiceError("Agent did not confirm the edit; inspect store list before retrying.") }
                print("Updated \(changed.name). Operational settings saved; check status for application and recovery.")
            } else { try StoreUI.setup(changed, connection: connection) }
            return
        }
        _ = try connection.send(Request(protocolVersion: 1, operation: "stores.change", store: changed))
        print("Updated \(changed.name).")
    } }
}
struct StoreSpool: ParsableCommand {
    enum Mode: String, EnumerableFlag { case on, off }
    static let configuration = CommandConfiguration(commandName: "spool", abstract: "Persistently force S3 spooling (--on) or release the manual hold (--off). No AWS validation or sudo required. Pauses new uploads/probes, not in-flight requests; recording continues while spool capacity permits. Other automatic safety reasons remain in effect.", usage: "hbnvr store spool [<selector>] (--on | --off) [--runtime-dir <path>]")
    @OptionGroup var target: StoreTarget
    @Flag(exclusivity: .exclusive, help: "Choose exactly one: --on forces spooling; --off restores automatic upload/recovery policy.") var mode: Mode
    func run() throws { try command {
        let (connection, store) = try target.selected()
        guard store.type == "S3" else { throw ServiceError("Forced spooling applies only to S3 stores.") }
        let reply = try connection.send(Request(protocolVersion: 1, operation: "stores.spool." + mode.rawValue, storeID: store.id))
        guard reply.store?.s3?.settings.forceSpooling == (mode == .on) else { throw ServiceError("Agent did not confirm spooling mode; inspect store list before retrying.") }
        print(mode == .on ? "\(store.name): forced spooling saved. New uploads and probes are held; in-flight requests may finish. Check status for application and capacity."
              : "\(store.name): manual spooling released. Automatic upload/recovery policy remains in effect.")
    } }
}

struct StoreEnable: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "enable", abstract: "Persistently enable a store for cameras whose recording state is started.")
    @OptionGroup var target: StoreTarget
    func run() throws { try command { try StoreUI.action("enable", target: target) } }
}
struct StoreDisable: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "disable", abstract: "Finalize current recordings and stop new recording. S3 upload/recovery and retention continue.")
    @OptionGroup var target: StoreTarget
    func run() throws { try command { try StoreUI.action("disable", target: target) } }
}
struct StoreRemove: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove configuration, preserving recordings. S3 requires disabled and drained; cloud lifecycle rules remain.")
    @OptionGroup var target: StoreTarget
    func run() throws { try command {
        let (connection, store) = try target.selected()
        let consequence = store.type == "S3" ? "Cloud recordings and lifecycle rules remain. The store must be disabled and fully drained." : "Recordings and directory access remain; local retention stops."
        guard try CameraPrompt.confirm("Remove \(store.name)? \(consequence)") else { print("Cancelled; no changes made."); return }
        _ = try connection.send(Request(protocolVersion: 1, operation: "stores.remove", storeID: store.id))
        print("Removed \(store.name). \(consequence)")
    } }
}
