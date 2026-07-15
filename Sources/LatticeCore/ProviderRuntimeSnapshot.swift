import Foundation

/// Stable keys for provider/runtime connection snapshots.
/// Prefer these over parallel per-provider `@Published` fields.
public enum ProviderConnectionKey: String, CaseIterable, Codable, Hashable, Sendable {
    case codex
    case grok
    case opencode
    case antigravity
    case pi
    case hermes
    case ollama
    case apple
}

/// Map-driven provider runtime observation. Never caches secrets.
public struct ProviderRuntimeSnapshot: Equatable, Sendable {
    public var installed: Bool
    public var authenticated: Bool
    public var catalogStatus: ProviderCatalogStatus
    public var models: [ProviderModel]
    public var harnessModels: [HarnessModel]
    public var cliVersion: String?
    public var latestCLIVersion: String?
    /// Freeform protocol/detail note (unavailable reason, protocol support text, etc.).
    public var protocolDetail: String?
    /// Explicit runnable-model count used for readiness. Prefer this over raw model array lengths
    /// so filtered catalogs (visible/runnable) and harness-only catalogs stay consistent.
    public var runnableModelCount: Int
    public var ready: Bool
    public var usage: ProviderUsage?
    public var updateInfo: CLIUpdateInfo?

    /// - Note: `ready` is always derived from installed/authenticated/catalog/runnableModelCount.
    ///   Callers cannot force a ready bit that disagrees with the formula.
    public init(
        installed: Bool = false,
        authenticated: Bool = false,
        catalogStatus: ProviderCatalogStatus = .unknown,
        models: [ProviderModel] = [],
        harnessModels: [HarnessModel] = [],
        cliVersion: String? = nil,
        latestCLIVersion: String? = nil,
        protocolDetail: String? = nil,
        runnableModelCount: Int? = nil,
        usage: ProviderUsage? = nil,
        updateInfo: CLIUpdateInfo? = nil
    ) {
        self.installed = installed
        self.authenticated = authenticated
        self.catalogStatus = catalogStatus
        self.models = models
        self.harnessModels = harnessModels
        self.cliVersion = cliVersion
        self.latestCLIVersion = latestCLIVersion
        self.protocolDetail = protocolDetail
        let count = runnableModelCount
            ?? max(models.count, harnessModels.count)
        self.runnableModelCount = max(0, count)
        self.ready = ProviderRuntimeSnapshotStore.computeReady(
            installed: installed,
            authenticated: authenticated,
            catalogStatus: catalogStatus,
            runnableModelCount: self.runnableModelCount
        )
        self.usage = usage
        self.updateInfo = updateInfo
    }

    public static let empty = ProviderRuntimeSnapshot()

    /// Single readiness formula — always agrees with `ready` when constructed via the designated init.
    public var readiness: ProviderReadinessSnapshot {
        ProviderReadinessSnapshot(
            installed: installed,
            authenticated: authenticated,
            catalogStatus: catalogStatus,
            runnableModelCount: runnableModelCount
        )
    }

    /// Apply catalog-loading transition without inventing readiness.
    public func markingCatalogLoading() -> ProviderRuntimeSnapshot {
        var copy = self
        copy.catalogStatus = .loading
        copy.ready = false
        return copy
    }
}

/// Pure helpers for map-driven connection state.
public enum ProviderRuntimeSnapshotStore {
    public static func upsert(
        _ snapshots: inout [String: ProviderRuntimeSnapshot],
        key: ProviderConnectionKey,
        snapshot: ProviderRuntimeSnapshot
    ) {
        snapshots[key.rawValue] = snapshot
    }

    public static func snapshot(
        in snapshots: [String: ProviderRuntimeSnapshot],
        key: ProviderConnectionKey
    ) -> ProviderRuntimeSnapshot {
        snapshots[key.rawValue] ?? .empty
    }

    public static func markLoading(
        _ snapshots: inout [String: ProviderRuntimeSnapshot],
        key: ProviderConnectionKey
    ) {
        var current = snapshot(in: snapshots, key: key)
        current = current.markingCatalogLoading()
        snapshots[key.rawValue] = current
    }

    public static func markAllLoading(
        _ snapshots: inout [String: ProviderRuntimeSnapshot],
        keys: [ProviderConnectionKey] = ProviderConnectionKey.allCases
    ) {
        for key in keys {
            markLoading(&snapshots, key: key)
        }
    }

    /// Fail-closed readiness: ready only when installed, authenticated, loaded, and runnable models exist.
    public static func computeReady(
        installed: Bool,
        authenticated: Bool,
        catalogStatus: ProviderCatalogStatus,
        runnableModelCount: Int
    ) -> Bool {
        ProviderReadinessSnapshot(
            installed: installed,
            authenticated: authenticated,
            catalogStatus: catalogStatus,
            runnableModelCount: runnableModelCount
        ).isRunnable
    }

    /// Hydrate secret-free presence from durable cache without granting readiness.
    public static func hydratePresence(
        from cached: [String: PersistedConnectionState.Provider]
    ) -> [String: ProviderRuntimeSnapshot] {
        var result: [String: ProviderRuntimeSnapshot] = [:]
        for key in ProviderConnectionKey.allCases {
            guard let entry = cached[key.rawValue] else { continue }
            result[key.rawValue] = ProviderRuntimeSnapshot(
                installed: entry.installed,
                authenticated: entry.authenticated,
                catalogStatus: .unknown,
                runnableModelCount: 0
            )
        }
        return result
    }
}
