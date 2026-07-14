import Foundation
import Testing
@testable import LatticeCore

@Suite("Pi instruction runtime")
struct PiInstructionRuntimeTests {
    @Test func userAddOnsUseIndependentEightKiBUTF8Limits() throws {
        let exact = String(repeating: "é", count: 4_096)
        let envelope = try LatticeInstructionEnvelope(
            selectedMode: .code,
            codeUserAddOn: exact,
            workUserAddOn: exact
        )
        #expect(envelope.codeUserAddOn.utf8.count == 8_192)
        #expect(envelope.workUserAddOn.utf8.count == 8_192)

        #expect(throws: LatticeInstructionEnvelopeError.userAddOnTooLarge(mode: .code, byteCount: 8_194)) {
            try LatticeInstructionEnvelope(selectedMode: .code, codeUserAddOn: exact + "é")
        }
        #expect(throws: LatticeInstructionEnvelopeError.userAddOnTooLarge(mode: .work, byteCount: 8_194)) {
            try LatticeInstructionEnvelope(selectedMode: .work, workUserAddOn: exact + "é")
        }
    }

    @Test func envelopeRoundTripKeepsVersionIdentityModeAndTrustFacts() throws {
        let envelope = try LatticeInstructionEnvelope(
            selectedMode: .work,
            workspaceFacts: ["workspace fact"],
            controlFacts: ["control fact"],
            capabilityFacts: ["capability fact"],
            workspaceInstructionsTrusted: true,
            trustedWorkspaceInstructionNames: ["AGENTS.md", "CLAUDE.md"],
            codeUserAddOn: "code only",
            workUserAddOn: "work only"
        )
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(LatticeInstructionEnvelope.self, from: data)

        #expect(decoded == envelope)
        #expect(decoded.version == LatticeInstructionEnvelope.currentVersion)
        #expect(decoded.identity == LatticeInstructionEnvelope.latticeIdentity)
        #expect(decoded.activeUserAddOn == "work only")
    }

    @Test func untrustedEnvelopeCannotClaimWorkspaceInstructionNames() {
        #expect(throws: LatticeInstructionEnvelopeError.untrustedWorkspaceInstructionNames) {
            try LatticeInstructionEnvelope(
                selectedMode: .code,
                workspaceInstructionsTrusted: false,
                trustedWorkspaceInstructionNames: ["AGENTS.md"]
            )
        }
    }

    @Test func launchPlanRedactsSecretsAndKeepsInstructionContentOutOfArgv() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let key = "open-code-key-must-not-be-argv"
        let addOn = "user instruction must stay in scratch file"
        let harness = PiRPCHarness(
            executableURL: fixture.pi,
            permissionExtensionURL: fixture.root.appendingPathComponent("permission.js"),
            sandboxExecutableURL: fixture.sandbox,
            applicationSupportDirectory: fixture.root.appendingPathComponent("Application Support")
        )
        let plan = try harness.makeLaunchPlan(
            sessionID: UUID(),
            workspace: fixture.workspace,
            provider: "opencode",
            model: "opencode-go/alpha",
            allowFileModification: true,
            openCodeAPIKey: key,
            environmentOverrides: ["PI_OFFLINE": "1"]
        )

        #expect(plan.piArguments.contains("--provider"))
        #expect(plan.piArguments.contains("opencode-go"))
        #expect(plan.piArguments.contains("--model"))
        #expect(plan.piArguments.contains("alpha"))
        #expect(plan.piArguments.contains("--no-approve"))
        #expect(plan.piArguments.contains("--no-context-files"))
        #expect(!plan.piArguments.contains(key))
        #expect(!plan.arguments.joined(separator: " ").contains(addOn))
        #expect(plan.environment["OPENCODE_API_KEY"] == key)
        #expect(plan.environment["PI_OFFLINE"] == "1")
        #expect(plan.redactedEnvironment["OPENCODE_API_KEY"] == "<redacted>")
        #expect(plan.logSafeArguments == plan.arguments)

        let envelope = try LatticeInstructionEnvelope(
            selectedMode: .code,
            codeUserAddOn: addOn
        )
        let contentPlan = try harness.makeLaunchPlan(
            sessionID: UUID(),
            workspace: fixture.workspace,
            provider: "codex",
            model: "gpt-test",
            instructionEnvelope: envelope
        )
        #expect(String(decoding: try Data(contentsOf: contentPlan.instructionFileURL), as: UTF8.self).contains(addOn))
        #expect(!contentPlan.arguments.joined(separator: " ").contains(addOn))
        #expect(fileMode(contentPlan.instructionFileURL) == 0o600)
    }

    @Test func trustedPlanUsesPiTrustAndOnlyDocumentedContextDiscovery() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let harness = PiRPCHarness(
            executableURL: fixture.pi,
            permissionExtensionURL: fixture.root.appendingPathComponent("permission.js"),
            sandboxExecutableURL: fixture.sandbox,
            applicationSupportDirectory: fixture.root.appendingPathComponent("support")
        )
        let envelope = try LatticeInstructionEnvelope.default(
            mode: .code,
            workspace: fixture.workspace,
            allowFileModification: true,
            workspaceInstructionsTrusted: true,
            trustedWorkspaceInstructionNames: ["AGENTS.md", "CLAUDE.md"]
        )
        let plan = try harness.makeLaunchPlan(
            sessionID: UUID(),
            workspace: fixture.workspace,
            provider: "codex",
            model: "gpt-test",
            allowFileModification: true,
            workspaceInstructionsTrusted: true,
            instructionEnvelope: envelope
        )

        #expect(plan.piArguments.contains("--approve"))
        #expect(!plan.piArguments.contains("--no-approve"))
        #expect(!plan.piArguments.contains("--no-context-files"))
        #expect(plan.piArguments.contains("--no-extensions"))
        #expect(plan.piArguments.contains("--no-skills"))
        #expect(plan.piArguments.contains("--no-prompt-templates"))
        #expect(plan.piArguments.contains("--no-themes"))
        #expect(plan.environment["PI_CODING_AGENT_DIR"] == plan.agentDirectory.path)
        #expect(plan.environment["PI_CODING_AGENT_SESSION_DIR"] == plan.sessionDirectory.path)
        #expect(plan.sessionDirectory.path.contains("support/Lattice/HarnessSessions/Pi"))
        #expect(plan.agentDirectory.path.contains("support/Lattice/HarnessRuntime/Pi"))
        #expect(plan.instructionEnvelope.trustedWorkspaceInstructionNames == ["AGENTS.md", "CLAUDE.md"])
    }

    @Test func providerMappingKeepsCodeCodexAndOpenCodeOnPi() {
        #expect(PiRPCHarness.mapProviderModel(provider: "codex", model: "gpt-test") == .init(provider: "openai-codex", model: "gpt-test"))
        #expect(PiRPCHarness.mapProviderModel(provider: "opencode", model: "opencode-go/model") == .init(provider: "opencode-go", model: "model"))
        let route = ExecutionRoute(mode: .code, providerID: "opencode", modelID: "opencode-go/model", runtimeID: "pi")
        #expect(PiRPCHarness.providerModel(for: route) == .init(provider: "opencode-go", model: "model"))
        let workRoute = ExecutionRoute(mode: .work, providerID: "opencode", modelID: "opencode-go/model", runtimeID: "pi")
        #expect(PiRPCHarness.providerModel(for: workRoute) == nil)
    }

    @Test func explicitExtensionInjectsSystemPromptAndExtendsPermissionGate() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let extensionURL = try PiRPCHarness.installPermissionExtension(at: fixture.root.appendingPathComponent("lattice.js"))
        let source = try String(contentsOf: extensionURL, encoding: .utf8)

        #expect(source.contains("before_agent_start"))
        #expect(source.contains("LATTICE_PI_INSTRUCTION_FILE"))
        #expect(source.contains("readFileSync"))
        #expect(source.contains("systemPrompt"))
        #expect(source.contains("tool_call"))
        #expect(source.contains("ctx.ui.confirm"))
        #expect(!source.contains("--append-system-prompt"))
        #expect(fileMode(extensionURL) == 0o600)
    }

    private func fileMode(_ url: URL) -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let permissions = attributes[.posixPermissions] as? NSNumber else { return -1 }
        return permissions.intValue
    }
}

private struct Fixture {
    let root: URL
    let workspace: URL
    let pi: URL
    let sandbox: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lattice-pi-" + UUID().uuidString, isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        pi = root.appendingPathComponent("pi")
        sandbox = root.appendingPathComponent("sandbox-exec")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        for executable in [pi, sandbox] {
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
