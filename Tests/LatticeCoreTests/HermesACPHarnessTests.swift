import Foundation
import Testing
@testable import LatticeCore

@Suite("Hermes ACP path scope")
struct HermesACPHarnessTests {
    @Test(arguments: ["Sources/App.swift", "./Sources/App.swift", "Sources/../Sources/App.swift"])
    func validRelativePOSIXPathsStayScoped(_ path: String) throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.deletingLastPathComponent()) }
        #expect(WorkspacePathScope.isWorkspaceScoped(path, workspace: workspace))
    }

    @Test func absolutePathInsideWorkspaceStaysScoped() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.deletingLastPathComponent()) }
        #expect(WorkspacePathScope.isWorkspaceScoped(workspace.appendingPathComponent("Sources/App.swift").path, workspace: workspace))
    }

    @Test(arguments: [
        "~/workspace/Sources/App.swift", "~other/workspace/Sources/App.swift", "Sources\\App.swift",
        "C:/workspace/Sources/App.swift", "D:\\workspace\\Sources\\App.swift",
        "https://example.test/workspace/Sources/App.swift", "file:///workspace/Sources/App.swift", "../outside/Sources/App.swift"
    ])
    func ambiguousOrEscapingPathFormsFailClosed(_ path: String) throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.deletingLastPathComponent()) }
        #expect(!WorkspacePathScope.isWorkspaceScoped(path, workspace: workspace))
    }

    @Test(arguments: ["", "   ", "\nSources/App.swift"])
    func malformedOrEmptyPathFormsFailClosed(_ path: String) throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.deletingLastPathComponent()) }
        #expect(!WorkspacePathScope.isWorkspaceScoped(path, workspace: workspace))
        #expect(!WorkspacePathScope.isWorkspaceScoped(nil, workspace: workspace))
    }

    @Test func ACPPermissionUsesSharedPathFormGuard() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.deletingLastPathComponent()) }
        let request = permission(toolCall: ["title": "Read file", "kind": "read", "rawInput": ["path": "~/workspace/Sources/App.swift"]], workspace: workspace)
        #expect(request?.workspaceScoped == false)
    }

    @Test func insideAndOutsideLocationsFailClosed() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.deletingLastPathComponent()) }
        let request = permission(toolCall: ["title": "Read files", "kind": "read", "locations": [["path": "Sources/App.swift"], ["path": workspace.deletingLastPathComponent().appendingPathComponent("outside.txt").path]]], workspace: workspace)
        #expect(request?.workspaceScoped == false)
    }

    @Test func insideAndMalformedLocationFailClosed() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.deletingLastPathComponent()) }
        let request = permission(toolCall: ["title": "Read files", "kind": "read", "locations": [["path": "Sources/App.swift"], ["path": 42]]], workspace: workspace)
        #expect(request?.workspaceScoped == false)
    }

    @Test func emptyPathFailsClosed() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.deletingLastPathComponent()) }
        let request = permission(toolCall: ["title": "Read file", "kind": "read", "rawInput": ["path": ""]], workspace: workspace)
        #expect(request?.workspaceScoped == false)
    }

    @Test func allRawInputAndLocationPathsInsideAreScoped() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.deletingLastPathComponent()) }
        let request = permission(toolCall: ["title": "Read files", "kind": "read", "rawInput": ["path": "Sources/App.swift"], "locations": [["path": "Sources/App.swift"], ["path": "Tests/AppTests.swift"]]], workspace: workspace)
        #expect(request?.workspaceScoped == true)
    }

    @Test func eventDecoderKeepsAllValidLocationEvidence() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.deletingLastPathComponent()) }
        let event: [String: Any] = ["method": "session/update", "params": ["update": ["sessionUpdate": "tool_call", "toolCallId": "call-1", "title": "Read files", "kind": "read", "rawInput": ["path": "Sources/App.swift"], "locations": [["path": "Sources/App.swift"], ["path": "Tests/AppTests.swift"]]]]]
        guard case .toolRequested(let request)? = HarnessToolEventDecoder.hermesEvent(from: event, workspace: workspace) else { Issue.record("Hermes tool event did not decode"); return }
        #expect(request.workspaceScoped)
        #expect(request.detail == "Sources/App.swift, Tests/AppTests.swift")
    }

    @Test func malformedCodexFileChangePathIsNotDropped() {
        let workspace = URL(fileURLWithPath: "/tmp/lattice-workspace")
        let event: [String: Any] = [
            "method": "item/started",
            "params": ["item": [
                "type": "fileChange",
                "id": "change-1",
                "changes": [["path": "Sources/App.swift"], ["path": 42]]
            ]]
        ]
        guard case .toolRequested(let request)? = CodexExecHarness.appServerEvent(from: event, workspace: workspace) else {
            Issue.record("Codex file-change event did not decode")
            return
        }
        #expect(!request.workspaceScoped)
    }

    @Test func recoveryRequiresRecognizedStaleSessionRejection() {
        #expect(HermesACPHarness.isStaleSessionRejection(["error": ["message": "session not found"]]))
        #expect(HermesACPHarness.isStaleSessionRejection(["error": ["message": "saved session has expired"]]))
        #expect(!HermesACPHarness.isStaleSessionRejection(["error": ["message": "provider returned no result"]]))
        #expect(!HermesACPHarness.isStaleSessionRejection(["error": ["message": "authentication required"]]))
        #expect(!HermesACPHarness.isStaleSessionRejection(["result": [:]]))
    }

    @Test func recoveryRequiresDeliverableVisibleTranscriptHandoff() {
        #expect(HermesACPHarness.validatedRecoveryPrompt(
            "Visible transcript",
            usesVisibleTranscriptHandoff: true,
            deliveryIssue: nil
        ) == "Visible transcript")
        #expect(HermesACPHarness.validatedRecoveryPrompt(
            "   ",
            usesVisibleTranscriptHandoff: true,
            deliveryIssue: nil
        ) == nil)
        #expect(HermesACPHarness.validatedRecoveryPrompt(
            "Visible transcript",
            usesVisibleTranscriptHandoff: false,
            deliveryIssue: nil
        ) == nil)
        #expect(HermesACPHarness.validatedRecoveryPrompt(
            "Visible transcript",
            usesVisibleTranscriptHandoff: true,
            deliveryIssue: "over context limit"
        ) == nil)
    }

    private func makeWorkspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lattice-acp-scope-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return workspace
    }

    private func permission(toolCall: [String: Any], workspace: URL) -> ToolRequest? {
        let object: [String: Any] = ["method": "session/request_permission", "params": ["toolCall": toolCall, "options": [["optionId": "allow_once", "name": "Allow once", "kind": "allow_once"]]]]
        return HermesACPHarness.permissionRequest(from: object, workspace: workspace)?.toolRequest
    }
}
