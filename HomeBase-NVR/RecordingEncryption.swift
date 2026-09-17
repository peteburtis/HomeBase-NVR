import Foundation
import CryptoKit
import Darwin
import Security

/// Private configuration. A redacted, enabled value means preserve the existing
/// password during editing; an explicit Enabled:false opts out. Missing settings
/// from an older client must never silently switch an encrypted store to plaintext.
struct S3ClientEncryption: Codable, Equatable, Sendable {
    var enabled = true
    var password: String?
    enum CodingKeys: String, CodingKey { case enabled = "Enabled", password = "Password" }
    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.enabled == rhs.enabled else { return false }
        switch (lhs.password, rhs.password) {
        case (nil, nil): return true
        case (.some(let a), .some(let b)): return a.utf8.elementsEqual(b.utf8)
        default: return false
        }
    }
    func validate(requirePassword: Bool = false) throws {
        if let password {
            guard enabled else { throw ServiceError("Remove the encryption password when disabling client-side encryption.") }
            try RecordingEncryption.validatePassword(password)
        } else if enabled && requirePassword { throw ServiceError("A client-side encryption password is required; refusing plaintext recording.") }
    }
}

/// HBNVR-PBE v1 is an application envelope, not the AWS Encryption Client format.
/// The primitives are Apple's CommonCrypto PBKDF2 and CryptoKit AES-256-GCM.
/// Authenticate the entire fixed-size header; freeze the resulting envelope once,
/// before it enters upload/retry/spool management. Never encrypt on replay.
enum RecordingEncryption {
    static let format = "hbnvr-pbe-v1"
    static let magic = Data("HBNVRE01".utf8)
    static let rounds: UInt32 = 600_000
    static let headerSize = 56 // magic(8), rounds BE(4), salt(32), nonce(12)
    static let overhead = headerSize + 16 // GCM authentication tag
    static let maximumPlaintextSize: Int64 = (1 << 36) - 32 // AES-GCM per-invocation limit

    static func validatePassword(_ password: String) throws {
        guard (1...1024).contains(password.utf8.count), !password.utf8.contains(0),
              !password.contains("\n"), !password.contains("\r") else {
            throw ServiceError("Encryption passwords must contain 1...1024 UTF-8 bytes without NUL or newline characters.")
        }
    }
    // Internal to allow a published PBKDF2 test vector. File readers only accept
    // the fixed v1 work factor, preventing attacker-selected excessive KDF work.
    static func deriveKey(password: String, salt: Data, rounds: UInt32) throws -> SymmetricKey {
        try validatePassword(password)
        guard !salt.isEmpty, rounds > 0 else { throw ServiceError("Invalid key derivation parameters.") }
        var derived = [UInt8](repeating: 0, count: 32)
        defer { _ = derived.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        let result = password.withCString { chars in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), chars, password.utf8.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &derived, derived.count)
            }
        }
        guard result == kCCSuccess else { throw ServiceError("Password key derivation failed; no plaintext was uploaded.") }
        return SymmetricKey(data: derived)
    }
    static func encrypt(_ plaintext: Data, password: String) throws -> Data {
        guard Int64(plaintext.count) <= maximumPlaintextSize else { throw ServiceError("Shard exceeds the encryption format's size limit.") }
        var salt = Data(count: 32)
        let result = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        guard result == errSecSuccess else { throw ServiceError("Could not generate encryption salt; no plaintext was uploaded.") }
        let key = try deriveKey(password: password, salt: salt, rounds: rounds)
        let nonce = AES.GCM.Nonce()
        var header = magic
        header.append(contentsOf: [UInt8(rounds >> 24), UInt8(truncatingIfNeeded: rounds >> 16), UInt8(truncatingIfNeeded: rounds >> 8), UInt8(truncatingIfNeeded: rounds)])
        header.append(salt); nonce.withUnsafeBytes { header.append(contentsOf: $0) }
        do {
            let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: header)
            var result = header; result.append(sealed.ciphertext); result.append(sealed.tag); return result
        } catch { throw ServiceError("Shard encryption failed; no plaintext was uploaded.") }
    }
    /// Structural check only, not authentication. Replay need not know an old
    /// shard's password; authentication still happens during offline decryption.
    static func validateEnvelopeHeader(_ header: Data, size: Int64) throws {
        guard size >= overhead, size - Int64(overhead) <= maximumPlaintextSize,
              header.count >= headerSize, header.prefix(8) == magic else { throw ServiceError("Not a supported HBNVR encrypted recording.") }
        let iterations = header[8..<12].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard iterations == rounds else { throw ServiceError("Unsupported encrypted-recording key derivation parameters.") }
    }
    static func decrypt(_ envelope: Data, password: String) throws -> Data {
        let header = Data(envelope.prefix(headerSize))
        try validateEnvelopeHeader(header, size: Int64(envelope.count))
        let key = try deriveKey(password: password, salt: header.subdata(in: 12..<44), rounds: rounds)
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: header.subdata(in: 44..<56)),
                ciphertext: envelope.subdata(in: headerSize..<(envelope.count - 16)), tag: envelope.suffix(16))
            return try AES.GCM.open(box, using: key, authenticating: header)
        } catch { throw ServiceError("Decryption failed: incorrect password or damaged recording. No output was written.") }
    }

    /// Offline recovery. Authenticate fully before writing any plaintext. Publish
    /// a private file without overwriting an existing path (including symlinks).
    static func decryptFile(input: String, output: String, password: String) throws {
        let fd = open(input, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ServiceError.posix("Open encrypted recording") }; defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= overhead, info.st_size <= maximumPlaintextSize + Int64(overhead) else { throw ServiceError("Input must be a supported, regular encrypted recording file.") }
        let bytes = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
        let plaintext = try decrypt(bytes, password: password)
        let url = URL(fileURLWithPath: output).standardizedFileURL
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { throw ServiceError.posix("Open output directory") }; defer { close(parent) }
        let temporary = ".hbnvr-decrypt-" + UUID().uuidString
        let target = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard target >= 0 else { throw ServiceError.posix("Create decrypted recording") }
        defer { close(target); unlinkat(parent, temporary, 0) }
        try plaintext.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(target, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw ServiceError.posix("Write decrypted recording") }; offset += n
            }
        }
        guard fsync(target) == 0 else { throw ServiceError.posix("Persist decrypted recording") }
        guard renameatx_np(parent, temporary, parent, url.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else {
            throw ServiceError.posix("Publish decrypted recording (output must not already exist)")
        }
        guard fsync(parent) == 0 else { throw ServiceError("Decrypted output was created, but its directory could not be synchronized.") }
    }
}
