import Foundation
import Testing
@testable import LatticeCore

@Suite("ACP tool classification")
struct ACPToolClassificationTests {
    private let workspace = URL(fileURLWithPath: "/Users/test/Lattice")

    @Test func explicitReadRemainsSafeInsideWorkspace() {
        let request = makePermission(toolKind: "read", title: "Read file", rawInput: ["path": "Sources/App.swift"])
        let toolRequest = request?.toolRequest

        #expect(toolRequest?.kind == .read)
        #expect(toolRequest?.workspaceScoped == true)
        #expect(toolRequest.map { DeterministicPolicyEngine().evaluate($0, under: .smart) } == .allow(reason: "Workspace-scoped reads are allowed."))
    }

    @Test func unknownInWorkspaceDoesNotBorrowSafeReadFromTitle() {
        let request = makePermission(toolKind: "mystery_action", title: "Read project metadata", rawInput: ["path": "Sources/App.swift"])
        let toolRequest = request?.toolRequest

        #expect(toolRequest?.kind == .unknown)
        #expect(toolRequest?.workspaceScoped == true)
        guard let toolRequest else { return }
        guard case .requireApproval(let reason) = DeterministicPolicyEngine().evaluate(toolRequest, under: .smart) else {
            Issue.record("Unknown in-workspace ACP tools must not be Smart auto-allowed")
            return
        }
        #expect(reason == "Unknown tool capabilities require confirmation.")
    }

    @Test func commandAndDestructiveNamesStayConservativeInsideWorkspace() {
        let cases: [(title: String, input: [String: Any], kind: ToolRequest.Kind)] = [
            ("Run command", ["path": "Sources/App.swift", "command": "git status"], .command),
            ("Delete file", ["path": "Sources/App.swift"], .destructive)
        ]

        for testCase in cases {
            let request = makePermission(toolKind: "mystery_action", title: testCase.title, rawInput: testCase.input)
            let toolRequest = request?.toolRequest
            #expect(toolRequest?.kind == testCase.kind)
            #expect(toolRequest?.workspaceScoped == true)
            guard let toolRequest else { continue }
            guard case .requireApproval = DeterministicPolicyEngine().evaluate(toolRequest, under: .smart) else {
                Issue.record("\(testCase.title) must require Smart approval")
                continue
            }
        }
    }

    private func makePermission(toolKind: String, title: String, rawInput: [String: Any]) -> ApprovalRequest? {
        let toolCall: [String: Any] = [
            "kind": toolKind,
            "title": title,
            "rawInput": rawInput
        ]
        let options: [[String: Any]] = [
            ["optionId": "allow", "name": "Allow once", "kind": "allow_once"],
            ["optionId": "reject", "name": "Deny", "kind": "reject_once"]
        ]
        let object: [String: Any] = [
            "method": "session/request_permission",
            "params": ["toolCall": toolCall, "options": options]
        ]
        return ACPHarness.permissionRequest(from: object, workspace: workspace)
    }
}
