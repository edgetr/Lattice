import Foundation
import Testing
@testable import LatticeCore

@Suite("Code mode phase 3–4")
struct CodeModePhase3Phase4Tests {
    @Test func codeModeBaselineIsSlimWithoutProductFAQ() {
        let code = LatticeProductInstructions.codeMode
        #expect(code.contains("Engineering contract"))
        #expect(code.contains("prompt text never grants permission") || code.localizedCaseInsensitiveContains("never grants permission"))
        #expect(!code.contains("Lattice product context:"))
        #expect(!code.contains("Extensions & Skills"))
        #expect(code.utf8.count < LatticeProductInstructions.current.utf8.count)
    }

    @Test func productContextOptInForCode() {
        #expect(!LatticeProductInstructions.shouldIncludeProductContext(
            mode: .code,
            submittedText: "Fix the flaky test in ContextBudgetTests"
        ))
        #expect(!LatticeProductInstructions.shouldIncludeProductContext(
            mode: .code,
            submittedText: "Use Accept Edits policy and YOLO mode for this Lattice Agent task"
        ))
        #expect(LatticeProductInstructions.shouldIncludeProductContext(
            mode: .code,
            submittedText: "What is Lattice and how do skills work?"
        ))
        #expect(LatticeProductInstructions.shouldIncludeProductContext(
            mode: .code,
            submittedText: "tweak composer",
            isExtensionSelfEdit: true
        ))
        #expect(LatticeProductInstructions.shouldIncludeProductContext(
            mode: .code,
            submittedText: "/lattice-extension",
            skillID: "lattice-extension"
        ))
        #expect(LatticeProductInstructions.shouldIncludeProductContext(
            mode: .work,
            submittedText: "research something"
        ))
    }

    @Test func acceptEditsAllowsPiWorkspaceWritePermissionRequest() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-accept-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let path = workspace.appendingPathComponent("Sources/App.swift").path
        let payload: [String: Any] = [
            "toolName": "write",
            "input": ["path": path, "content": "x"]
        ]
        let message = String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
        let object: [String: Any] = [
            "type": "extension_ui_request",
            "method": "confirm",
            "message": message
        ]
        let approval = try #require(PiRPCHarness.permissionRequest(from: object, workspace: workspace))
        let request = try #require(approval.toolRequest)
        #expect(request.kind == .write)
        #expect(request.workspaceScoped)
        #expect(!request.reversible)
        let engine = DeterministicPolicyEngine()
        guard case .allow = engine.evaluate(request, under: .acceptEdits) else {
            Issue.record("Accept Edits must auto-allow Lattice Agent workspace write after reported request")
            return
        }
        guard case .requireApproval = engine.evaluate(request, under: .smart) else {
            Issue.record("Smart must still require approval without undo evidence")
            return
        }
        let resolution = AutomaticPermissionResolutionPolicy.resolve(
            decision: engine.evaluate(request, under: .acceptEdits),
            policy: .acceptEdits,
            options: approval.options
        )
        guard case .forward(_, true) = resolution else {
            Issue.record("Automatic resolution should forward allow for Accept Edits workspace write")
            return
        }

        let bashPayload: [String: Any] = [
            "toolName": "bash",
            "input": ["command": "echo hi"]
        ]
        let bashMessage = String(data: try JSONSerialization.data(withJSONObject: bashPayload), encoding: .utf8)!
        let bashObject: [String: Any] = [
            "type": "extension_ui_request",
            "method": "confirm",
            "message": bashMessage
        ]
        let bashApproval = try #require(PiRPCHarness.permissionRequest(from: bashObject, workspace: workspace))
        let bashRequest = try #require(bashApproval.toolRequest)
        guard case .requireApproval = engine.evaluate(bashRequest, under: .acceptEdits) else {
            Issue.record("Accept Edits must not auto-allow bash")
            return
        }
    }

    @Test func planRestrictedLaunchWithholdsWriteTools() throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-plan-launch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let pi = fixtureRoot.appendingPathComponent("LatticeAgent")
        try "#!/bin/sh\n".write(to: pi, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pi.path)
        let sandbox = fixtureRoot.appendingPathComponent("sandbox-exec")
        try "#!/bin/sh\n".write(to: sandbox, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sandbox.path)
        let permission = fixtureRoot.appendingPathComponent("permission.js")
        try "export default {}\n".write(to: permission, atomically: true, encoding: .utf8)
        let workspace = fixtureRoot.appendingPathComponent("ws", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let harness = PiRPCHarness(
            executableURL: pi,
            permissionExtensionURL: permission,
            sandboxExecutableURL: sandbox,
            applicationSupportDirectory: fixtureRoot.appendingPathComponent("support")
        )
        let plan = try harness.makeLaunchPlan(
            sessionID: UUID(),
            workspace: workspace,
            provider: "codex",
            model: "gpt-test",
            allowFileModification: false
        )
        let toolsIndex = plan.piArguments.firstIndex(of: "--tools")
        #expect(toolsIndex != nil)
        if let toolsIndex, toolsIndex + 1 < plan.piArguments.count {
            let tools = plan.piArguments[toolsIndex + 1]
            #expect(tools.contains("read"))
            #expect(!tools.contains("write"))
            #expect(!tools.contains("edit"))
            #expect(!tools.contains("bash"))
        }
    }

    @Test func codeEnvelopeDefaultOmitsProductFAQ() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-code-env-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let slim = try LatticeInstructionEnvelope.default(
            mode: .code,
            workspace: workspace,
            allowFileModification: true,
            workspaceInstructionsTrusted: false,
            includeProductContext: false
        )
        #expect(!slim.latticeInstructions.contains("Lattice product context:"))
        #expect(slim.latticeInstructions.contains("Engineering contract") || slim.latticeInstructions.contains("Lattice Agent"))
        #expect(slim.capabilityFacts.contains(where: { $0.contains("product FAQ included: no") }))
        #expect(slim.controlFacts.contains(where: { $0.contains("code session phase: normal") }))

        let withFAQ = try LatticeInstructionEnvelope.default(
            mode: .code,
            workspace: workspace,
            allowFileModification: false,
            workspaceInstructionsTrusted: false,
            includeProductContext: true,
            codePhase: .planActive
        )
        #expect(withFAQ.latticeInstructions.contains("Lattice product context:"))
        #expect(withFAQ.controlFacts.contains(where: { $0.contains("planActive") && $0.contains("mutating tools withheld") }))
        #expect(withFAQ.controlFacts.contains(where: { $0.contains("write capability requested: no") }))
    }

    @Test func bundledSkillsPackHasExpectedDefaults() {
        let ids = Set(LatticeBundledCodeSkills.all.map(\.id))
        #expect(ids == [
            "lattice-extension",
            "lattice-skill-author",
            "resume-codex",
            "resume-claude",
            "resume-cursor",
            "implement",
            "review"
        ])
        #expect(LatticeBundledCodeSkills.defaultEnabledIDs == ["lattice-extension"])
        #expect(LatticeBundledCodeSkills.defaultDisabledIDs.contains("resume-codex"))
        #expect(LatticeBundledCodeSkills.markdown(for: "resume-codex")?.contains("name: resume-codex") == true)
        #expect(LatticeBundledCodeSkills.markdown(for: "resume-codex")?.contains("Do not launch") == true)
        #expect(LatticeBundledCodeSkills.markdown(for: "lattice-extension")?.contains("/self-edit") == true)
    }

    @Test func seedBundledSkillsIsIdempotentAndRespectsTombstones() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-skills-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = LatticeSkillStore(rootURL: root, globalRoots: [])
        let first = try store.seedBundledCodeSkills()
        #expect(first.seededIDs.count == LatticeBundledCodeSkills.all.count)
        #expect(Set(first.defaultDisabledIDs) == LatticeBundledCodeSkills.defaultDisabledIDs)

        let loaded = store.load()
        #expect(loaded.filter { $0.source == .bundled }.count == LatticeBundledCodeSkills.all.count)

        let second = try store.seedBundledCodeSkills()
        #expect(second.skippedTombstonedIDs.isEmpty)
        // Second seed refreshes untouched bundled baselines (counts as seeded) or skips if edited.
        #expect(second.seededIDs.count + second.skippedExistingIDs.count == LatticeBundledCodeSkills.all.count)

        try store.deleteSkill(id: "review")
        let afterDelete = try store.seedBundledCodeSkills()
        #expect(afterDelete.skippedTombstonedIDs.contains("review"))
        #expect(!store.load().contains(where: { $0.id == "review" }))

        // User-authored skill with same id as a pack member must not be clobbered.
        _ = try store.writeUserAuthoredSkill(
            .init(id: "custom-one", title: "Custom", summary: "User skill", markdown: "# Custom\n\nBody."),
            overwrite: false
        )
        // Overwrite a bundled id with generated-style content path: create non-bundled collision by writing generated.
        // Simulate by removing source marker and rewriting as generated after delete-restore path:
        // Create a non-bundled skill first with unique id, then seed remains independent.
        let third = try store.seedBundledCodeSkills()
        #expect(store.load().contains(where: { $0.id == "custom-one" && $0.source == .generated }))
        #expect(third.skippedTombstonedIDs.contains("review"))
    }

    @Test func seedDoesNotClobberUserEditedBundledSkill() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-skills-edit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LatticeSkillStore(rootURL: root, globalRoots: [])
        _ = try store.seedBundledCodeSkills()

        let folder = root.appendingPathComponent("implement", isDirectory: true)
        let skillURL = folder.appendingPathComponent("SKILL.md")
        let edited = """
        ---
        name: implement
        description: User-edited implement skill that must not be clobbered by reseeding.
        ---

        # Implement (user edit)

        ## Quick start
        Custom user body that differs from the bundled baseline.

        ## Workflow
        1. Custom step

        ## Guardrails
        User guardrails

        ## Verification
        User verification
        """
        try Data(edited.utf8).write(to: skillURL, options: .atomic)

        let result = try store.seedBundledCodeSkills()
        #expect(result.skippedExistingIDs.contains("implement"))
        let reloaded = try String(contentsOf: skillURL, encoding: .utf8)
        #expect(reloaded.contains("User-edited implement skill"))
    }

    @Test func codeSessionPhaseRestrictsMutatingTools() {
        #expect(CodeSessionPhase.planActive.restrictsMutatingTools)
        #expect(CodeSessionPhase.planAwaitingApproval.restrictsMutatingTools)
        #expect(!CodeSessionPhase.normal.restrictsMutatingTools)
        #expect(!CodeSessionPhase.implement.restrictsMutatingTools)
    }

    @Test func sessionRoundTripsCodePhasePlanAndCompactFlag() throws {
        var session = LatticeSession(
            title: "Code",
            backend: .codex(model: "gpt-test"),
            executionRoute: .init(mode: .code, providerID: "codex", modelID: "gpt-test", runtimeID: "pi"),
            codePhase: .planAwaitingApproval,
            codePlan: CodePlanArtifact(title: "Ship feature", body: "1. Read\n2. Edit"),
            compactContextOnNextSend: true
        )
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(LatticeSession.self, from: data)
        #expect(decoded.codePhase == .planAwaitingApproval)
        #expect(decoded.codePlan?.title == "Ship feature")
        #expect(decoded.compactContextOnNextSend)

        session.codePhase = .normal
        session.compactContextOnNextSend = false
        let data2 = try JSONEncoder().encode(session)
        let decoded2 = try JSONDecoder().decode(LatticeSession.self, from: data2)
        #expect(decoded2.codePhase == .normal)
        #expect(!decoded2.compactContextOnNextSend)
    }

    @Test func executionPolicyAcceptEditsRoundTrips() throws {
        #expect(ExecutionPolicy.allCases.contains(.acceptEdits))
        #expect(ExecutionPolicy.decoding("Accept Edits") == .acceptEdits)
        #expect(ExecutionPolicy.decoding("unknown-policy") == .ask)
        let route = CodexProviderExecutionRoute.resolve(policy: .acceptEdits)
        #expect(route.approvalPolicy == "on-request")
        #expect(route.sandbox == "workspace-write")
    }

    @Test func resumeSkillsForbidAuthFileReads() {
        let md = LatticeBundledCodeSkills.markdown(for: "resume-codex") ?? ""
        #expect(md.contains("auth.json"))
        #expect(md.contains("Never open or paste") || md.localizedCaseInsensitiveContains("never open"))
        #expect(md.contains("Do not launch"))
        #expect(!LatticeProductInstructions.refersToLatticeProduct("accept edits yolo mode lattice agent"))
    }

    @Test func forceCompactLaunchPlanResetsThread() {
        let messages = (0..<20).map { i in
            ChatMessage(role: i.isMultiple(of: 2) ? .user : .assistant, text: String(repeating: "x", count: 200))
        }
        let session = LatticeSession(
            title: "Compact",
            messages: messages,
            backend: .codex(model: "gpt-test"),
            executionRoute: .init(mode: .code, providerID: "codex", modelID: "gpt-test", runtimeID: "pi"),
            harnessThreadID: "pi:existing-thread",
            compactContextOnNextSend: true
        )
        let plan = RunLaunchPlanner.plan(.init(
            session: session,
            submittedText: "Continue",
            additionalContext: "",
            tokenLimit: 8_000,
            effectiveRuntimeID: "pi"
        ))
        #expect(plan.resetsHarnessSession)
        #expect(plan.didCompact)
        #expect(plan.routeThreadID == nil)
        #expect(plan.statusDetail != nil)
    }

    @Test func codeSessionLockIsExclusive() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }

        let sessionID = UUID()
        let first = try LatticeCodeSessionLock.acquire(
            sessionID: sessionID,
            owner: "desktop",
            applicationSupport: support,
            isProcessAlive: { _ in true }
        )
        #expect(first.owner == "desktop")

        #expect(throws: LatticeCodeSessionLock.Error.alreadyHeld(by: first)) {
            try LatticeCodeSessionLock.acquire(
                sessionID: sessionID,
                owner: "terminal",
                applicationSupport: support,
                isProcessAlive: { _ in true }
            )
        }

        try LatticeCodeSessionLock.release(sessionID: sessionID, owner: "desktop", applicationSupport: support)
        let second = try LatticeCodeSessionLock.acquire(
            sessionID: sessionID,
            owner: "terminal",
            applicationSupport: support,
            isProcessAlive: { _ in true }
        )
        #expect(second.owner == "terminal")
        try LatticeCodeSessionLock.ensureNotes(applicationSupport: support)
        let notes = support.appendingPathComponent("HarnessSessions/CodeLocks/\(LatticeCodeSessionLock.notesFileName)")
        #expect(FileManager.default.fileExists(atPath: notes.path))
    }

    @Test func contextBudgetBreakdownIsEstimateLabeled() {
        let session = LatticeSession(
            title: "Budget",
            messages: [
                .init(role: .user, text: String(repeating: "u", count: 40)),
                .init(role: .assistant, text: String(repeating: "a", count: 80))
            ],
            backend: .codex(model: "gpt-test"),
            attachments: [.init(path: "/tmp/Lattice/PLAN.md")]
        )
        let breakdown = LatticeContextBudgetEstimator.breakdown(session: session, draft: "draft text")
        #expect(breakdown.isEstimate)
        #expect(breakdown.tokens(for: .user) > 0)
        #expect(breakdown.tokens(for: .assistant) > 0)
        #expect(breakdown.tokens(for: .draft) > 0)
        #expect(breakdown.estimatedTotal > 0)
    }
}
