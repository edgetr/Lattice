import Foundation
import LatticeCore
import Combine

/// Owns the provider runtime snapshot map only.
/// Refresh presentation (`isRefreshingConnections`, `connectionRefreshAction`) stays on AppState
/// until a real ownership move; do not mirror those fields here.
@MainActor
final class ProviderConnectionStore: ObservableObject {
    @Published private(set) var snapshots: [String: ProviderRuntimeSnapshot] = [:]

    func snapshot(for key: ProviderConnectionKey) -> ProviderRuntimeSnapshot {
        ProviderRuntimeSnapshotStore.snapshot(in: snapshots, key: key)
    }

    func setSnapshot(_ snapshot: ProviderRuntimeSnapshot, for key: ProviderConnectionKey) {
        ProviderRuntimeSnapshotStore.upsert(&snapshots, key: key, snapshot: snapshot)
    }

    func markLoading(_ key: ProviderConnectionKey) {
        ProviderRuntimeSnapshotStore.markLoading(&snapshots, key: key)
    }

    func replaceAll(_ newSnapshots: [String: ProviderRuntimeSnapshot]) {
        snapshots = newSnapshots
    }
}
