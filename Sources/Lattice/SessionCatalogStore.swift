import Foundation
import LatticeCore
import Combine

/// Composition-root handle for session catalog work.
/// Live sessions/selection remain on AppState until a full ownership move.
/// This type intentionally holds no dual `@Published` session maps.
@MainActor
final class SessionCatalogStore: ObservableObject {
    /// Reserved for future ownership of persistence/hydration side channels.
    /// Do not mirror AppState.sessions here.
}
