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

    @Test func readyAndReadinessAgreeForHarnessOnlyCatalogs() {
        let snap = ProviderRuntimeSnapshot(
            installed: true,
            authenticated: true,
            catalogStatus: .loaded,
            harnessModels: [HarnessModel(id: "p:m", name: "m")],
            runnableModelCount: 1
        )
        #expect(snap.ready)
        #expect(snap.readiness.isRunnable)
        #expect(snap.ready == snap.readiness.isRunnable)
        #expect(snap.models.isEmpty)
        #expect(snap.runnableModelCount == 1)
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

    @Test func hydratePresenceNeverGrantsReadiness() {
        let hydrated = ProviderRuntimeSnapshotStore.hydratePresence(from: [
            "codex": .init(installed: true, authenticated: true, catalogStatus: .loaded, runnableModelCount: 4)
        ])
        #expect(hydrated["codex"]?.installed == true)
        #expect(hydrated["codex"]?.authenticated == true)
        #expect(hydrated["codex"]?.ready == false)
        #expect(hydrated["codex"]?.catalogStatus == .unknown)
        #expect(hydrated["codex"]?.runnableModelCount == 0)
    }
}
