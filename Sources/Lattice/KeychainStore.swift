import Foundation
import Security
import LatticeCore

// MARK: - Structured results

enum KeychainStoreError: Error, Equatable, Sendable {
    case emptyValue
    case encodingFailed
    case unexpectedStatus(OSStatus)

    var message: String {
        switch self {
        case .emptyValue:
            return "Keychain value must not be empty."
        case .encodingFailed:
            return "Keychain value could not be encoded as UTF-8 data."
        case .unexpectedStatus(let status):
            return "Keychain operation failed with status \(status)."
        }
    }
}

enum KeychainStoreSaveResult: Equatable, Sendable {
    case success
    case failure(KeychainStoreError)

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var error: KeychainStoreError? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

// MARK: - Store

enum KeychainStore {
    private static let service = "Lattice"
    /// Pre-rename keychain service; read-only fallback so secrets survive the brand rename.
    private static let legacyService = LatticeLegacyBrandCompatibility.keychainService

    /// Bounded retries when update/add races with a concurrent writer (duplicate item).
    private static let maxDuplicateRaceAttempts = 4

    static func hasValue(account: String) -> Bool { read(account: account) != nil }

    static func read(account: String) -> String? {
        if let value = read(account: account, service: service) {
            return value
        }
        guard let legacy = read(account: account, service: legacyService) else { return nil }
        // Promote legacy secrets into the Lattice service on first successful read.
        // Only remove the legacy entry after a confirmed successful write to the new service.
        let promotion = saveResult(legacy, account: account, service: service)
        if promotion.isSuccess {
            delete(account: account, service: legacyService)
        }
        return legacy
    }

    /// Compatibility boolean API used by existing call sites.
    @discardableResult
    static func save(_ value: String, account: String) -> Bool {
        saveResult(value, account: account).isSuccess
    }

    /// Update-or-add with duplicate-race retry. Never delete-then-add.
    @discardableResult
    static func saveResult(_ value: String, account: String) -> KeychainStoreSaveResult {
        saveResult(value, account: account, service: service)
    }

    static func delete(account: String) {
        delete(account: account, service: service)
        delete(account: account, service: legacyService)
    }

    // MARK: - Internals

    private static func saveResult(
        _ value: String,
        account: String,
        service: String
    ) -> KeychainStoreSaveResult {
        guard !value.isEmpty else { return .failure(.emptyValue) }
        let data = Data(value.utf8)
        // UTF-8 encoding of a non-empty String is always non-empty for scalar text;
        // keep the branch for defensive completeness if Data bridging ever changes.
        guard !data.isEmpty else { return .failure(.encodingFailed) }

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        for _ in 0..<maxDuplicateRaceAttempts {
            // Prefer in-place update so we never drop the only copy on a failed re-add.
            let updateStatus = SecItemUpdate(
                baseQuery as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            switch updateStatus {
            case errSecSuccess:
                return .success
            case errSecItemNotFound:
                var addQuery = baseQuery
                addQuery[kSecValueData as String] = data
                let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
                switch addStatus {
                case errSecSuccess:
                    return .success
                case errSecDuplicateItem:
                    // Lost the race to another writer — retry via update.
                    continue
                default:
                    return .failure(.unexpectedStatus(addStatus))
                }
            default:
                return .failure(.unexpectedStatus(updateStatus))
            }
        }
        return .failure(.unexpectedStatus(errSecDuplicateItem))
    }

    private static func read(account: String, service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func delete(account: String, service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
