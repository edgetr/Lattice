import Foundation

/// Minimal, secret-blind checks for provider-owned credential files.
///
/// These checks establish that a file has the shape expected by its provider.
/// They do not validate tokens with a service or claim that credentials are usable.
public enum CredentialPresencePolicy {
    public static func hasOpenCodeGoCredential(in root: [String: Any]) -> Bool {
        guard let provider = root["opencode-go"] as? [String: Any],
              provider["type"] as? String == "api",
              let key = provider["key"] as? String else {
            return false
        }
        return hasNonBlankString(key)
    }

    /// Validates the legacy Gemini OAuth file without inspecting token contents.
    /// A refresh token or access token is enough for a syntactically valid local
    /// credential record; actual provider authentication remains provider-owned.
    public static func hasAntigravityOAuthCredential(in data: Data) -> Bool {
        guard !data.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: data),
              let object = root as? [String: Any] else {
            return false
        }

        return ["access_token", "refresh_token"].contains {
            guard let value = object[$0] as? String else { return false }
            return hasNonBlankString(value)
        }
    }

    /// Validates the account-cache marker when the optional cache is present.
    /// This marker is not itself a credential and must never authenticate a user.
    public static func hasAntigravityAccountMarker(in data: Data) -> Bool {
        guard !data.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: data),
              let object = root as? [String: Any],
              let active = object["active"] as? String else {
            return false
        }
        return hasNonBlankString(active)
    }

    private static func hasNonBlankString(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
