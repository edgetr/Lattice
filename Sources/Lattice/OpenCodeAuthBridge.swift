import Foundation
import LatticeCore

// MARK: - Structured results

enum OpenCodeAuthError: Error, Equatable, Sendable {
    case missingCredential
    case malformedAuthFile(String)
    case conflict
    case writeFailed(String)

    var message: String {
        switch self {
        case .missingCredential:
            return "OpenCode Go API key is not available in the keychain."
        case .malformedAuthFile(let detail):
            return "OpenCode auth.json is malformed: \(detail)"
        case .conflict:
            return "OpenCode auth.json changed concurrently; merge retries exhausted."
        case .writeFailed(let detail):
            return "Failed to update OpenCode auth.json: \(detail)"
        }
    }
}

enum OpenCodeAuthMutationResult: Equatable, Sendable {
    case success
    case failure(OpenCodeAuthError)

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var error: OpenCodeAuthError? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

// MARK: - Bridge

/// Serializes mutations to `~/.local/share/opencode/auth.json` with conflict-aware merge.
///
/// Guarantees:
/// - Unknown / unrelated top-level fields are preserved.
/// - Malformed JSON is never treated as an empty object.
/// - Concurrent modifications are detected; mutate-and-retry is bounded.
/// - Writes use a same-directory unique temp file (mode `0600`) then atomic replacement.
enum OpenCodeAuthBridge {
    private static let mutationLock = NSLock()
    private static let goProviderKey = "opencode-go"
    private static let goAPIKeyAccount = "opencode-go-api-key"

    private static var authURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/auth.json")
    }

    // MARK: Public API (compat + structured)

    @discardableResult
    static func syncGoAPIKeyFromKeychain() -> Bool {
        syncGoAPIKeyFromKeychainResult().isSuccess
    }

    static func syncGoAPIKeyFromKeychainResult() -> OpenCodeAuthMutationResult {
        guard let value = KeychainStore.read(account: goAPIKeyAccount)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return .failure(.missingCredential)
        }
        return writeGoAPIKeyResult(value)
    }

    static func hasGoCredential() -> Bool {
        switch readAuthRoot(at: authURL) {
        case .success(let root):
            return CredentialPresencePolicy.hasOpenCodeGoCredential(in: root)
        case .failure:
            // Malformed file: do not claim a credential is present.
            return false
        }
    }

    static func removeGoAPIKey() {
        _ = removeGoAPIKeyResult()
    }

    @discardableResult
    static func removeGoAPIKeyResult() -> OpenCodeAuthMutationResult {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        return AtomicJSONFileTransaction.mutateObject(at: authURL) { root in
            root.removeValue(forKey: goProviderKey)
        }.asOpenCodeResult
    }

    // MARK: Private

    @discardableResult
    private static func writeGoAPIKey(_ value: String) -> Bool {
        writeGoAPIKeyResult(value).isSuccess
    }

    private static func writeGoAPIKeyResult(_ value: String) -> OpenCodeAuthMutationResult {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        return AtomicJSONFileTransaction.mutateObject(at: authURL) { root in
            // Preserve unrelated providers/fields; only replace the Go credential entry.
            root[goProviderKey] = ["type": "api", "key": value]
        }.asOpenCodeResult
    }

    /// Reads the auth root. Missing file → empty object. Malformed → failure (never empty).
    private static func readAuthRoot(at url: URL) -> Result<[String: Any], OpenCodeAuthError> {
        switch AtomicJSONFileTransaction.readObject(at: url) {
        case .success(let snapshot):
            return .success(snapshot.object ?? [:])
        case .failure(let error):
            return .failure(.malformedAuthFile(error.message))
        }
    }
}

private extension AtomicJSONFileWriteResult {
    var asOpenCodeResult: OpenCodeAuthMutationResult {
        switch self {
        case .success:
            return .success
        case .conflict:
            return .failure(.conflict)
        case .failure(let message):
            // Surface malformed baseline through the write path's read step message.
            if message.localizedCaseInsensitiveContains("not valid JSON")
                || message.localizedCaseInsensitiveContains("not a JSON object") {
                return .failure(.malformedAuthFile(message))
            }
            return .failure(.writeFailed(message))
        }
    }
}
