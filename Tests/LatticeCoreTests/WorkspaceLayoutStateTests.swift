import Foundation
import Testing
@testable import LatticeCore

@Suite("Workspace layout persistence")
struct WorkspaceLayoutStateTests {
    private let screen = WorkspaceWindowFrame(x: 0, y: 0, width: 1440, height: 900)

    @Test func missingStateUsesSafeNonSensitiveDefaults() {
        let state = WorkspaceLayoutStatePolicy.restoredState(for: "main", in: .init(), visibleScreens: [screen])
        #expect(state.selectedPage == "conversations")
        #expect(state.sidebarVisibility == "all")
        #expect(state.sidebarWidth == 190)
        #expect(!state.inspectorVisible)
        #expect(state.windowFrame == nil)
    }

    @Test func migratesLegacySingleWindowStateIntoMainKey() throws {
        let legacy = #"{"schemaVersion":1,"selectedPage":"models","sidebarVisible":false,"sidebarWidth":205,"inspectorVisible":true,"inspectorWidth":370,"primarySplitWidth":310,"windowFrame":null,"windowIsMaximized":false}"#
        let archive = WorkspaceLayoutStatePolicy.decodeArchive(Data(legacy.utf8))
        let state = try #require(archive.windows["main"])
        #expect(archive.schemaVersion == WorkspaceLayoutState.currentSchemaVersion)
        #expect(state.selectedPage == "models")
        #expect(state.sidebarVisibility == "doubleColumn")
        #expect(state.primarySplitSizes == [310])
    }

    @Test func clampsOffscreenAndOversizedFramesToCurrentTopology() {
        var state = WorkspaceLayoutState(windowFrame: .init(x: 3000, y: -800, width: 2200, height: 1200))
        state = WorkspaceLayoutStatePolicy.clamped(state, visibleScreens: [screen])
        #expect(state.windowFrame == screen)
    }

    @Test func clampsInvalidAndUnusablePanelSizes() {
        let state = WorkspaceLayoutState(
            sidebarWidth: -20,
            inspectorVisible: true,
            inspectorWidth: 9_000,
            primarySplitSizes: [12, 9_000, .nan]
        )
        let restored = WorkspaceLayoutStatePolicy.clamped(state, visibleScreens: [screen], availableContentWidth: 1_000)
        #expect(restored.sidebarWidth == 56)
        #expect(restored.inspectorWidth == 420)
        #expect(!restored.inspectorVisible)
        #expect(restored.primarySplitSizes == [220, 340, 280])
    }

    @Test func keyedWindowsRemainIsolatedAcrossRoundTrip() throws {
        var archive = WorkspaceLayoutArchive()
        archive = WorkspaceLayoutStatePolicy.updating(archive, key: "one", state: .init(selectedPage: "projects", sidebarWidth: 180))
        archive = WorkspaceLayoutStatePolicy.updating(archive, key: "two", state: .init(selectedPage: "connections", sidebarWidth: 210))
        let encoded = try #require(WorkspaceLayoutStatePolicy.encodeArchive(archive))
        let decoded = WorkspaceLayoutStatePolicy.decodeArchive(encoded)
        #expect(decoded.windows["one"]?.selectedPage == "projects")
        #expect(decoded.windows["one"]?.sidebarWidth == 180)
        #expect(decoded.windows["two"]?.selectedPage == "connections")
        #expect(decoded.windows["two"]?.sidebarWidth == 210)
        let serialized = String(decoding: encoded, as: UTF8.self)
        #expect(!serialized.localizedCaseInsensitiveContains("transcript"))
        #expect(!serialized.localizedCaseInsensitiveContains("credential"))
    }

    @Test func restorationPreservesValidStateAndDropsUnknownValues() {
        let valid = WorkspaceLayoutState(
            selectedPage: "extensions",
            sidebarVisibility: "detailOnly",
            sidebarExpanded: false,
            sidebarWidth: 200,
            inspectorVisible: true,
            inspectorWidth: 360,
            primarySplitSizes: [300],
            windowFrame: .init(x: 100, y: 100, width: 1240, height: 700),
            windowIsMaximized: true
        )
        var archive = WorkspaceLayoutArchive(windows: ["valid": valid, "bad": .init(selectedPage: "secret-page", sidebarVisibility: "unknown")])
        archive = WorkspaceLayoutStatePolicy.decodeArchive(WorkspaceLayoutStatePolicy.encodeArchive(archive))
        #expect(WorkspaceLayoutStatePolicy.restoredState(for: "valid", in: archive, visibleScreens: [screen]) == valid)
        let bad = WorkspaceLayoutStatePolicy.restoredState(for: "bad", in: archive, visibleScreens: [screen])
        #expect(bad.selectedPage == "conversations")
        #expect(bad.sidebarVisibility == "all")
    }
}
