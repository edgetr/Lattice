import Testing
@testable import LatticeCore

@Suite("Policy engine")
struct PolicyEngineTests {
    let engine = DeterministicPolicyEngine()

    @Test func askAllowsScopedReads() {
        let request = ToolRequest(kind: .read, title: "Read file", detail: "README", workspaceScoped: true, reversible: true)
        #expect(engine.evaluate(request, under: .ask) == .allow(reason: "Workspace-scoped reads are allowed."))
    }

    @Test func askRequiresApprovalForWrites() {
        let request = ToolRequest(kind: .write, title: "Edit file", detail: "Sources/App.swift", workspaceScoped: true, reversible: true)
        guard case .requireApproval = engine.evaluate(request, under: .ask) else { Issue.record("Ask must gate writes"); return }
    }

    @Test func smartAllowsReversibleScopedWrite() {
        let request = ToolRequest(kind: .write, title: "Edit file", detail: "Sources/App.swift", workspaceScoped: true, reversible: true)
        guard case .allow = engine.evaluate(request, under: .smart) else { Issue.record("Smart should allow reversible scoped edits"); return }
    }

    @Test func smartRequiresApprovalForMaterialFileChangeWithoutReversibleEvidence() {
        let request = ToolRequest(kind: .write, title: "Change files", detail: "Sources/App.swift", workspaceScoped: true, reversible: false)
        guard case .requireApproval = engine.evaluate(request, under: .smart) else {
            Issue.record("Smart must gate material file changes without provider undoability evidence")
            return
        }
    }

    @Test func smartRequiresApprovalForCodexFileChangeRequestWithoutProviderEvidence() throws {
        let workspace = URL(fileURLWithPath: "/tmp/Lattice")
        let object: [String: Any] = [
            "method": "item/fileChange/requestApproval",
            "params": [
                "grantRoot": workspace.path,
                "reason": "Update Sources/App.swift"
            ]
        ]

        let approval = try #require(CodexExecHarness.appServerPermissionRequest(from: object, workspace: workspace))
        let request = try #require(approval.toolRequest)
        #expect(request.kind == .write)
        #expect(request.workspaceScoped)
        #expect(!request.reversible)
        guard case .requireApproval = engine.evaluate(request, under: .smart) else {
            Issue.record("Smart must gate Codex file-change requests without undo evidence")
            return
        }
    }

    @Test func smartRequiresApprovalForCodexFileChangeEventWithoutProviderEvidence() throws {
        let workspace = URL(fileURLWithPath: "/tmp/Lattice")
        let object: [String: Any] = [
            "method": "item/started",
            "params": [
                "item": [
                    "id": "file-change-1",
                    "type": "fileChange",
                    "changes": [["path": "Sources/App.swift"]]
                ]
            ]
        ]

        guard case .toolRequested(let request)? = CodexExecHarness.appServerEvent(from: object, workspace: workspace) else {
            Issue.record("Expected Codex file-change tool request")
            return
        }
        #expect(request.workspaceScoped)
        #expect(!request.reversible)
        guard case .requireApproval = engine.evaluate(request, under: .smart) else {
            Issue.record("Smart must gate Codex file-change events without undo evidence")
            return
        }
    }

    @Test func smartKeepsOutOfWorkspaceCodexFileChangeApprovalGated() throws {
        let workspace = URL(fileURLWithPath: "/tmp/Lattice")
        let object: [String: Any] = [
            "method": "item/started",
            "params": [
                "item": [
                    "id": "file-change-outside",
                    "type": "fileChange",
                    "changes": [["path": "/tmp/Other/App.swift"]]
                ]
            ]
        ]

        guard case .toolRequested(let request)? = CodexExecHarness.appServerEvent(from: object, workspace: workspace) else {
            Issue.record("Expected Codex out-of-workspace file-change tool request")
            return
        }
        #expect(!request.workspaceScoped)
        #expect(!request.reversible)
        guard case .requireApproval = engine.evaluate(request, under: .smart) else {
            Issue.record("Smart must gate Codex file changes outside selected workspace")
            return
        }
    }
    @Test(arguments: ExecutionPolicy.allCases)
    func credentialsAlwaysDenied(policy: ExecutionPolicy) {
        let request = ToolRequest(kind: .credential, title: "Read token", detail: "Keychain", workspaceScoped: true, reversible: true)
        guard case .deny = engine.evaluate(request, under: policy) else { Issue.record("Credential access must stay denied"); return }
    }

