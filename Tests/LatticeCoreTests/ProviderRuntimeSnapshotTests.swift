import Foundation
import Testing
@testable import LatticeCore

@Suite("ProviderRuntimeSnapshot")
struct ProviderRuntimeSnapshotTests {
    @Test func readyIsFailClosedUntilCatalogAndModelsArePresent() {
        #expect(!ProviderRuntimeSnapshotStore.computeReady(
            installed: true,
            authenticated: true,
            catalogStatus: .loading,
            runnableModelCount: 2
        ))
        #expect(!ProviderRuntimeSnapshotStore.computeReady(
            installed: true,
            authenticated: true,
            catalogStatus: .loaded,
            runnableModelCount: 0
        ))
        #expect(ProviderRuntimeSnapshotStore.computeReady(
            installed: true,
            authenticated: true,
            catalogStatus: .loaded,
            runnableModelCount: 1
        ))
    }

    @Test func upsertAndSnapshotRoundTrip() {
        var map: [String: ProviderRuntimeSnapshot] = [:]
        let snapshot = ProviderRuntimeSnapshot(
            installed: true,
            authenticated: true,
            catalogStatus: .loaded,
            models: [ProviderModel(id: "gpt", name: "GPT")],
            cliVersion: "1.2.3",
            ready: true
        )
        ProviderRuntimeSnapshotStore.upsert(&map, key: .codex, snapshot: snapshot)
        let read = ProviderRuntimeSnapshotStore.snapshot(in: map, key: .codex)
        #expect(read.installed)
        #expect(read.models.count == 1)
        #expect(read.cliVersion == "1.2.3")
        #expect(ProviderRuntimeSnapshotStore.snapshot(in: map, key: .hermes) == .empty)
    }

    @Test func markLoadingClearsReady() {
        var map: [String: ProviderRuntimeSnapshot] = [
            ProviderConnectionKey.grok.rawValue: ProviderRuntimeSnapshot(
                installed: true,
                authenticated: true,
                catalogStatus: .loaded,
                models: [ProviderModel(id: "g", name: "G")],
                ready: true
            )
        ]
        ProviderRuntimeSnapshotStore.markLoading(&map, key: .grok)
        let snap = ProviderRuntimeSnapshotStore.snapshot(in: map, key: .grok)
        #expect(snap.catalogStatus == .loading)
        #expect(!snap.ready)
        #expect(snap.installed)
    }
}
