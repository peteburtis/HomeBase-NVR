import Foundation
import Darwin

struct Controller: Codable, Equatable {
    let uid: uid_t
    let accountUUID: UUID
}
enum Authorization {
    case local(uid_t)
    case installed(Controller)
    func permits(uid: uid_t, daemonUID: uid_t = geteuid(), lookup: (uid_t) throws -> Controller = Accounts.lookup(uid:)) -> Bool {
        switch self {
        case .local(let owner): return uid == owner
        case .installed(let owner):
            // The daemon account already owns its private configuration and credentials.
            // Both UIDs come from the OS, never from the request or socket file owner.
            if uid == 0 || uid == daemonUID { return true }
            return uid == owner.uid && (try? lookup(uid)) == owner
        }
    }
}
struct ServiceAccount { let uid: uid_t; let gid: gid_t }
enum Accounts {
    static func lookup(name: String) throws -> Controller {
        guard let record = getpwnam(name) else { throw ServiceError("Unknown local account: \(name).") }
        return try lookup(uid: record.pointee.pw_uid)
    }
    static func lookup(uid: uid_t) throws -> Controller {
        guard let record = getpwuid(uid) else { throw ServiceError("Unknown account UID \(uid).") }
        let name = String(cString: record.pointee.pw_name)
        let result = try Processes.run("/usr/bin/dscl", [".", "-read", "/Users/" + name, "GeneratedUID"])
        try Processes.require(result, "Resolve local account identity")
        guard let value = result.output.split(whereSeparator: \.isWhitespace).last, let uuid = UUID(uuidString: String(value)) else {
            throw ServiceError("Account \(name) has no valid local GeneratedUID.")
        }
        return Controller(uid: uid, accountUUID: uuid)
    }
    static func initialOwner(explicit: String?, sudoUID: String?, byName: (String) throws -> Controller = lookup(name:), byUID: (uid_t) throws -> Controller = lookup(uid:)) throws -> Controller {
        if let explicit { return try byName(explicit) }
        guard let sudoUID, let uid = uid_t(sudoUID), uid != 0 else {
            throw ServiceError("First installation requires an originating sudo user or --owner USER.")
        }
        return try byUID(uid)
    }
    static func selectOwner(existing: Controller?, explicit: String?, sudoUID: String?, byName: (String) throws -> Controller = lookup(name:), byUID: (uid_t) throws -> Controller = lookup(uid:)) throws -> Controller {
        if let existing {
            if let explicit, try byName(explicit) != existing { throw ServiceError(.permission, "Installation cannot replace the existing authorized controller.") }
            return existing
        }
        return try initialOwner(explicit: explicit, sudoUID: sudoUID, byName: byName, byUID: byUID)
    }
    static func provision(run: ProcessRunner = Processes.run) throws -> ServiceAccount {
        let user = "/Users/_hbnvr", group = "/Groups/_hbnvr", marker = "HomeBase NVR service"
        func read(_ path: String, _ key: String) throws -> String? {
            let result = try run("/usr/bin/dscl", [".", "-read", path, key])
            if result.status != 0 {
                if result.output.contains("eDSRecordNotFound") { return nil }
                if result.output.contains("eDSAttributeNotFound") || result.output.contains("No such key:") { return nil }
                throw ServiceError("Cannot inspect \(path) \(key): \(result.output)")
            }
            if result.output.contains("No such key:") {
                return nil
            }
            guard let field = result.output.range(of: key + ":") else { throw ServiceError("Invalid directory-service response for \(path) \(key).") }
            return result.output[field.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func create(_ path: String, _ key: String, _ value: String) throws {
            try Processes.require(run("/usr/bin/dscl", [".", "-create", path, key, value]), "Set \(path) \(key)")
        }
        // These exact names are reserved to this application. Installation reconciles
        // their service settings, including records left by an interrupted install.
        let users = try run("/usr/bin/dscl", [".", "-list", "/Users", "UniqueID"])
        let groups = try run("/usr/bin/dscl", [".", "-list", "/Groups", "PrimaryGroupID"])
        try Processes.require(users, "List user IDs"); try Processes.require(groups, "List group IDs")
        func otherIDs(_ output: String) -> Set<UInt32> { Set(output.split(separator: "\n").compactMap { line -> UInt32? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.first != "_hbnvr" else { return nil }
            return fields.last.flatMap { UInt32($0) }
        }) }
        let otherUsers = otherIDs(users.output), otherGroups = otherIDs(groups.output)
        func existingID(_ path: String, _ key: String) throws -> UInt32? {
            guard let value = try read(path, key) else { return nil }
            guard let id = UInt32(value), id != 0 else { throw ServiceError("Invalid \(path) \(key); refusing to change its identity.") }
            return id
        }
        let savedUID = try existingID(user, "UniqueID")
        let savedGID = try existingID(group, "PrimaryGroupID")
        let freeID = (UInt32(400)...UInt32(59999)).first(where: { !otherUsers.contains($0) && !otherGroups.contains($0) && getpwuid($0) == nil && getgrgid($0) == nil })
        guard let uid = savedUID ?? (savedGID.flatMap { otherUsers.contains($0) ? nil : $0 }) ?? freeID,
              let gid = savedGID ?? (otherGroups.contains(uid) ? freeID : uid),
              !otherUsers.contains(uid), !otherGroups.contains(gid) else {
            throw ServiceError("The _hbnvr UID or GID collides with another account, or no unused ID is available.")
        }

        let fields = [(group, "RealName", marker), (user, "RealName", marker),
                      (group, "PrimaryGroupID", String(gid)), (user, "UniqueID", String(uid)),
                      (user, "PrimaryGroupID", String(gid)), (user, "UserShell", "/usr/bin/false"),
                      (user, "NFSHomeDirectory", Paths.system.base + "/private"), (user, "IsHidden", "1")]
        for path in [group, user] {
            if let value = try read(path, "GeneratedUID"), UUID(uuidString: value) == nil { throw ServiceError("Invalid \(path) GeneratedUID; refusing to replace it.") }
        }
        for (path, key, value) in fields where try read(path, key) != value { try create(path, key, value) }
        for path in [group, user] {
            // Directory Services normally generates this identity while creating the record.
            // Never rotate it: macOS can prohibit replacing an existing user GeneratedUID.
            if try read(path, "GeneratedUID") == nil { try create(path, "GeneratedUID", UUID().uuidString) }
            let password = try read(path, "Password")
            if password == nil || password!.isEmpty || !password!.allSatisfy({ $0 == "*" }) { try create(path, "Password", "*") }
        }
        for (path, key, expected) in fields {
            guard try read(path, key) == expected else { throw ServiceError("Repair did not persist \(path) \(key) = \(expected).") }
        }
        for path in [group, user] {
            guard let value = try read(path, "GeneratedUID"), UUID(uuidString: value) != nil else { throw ServiceError("Missing or invalid \(path) GeneratedUID after provisioning.") }
        }
        return ServiceAccount(uid: uid, gid: gid)
    }
}
