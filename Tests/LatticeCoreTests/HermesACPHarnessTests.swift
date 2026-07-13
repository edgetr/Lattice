import Foundation
import Testing
@testable import LatticeCore

@Suite("Hermes ACP path scope")
struct HermesACPHarnessTests {
    @Test func insideAndOutsideLocationsFailClosed() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.deletingLastPathComponent()) }

        let request = permission(toolCall: [
            "title": "Read files",
            "kind": "read",
            "locations": [
                ["path": "Sources/App.swift"],
                ["path": workspace.deletingLastPathComponent().appendingPathComponent("outside.txt").path]
            ]
        ], workspace: workspace)

        #expect(request?.workspaceScoped == false)
    }

    @Test func insideAndMalformedLocationFailClosed() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.deletingLastPathComponent()) }

        let request = permission(toolCall: [
            "title": "Read files",
            "kind": "read",
            "locations": [
                ["path": "Sources/App.swift"],
                ["path": 42]
            ]
        ], workspace: workspace)

        #expect(request?.workspaceScoped == false)
    }

    @Test func emptyPathFailsClosed() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.deletingLastPathComponent()) }

        let request = permission(toolCall: [
            "title": "Read file",
            "kind": "read",
            "rawInput": ["path": ""]
        ], workspace: workspace)

        #expect(request?.workspaceScoped == false)
    }

    @Test func allRawInputAndLocationPathsInsideAreScoped() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.deletingLastPathComponent()) }

        let request = permission(toolCall: [
            "title": "Read files",
            "kind": "read",
            "rawInput": ["path": "Sources/App.swift"],
            "locations": [
                ["path": "Sources/App.swift"],
                ["path": "Tests/AppTests.swift"]
            ]
        ], workspace: workspace)

        #expect(request?.workspaceScoped == true)
    }

    @Test func eventDecoderKeepsAllValidLocationEvidence() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.deletingLastPathComponent()) }

        let event: [String: Any] = [
            "method": "session/update",
            "params": ["update": [
                "sessionUpdate": "tool_call",
                "toolCallId": "call-1",
                "title": "Read files",
                "kind": "read",
                "rawInput": ["path": "Sources/App.swift"],
                "locations": [
                    ["path": "Sources/App.swift"],
                    ["path": "Tests/AppTests.swift"]
                ]
            ]]
        ]

        guard case .toolRequested(let request)? = HarnessToolEventDecoder.hermesEvent(from: event, workspace: workspace) else {
            Issue.record("Hermes tool event did not decode")
            return
        }
        #expect(request.workspaceScoped)
        #expect(request.detail == "Sources/App.swift, Tests/AppTests.swift")
    }

    private func makeWorkspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lattice-acp-scope-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return workspace
    }

    private func permission(toolCall: [String: Any], workspace: URL) -> ToolRequest? {
        let object: [String: Any] = [
            "method": "session/request_permission",
            "params": [
                "toolCall": toolCall,
                "options": [["optionId": "allow_once", "name": "Allow once", "kind": "allow_once"]]
            ]
        ]
        return HermesACPHarness.permissionRequest(from: object, workspace: workspace)?.toolRequest
    }
}
