import Foundation

/// Secret-free result state from a non-interactive credential read.
/// The value itself stays in the app target; Core only decides whether a
/// legacy service may be consulted and how a failure must be presented.
public enum CredentialReadState: Equatable, Sendable {
    case value
    case missing
    case locked
    case denied
    case unavailable
    case invalidData
}

public enum CredentialReadPolicy {
    /// Legacy migration is safe only when the current service authoritatively
    /// says that no item exists. Access failures must never fall through.
    public static func shouldConsultLegacy(after state: CredentialReadState) -> Bool {
        state == .missing
    }

    public static func availability(for state: CredentialReadState) -> CredentialStoreAvailability {
        switch state {
        case .value: .present
        case .missing: .missing
        case .locked: .locked
        case .denied: .denied
        case .unavailable, .invalidData: .unavailable
        }
    }

    public static func failureMessage(for state: CredentialReadState, provider: String) -> String {
        switch state {
        case .value:
            return ""
        case .missing:
            return "\(provider) credential is not saved. Add it in Connections, then try again."
        case .locked:
            return "The Keychain is locked. Unlock it, then try \(provider) again."
        case .denied:
            return "Keychain access was denied. Allow access for Lattice, then try \(provider) again."
        case .unavailable:
            return "The Keychain is unavailable. Check macOS Keychain access, then try \(provider) again."
        case .invalidData:
            return "The saved \(provider) credential is unreadable. Replace it in Connections, then try again."
        }
    }
}
