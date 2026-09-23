import Foundation
import Darwin

/// Requires private daemon access. Requester access is optional; never changes ancestors.
enum StoreDirectory {
    static func identity(_ uid: uid_t) throws -> UUID {
        var value = UUID().uuid
        guard mbr_uid_to_uuid(uid, &value) == 0 else { throw ServiceError(.permission, "Cannot resolve filesystem identity for UID \(uid).") }
        return UUID(uuid: value)
    }
    static func expanded(_ text: String, existingPath: String? = nil) throws -> String {
        let path = (text as NSString).expandingTildeInPath
        guard path.hasPrefix("/"), !path.contains("\0") else { throw ServiceError("Store directory must be an absolute path or start with ~/.") }
        let parts = path.split(separator: "/")
        guard !parts.contains(where: { $0 == "." || $0 == ".." }), let leaf = parts.last else { throw ServiceError("Choose a dedicated recording directory.") }
        let normalized = "/" + parts.joined(separator: "/")
        // Editing a configured destination must not require the CLI user to be
        // able to inspect it. The daemon revalidates its pinned directory on save.
        if normalized == existingPath { return normalized }
        var info = stat()
        if lstat(normalized, &info) == 0 {
            guard info.st_mode & S_IFMT != S_IFLNK else { throw ServiceError(.permission, "Store directory must not be a symbolic link.") }
        } else if ![ENOENT, EACCES, EPERM].contains(errno) { throw ServiceError.posix("Inspect recording directory") }
        let parent = "/" + parts.dropLast().joined(separator: "/")
        guard let resolved = realpath(parent, nil) else {
            // A pre-created daemon-only destination may be inaccessible here.
            // The daemon's no-follow walk remains authoritative, including for aliases.
            if [EACCES, EPERM].contains(errno) { return normalized }
            throw ServiceError.posix("Resolve recording directory parent")
        }
        defer { free(resolved) }
        let prefix = String(cString: resolved)
        return (prefix == "/" ? "" : prefix) + "/" + leaf
    }
    /// Walk from / with openat and O_NOFOLLOW; filesystem operations use the pinned descriptor.
    static func openDirectory(_ path: String) throws -> Int32 {
        guard path.hasPrefix("/"), !path.contains("\0"), !path.split(separator: "/").contains("..") else { throw ServiceError("Invalid store directory.") }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw ServiceError.posix("Open filesystem root") }
        do {
            for part in path.split(separator: "/") {
                let next = openat(fd, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw ServiceError(.permission, "Cannot access store directory \(path): \(String(cString: strerror(errno))). Check ancestor traversal and macOS privacy permissions; HBNVR will not broaden parent-directory permissions.") }
                close(fd); fd = next
            }
            return fd
        } catch { close(fd); throw error }
    }
    static func create(_ path: String, owner: uid_t, daemon: uid_t) throws {
        guard owner == geteuid(), owner != 0 else { throw ServiceError(.permission, "Run store setup as the requesting user, without sudo.") }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard parent != path, path != FileManager.default.homeDirectoryForCurrentUser.path else { throw ServiceError("Choose a dedicated recording directory, not / or your home directory.") }
        // Existing directories are validated by stores.add in the daemon, not
        // by the requesting account. Never adopt, chmod, or reopen them here.
        var info = stat()
        if lstat(path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFDIR else { throw ServiceError(.permission, "Recording destination must be a directory, not a symbolic link or file.") }
            return
        }
        if [EACCES, EPERM].contains(errno) { return }
        guard errno == ENOENT else { throw ServiceError.posix("Inspect recording directory") }
        let fd = try openDirectory(parent); defer { close(fd) }
        let leaf = URL(fileURLWithPath: path).lastPathComponent
        if mkdirat(fd, leaf, 0o700) != 0 {
            guard errno == EEXIST else { throw ServiceError.posix("Create recording directory") }
            return // The daemon validates even if another process created it meanwhile.
        }
        let created = openat(fd, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard created >= 0 else { throw ServiceError.posix("Open new recording directory") }
        defer { close(created) }
        do { try restrict(created, owner: owner, daemon: daemon, directory: true) }
        catch { _ = unlinkat(fd, leaf, AT_REMOVEDIR); throw error }
    }
    static func restrict(_ fd: Int32, owner: uid_t, daemon: uid_t, directory: Bool) throws {
        var acl = acl_init(2)
        guard acl != nil else { throw ServiceError.posix("Allocate recording ACL") }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        for uid in Set([owner, daemon]).sorted() {
            var entry: acl_entry_t?
            var uuid = try identity(uid).uuid
            guard acl_create_entry(&acl, &entry) == 0, let entry,
                  acl_set_tag_type(entry, ACL_EXTENDED_ALLOW) == 0,
                  acl_set_qualifier(entry, &uuid) == 0,
                  acl_set_permset_mask_np(entry, rights(directory: directory)) == 0 else { throw ServiceError.posix("Configure recording ACL") }
            if directory {
                var flags: acl_flagset_t?
                guard acl_get_flagset_np(UnsafeMutableRawPointer(entry), &flags) == 0,
                      acl_add_flag_np(flags, ACL_ENTRY_FILE_INHERIT) == 0,
                      acl_add_flag_np(flags, ACL_ENTRY_DIRECTORY_INHERIT) == 0 else { throw ServiceError.posix("Configure recording ACL inheritance") }
            }
        }
        guard fchmod(fd, directory ? 0o700 : 0o600) == 0, acl_set_fd_np(fd, acl, ACL_TYPE_EXTENDED) == 0 else { throw ServiceError.posix("Set private recording permissions") }
    }
    private static func rights(directory: Bool) -> acl_permset_mask_t {
        // Read/write data, append, attributes, extended attributes, and inspect security.
        var mask: UInt64 = (1 << 1) | (1 << 2) | (1 << 5) | (1 << 7) | (1 << 8) | (1 << 9) | (1 << 10) | (1 << 11)
        if directory { mask |= (1 << 3) | (1 << 6) } // traverse and remove children
        return mask
    }
    static func validate(_ fd: Int32, owner: uid_t, daemon: uid_t) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              [owner, daemon].contains(info.st_uid), info.st_mode & 0o077 == 0 else {
            throw ServiceError(.permission, "Recording directory must belong to the requester or daemon, have no group/other POSIX access, and keep data-access ACLs private to those accounts. Only the daemon requires access; requester permissions may be removed. Existing permissions were not changed.")
        }
        let acl = try SecureFiles.readACL(fd)
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        let daemonID = try identity(daemon), expected = try Set([identity(owner), daemonID])
        // Finder can leave everyone readattr/readsecurity after editing access.
        // These do not grant directory listing, traversal, or video reads. Do
        // not include readextattr: extended attributes may contain private data.
        let visibleMetadata: acl_permset_mask_t = (1 << 7) | (1 << 11)
        var daemonRights: acl_permset_mask_t = 0, entry: acl_entry_t?
        let daemonOwns = info.st_uid == daemon && info.st_mode & 0o700 == 0o700
        var result = acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry)
        while result == 0, let current = entry {
            var tag = ACL_UNDEFINED_TAG, mask: acl_permset_mask_t = 0
            guard let qualifier = acl_get_qualifier(current) else { throw ServiceError("Invalid recording ACL principal.") }
            let id = UUID(uuid: qualifier.assumingMemoryBound(to: uuid_t.self).pointee)
            acl_free(qualifier)
            var flags: acl_flagset_t?
            guard acl_get_tag_type(current, &tag) == 0,
                  tag == ACL_EXTENDED_ALLOW || (tag == ACL_EXTENDED_DENY && id != daemonID),
                  acl_get_permset_mask_np(current, &mask) == 0,
                  expected.contains(id) || (tag == ACL_EXTENDED_ALLOW && mask & ~visibleMetadata == 0),
                  tag == ACL_EXTENDED_DENY || mask & ~rights(directory: true) == 0,
                  acl_get_flagset_np(UnsafeMutableRawPointer(current), &flags) == 0 else {
                throw ServiceError(.permission, "Recording directory has unexpected ACLs; unrelated principals may only be allowed readattr/readsecurity, not access to recordings. Existing permissions were not changed.")
            }
            if id == daemonID, acl_get_flag_np(flags, ACL_ENTRY_ONLY_INHERIT) == 0 { daemonRights |= mask }
            result = acl_get_entry(acl, ACL_NEXT_ENTRY.rawValue, &entry)
        }
        guard daemonOwns || daemonRights & rights(directory: true) == rights(directory: true) else {
            throw ServiceError(.permission, "Recording directory requires daemon read/write/traverse access: daemon ownership with mode 0700, or a daemon ACL granting recording access. Requester access is optional; existing permissions were not changed.")
        }
        if geteuid() == daemon, faccessat(fd, ".", R_OK | W_OK | X_OK, AT_EACCESS) != 0 {
            throw ServiceError.posix("Access recording directory as daemon")
        }
    }
    static func child(_ name: String, parent: Int32, owner: uid_t, daemon: uid_t) throws -> Int32 {
        guard !name.contains("/"), name != ".", name != ".." else { throw ServiceError("Invalid recording subdirectory.") }
        let created = mkdirat(parent, name, 0o700) == 0
        guard created || errno == EEXIST else { throw ServiceError.posix("Create recording subdirectory") }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ServiceError.posix("Open recording subdirectory") }
        do {
            // Retain the parent's inherited ACLs, including absent/reduced
            // requester access. Do not recreate the initial setup grants.
            if created, fchmod(fd, 0o700) != 0 { throw ServiceError.posix("Set recording subdirectory mode") }
            try validate(fd, owner: owner, daemon: daemon)
            return fd
        } catch { close(fd); throw error }
    }
}
