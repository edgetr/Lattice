import Foundation
import Testing
@testable import LatticeCore

@Suite("Recommendation router")
struct RecommendationTests {
    private let harness = HarnessProfile(id: "native", name: "Native", executable: nil, protocolName: "native", supportsTools: true, isQualifiedForActions: true)
    private var local: ModelDescriptor { .init(id: "local", name: "Local", provider: "Lattice", engine: .mlx, quantization: "4-bit", contextWindow: 32_768, capabilities: ["coding"], fit: .comfortable, isLocal: true) }
    private var cloud: ModelDescriptor { .init(id: "cloud", name: "Cloud", provider: "API", engine: .remote, quantization: "server", contextWindow: 128_000, capabilities: ["coding"], fit: .comfortable, isLocal: false) }

    @Test func localOnlyNeverRoutesToCloud() {
        let catalog = [
            ExecutionTuple(id: "cloud", model: cloud, harness: harness, contextPolicy: "long", categories: ["balanced"]),
            ExecutionTuple(id: "local", model: local, harness: harness, contextPolicy: "standard", categories: ["balanced"])
        ]
        let result = DeterministicTaskRouter().recommend(for: .init(task: .coding, requiresLocal: true, requiredContext: 8_000), catalog: catalog)
        #expect(result?.configuration.model.id == "local")
    }

    @Test func insufficientContextReturnsNoRecommendation() {
        let tuple = ExecutionTuple(id: "local", model: local, harness: harness, contextPolicy: "standard", categories: ["balanced"])
        #expect(DeterministicTaskRouter().recommend(for: .init(task: .coding, requiresLocal: true, requiredContext: 90_000), catalog: [tuple]) == nil)
    }

    @Test func executableDiscoveryRejectsPathInjection() {
        #expect(ExecutableDiscovery.locate("../tool", path: "/bin:/usr/bin") == nil)
        #expect(ExecutableDiscovery.locate("sh", path: "/bin") != nil)
    }

    @Test func cliInstallResolverPrefersDirectProviderInstallOverPackageFallbacks() {
        let snapshot = CLIInstallSnapshot(
            executablePath: "/Users/test/.opencode/bin/opencode",
            homebrewPrefix: "/opt/homebrew",
            npmPrefix: "/Users/test/.local",
            homebrewFormulaInstalled: true,
            npmPackageInstalled: true
        )
        #expect(CLIInstallResolver.source(for: snapshot, directPathMarkers: ["/.opencode/bin/"]) == .direct)
        let plan = CLIInstallResolver.updatePlan(
            executableName: "opencode",
            source: .direct,
            homebrewFormula: "opencode",
            npmPackage: "opencode-ai",
            selfUpdateArguments: ["upgrade"],
            directArguments: ["upgrade", "--method", "curl"]
        )
        #expect(plan == CLIUpdateCommandPlan(source: .direct, executable: "opencode", arguments: ["upgrade", "--method", "curl"]))
    }

    @Test func cliInstallResolverUsesOwningPackageManager() {
        let brewSnapshot = CLIInstallSnapshot(
            executablePath: "/opt/homebrew/bin/codex",
            homebrewPrefix: "/opt/homebrew",
            homebrewCaskInstalled: true,
            npmPackageInstalled: true
        )
        #expect(CLIInstallResolver.source(for: brewSnapshot) == .homebrewCask)
        #expect(CLIInstallResolver.updatePlan(executableName: "codex", source: .homebrewCask, homebrewCask: "codex") == CLIUpdateCommandPlan(source: .homebrewCask, executable: "brew", arguments: ["upgrade", "--cask", "codex"]))

        let npmSnapshot = CLIInstallSnapshot(
            executablePath: "/Users/test/.local/bin/codex",
            npmPrefix: "/Users/test/.local",
            npmPackageInstalled: true
        )
        #expect(CLIInstallResolver.source(for: npmSnapshot) == .npmGlobal)
        #expect(CLIInstallResolver.updatePlan(executableName: "codex", source: .npmGlobal, npmPackage: "@openai/codex") == CLIUpdateCommandPlan(source: .npmGlobal, executable: "npm", arguments: ["install", "-g", "@openai/codex@latest"]))
    }

    @Test func cliInstallResolverUsesPublishedPiPackage() {
        #expect(CLIInstallResolver.packageInstallPlan(npmPackage: "@earendil-works/pi-coding-agent", npmAvailable: true, pnpmAvailable: true) == CLIUpdateCommandPlan(source: .npmGlobal, executable: "npm", arguments: ["install", "-g", "@earendil-works/pi-coding-agent@latest"]))
        #expect(CLIInstallResolver.packageInstallPlan(npmPackage: "@earendil-works/pi-coding-agent", npmAvailable: false, pnpmAvailable: true) == CLIUpdateCommandPlan(source: .pnpmGlobal, executable: "pnpm", arguments: ["add", "-g", "@earendil-works/pi-coding-agent@latest"]))
        #expect(CLIInstallResolver.packageInstallPlan(npmPackage: "package", npmAvailable: false, pnpmAvailable: false) == nil)
    }

