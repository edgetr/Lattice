import Foundation
import Testing
@testable import LatticeCore

@Suite("Hermes location metadata")
struct HermesLocationMetadataTests {
    private func makeWorkspace() throws -> URL {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-hermes-workspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        return workspace
    }

    @Test func mixedEventLocationsFailClosed() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let object: [String: Any] = [
            "method": "session/update",
            "params": [
                "update": [
                    "sessionUpdate": "tool_call",
                    "toolCallId": "mixed-event",
                    "title": "Edit file",
                    "kind": "edit",
                    "locations": [
                        ["path": "Sources/App.swift"],
                        ["line": 12]
                    ],
                    "rawInput": ["path": "Sources/App.swift"]
                ]
            ]
        ]

        guard case .toolRequested(let request)? = HarnessToolEventDecoder.hermesEvent(from: object, workspace: workspace) else {
            Issue.record("Expected Hermes tool event")
            return
        }
        #expect(request.detail == "Sources/App.swift")
        #expect(!request.workspaceScoped)
    }

    @Test func mixedPermissionLocationsFailClosedEvenWithValidRawInputPath() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let object: [String: Any] = [
            "method": "session/request_permission",
            "params": [
                "toolCall": [
                    "title": "Edit file",
                    "kind": "edit",
                    "locations": [
                        ["path": "Sources/App.swift"],
                        ["path": NSNull()]
                    ],
                    "rawInput": ["path": "Sources/App.swift"]
                ],
                "options": [
                    ["optionId": "allow_once", "name": "Allow once", "kind": "allow_once"]
                ]
            ]
        ]

        let request = try #require(HermesACPHarness.permissionRequest(from: object, workspace: workspace)?.toolRequest)
        #expect(!request.workspaceScoped)
        guard case .requireApproval = DeterministicPolicyEngine().evaluate(request, under: .smart) else {
            Issue.record("Malformed Hermes location metadata must not auto-approve")
            return
        }
    }

    @Test func validRawInputPathFallbackRemainsWorkspaceScoped() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let event: [String: Any] = [
            "method": "session/update",
            "params": [
                "update": [
                    "sessionUpdate": "tool_call",
                    "toolCallId": "raw-event",
                    "title": "Edit file",
                    "kind": "edit",
                    "rawInput": ["path": "Sources/App.swift"]
                ]
            ]
        ]
        let permission: [String: Any] = [
            "method": "session/request_permission",
            "params": [
                "toolCall": [
                    "title": "Edit file",
                    "kind": "edit",
                    "rawInput": ["path": "Sources/App.swift"]
                ],
                "options": [
                    ["optionId": "allow_once", "name": "Allow once", "kind": "allow_once"]
                ]
            ]
        ]

        guard case .toolRequested(let eventRequest)? = HarnessToolEventDecoder.hermesEvent(from: event, workspace: workspace) else {
            Issue.record("Expected Hermes tool event")
            return
        }
        let permissionRequest = try #require(HermesACPHarness.permissionRequest(from: permission, workspace: workspace)?.toolRequest)
        #expect(eventRequest.workspaceScoped)
        #expect(permissionRequest.workspaceScoped)
    }
}
