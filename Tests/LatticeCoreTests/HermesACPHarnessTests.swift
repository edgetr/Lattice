import Foundation
import Testing
@testable import LatticeCore

@Suite("Hermes ACP path scope")
struct HermesACPHarnessTests {
    @Test(arguments: ["Sources/App.swift", "./Sources/App.swift"])
    func validRelativePOSIXPathsStayScoped(_ path: String) throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.deletingLastPathComponent()) }
        #expect(WorkspacePathScope.isWorkspaceScoped(path, workspace: workspace))
    }

    @Test func relativePathsThatTraverseParentSegmentsFailClosed() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.deletingLastPathComponent()) }
        #expect(!WorkspacePathScope.isWorkspaceScoped("Sources/../Sources/App.swift", workspace: workspace))
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

    @Test func recoveryRequiresDeliverableVisibleTranscriptHandoff() throws {
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
        try verifyWorkProfileCreatesOnlyPrivateLatticeState()
        try verifyWorkEnvironmentRedactsInheritedCredentials()
        try verifyWorkRouteAndReadinessFailClosed()
        verifyWorkModelMatchingUsesExactIDOnly()
        try verifyInstalledHermesIsNotAuthenticated()
    }

    @Test func profileRejectsSymlinkHomesAndTemporaryDirectories() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let linkedHome = root.appendingPathComponent("linked-home", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedHome, withDestinationURL: outside)
        let linkedProfile = LatticeHermesProfile(hermesHome: linkedHome)
        #expect(throws: LatticeHermesProfileError.invalidHome(linkedHome.path)) {
            try linkedProfile.ensureHome()
        }

        let profile = LatticeHermesProfile(hermesHome: root.appendingPathComponent("safe-home", isDirectory: true))
        let linkedTemporary = root.appendingPathComponent("linked-tmp", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedTemporary, withDestinationURL: outside)
        #expect(throws: LatticeHermesProfileError.invalidTemporaryDirectory(linkedTemporary.path)) {
            _ = try profile.launchEnvironment(temporaryDirectory: linkedTemporary)
        }
    }

    @Test func profileBoundsModelAndSystemIdentityPayloads() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let profile = LatticeHermesProfile(hermesHome: root.appendingPathComponent("home", isDirectory: true))
        let oversizedModel = String(repeating: "m", count: LatticeHermesWorkRoute.maximumModelByteCount + 1)
        #expect(throws: LatticeHermesProfileError.invalidModel(oversizedModel)) {
            try LatticeHermesWorkRoute(provider: "openai-codex", model: oversizedModel).validate()
        }
        let oversizedIdentity = String(repeating: "i", count: LatticeHermesProfile.maximumSystemIdentityByteCount + 1)
        #expect(throws: LatticeHermesProfileError.systemIdentityTooLarge(LatticeHermesProfile.maximumSystemIdentityByteCount)) {
            _ = try profile.configure(
                systemIdentity: oversizedIdentity,
                route: LatticeHermesWorkRoute(provider: "openai-codex", model: "openai-codex:model")
            )
        }
    }

    private func verifyWorkProfileCreatesOnlyPrivateLatticeState() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let profile = LatticeHermesProfile(hermesHome: root.appendingPathComponent("hermes-home", isDirectory: true))
        let route = LatticeHermesWorkRoute(provider: "openai-codex", model: "openai-codex:gpt-5.5")

        try profile.configure(systemIdentity: "Lattice Work identity", route: route)

        #expect(String(data: try Data(contentsOf: profile.soulURL), encoding: .utf8) == "Lattice Work identity")
        let config = try String(contentsOf: profile.configURL, encoding: .utf8)
        #expect(config.contains("provider: \"openai-codex\""))
        #expect(config.contains("default: \"openai-codex:gpt-5.5\""))
        for tool in ["browser", "computer_use", "web", "file", "terminal", "messaging", "cronjob", "credentials", "secrets", "financial"] {
            #expect(config.contains("- \"\(tool)\""))
        }
        #expect(!config.contains("OPENCODE_API_KEY"))
        #expect(!config.contains("auth.json"))
        #expect(!config.contains("state.db"))

        let names = try FileManager.default.contentsOfDirectory(atPath: profile.homeURL.path)
        #expect(Set(names) == [LatticeHermesProfile.configFileName, LatticeHermesProfile.soulFileName])
        #expect(permissions(of: profile.homeURL) == 0o700)
        #expect(permissions(of: profile.configURL) == 0o600)
        #expect(permissions(of: profile.soulURL) == 0o600)
    }

    private func verifyWorkEnvironmentRedactsInheritedCredentials() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let profile = LatticeHermesProfile(hermesHome: root.appendingPathComponent("hermes-home", isDirectory: true))
        let scratch = root.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let base = [
            "PATH": "/usr/bin",
            "OPENAI_API_KEY": "parent-secret",
            "XAI_API_KEY": "parent-secret",
            "CODEX_AUTH_TOKEN": "parent-secret",
            "AUTH_TOKEN": "parent-secret",
            "HERMES_HOME": "/user/home/.hermes"
        ]
        let route = LatticeHermesWorkRoute(provider: "opencode-go", model: "opencode-go:deepseek-v4")
        let environment = try profile.launchEnvironment(
            base: base,
            temporaryDirectory: scratch,
            route: route,
            opencodeAPIKey: "opencode-test-key"
        )

        #expect(environment["PATH"] == "/usr/bin")
        #expect(environment["HERMES_HOME"] == profile.homeURL.path)
        #expect(environment["HOME"] == profile.homeURL.path)
        #expect(environment["TMPDIR"] == scratch.path + "/")
        #expect(environment["OPENCODE_GO_API_KEY"] == "opencode-test-key")
        #expect(environment["OPENCODE_API_KEY"] == nil)
        #expect(environment["OPENAI_API_KEY"] == nil)
        #expect(environment["XAI_API_KEY"] == nil)
        #expect(environment["CODEX_AUTH_TOKEN"] == nil)
        #expect(environment["AUTH_TOKEN"] == nil)

        let zenRoute = LatticeHermesWorkRoute(provider: "opencode-zen", model: "opencode-zen:free")
        let zenEnvironment = try profile.launchEnvironment(
            base: base,
            temporaryDirectory: scratch,
            route: zenRoute,
            opencodeAPIKey: "opencode-test-key"
        )
        #expect(zenEnvironment["OPENCODE_ZEN_API_KEY"] == "opencode-test-key")
        #expect(zenEnvironment["OPENCODE_GO_API_KEY"] == nil)
        #expect(zenEnvironment["OPENCODE_API_KEY"] == nil)
    }

    private func verifyWorkRouteAndReadinessFailClosed() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let profile = LatticeHermesProfile(hermesHome: root.appendingPathComponent("hermes-home", isDirectory: true))
        let invalid = LatticeHermesWorkRoute(provider: "openrouter", model: "gpt-5.5")
        #expect(!invalid.isValid)
        #expect(throws: LatticeHermesProfileError.invalidProvider("openrouter")) {
            try invalid.validate()
        }

        let route = LatticeHermesWorkRoute(provider: "xai-oauth", model: "xai-oauth:grok-4")
        try profile.configure(systemIdentity: "Work", route: route)
        let readiness = profile.readiness(runtimePresent: true, auth: .unknown, catalog: .unknown)
        #expect(readiness.runtimePresent)
        #expect(readiness.profileConfigured)
        #expect(readiness.auth == .unknown)
        #expect(readiness.catalog == .unknown)
        #expect(!readiness.isAuthenticated)
        #expect(!readiness.isReady)
        #expect(profile.readiness(runtimePresent: true, auth: .validated, catalog: .validated).isReady)
    }

    private func verifyWorkModelMatchingUsesExactIDOnly() {
        let models = [
            HarnessModel(id: "opencode-go:deepseek-v4", name: "DeepSeek V4"),
            HarnessModel(id: "opencode-go:minimax-m3", name: "MiniMax M3")
        ]
        #expect(HermesACPHarness.exactMatch(for: "opencode-go:deepseek-v4", in: models)?.id == "opencode-go:deepseek-v4")
        #expect(HermesACPHarness.exactMatch(for: "deepseek-v4", in: models) == nil)
        #expect(HermesACPHarness.exactMatch(for: "DeepSeek V4", in: models) == nil)
    }

    private func verifyInstalledHermesIsNotAuthenticated() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let profile = LatticeHermesProfile(hermesHome: root.appendingPathComponent("hermes-home", isDirectory: true))
        let executable = root.appendingPathComponent("hermes")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let harness = HermesACPHarness(executableURL: executable, sandboxExecutableURL: nil, hermesProfile: profile)
        let readiness = harness.hermesReadiness()
        #expect(readiness.runtimePresent)
        #expect(!readiness.profileConfigured)
        #expect(readiness.auth == .unknown)
        #expect(!readiness.isAuthenticated)
        #expect(!readiness.isReady)
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

    private func permissions(of url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}
