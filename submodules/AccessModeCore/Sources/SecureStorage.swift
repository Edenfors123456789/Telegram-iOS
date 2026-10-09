import Foundation
import CryptoKit
import CommonCrypto
import Security
import LocalAuthentication
import Darwin

enum AccessCrypto {
    static let minimumIterations = 600_000
    static let maximumIterations = 3_000_000

    static func calibratedIterations() -> Int {
        let count = Int(CCCalibratePBKDF(CCPBKDFAlgorithm(kCCPBKDF2), 32, 16,
                                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 32, 350))
        return min(maximumIterations, max(minimumIterations, count))
    }

    static func random(_ count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw AccessError.keychain(status) }
        return data
    }

    static func derive(_ pin: String, deviceKey: Data, salt: Data, iterations: Int) throws -> Data {
        guard deviceKey.count == 32, salt.count == 16,
              (minimumIterations ... maximumIterations).contains(iterations) else { throw AccessError.corrupt }
        var password = Data(HMAC<SHA256>.authenticationCode(for: Data(("telegram.dual-pin.v1\0" + pin).utf8),
                                                          using: SymmetricKey(data: deviceKey)))
        defer { password.resetBytes(in: 0 ..< password.count) }
        var key = Data(count: 32)
        let result = password.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                key.withUnsafeMutableBytes { keyBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes.baseAddress!.assumingMemoryBound(to: Int8.self),
                        password.count, saltBytes.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                        keyBytes.baseAddress!.assumingMemoryBound(to: UInt8.self), 32)
                }
            }
        }
        guard result == kCCSuccess else { key.resetBytes(in: 0 ..< key.count); throw AccessError.unavailable }
        return key
    }

    static func seal(_ data: Data, key: Data, context: String) throws -> Data {
        guard key.count == 32 else { throw AccessError.corrupt }
        let result = try AES.GCM.seal(data, using: SymmetricKey(data: key),
                                     nonce: AES.GCM.Nonce(data: random(12)), authenticating: Data(context.utf8))
        guard let combined = result.combined else { throw AccessError.corrupt }
        return combined
    }

    static func open(_ data: Data, key: Data, context: String) throws -> Data {
        guard key.count == 32, data.count >= 28 else { throw AccessError.corrupt }
        do { return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: SymmetricKey(data: key), authenticating: Data(context.utf8)) }
        catch { throw AccessError.corrupt }
    }
}

/// Supplies a device-local key. Implementations must never replace an existing key or
/// generate a key when `allowCreation` is false (for example, after loss of Keychain state).
public protocol AccessDeviceKeyProvider {
    func loadKey(allowCreation: Bool) throws -> Data
}

public final class KeychainAccessDeviceKey: AccessDeviceKeyProvider {
    private let service: String
    private let accessGroup: String?

    public init(service: String, accessGroup: String? = nil) throws {
        guard !service.isEmpty, service.contains(".") else { throw AccessError.invalidConfiguration }
        self.service = service
        self.accessGroup = accessGroup
    }

    private var query: [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        var result: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "dual-pin-device-key.v1",
            kSecAttrSynchronizable as String: false, kSecUseAuthenticationContext as String: context]
        if let accessGroup { result[kSecAttrAccessGroup as String] = accessGroup }
        #if os(macOS)
        result[kSecUseDataProtectionKeychain as String] = true
        #endif
        return result
    }

    public func loadKey(allowCreation: Bool) throws -> Data {
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &item)
        if status == errSecSuccess {
            guard let data = item as? Data, data.count == 32 else { throw AccessError.corrupt }
            return data
        }
        guard status == errSecItemNotFound else { throw AccessError.keychain(status) }
        guard allowCreation else { throw AccessError.missingKey }
        let key = try AccessCrypto.random(32)
        var create = query
        create.removeValue(forKey: kSecUseAuthenticationContext as String)
        create[kSecValueData as String] = key
        create[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(create as CFDictionary, nil)
        if added == errSecDuplicateItem { return try loadKey(allowCreation: false) }
        guard added == errSecSuccess else { throw AccessError.keychain(added) }
        return key
    }
}

/// No delete/reset path: errors cannot silently discard existing access state.
final class EncryptedAccessFile<State: Codable> {
    struct Envelope: Codable {
        let version: Int
        let revision: UInt64
        let ciphertext: Data
    }

