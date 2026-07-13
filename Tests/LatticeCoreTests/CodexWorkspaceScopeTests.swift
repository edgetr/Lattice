import Foundation
import Testing
@testable import LatticeCore

@Suite("Codex workspace scope classification")
struct CodexWorkspaceScopeTests {
    private let policy = DeterministicPolicyEngine()

    private func uniqueWorkspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-codex-scope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: - fileChange requestApproval / grantRoot

    @Test func missingGrantRootIsUnscoped() throws {
        let workspace = try uniqueWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let object: [String: Any] = [
            "method": "item/fileChange/requestApproval",
            "params": ["reason": "patch files"]
        ]
        let request = CodexExecHarness.appServerPermissionRequest(from: object, workspace: workspace)
        #expect(request?.toolRequest?.workspaceScoped == false)
        #expect(request?.toolRequest?.kind == .write)
        #expect(request?.toolRequest?.reversible == true)
    }

    @Test func emptyWhitespaceMalformedOutsideAndSymlinkOutsideGrantRootAreUnscoped() throws {
        let workspace = try uniqueWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-codex-out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = workspace.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let cases: [String?] = [
            "",
            "   ",
            "file:///tmp/x",
            outside.path,
            link.path,
            "escape"
        ]
        for grantRoot in cases {
            var params: [String: Any] = ["reason": "edit"]
            if let grantRoot {
                params["grantRoot"] = grantRoot
            }
            let object: [String: Any] = [
                "method": "item/fileChange/requestApproval",
                "params": params
            ]
            let scoped = CodexExecHarness.appServerPermissionRequest(from: object, workspace: workspace)?
                .toolRequest?.workspaceScoped
            #expect(scoped == false, "grantRoot \(String(describing: grantRoot)) must fail closed")
        }
    }

    @Test func falseScopedReversibleWriteRequiresApprovalUnderSmart() throws {
        let workspace = try uniqueWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let object: [String: Any] = [
            "method": "item/fileChange/requestApproval",
            "params": ["reason": "apply patch"]
        ]
        guard let toolRequest = CodexExecHarness.appServerPermissionRequest(from: object, workspace: workspace)?
            .toolRequest else {
            Issue.record("Expected file change approval request")
            return
        }
        #expect(toolRequest.workspaceScoped == false)
        #expect(toolRequest.reversible == true)
        guard case .requireApproval = policy.evaluate(toolRequest, under: .smart) else {
            Issue.record("Smart must require approval when scope is false")
            return
        }
    }

    @Test func validInsideGrantRootIsScopedAndSmartMayAllow() throws {
        let workspace = try uniqueWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let object: [String: Any] = [
            "method": "item/fileChange/requestApproval",
            "params": [
                "grantRoot": workspace.path,
                "reason": "apply patch inside workspace"
            ]
        ]
        guard let toolRequest = CodexExecHarness.appServerPermissionRequest(from: object, workspace: workspace)?
            .toolRequest else {
            Issue.record("Expected file change approval request")
            return
        }
        #expect(toolRequest.workspaceScoped == true)
        #expect(toolRequest.reversible == true)
        guard case .allow = policy.evaluate(toolRequest, under: .smart) else {
            Issue.record("Smart may allow reversible scoped writes")
            return
        }
    }

    // MARK: - command cwd

    @Test func commandCwdFollowsSameBoundaryBehavior() throws {
        let workspace = try uniqueWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let inside: [String: Any] = [
            "method": "item/commandExecution/requestApproval",
            "params": [
                "command": "swift build",
                "cwd": workspace.path,
                "availableDecisions": ["accept", "decline"]
            ]
        ]
        #expect(
            CodexExecHarness.appServerPermissionRequest(from: inside, workspace: workspace)?
                .toolRequest?.workspaceScoped == true
        )

