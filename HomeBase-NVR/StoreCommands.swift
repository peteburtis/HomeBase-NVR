import ArgumentParser
import Foundation
import Darwin

struct Store: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Configure recording stores. Enabled stores record all configured cameras automatically.", subcommands: [StoreAdd.self, StoreList.self, StoreChange.self, StoreEnable.self, StoreDisable.self, StoreRemove.self])
}
struct StoreTarget: ParsableArguments {
    @Option(help: "Local agent runtime directory; omit for the installed service.") var runtimeDir: String?
    @Argument(help: "Store name or UUID. Omit for an interactive picker.") var selector: String?
    func selected() throws -> (CameraConnection, RecordingStoreConfiguration) {
        let connection = try CameraConnection(runtimeDir: runtimeDir)
        let stores = try StoreUI.list(connection)
        let matches = selector.map { value in stores.filter { $0.id == value || $0.name == value } } ?? stores
        guard !matches.isEmpty else { throw ServiceError("No matching recording stores.") }
        if selector != nil, matches.count == 1 { return (connection, matches[0]) }
        guard isatty(STDIN_FILENO) == 1 else { throw ServiceError("Specify an unambiguous store name or UUID when not using a terminal.") }
        let index = try CameraPrompt.choose(matches.map { "\($0.name) [\($0.id)] — \($0.directory)" }, title: "Choose a store")
        return (connection, matches[index])
    }
}
enum StoreUI {
    static func list(_ connection: CameraConnection) throws -> [RecordingStoreConfiguration] {
        guard let stores = try connection.send(Request(protocolVersion: 1, operation: "stores.list")).stores else {
            throw ServiceError("Agent does not support stores; install hbnvr 0.5.0 or newer.")
        }
        return stores
    }
    static func edit(_ current: RecordingStoreConfiguration) throws -> RecordingStoreConfiguration {
        var draft = current
        draft.name = try CameraPrompt.line("Store name", default: current.name)
        draft.directory = try StoreDirectory.expanded(CameraPrompt.line("Local directory", default: current.directory))
        draft.shardDuration = try CameraPrompt.line("Shard duration", default: current.shardDuration)
        draft.retentionPeriod = try CameraPrompt.line("Retention period", default: current.retentionPeriod)
        let enabled = try CameraPrompt.line("Enable recording to this store? (yes/no)", default: current.enabled ? "yes" : "no").lowercased()
        guard ["yes", "y", "no", "n"].contains(enabled) else { throw ServiceError("Answer yes or no.") }
        draft.enabled = ["yes", "y"].contains(enabled)
        try draft.validate()
        print("\(draft.name) — \(draft.directory)")
        print("Shard: \(draft.shardDuration) (\(try IntervalText.seconds(draft.shardDuration)) seconds); retention: \(draft.retentionPeriod) (\(try IntervalText.seconds(draft.retentionPeriod)) seconds)")
        if draft.enabled { print("All configured cameras will record to this store automatically.") }
        return draft
    }
    static func action(_ operation: String, target: StoreTarget) throws {
        let (connection, store) = try target.selected()
        let reply = try connection.send(Request(protocolVersion: 1, operation: "stores." + operation, storeID: store.id))
        guard reply.store?.id == store.id else { throw ServiceError("Agent did not confirm store operation; check status before retrying.") }
        print("\(store.name): \(operation == "enable" ? "enabled" : "disabled").")
    }
}
struct StoreAdd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Add a local recording store; creates a private requester/daemon directory. No sudo.")
    @Option(help: "Local agent runtime directory; omit for the installed service.") var runtimeDir: String?
    func run() throws { try command {
        guard geteuid() != 0 else { throw ServiceError(.permission, "Run store add without sudo, as the requesting user.") }
        let connection = try CameraConnection(runtimeDir: runtimeDir)
        let existing = try StoreUI.list(connection)
        print("Add a local recording store")
        let initial = RecordingStoreConfiguration(directory: "~/NVR", ownerUID: geteuid(), ownerUUID: try StoreDirectory.identity(geteuid()))
        let config = try StoreUI.edit(initial)
        guard !existing.contains(where: { RecordingStoreRepository.overlap($0.directory, config.directory) }) else { throw ServiceError("Store directories must not overlap.") }
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
        else { for store in stores { print("\(store.name) [\(store.id)] — \(store.enabled ? "enabled" : "disabled"), \(store.directory), shard \(store.shardDuration), retention \(store.retentionPeriod)") } }
    } }
}
struct StoreChange: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "change", abstract: "Edit store options using the add workflow. Directory relocation requires remove/add; recordings are preserved.")
    @OptionGroup var target: StoreTarget
    func run() throws { try command {
        let (connection, current) = try target.selected()
        let changed = try StoreUI.edit(current)
        guard current.directory == changed.directory else { throw ServiceError("To relocate a store, remove it and add a new one. Existing recordings will be preserved.") }
        if try IntervalText.seconds(changed.retentionPeriod) < IntervalText.seconds(current.retentionPeriod) { print("Warning: reducing retention may delete older recordings immediately.") }
        guard try CameraPrompt.confirm("Save these store options? Active shards will be finalized.") else { print("Cancelled; no changes made."); return }
        _ = try connection.send(Request(protocolVersion: 1, operation: "stores.change", store: changed))
        print("Updated \(changed.name).")
    } }
}
struct StoreEnable: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "enable", abstract: "Persistently enable recording all cameras to a store.")
    @OptionGroup var target: StoreTarget
    func run() throws { try command { try StoreUI.action("enable", target: target) } }
}
struct StoreDisable: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "disable", abstract: "Finalize current recordings and stop new recording to a store. Retention continues.")
    @OptionGroup var target: StoreTarget
    func run() throws { try command { try StoreUI.action("disable", target: target) } }
}
struct StoreRemove: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove store configuration, preserving recorded files, directories, and access permissions. Retention stops.")
    @OptionGroup var target: StoreTarget
    func run() throws { try command {
        let (connection, store) = try target.selected()
        guard try CameraPrompt.confirm("Remove \(store.name)? Recordings and directory access will be preserved; retention will stop.") else { print("Cancelled; no changes made."); return }
        _ = try connection.send(Request(protocolVersion: 1, operation: "stores.remove", storeID: store.id))
        print("Removed \(store.name). Recordings and directory permissions were preserved.")
    } }
}
