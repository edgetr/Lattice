import Foundation
import LatticeCore
import Combine

/// Composition-root handle for run orchestration work.
/// Live runUIStates/activeRunIDs remain on AppState until a full ownership move.
/// This type intentionally holds no dual `@Published` run maps.
@MainActor
final class RunOrchestrator: ObservableObject {
    /// Reserved for future ownership of apply/finalize extraction.
    /// Do not mirror AppState run maps here.
}