    let directory: URL
    let keyProvider: AccessDeviceKeyProvider
    private let namespace: String
    private let mutex = NSLock()
    private var stateURL: URL { directory.appendingPathComponent("access-state.v1.enc") }

    init(directory: URL, namespace: String, keyProvider: AccessDeviceKeyProvider) throws {
        guard directory.isFileURL, !namespace.isEmpty else { throw AccessError.invalidConfiguration }
        self.directory = directory
        self.namespace = namespace
        self.keyProvider = keyProvider
    }

    func read() throws -> State {
        try locked {
            guard let value = try load().state else { throw AccessError.authenticationRequired }
            return value
        }
    }

    /// The closure runs under an interprocess lock; throwing leaves the previous file intact.
    /// Authentication failure is returned as a Result so its attempt state is committed first.
    func transaction<Result>(expectedRevision: UInt64? = nil, allowInitialization: Bool = false, _ body: (inout State?, Data) throws -> Result) throws -> Result {
        try locked {
            let loaded = try load(allowInitialization: allowInitialization)
            if let expectedRevision, expectedRevision != loaded.revision { throw AccessError.revisionConflict }
            guard loaded.revision < UInt64.max else { throw AccessError.corrupt }
            var value = loaded.state
            let result = try body(&value, loaded.key)
            guard let value else { throw AccessError.invalidTransition }
            try write(value, key: loaded.key, revision: loaded.revision + 1)
            return result
        }
    }

    private func context(_ revision: UInt64) -> String { "telegram.dual-pin.vault.v1:\(namespace):\(revision)" }

    private func load(allowInitialization: Bool = false) throws -> (state: State?, key: Data, revision: UInt64) {
        let fd = Darwin.open(stateURL.path, O_RDONLY | O_NOFOLLOW)
        if fd < 0 {
            guard errno == ENOENT else { throw AccessError.unavailable }
            return (nil, allowInitialization ? try keyProvider.loadKey(allowCreation: true) : Data(), 0)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size <= 4 * 1024 * 1024 else { throw AccessError.corrupt }
        let data = try handle.readToEnd() ?? Data()
        let envelope: Envelope
        do { envelope = try JSONDecoder().decode(Envelope.self, from: data) } catch { throw AccessError.corrupt }
        guard envelope.version == 1 else { throw AccessError.unsupportedVersion }
        guard envelope.revision > 0 else { throw AccessError.corrupt }
        let key = try keyProvider.loadKey(allowCreation: false)
        var plain = try AccessCrypto.open(envelope.ciphertext, key: key, context: context(envelope.revision))
        defer { plain.resetBytes(in: 0 ..< plain.count) }
        do { return (try JSONDecoder().decode(State.self, from: plain), key, envelope.revision) }
        catch { throw AccessError.corrupt }
    }

    private func write(_ state: State, key: Data, revision: UInt64) throws {
        var plain = try JSONEncoder().encode(state)
        defer { plain.resetBytes(in: 0 ..< plain.count) }
        let envelope = Envelope(version: 1, revision: revision, ciphertext: try AccessCrypto.seal(plain, key: key, context: context(revision)))
        let data = try JSONEncoder().encode(envelope)
        guard data.count <= 4 * 1024 * 1024 else { throw AccessError.unavailable }
        let temporary = directory.appendingPathComponent(".access-\(UUID().uuidString).tmp")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw AccessError.unavailable }
        defer { Darwin.close(fd); Darwin.unlink(temporary.path) }
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: temporary.path)
        #endif
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw AccessError.unavailable }
                offset += count
            }
        }
        guard fsync(fd) == 0, Darwin.rename(temporary.path, stateURL.path) == 0 else { throw AccessError.unavailable }
        let parent = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY)
        guard parent >= 0 else { throw AccessError.unavailable }
        defer { Darwin.close(parent) }
        guard fsync(parent) == 0 else { throw AccessError.unavailable }
    }

    private func locked<Result>(_ body: () throws -> Result) throws -> Result {
        mutex.lock()
        defer { mutex.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        var folder = directory
        try folder.setResourceValues(resources)
        let fd = Darwin.open(directory.appendingPathComponent("access-state.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw AccessError.unavailable }
        defer { Darwin.close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw AccessError.unavailable }
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}
