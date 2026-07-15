import Foundation
import LatticeCore
import Combine

/// Owns provider runtime snapshots and connection-refresh presentation state.
@MainActor
final class ProviderConnectionStore: ObservableObject {
    @Published private(set) var snapshots: [String: ProviderRuntimeSnapshot] = [:]
    @Published private(set) var isRefreshingConnections = false
    @Published private(set) var connectionRefreshAction = ControlActionState()

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
