import Foundation

public enum SessionPrivacyPolicy {
    public static let cloudBlockedMessage = "Local-only mode blocks cloud provider routes. Choose Apple Intelligence or a local Ollama model."

    public static func allows(_ backend: ChatBackend, in mode: SessionPrivacyMode) -> Bool {
        switch mode {
        case .cloudAllowed:
            return true
        case .localOnly:
            return backend.isLocal
        }
    }

    public static func blockedMessage(for backend: ChatBackend, in mode: SessionPrivacyMode) -> String? {
        allows(backend, in: mode) ? nil : cloudBlockedMessage
    }
}