        let outside: [String: Any] = [
            "method": "item/commandExecution/requestApproval",
            "params": [
                "command": "open /tmp",
                "cwd": "/tmp",
                "availableDecisions": ["accept", "decline"]
            ]
        ]
        #expect(
            CodexExecHarness.appServerPermissionRequest(from: outside, workspace: workspace)?
                .toolRequest?.workspaceScoped == false
        )

        let missingCwd: [String: Any] = [
            "method": "item/commandExecution/requestApproval",
            "params": [
                "command": "ls",
                "availableDecisions": ["accept", "decline"]
            ]
        ]
        #expect(
            CodexExecHarness.appServerPermissionRequest(from: missingCwd, workspace: workspace)?
                .toolRequest?.workspaceScoped == false
        )

        let whitespaceCwd: [String: Any] = [
            "method": "item/commandExecution/requestApproval",
            "params": [
                "command": "ls",
                "cwd": "  ",
                "availableDecisions": ["accept", "decline"]
            ]
        ]
        #expect(
            CodexExecHarness.appServerPermissionRequest(from: whitespaceCwd, workspace: workspace)?
                .toolRequest?.workspaceScoped == false
        )
    }

    // MARK: - started fileChange

    @Test func startedFileChangeMissingEmptyMalformedOrOutsideIsUnscoped() throws {
        let workspace = try uniqueWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let insideFile = workspace.appendingPathComponent("a.swift")
        try Data("// a".utf8).write(to: insideFile)

        // Missing changes
        assertFileChangeScoped(
            item: ["type": "fileChange", "id": "fc-missing"],
            workspace: workspace,
            expected: false
        )

        // Empty changes
        assertFileChangeScoped(
            item: ["type": "fileChange", "id": "fc-empty", "changes": [] as [Any]],
            workspace: workspace,
            expected: false
        )

        // Malformed entry (not a dictionary)
        assertFileChangeScoped(
            item: ["type": "fileChange", "id": "fc-malformed", "changes": ["not-a-dict"] as [Any]],
            workspace: workspace,
            expected: false
        )

        // Partially malformed: one valid path plus one without path must not compact into safety
        assertFileChangeScoped(
            item: [
                "type": "fileChange",
                "id": "fc-partial",
                "changes": [
                    ["path": insideFile.path] as [String: Any],
                    ["kind": "add"] as [String: Any]
                ] as [Any]
            ],
            workspace: workspace,
            expected: false
        )

        // Outside path
        assertFileChangeScoped(
            item: [
                "type": "fileChange",
                "id": "fc-outside",
                "changes": [["path": "/tmp/outside.txt"] as [String: Any]] as [Any]
            ],
            workspace: workspace,
            expected: false
        )
    }

    @Test func startedFileChangeAllValidInsidePathsIsScoped() throws {
        let workspace = try uniqueWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let a = workspace.appendingPathComponent("a.swift")
        let b = workspace.appendingPathComponent("b.swift")
        try Data("// a".utf8).write(to: a)
        try Data("// b".utf8).write(to: b)

        assertFileChangeScoped(
            item: [
                "type": "fileChange",
                "id": "fc-good",
                "changes": [
                    ["path": a.path] as [String: Any],
                    ["path": "b.swift"] as [String: Any]
                ] as [Any]
            ],
            workspace: workspace,
            expected: true
        )

        // Detail should list the paths truthfully.
        let event = CodexExecHarness.appServerEvent(
            from: [
                "method": "item/started",
                "params": [
                    "item": [
                        "type": "fileChange",
                        "id": "fc-detail",
                        "changes": [
                            ["path": a.path] as [String: Any],
                            ["path": "b.swift"] as [String: Any]
                        ] as [Any]
                    ] as [String: Any]
                ]
            ],
            workspace: workspace
        )
        guard case .toolRequested(let request)? = event else {
            Issue.record("Expected toolRequested for valid fileChange")
            return
        }
        #expect(request.detail.contains(a.path))
        #expect(request.detail.contains("b.swift"))
        #expect(request.workspaceScoped)
    }

    private func assertFileChangeScoped(item: [String: Any], workspace: URL, expected: Bool) {
        let object: [String: Any] = [
            "method": "item/started",
            "params": ["item": item]
        ]
        guard case .toolRequested(let request)? = CodexExecHarness.appServerEvent(from: object, workspace: workspace) else {
            Issue.record("Expected toolRequested for fileChange item \(item["id"] as? String ?? "?")")
            return
        }
        #expect(request.workspaceScoped == expected, "fileChange \(item["id"] as? String ?? "?") scope")
        #expect(request.kind == .write)
        #expect(request.reversible == true)
    }
}