    @Test func cliInstallResolverUsesOfficialCodexInstallers() {
        #expect(CLIInstallResolver.codexInstallPlan(homebrewAvailable: true, npmAvailable: true, pnpmAvailable: true) == CLIUpdateCommandPlan(source: .homebrewCask, executable: "brew", arguments: ["install", "--cask", "codex"]))
        #expect(CLIInstallResolver.codexInstallPlan(homebrewAvailable: false, npmAvailable: true, pnpmAvailable: true) == CLIUpdateCommandPlan(source: .npmGlobal, executable: "npm", arguments: ["install", "-g", "@openai/codex@latest"]))
        #expect(CLIInstallResolver.codexInstallPlan(homebrewAvailable: false, npmAvailable: false, pnpmAvailable: true) == CLIUpdateCommandPlan(source: .pnpmGlobal, executable: "pnpm", arguments: ["add", "-g", "@openai/codex@latest"]))
        #expect(CLIInstallResolver.codexInstallPlan(homebrewAvailable: false, npmAvailable: false, pnpmAvailable: false) == nil)
    }

    @Test func cliUpdateAvailabilityOnlyAcceptsNewerVersions() {
        #expect(CLIVersionDisplayPolicy.isUpdateAvailable(currentVersion: "0.13.0", latestVersion: "0.14.0"))
        #expect(!CLIVersionDisplayPolicy.isUpdateAvailable(currentVersion: "0.141.0", latestVersion: "0.141.0"))
        #expect(!CLIVersionDisplayPolicy.isUpdateAvailable(currentVersion: "0.141.0", latestVersion: "0.140.0"))
        #expect(CLIVersionDisplayPolicy.targetVersion(currentVersion: nil, latestVersion: "v0.15.0") == "0.15.0")
        #expect(CLIVersionDisplayPolicy.releaseNotes(from: "Update available\nRelease notes:\n- Better ACP restore\n- Fix cancellation") == "- Better ACP restore\n- Fix cancellation")
        #expect(CLIVersionDisplayPolicy.releaseNotes(from: "Update available: 1048 commits behind") == nil)
        #expect(CLIUpdateInfo(latestVersion: "0.15.0", updateAvailable: true).statusText == "Update available · 0.15.0")
    }

    @Test func cliActionStatusPolicyKeepsInstallAndUpdateMessagesTruthful() {
        #expect(CLIActionStatusPolicy.signInMessage(providerName: "OpenCode", commandSucceeded: true, readyAfterRefresh: true).isEmpty)
        #expect(CLIActionStatusPolicy.signInMessage(providerName: "OpenCode", commandSucceeded: false, readyAfterRefresh: false) == "Sign in failed for OpenCode.")
        #expect(CLIActionStatusPolicy.signInMessage(providerName: "OpenCode", commandSucceeded: true, readyAfterRefresh: false) == "Sign in finished, but Lattice could not verify a runnable OpenCode connection.")
        #expect(CLIActionStatusPolicy.signInMessage(providerName: "OpenCode", commandSucceeded: false, readyAfterRefresh: true).isEmpty)
        #expect(CLIActionStatusPolicy.messageIndicatesProblem("pi installed, but it is not on PATH yet."))
        #expect(CLIActionStatusPolicy.messageIndicatesProblem("Active CLI stayed on 1.0.0."))
        #expect(!CLIActionStatusPolicy.messageIndicatesProblem("Update available"))
        #expect(CLIActionStatusPolicy.installMessage(executableName: "pi", status: 1, output: Data("network failed".utf8), executableAvailableAfterRefresh: true) == "Install failed: network failed")
        #expect(CLIActionStatusPolicy.installMessage(executableName: "pi", status: 0, output: Data(), executableAvailableAfterRefresh: false) == "pi installed, but it is not on PATH yet.")
        #expect(CLIActionStatusPolicy.installMessage(executableName: "pi", status: 0, output: Data(), executableAvailableAfterRefresh: true).isEmpty)
        #expect(CLIActionStatusPolicy.updateMessage(status: 1, output: Data("permission denied".utf8), beforeVersion: "1.0.0", afterVersion: "1.0.0") == "Update failed: permission denied")
        #expect(CLIActionStatusPolicy.updateMessage(status: 0, output: Data(), beforeVersion: "1.0.0", afterVersion: "1.1.0").isEmpty)
        #expect(CLIActionStatusPolicy.updateMessage(status: 0, output: Data(), beforeVersion: nil, afterVersion: "1.1.0").isEmpty)
        #expect(CLIActionStatusPolicy.updateMessage(status: 0, output: Data("Already up to date".utf8), beforeVersion: "1.0.0", afterVersion: "1.0.0").isEmpty)
        #expect(CLIActionStatusPolicy.updateMessage(status: 0, output: Data("done".utf8), beforeVersion: "1.0.0", afterVersion: "1.0.0") == "Active CLI stayed on 1.0.0.")
        #expect(CLIActionStatusPolicy.updateMessage(status: 0, output: Data("done".utf8), beforeVersion: "1.0.0", afterVersion: nil) == "Update finished, but Lattice could not verify the active CLI version.")
        #expect(CLIActionStatusPolicy.updateMessage(status: 0, output: Data("done".utf8), beforeVersion: nil, afterVersion: nil) == "Update finished, but Lattice could not verify the active CLI version.")
    }

