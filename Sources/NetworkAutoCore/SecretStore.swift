import Foundation
import Security

public protocol SecretStore: Sendable {
    func loadPassword() throws -> String?
    func savePassword(_ password: String) throws
    func deletePassword() throws
}

public enum SecretStoreError: Error, LocalizedError, Equatable {
    case keychainFailure(OSStatus, String)
    case encodingFailure

    public var errorDescription: String? {
        switch self {
        case .keychainFailure(let status, let message):
            return "钥匙串读写失败（\(status)）：\(message)"
        case .encodingFailure:
            return "密码编码格式无效。"
        }
    }
}

public final class KeychainSecretStore: SecretStore, Sendable {
    private let service: String
    private let account: String

    public init(
        service: String = AppConstants.bundleIdentifier,
        account: String = "campus-password"
    ) {
        self.service = service
        self.account = account
    }

    public func loadPassword() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw SecretStoreError.keychainFailure(status, describe(status))
        }
        guard let data = item as? Data, let password = String(data: data, encoding: .utf8) else {
            throw SecretStoreError.encodingFailure
        }
        return password
    }

    public func savePassword(_ password: String) throws {
        guard let data = password.data(using: .utf8) else {
            throw SecretStoreError.encodingFailure
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrLabel as String] = AppConstants.displayName
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw SecretStoreError.keychainFailure(addStatus, describe(addStatus))
            }
            return
        }
        throw SecretStoreError.keychainFailure(updateStatus, describe(updateStatus))
    }

    public func deletePassword() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.keychainFailure(status, describe(status))
        }
    }

    private func describe(_ status: OSStatus) -> String {
        switch status {
        case errSecAuthFailed, errSecUserCanceled:
            return "未授权访问钥匙串（请使用固定代码签名证书重新编译并在系统弹窗中选择“始终允许”）"
        case errSecInteractionNotAllowed:
            return "钥匙串当前已锁定，无法交互授权"
        default:
            return (SecCopyErrorMessageString(status, nil) as String?) ?? "未知错误"
        }
    }
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var password: String?
    public var simulatedError: Error?

    public init(password: String? = nil) {
        self.password = password
    }

    public func loadPassword() throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let simulatedError { throw simulatedError }
        return password
    }

    public func savePassword(_ password: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if let simulatedError { throw simulatedError }
        self.password = password
    }

    public func deletePassword() throws {
        lock.lock()
        defer { lock.unlock() }
        if let simulatedError { throw simulatedError }
        password = nil
    }
}