    @Test func scopeExpansionAlwaysAsksOutsideYolo() {
        let request = ToolRequest(kind: .read, title: "Read file", detail: "/private", workspaceScoped: false, reversible: true)
        guard case .requireApproval = engine.evaluate(request, under: .smart) else { Issue.record("Scope expansion must ask"); return }
    }

    @Test func smartExposesProviderNativeSessionApprovalByKind() {
        let options = [
            ApprovalOption(id: "accept", name: "Allow once", kind: "allow_once"),
            ApprovalOption(id: "acceptForSession", name: "Allow for session", kind: "allow_session"),
            ApprovalOption(id: "acceptAlways", name: "Allow always", kind: "allow_always"),
            ApprovalOption(id: "decline", name: "Deny", kind: "reject_once"),
            ApprovalOption(id: "cancel", name: "Stop", kind: "reject_always")
        ]
        #expect(ApprovalOptionPolicy.visibleOptions(options, under: .ask).map(\.id) == ["accept", "decline"])
        #expect(ApprovalOptionPolicy.visibleOptions(options, under: .smart).map(\.id) == ["accept", "acceptForSession", "decline"])
        #expect(ApprovalOptionPolicy.visibleOptions(options, under: .yolo).map(\.id) == ["accept", "acceptForSession", "acceptAlways", "decline"])
        #expect(!ApprovalOptionPolicy.isVisible(options[2], under: .ask))
        #expect(!ApprovalOptionPolicy.isVisible(options[2], under: .smart))
        #expect(ApprovalOptionPolicy.isVisible(options[2], under: .yolo))
        #expect(!ApprovalOptionPolicy.isVisible(options[4], under: .yolo))
    }

    @Test func localToolBrokerReturnsApprovalInsteadOfExecutingAskWrites() async {
        let broker = LocalToolBroker(handlers: [
            .write: { _ in .completed }
        ])
        let request = ToolRequest(kind: .write, title: "Edit file", detail: "Sources/App.swift", workspaceScoped: true, reversible: true)
        let result = await broker.submit(request, policy: .ask)
        guard case .requiresApproval(let approval) = result else { Issue.record("Ask writes must require approval before execution"); return }
        #expect(approval.toolRequest == request)
        #expect(approval.options.map(\.id) == ["allow_once", "reject_once"])
        let audit = await broker.auditSnapshot()
        #expect(audit.map(\.decision) == [.approvalRequired])
    }

    @Test func localToolBrokerExecutesRegisteredSmartReversibleWrite() async {
        let broker = LocalToolBroker(handlers: [
            .write: { request in .toolProgress(id: request.id, fraction: 1, detail: "patched") }
        ])
        let request = ToolRequest(kind: .write, title: "Edit file", detail: "Sources/App.swift", workspaceScoped: true, reversible: true)
        let result = await broker.submit(request, policy: .smart)
        guard case .executed(.toolProgress(let id, let fraction, let detail)) = result else { Issue.record("Smart reversible write should execute through registered handler"); return }
        #expect(id == request.id)
        #expect(fraction == 1)
        #expect(detail == "patched")
        let audit = await broker.auditSnapshot()
        #expect(audit.map(\.decision) == [.allowed, .executed])
    }

    @Test func localToolBrokerDeniesCredentialAccessBeforeHandler() async {
        let broker = LocalToolBroker(handlers: [
            .credential: { _ in .completed }
        ])
        let request = ToolRequest(kind: .credential, title: "Read token", detail: "Keychain", workspaceScoped: true, reversible: false)
        let result = await broker.submit(request, policy: .yolo)
        guard case .denied(let reason) = result else { Issue.record("Credential access must be denied before handler execution"); return }
        #expect(reason.contains("Credential"))
        let audit = await broker.auditSnapshot()
        #expect(audit.map(\.decision) == [.denied])
    }

    @Test func localToolBrokerAuditsMissingHandlerFailure() async {
        let broker = LocalToolBroker()
        let request = ToolRequest(kind: .read, title: "Read file", detail: "README.md", workspaceScoped: true, reversible: true)
        let result = await broker.submit(request, policy: .ask)
        guard case .failed(let reason) = result else { Issue.record("Allowed work without a handler must fail closed"); return }
        #expect(reason.contains("noHandler"))
        let audit = await broker.auditSnapshot()
        #expect(audit.map(\.decision) == [.allowed, .failed])
    }
}