    @Test func grokTextCatalogDoesNotInferReasoningOptionsFromModelName() {
        let output = """
        You are logged in
        * grok-thinking-test (default)
        - grok-reasoning-test
        """
        let models = StructuredCLIHarness.parseModels(Data(output.utf8), kind: .grok)
        #expect(models.count == 2)
        #expect(models.allSatisfy { $0.reasoningOptions.isEmpty })
        #expect(models.first { $0.id == "grok-thinking-test" }?.isDefault == true)
    }

    @Test func openCodeCatalogRefreshExecutesRefreshCommandBeforeReadingModels() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let executable = root.appendingPathComponent("opencode")
        let marker = root.appendingPathComponent("refreshed")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        if [ "$1" = "models" ] && [ "$2" = "--refresh" ]; then
          printf refreshed > "\(marker.path)"
          exit 0
        fi
        if [ "$1" = "models" ] && [ "$2" = "opencode" ]; then
          printf '%s\\n' '{"id":"fresh","providerID":"opencode","name":"Fresh Model"}'
          exit 0
        fi
        if [ "$1" = "models" ] && [ "$2" = "opencode-go" ]; then
          exit 0
        fi
        exit 1
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let models = await StructuredCLIHarness(kind: .openCode, executableURL: executable).models(refreshCache: true)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(models.map(\.id) == ["opencode/fresh"])
        try? FileManager.default.removeItem(at: root)
    }

    @Test func grokStructuredCatalogCanExposeReasoningOptions() throws {
        let output = """
        {"id":"grok-structured","name":"Grok Structured","isDefault":true,"reasoningOptions":["high","low"],"defaultReasoningEffort":"high"}
        """
        let model = try #require(StructuredCLIHarness.parseModels(Data(output.utf8), kind: .grok).first)
        #expect(model.id == "grok-structured")
        #expect(model.reasoningOptions.map(\.effort) == [.low, .high])
        #expect(model.defaultReasoningEffort == .high)
        #expect(model.isDefault)
    }

    @Test func reasoningCapabilityPolicyMatchesExecutableRoutes() {
        let codexModels = [
            ProviderModel(
                id: "gpt",
                name: "GPT",
                reasoningOptions: [ReasoningOption(effort: .low), ReasoningOption(effort: .high)],
                defaultReasoningEffort: .high
            )
        ]
        let grokModels = [
            ProviderModel(
                id: "grok-structured",
                name: "Grok Structured",
                reasoningOptions: [ReasoningOption(effort: .high)],
                defaultReasoningEffort: .high
            )
        ]
        let openCodeModels = [
            ProviderModel(
                id: "opencode-go/deepseek",
                name: "DeepSeek",
                reasoningOptions: [ReasoningOption(effort: .thinking)],
                defaultReasoningEffort: .thinking
            )
        ]
        #expect(ReasoningCapabilityPolicy.options(for: .codex(model: "gpt"), harnessID: "codex", codexModels: codexModels, grokModels: grokModels, openCodeModels: openCodeModels).map(\.effort) == [.low, .high])
        #expect(ReasoningCapabilityPolicy.defaultEffort(for: .codex(model: "gpt"), harnessID: "codex", codexModels: codexModels, grokModels: grokModels, openCodeModels: openCodeModels) == .high)
        #expect(ReasoningCapabilityPolicy.options(for: .grok(model: "grok-structured"), harnessID: "grok", codexModels: codexModels, grokModels: grokModels, openCodeModels: openCodeModels).isEmpty)
        #expect(ReasoningCapabilityPolicy.defaultEffort(for: .grok(model: "grok-structured"), harnessID: "grok", codexModels: codexModels, grokModels: grokModels, openCodeModels: openCodeModels) == nil)
        #expect(ReasoningCapabilityPolicy.options(for: .openCode(model: "opencode-go/deepseek"), harnessID: "opencode", codexModels: codexModels, grokModels: grokModels, openCodeModels: openCodeModels).isEmpty)
        #expect(ReasoningCapabilityPolicy.options(for: .openCode(model: "opencode-go/deepseek"), harnessID: "pi", codexModels: codexModels, grokModels: grokModels, openCodeModels: openCodeModels).map(\.effort) == [.thinking])
        #expect(ReasoningCapabilityPolicy.defaultEffort(for: .openCode(model: "opencode-go/deepseek"), harnessID: "pi", codexModels: codexModels, grokModels: grokModels, openCodeModels: openCodeModels) == .thinking)
    }

    @Test func executionRoutesOnlyExposeImplementedPairs() {
        #expect(ExecutionRoutePolicy.compatibleHarnessIDs(for: "codex") == ["codex", "pi"])
        #expect(ExecutionRoutePolicy.compatibleHarnessIDs(for: "opencode") == ["opencode", "pi", "hermes"])
        #expect(ExecutionRoutePolicy.compatibleHarnessIDs(for: "grok") == ["grok"])
        #expect(ExecutionRoutePolicy.compatibleHarnessIDs(for: "antigravity") == ["antigravity"])
        #expect(ExecutionRoutePolicy.compatibleHarnessIDs(for: "ollama") == ["lattice"])
        #expect(ExecutionRoutePolicy.compatibleHarnessIDs(for: "apple") == ["lattice"])
        #expect(ExecutionRoutePolicy.normalize(.init(engineID: "codex", harnessID: "lattice"), fallbackEngineID: "codex", fallbackHarnessID: "codex") == .init(engineID: "codex", harnessID: "codex"))
    }

    @Test func antigravityAvailabilityKeepsRunnableModelsAndRepairsStaleOnes() {
        let models = [ProviderModel(id: "Gemini 3.5 Flash (High)", name: "Gemini 3.5 Flash (High)", isDefault: true)]
        let snapshot = BackendAvailabilitySnapshot(antigravityModels: models, antigravityReady: true)
        #expect(BackendAvailabilityPolicy.normalize(.antigravity(model: models[0].id), using: snapshot) == .antigravity(model: models[0].id))
        #expect(BackendAvailabilityPolicy.normalize(.antigravity(model: "Retired model"), using: snapshot) == .antigravity(model: models[0].id))
    }

    @Test func hermesCompatibilityMatchesModelIdentityAcrossProviders() {
        let models = [HarnessModel(id: "nvidia:deepseek-ai/deepseek-v4-pro", name: "deepseek-ai/deepseek-v4-pro")]
        #expect(HermesACPHarness.bestMatch(for: "opencode-go/deepseek-v4-pro", in: models)?.id == "nvidia:deepseek-ai/deepseek-v4-pro")
        #expect(HermesACPHarness.bestMatch(for: "opencode-go/minimax-m3", in: models) == nil)
    }

    @Test func hardwareFitUsesSafeBudget() {
        let hardware = HardwareProfile(chipName: "Test", physicalMemoryBytes: 16 * 1_073_741_824)
        let small = LocalModelRecommendation(id: "small", name: "Small", ollamaTag: "small", parameterCountB: 3, quantizationBits: 4, category: "Fast", contextTokens: 8_192)
        let huge = LocalModelRecommendation(id: "huge", name: "Huge", ollamaTag: "huge", parameterCountB: 100, quantizationBits: 8, category: "Large", contextTokens: 8_192)
        #expect(small.fit(on: hardware) == .comfortable)
        #expect(huge.fit(on: hardware) == .unsupported)
        #expect(small.canInstall(on: hardware))
        #expect(!huge.canInstall(on: hardware))
        #expect(LocalModelCatalog.recommendations(for: hardware, category: "Coding", fitOnly: true).allSatisfy { $0.canInstall(on: hardware) })
        let fullCodingCount = LocalModelCatalog.recommendations(for: hardware, category: "Coding", fitOnly: false).count
        let fitCodingCount = LocalModelCatalog.recommendations(for: hardware, category: "Coding", fitOnly: true).count
        #expect(LocalModelCatalog.hiddenOversizedRecommendationCount(for: hardware, category: "Coding") == fullCodingCount - fitCodingCount)
    }

    @Test func thermalPressureReducesModelBudget() {
        let nominal = HardwareProfile(chipName: "Test", physicalMemoryBytes: 16 * 1_073_741_824, thermalState: "Nominal")
        let critical = HardwareProfile(chipName: "Test", physicalMemoryBytes: 16 * 1_073_741_824, thermalState: "Critical")
        #expect(critical.safeModelBudgetBytes < nominal.safeModelBudgetBytes)
    }
}
