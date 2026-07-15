import Foundation
import LatticeCore
import Combine

/// Sole owner of provider connection observation state.
/// Snapshot map is the source of truth for readiness, catalogs, CLI versions, and models.
/// Extra fields that do not fit the generic snapshot (rich Ollama models, protocol enums) live here too.
@MainActor
final class ProviderConnectionStore: ObservableObject {
    @Published private(set) var snapshots: [String: ProviderRuntimeSnapshot] = [:]

    /// Rich local model rows (size/quantization) — not fully representable as `ProviderModel`.
    @Published var ollamaModels: [OllamaModel] = []
    /// Codex image-input protocol probe (not part of the generic snapshot shape).
    @Published var codexImageInputProtocolSupport: InputCapabilitySupport = .unknown
    /// Antigravity structured-vs-transcript protocol probe.
    @Published var antigravityProtocolSupport: AntigravityCLIProtocol = .transcript(reason: "Not checked.")

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

    // MARK: - Map-driven accessors (single source of truth)

    func ready(_ key: ProviderConnectionKey) -> Bool { snapshot(for: key).ready }
    func installed(_ key: ProviderConnectionKey) -> Bool { snapshot(for: key).installed }
    func authenticated(_ key: ProviderConnectionKey) -> Bool { snapshot(for: key).authenticated }
    func catalogStatus(_ key: ProviderConnectionKey) -> ProviderCatalogStatus { snapshot(for: key).catalogStatus }
    func models(_ key: ProviderConnectionKey) -> [ProviderModel] { snapshot(for: key).models }
    func harnessModels(_ key: ProviderConnectionKey) -> [HarnessModel] { snapshot(for: key).harnessModels }
    func cliVersion(_ key: ProviderConnectionKey) -> String? { snapshot(for: key).cliVersion }
    func latestCLIVersion(_ key: ProviderConnectionKey) -> String? { snapshot(for: key).latestCLIVersion }
    func protocolDetail(_ key: ProviderConnectionKey) -> String? { snapshot(for: key).protocolDetail }
    func usage(_ key: ProviderConnectionKey) -> ProviderUsage? { snapshot(for: key).usage }
    func updateInfo(_ key: ProviderConnectionKey) -> CLIUpdateInfo? { snapshot(for: key).updateInfo }

    func piModelIDs() -> Set<String> {
        Set(snapshot(for: .pi).models.map(\.id))
    }

    /// Rebuild a snapshot while preserving fields not explicitly overridden.
    func update(_ key: ProviderConnectionKey, mutate: (inout ProviderRuntimeSnapshot) -> Void) {
        var current = snapshot(for: key)
        mutate(&current)
        // Reconstruct so `ready` stays formula-driven.
        setSnapshot(
            ProviderRuntimeSnapshot(
                installed: current.installed,
                authenticated: current.authenticated,
                catalogStatus: current.catalogStatus,
                models: current.models,
                harnessModels: current.harnessModels,
                cliVersion: current.cliVersion,
                latestCLIVersion: current.latestCLIVersion,
                protocolDetail: current.protocolDetail,
                runnableModelCount: current.runnableModelCount,
                usage: current.usage,
                updateInfo: current.updateInfo
            ),
            for: key
        )
    }

    func setCatalogStatus(_ status: ProviderCatalogStatus, for key: ProviderConnectionKey) {
        update(key) { $0.catalogStatus = status }
    }

    func setUpdateInfo(_ info: CLIUpdateInfo, for key: ProviderConnectionKey) {
        update(key) {
            $0.updateInfo = info
            $0.cliVersion = info.currentVersion
            $0.latestCLIVersion = info.latestVersion
            if let detail = info.detail { $0.protocolDetail = detail }
        }
    }
}
