import Foundation
import Combine
import AppKit
import SwiftUI
import Darwin
import UniformTypeIdentifiers
import LatticeCore

@MainActor
extension AppState {
    /// Records a secret-free Keychain observation. Only an authoritative
    /// missing item clears the user's consent; access failures retain consent
    /// while preventing credential injection.
    func applyOpenCodeCredentialReadResult(_ result: KeychainStoreReadResult) {
        let availability = result.availability
        let resolution = CredentialPresenceReconciler.resolve(
            availability,
            previouslyRecorded: openCodeAPIKeySaved
        )
        openCodeCredentialAvailability = availability
        openCodeAPIKeySaved = resolution.recorded
        guard resolution.shouldInvalidateConsent else { return }
        openCodeCredentialEnabledModes.removeAll()
        validatedPiOpenCodeModels.removeAll()
        validatedHermesOpenCodeModels.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.openCodeCredentialModesKey)
    }

    func openCodeCredentialReadFailureMessage(_ result: KeychainStoreReadResult) -> String {
        if case .value(let rawValue) = result,
           !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ""
        }
        if case .value = result {
            return CredentialReadPolicy.failureMessage(for: .invalidData, provider: "OpenCode")
        }
        return result.failureMessage(provider: "OpenCode")
    }

    // MARK: - Map-driven provider accessors (sole source of truth: ProviderConnectionStore)

    var codexReady: Bool { providerConnections.ready(.codex) }
    var codexAuthenticated: Bool { providerConnections.authenticated(.codex) }
    var codexCatalogStatus: ProviderCatalogStatus { providerConnections.catalogStatus(.codex) }
    var codexProtocolUnavailableReason: String? { providerConnections.protocolDetail(.codex) }
    var codexImageInputProtocolSupport: InputCapabilitySupport {
        get { providerConnections.codexImageInputProtocolSupport }
        set { providerConnections.codexImageInputProtocolSupport = newValue }
    }
    var codexModels: [ProviderModel] { providerConnections.models(.codex) }
    var codexUsage: ProviderUsage? { providerConnections.usage(.codex) }
    var codexCLIVersion: String? { providerConnections.cliVersion(.codex) }
    var codexLatestCLIVersion: String? { providerConnections.latestCLIVersion(.codex) }
    var grokReady: Bool { providerConnections.ready(.grok) }
    var grokAuthenticated: Bool { providerConnections.authenticated(.grok) }
    var grokCatalogStatus: ProviderCatalogStatus { providerConnections.catalogStatus(.grok) }
    var grokModels: [ProviderModel] { providerConnections.models(.grok) }
    var grokACPModels: [HarnessModel] { providerConnections.harnessModels(.grok) }
    var grokCLIInfo: CLIUpdateInfo { providerConnections.updateInfo(.grok) ?? CLIUpdateInfo() }
    var openCodeReady: Bool { providerConnections.ready(.opencode) }
    var openCodeAuthenticated: Bool { providerConnections.authenticated(.opencode) }
    var openCodeCatalogStatus: ProviderCatalogStatus { providerConnections.catalogStatus(.opencode) }
    var openCodeModels: [ProviderModel] { providerConnections.models(.opencode) }
    var openCodeACPModels: [HarnessModel] { providerConnections.harnessModels(.opencode) }
    var openCodeCLIVersion: String? { providerConnections.cliVersion(.opencode) }
    var openCodeLatestCLIVersion: String? { providerConnections.latestCLIVersion(.opencode) }
    var antigravityInstalled: Bool { providerConnections.installed(.antigravity) }
    var antigravityAuthenticated: Bool { providerConnections.authenticated(.antigravity) }
    var antigravityCatalogStatus: ProviderCatalogStatus { providerConnections.catalogStatus(.antigravity) }
    var antigravityProtocolSupport: AntigravityCLIProtocol {
        get { providerConnections.antigravityProtocolSupport }
        set { providerConnections.antigravityProtocolSupport = newValue }
    }
    var antigravityModels: [ProviderModel] { providerConnections.models(.antigravity) }
    var antigravityCLIVersion: String? { providerConnections.cliVersion(.antigravity) }
    var antigravityLatestCLIVersion: String? { providerConnections.latestCLIVersion(.antigravity) }
    var piInstalled: Bool { providerConnections.installed(.pi) }
    var piCLIVersion: String? { providerConnections.cliVersion(.pi) }
    var piLatestCLIVersion: String? { providerConnections.latestCLIVersion(.pi) }
    var piModelIDs: Set<String> { providerConnections.piModelIDs() }
    var hermesInstalled: Bool { providerConnections.installed(.hermes) }
    var hermesCatalogStatus: ProviderCatalogStatus { providerConnections.catalogStatus(.hermes) }
    var hermesCLIInfo: CLIUpdateInfo { providerConnections.updateInfo(.hermes) ?? CLIUpdateInfo() }
    var hermesModels: [HarnessModel] { providerConnections.harnessModels(.hermes) }
    var appleIntelligenceReady: Bool { providerConnections.ready(.apple) }
    var appleIntelligenceStatus: String { providerConnections.protocolDetail(.apple) ?? "Checking…" }
    var ollamaInstalled: Bool { providerConnections.installed(.ollama) }
    var ollamaReady: Bool {
        let snap = providerConnections.snapshot(for: .ollama)
        return snap.installed && snap.authenticated
    }
    var ollamaModels: [OllamaModel] {
        get { providerConnections.ollamaModels }
        set { providerConnections.ollamaModels = newValue }
    }
    var ollamaCatalogStatus: ProviderCatalogStatus { providerConnections.catalogStatus(.ollama) }
    /// Map-driven connection observations (owned by ProviderConnectionStore).
    var providerSnapshots: [String: ProviderRuntimeSnapshot] {
        get { providerConnections.snapshots }
        set { providerConnections.replaceAll(newValue) }
    }
    var grokUpdateStatus: String { grokCLIInfo.statusText }

    func refreshConnections(refreshProviderCatalogs: Bool = false) async {
        let generation = connectionRefreshGeneration.begin()
        let localGeneration = localModelRefreshGeneration.begin()
        // Authentication probes are observations of a specific runtime/profile
        // state. Every refresh invalidates them so revoked or changed login state
        // cannot remain runnable from a stale in-memory success.
        invalidateRuntimeAuthenticationValidations()
        // Capture map state before markLoading so cancel can restore exact prior snapshots.
        let previousSnapshots = providerConnections.snapshots
        let previousOllamaModels = providerConnections.ollamaModels
        let previousCodexImage = providerConnections.codexImageInputProtocolSupport
        let previousAntigravityProtocol = providerConnections.antigravityProtocolSupport
        isRefreshingConnections = true
        providerConnections.markLoading(.codex)
        providerConnections.markLoading(.grok)
        providerConnections.markLoading(.opencode)
        providerConnections.markLoading(.antigravity)
        providerConnections.markLoading(.pi)
        providerConnections.markLoading(.hermes)
        providerConnections.markLoading(.ollama)
        providerConnections.markLoading(.apple)
        defer {
            if connectionRefreshGeneration.isCurrent(generation) {
                if Task.isCancelled {
                    // Restore the pre-refresh map (sole source of truth).
                    providerConnections.replaceAll(previousSnapshots)
                    providerConnections.ollamaModels = previousOllamaModels
                    providerConnections.codexImageInputProtocolSupport = previousCodexImage
                    providerConnections.antigravityProtocolSupport = previousAntigravityProtocol
                }
                isRefreshingConnections = false
            }
        }
        async let codexRefresh: Void = refreshCodexConnection(generation: generation)
        async let grokRefresh: Void = refreshGrokConnection(generation: generation)
        async let openCodeRefresh: Void = refreshOpenCodeConnection(refreshCatalog: refreshProviderCatalogs, generation: generation)
        async let antigravityRefresh: Void = refreshAntigravityConnection(generation: generation)
        async let piRefresh: Void = refreshPiConnection(generation: generation)
        async let hermesRefresh: Void = refreshHermesConnection(generation: generation)
        async let localRefresh: Void = refreshLocalConnection(generation: generation, localGeneration: localGeneration)
        _ = await (codexRefresh, grokRefresh, openCodeRefresh, antigravityRefresh, piRefresh, hermesRefresh, localRefresh)
        guard canApplyCatalogRefresh(generation) else { return }
        normalizeBackendsAfterCatalogRefresh()
        normalizeExecutionRouteAfterCatalogRefresh()
        persistConnectionState()
    }

    func canApplyCatalogRefresh(_ generation: UInt64) -> Bool {
        !Task.isCancelled && connectionRefreshGeneration.isCurrent(generation)
    }


    func providerSnapshot(for key: ProviderConnectionKey) -> ProviderRuntimeSnapshot {
        providerConnections.snapshot(for: key)
    }

    func setProviderSnapshot(_ snapshot: ProviderRuntimeSnapshot, for key: ProviderConnectionKey) {
        providerConnections.setSnapshot(snapshot, for: key)
    }

    func refreshCodexConnection(generation: UInt64) async {
        let executable = ExecutableDiscovery.locate("codex")
        guard canApplyCatalogRefresh(generation) else { return }
        if codex.isInstalled != (executable != nil) { codex = CodexExecHarness(executableURL: executable) }
        providerConnections.markLoading(.codex)
        async let codexAuth = codex.isAuthenticated()
        async let codexData = codex.providerSnapshot()
        async let codexVersion = codex.cliVersion()
        async let codexLatest = Self.latestCLIVersion(executableName: "codex", homebrewFormula: "codex", homebrewCask: "codex", npmPackage: "@openai/codex", pnpmPackage: "@openai/codex", directPackage: "@openai/codex")
        let auth = await codexAuth
        let snapshot = await codexData
        let version = await codexVersion
        let latest = await codexLatest
        guard canApplyCatalogRefresh(generation) else { return }
        switch snapshot.capabilities.imageInput {
        case .supported: codexImageInputProtocolSupport = .supported
        case .unsupported: codexImageInputProtocolSupport = .unsupported
        case .unknown: codexImageInputProtocolSupport = .unknown
        }
        // Write models first so visibleCodexModels/runnable counts read the new catalog.
        setProviderSnapshot(
            ProviderRuntimeSnapshot(
                installed: codex.isInstalled,
                authenticated: auth,
                catalogStatus: snapshot.catalogStatus,
                models: snapshot.models,
                cliVersion: version,
                latestCLIVersion: latest,
                protocolDetail: snapshot.unavailableReason,
                runnableModelCount: snapshot.models.filter { isModelEnabled("codex:\($0.id)") }.count,
                usage: snapshot.usage
            ),
            for: .codex
        )
        // Recompute readiness with disabled-model filter after models are published.
        setProviderSnapshot(
            ProviderRuntimeSnapshot(
                installed: codex.isInstalled,
                authenticated: auth,
                catalogStatus: snapshot.catalogStatus,
                models: snapshot.models,
                cliVersion: version,
                latestCLIVersion: latest,
                protocolDetail: snapshot.unavailableReason,
                runnableModelCount: visibleCodexModels.count,
                usage: snapshot.usage
            ),
            for: .codex
        )
    }

    func refreshGrokConnection(generation: UInt64) async {
        let executable = ExecutableDiscovery.locate("grok")
        guard canApplyCatalogRefresh(generation) else { return }
        if grok.isInstalled != (executable != nil) { grok = StructuredCLIHarness(kind: .grok, executableURL: executable) }
        if grokACP.isInstalled != (executable != nil) { grokACP = ACPHarness(profile: .grok, executableURL: executable) }
        providerConnections.markLoading(.grok)
        async let grokAuth = grok.isAuthenticated()
        async let grokCatalog = grok.modelsResult()
        async let grokACPCatalog = grokACP.modelsResult(workspace: URL(fileURLWithPath: selectedWorkspacePath))
        async let grokUpdate = grok.updateStatus()
        let auth = await grokAuth
        let cliCatalog = await grokCatalog
        let acpCatalog = await grokACPCatalog
        let update = await grokUpdate
        guard canApplyCatalogRefresh(generation) else { return }
        let combinedStatus = ProviderCatalogStatus.combined(cliCatalog.status, acpCatalog.status)
        let models = cliCatalog.models.isEmpty ? acpCatalog.models.map { ProviderModel(id: $0.id, name: $0.name) } : cliCatalog.models
        setProviderSnapshot(
            ProviderRuntimeSnapshot(
                installed: grok.isInstalled,
                authenticated: auth,
                catalogStatus: combinedStatus,
                models: models,
                harnessModels: acpCatalog.models,
                cliVersion: update.currentVersion,
                latestCLIVersion: update.latestVersion,
                protocolDetail: update.detail,
                runnableModelCount: models.count,
                updateInfo: update
            ),
            for: .grok
        )
        setProviderSnapshot(
            ProviderRuntimeSnapshot(
                installed: grok.isInstalled,
                authenticated: auth,
                catalogStatus: combinedStatus,
                models: models,
                harnessModels: acpCatalog.models,
                cliVersion: update.currentVersion,
                latestCLIVersion: update.latestVersion,
                protocolDetail: update.detail,
                runnableModelCount: runnableGrokModels.count,
                updateInfo: update
            ),
            for: .grok
        )
    }

    func refreshOpenCodeConnection(refreshCatalog: Bool = false, generation: UInt64) async {
        let executable = ExecutableDiscovery.locate("opencode")
        guard canApplyCatalogRefresh(generation) else { return }
        if openCode.isInstalled != (executable != nil) { openCode = StructuredCLIHarness(kind: .openCode, executableURL: executable) }
        if openCodeACP.isInstalled != (executable != nil) { openCodeACP = ACPHarness(profile: .openCode, executableURL: executable) }
        providerConnections.markLoading(.opencode)
        async let openCodeAuth = openCode.isAuthenticated()
        async let openCodeCatalog = openCode.modelsResult(refreshCache: refreshCatalog)
        async let openCodeACPCatalog = openCodeACP.modelsResult(workspace: URL(fileURLWithPath: selectedWorkspacePath))
        async let openCodeVersion = openCode.cliVersion()
        async let openCodeInstalledVersion = Self.homebrewInstalledFormulaVersion("opencode")
        async let openCodeLatest = Self.latestCLIVersion(executableName: "opencode", homebrewFormula: "opencode", homebrewCask: nil, npmPackage: "opencode-ai", pnpmPackage: "opencode-ai", directPackage: "opencode-ai")
        let auth = await openCodeAuth
        let catalog = await openCodeCatalog
        let acpCatalog = await openCodeACPCatalog
        let detectedVersion = await openCodeVersion
        let installedVersion = await openCodeInstalledVersion
        let latest = await openCodeLatest
        let keychainPresence = KeychainStore.presence(account: OpenCodeCredentialPolicy.keychainAccount)
        guard canApplyCatalogRefresh(generation) else { return }
        let credentialResolution = CredentialPresenceReconciler.resolve(
            keychainPresence,
            previouslyRecorded: openCodeAPIKeySaved
        )
        openCodeCredentialAvailability = keychainPresence
        openCodeAPIKeySaved = credentialResolution.recorded
        if credentialResolution.shouldInvalidateConsent {
            openCodeCredentialEnabledModes.removeAll()
            validatedPiOpenCodeModels.removeAll()
            validatedHermesOpenCodeModels.removeAll()
            UserDefaults.standard.removeObject(forKey: Self.openCodeCredentialModesKey)
        }
        // Direct OpenCode authentication remains a compatibility route. A
        // Lattice Keychain credential is separately consented for Pi/Hermes.
        let combinedStatus = ProviderCatalogStatus.combined(catalog.status, acpCatalog.status)
        let cliVersion = detectedVersion ?? installedVersion
        setProviderSnapshot(
            ProviderRuntimeSnapshot(
                installed: openCode.isInstalled,
                authenticated: auth,
                catalogStatus: combinedStatus,
                models: catalog.models,
                harnessModels: acpCatalog.models,
                cliVersion: cliVersion,
                latestCLIVersion: latest,
                runnableModelCount: catalog.models.count,
            ),
            for: .opencode
        )
        setProviderSnapshot(
            ProviderRuntimeSnapshot(
                installed: openCode.isInstalled,
                authenticated: auth,
                catalogStatus: combinedStatus,
                models: catalog.models,
                harnessModels: acpCatalog.models,
                cliVersion: cliVersion,
                latestCLIVersion: latest,
                runnableModelCount: runnableOpenCodeModels.count,
            ),
            for: .opencode
        )
    }

    func refreshAntigravityConnection(generation: UInt64) async {
        let executable = ExecutableDiscovery.locate("agy")
        guard canApplyCatalogRefresh(generation) else { return }
        if antigravity.isInstalled != (executable != nil) {
            antigravity = AntigravityCLIHarness(executableURL: executable)
        }
        providerConnections.markLoading(.antigravity)
        async let antigravityVersion = Self.commandOutput("agy", ["--version"])
        async let antigravityLatest = Self.latestCLIVersion(executableName: "agy", homebrewFormula: nil, homebrewCask: "antigravity-cli", npmPackage: nil, pnpmPackage: nil, directPackage: "@google/antigravity-cli")
        async let antigravityProtocol = antigravity.protocolSupport()
        async let antigravityCatalog = antigravity.modelsResult()
        let version = await antigravityVersion
        let latest = await antigravityLatest
        let protocolSupport = await antigravityProtocol
        let catalog = await antigravityCatalog
        let models = catalog.models
        // A successful provider-owned catalog command is the authentication
        // probe. Never read Antigravity's OAuth token file in Lattice.
        let authenticated = executable != nil && !models.isEmpty
        guard canApplyCatalogRefresh(generation) else { return }
        antigravityProtocolSupport = protocolSupport
        let cliVersion = CLIVersionDisplayPolicy.normalizedVersion(version)
        setProviderSnapshot(
            ProviderRuntimeSnapshot(
                installed: executable != nil,
                authenticated: authenticated,
                catalogStatus: catalog.status,
                models: models,
                cliVersion: cliVersion,
                latestCLIVersion: latest,
                protocolDetail: String(describing: protocolSupport),
                runnableModelCount: models.count,
            ),
            for: .antigravity
        )
    }

    func refreshPiConnection(generation: UInt64) async {
        let executable = LatticeAgentExecutable.resolve()
        guard canApplyCatalogRefresh(generation) else { return }
        if pi.resolvedExecutableURL?.path != executable?.path {
            pi = PiRPCHarness(executableURL: executable)
        }
        providerConnections.markLoading(.pi)
        let version: String?
        if let executable {
            version = await Self.commandOutput(executable.path, ["--version"])
        } else {
            version = nil
        }
        async let piCatalog = pi.modelCatalog()
        async let piLatest = Self.latestCLIVersion(
            executableName: "pi",
            homebrewFormula: "pi",
            homebrewCask: nil,
            npmPackage: LatticeAgentExecutable.npmPackageName,
            pnpmPackage: LatticeAgentExecutable.npmPackageName,
            directPackage: LatticeAgentExecutable.npmPackageName
        )
        let catalog = await piCatalog
        let latest = await piLatest
        guard canApplyCatalogRefresh(generation) else { return }
        let installed = executable != nil
        setProviderSnapshot(
            ProviderRuntimeSnapshot(
                installed: installed,
                authenticated: installed,
                catalogStatus: catalog.isEmpty ? .empty : .loaded,
                models: catalog.sorted().map { ProviderModel(id: $0, name: $0) },
                cliVersion: version,
                latestCLIVersion: latest,
                runnableModelCount: catalog.count,
            ),
            for: .pi
        )
    }

    func refreshHermesConnection(generation: UInt64) async {
        let executable = ExecutableDiscovery.locate("hermes")
        guard canApplyCatalogRefresh(generation) else { return }
        if hermes.isInstalled != (executable != nil) { hermes = ACPHarness(executableURL: executable) }
        providerConnections.markLoading(.hermes)
        async let hermesInfo = Self.hermesUpdateInfo()
        async let hermesCatalog = hermes.modelsResult(workspace: URL(fileURLWithPath: selectedWorkspacePath))
        let catalog = await hermesCatalog
        let info = await hermesInfo
        guard canApplyCatalogRefresh(generation) else { return }
        let installed = executable != nil
        setProviderSnapshot(
            ProviderRuntimeSnapshot(
                installed: installed,
                authenticated: installed,
                catalogStatus: catalog.status,
                harnessModels: catalog.models,
                cliVersion: info.currentVersion,
                latestCLIVersion: info.latestVersion,
                protocolDetail: info.detail,
                runnableModelCount: catalog.models.count,
                updateInfo: info
            ),
            for: .hermes
        )
    }

    func refreshLocalConnection(generation: UInt64, localGeneration: UInt64) async {
        guard canApplyCatalogRefresh(generation),
              localModelRefreshGeneration.isCurrent(localGeneration) else { return }
        providerConnections.markLoading(.ollama)
        providerConnections.markLoading(.apple)
        async let local = ollama.isAvailable()
        async let models = ollama.modelsResult()
        let localReady = await local
        let localCatalog = await models
        let localInstalled = ExecutableDiscovery.locate("ollama") != nil || Self.ollamaAppURL() != nil
        let intelligenceReady = appleIntelligence.isAvailable
        let intelligenceStatus = appleIntelligence.statusDescription
        guard canApplyCatalogRefresh(generation),
              localModelRefreshGeneration.isCurrent(localGeneration) else { return }
        if localCatalog.status != .failed { ollamaModels = localCatalog.models }
        setProviderSnapshot(
            ProviderRuntimeSnapshot(
                installed: localInstalled,
                authenticated: localReady,
                catalogStatus: localCatalog.status,
                models: ollamaModels.map { ProviderModel(id: $0.name, name: $0.name) },
                protocolDetail: nil,
                runnableModelCount: ollamaModels.count,
            ),
            for: .ollama
        )
        setProviderSnapshot(
            ProviderRuntimeSnapshot(
                installed: intelligenceReady,
                authenticated: intelligenceReady,
                catalogStatus: intelligenceReady ? .loaded : .empty,
                protocolDetail: intelligenceStatus,
                runnableModelCount: intelligenceReady ? 1 : 0,
            ),
            for: .apple
        )
    }

    func connectCodex() {
        guard beginCLIAction(provider: "codex", progress: "Finish signing in to Codex…") else { return }
        Task {
            let commandSucceeded = await codex.login()
            await refreshConnections()
            finishCLISignIn(provider: "codex", providerName: "Codex", commandSucceeded: commandSucceeded, readyAfterRefresh: codexReady)
        }
    }

    func connectGrok() {
        guard beginCLIAction(provider: "grok", progress: "Finish signing in to Grok…") else { return }
        Task {
            let commandSucceeded = await grok.login()
            await refreshConnections()
            finishCLISignIn(provider: "grok", providerName: "Grok", commandSucceeded: commandSucceeded, readyAfterRefresh: grokReady)
        }
    }
    func connectOpenCode() {
        guard beginCLIAction(provider: "opencode", progress: "Finish signing in to OpenCode…") else { return }
        Task {
            let commandSucceeded = await openCode.login()
            await refreshConnections(refreshProviderCatalogs: true)
            finishCLISignIn(provider: "opencode", providerName: "OpenCode", commandSucceeded: commandSucceeded, readyAfterRefresh: openCodeReady)
        }
    }

    func beginCLIAction(provider: String, progress: String, estimatedSeconds: TimeInterval = 180) -> Bool {
        guard !cliBusyProviders.contains(provider) else { return false }
        cliBusyProviders.insert(provider)
        cliActionMessages[provider] = progress
        cliActionStartedAt[provider] = .now
        cliActionEstimatedSeconds[provider] = estimatedSeconds
        return true
    }

    func finishCLIAction(_ provider: String) {
        cliBusyProviders.remove(provider)
        cliActionStartedAt[provider] = nil
        cliActionEstimatedSeconds[provider] = nil
    }

    func cliProgressText(_ provider: String, at now: Date = .now) -> String {
        guard isCLIBusy(provider) else { return "" }
        let message = cliActionMessages[provider] ?? "Working…"
        guard let startedAt = cliActionStartedAt[provider],
              let estimate = cliActionEstimatedSeconds[provider] else { return message }
        let elapsed = max(0, now.timeIntervalSince(startedAt))
        let remaining = max(0, estimate - elapsed)
        if remaining < 1 { return "\(message) · Finishing…" }
        let seconds = Int(remaining.rounded(.up))
        let time = seconds >= 60 ? "~\(seconds / 60)m \(seconds % 60)s remaining" : "~\(seconds)s remaining"
        return "\(message) · \(time)"
    }

    func finishCLISignIn(provider: String, providerName: String, commandSucceeded: Bool, readyAfterRefresh: Bool) {
        cliActionMessages[provider] = CLIActionStatusPolicy.signInMessage(
            providerName: providerName,
            commandSucceeded: commandSucceeded,
            readyAfterRefresh: readyAfterRefresh
        )
        finishCLIAction(provider)
    }
    func connectAntigravity() {
        guard antigravityInstalled,
              beginCLIAction(provider: "antigravity", progress: "Finish signing in in your browser…") else { return }
        Task {
            let result = await Self.runAntigravityLogin()
            await refreshConnections()
            if antigravityAuthenticated {
                cliActionMessages["antigravity"] = ""
            } else {
                cliActionMessages["antigravity"] = CLIActionStatusPolicy.failureMessage(prefix: "Sign in failed", output: result.output)
            }
            finishCLIAction("antigravity")
        }
    }
    func installCodex() {
        requestCLIInstall("codex")
    }
    func performCodexInstall() {
        runCLIInstall(provider: "codex", progress: "Installing Codex…", executableName: "codex") {
            guard let plan = CLIInstallResolver.codexInstallPlan(
                homebrewAvailable: ExecutableDiscovery.locate("brew") != nil,
                npmAvailable: ExecutableDiscovery.locate("npm") != nil,
                pnpmAvailable: ExecutableDiscovery.locate("pnpm") != nil
            ) else {
                return (-1, Data("Homebrew or Node.js with npm or pnpm is required to install Codex from Lattice.".utf8))
            }
            return await Self.runCommand(plan.executable, plan.arguments)
        }
    }
    func installGrok() {
        requestCLIInstall("grok")
    }
    func performGrokInstall() {
        runCLIInstall(provider: "grok", progress: "Installing Grok…", executableName: "grok") {
            await Self.runRemoteInstallerScript("https://x.ai/cli/install.sh")
        }
    }
    func installOpenCode() {
        requestCLIInstall("opencode")
    }
    func performOpenCodeInstall() {
        runCLIInstall(provider: "opencode", progress: "Installing OpenCode…", executableName: "opencode") {
            if ExecutableDiscovery.locate("npm") != nil || ExecutableDiscovery.locate("pnpm") != nil {
                guard let plan = CLIInstallResolver.packageInstallPlan(
                    npmPackage: "opencode-ai",
                    npmAvailable: ExecutableDiscovery.locate("npm") != nil,
                    pnpmAvailable: ExecutableDiscovery.locate("pnpm") != nil
                ) else { return (-1, Data("Could not resolve the OpenCode package installer.".utf8)) }
                return await Self.runCommand(plan.executable, plan.arguments)
            }
            if ExecutableDiscovery.locate("brew") != nil {
                return await Self.runCommand("brew", ["install", "anomalyco/tap/opencode"])
            }
            return await Self.runRemoteInstallerScript("https://opencode.ai/install")
        }
    }
    func installPi() {
        requestRuntimeAction(.firstUseInstall, runtime: .pi)
    }
    func performPiInstall() {
        let version = RuntimeInstallDescriptor.pi.immutableVersion
        runCLIInstall(
            provider: "pi",
            progress: "Installing \(LatticeAgentExecutable.productDisplayName) \(version)…",
            executableName: "pi"
        ) {
            let reference = RuntimeInstallDescriptor.pi.installReference
            let prefix = LatticeAgentExecutable.managedInstallRoot().path
            try? FileManager.default.createDirectory(
                at: LatticeAgentExecutable.managedInstallRoot(),
                withIntermediateDirectories: true
            )
            if ExecutableDiscovery.locate("npm") != nil {
                let integrity = await Self.runCommand("npm", ["view", reference, "dist.integrity", "--json"], deadline: 30)
                let reported = String(decoding: integrity.output, as: UTF8.self)
                guard integrity.status == 0,
                      let expected = RuntimeInstallDescriptor.pi.registryIntegrity,
                      RuntimeArtifactVerification.registryIntegrityMatches(reported: reported, expected: expected) else {
                    return (-1, Data("Lattice Agent registry integrity did not match Lattice's pinned release metadata.".utf8))
                }
                // Prefix install keeps the engine out of the user's global npm/PATH Pi.
                return await Self.runCommand(
                    "npm",
                    ["install", "--prefix", prefix, "--ignore-scripts", reference],
                    deadline: 180
                )
            }
            if ExecutableDiscovery.locate("pnpm") != nil {
                let integrity = await Self.runCommand("pnpm", ["view", reference, "dist.integrity", "--json"], deadline: 30)
                let reported = String(decoding: integrity.output, as: UTF8.self)
                guard integrity.status == 0,
                      let expected = RuntimeInstallDescriptor.pi.registryIntegrity,
                      RuntimeArtifactVerification.registryIntegrityMatches(reported: reported, expected: expected) else {
                    return (-1, Data("Lattice Agent registry integrity did not match Lattice's pinned release metadata.".utf8))
                }
                return await Self.runCommand(
                    "pnpm",
                    ["add", "--dir", prefix, "--ignore-scripts", reference],
                    deadline: 180
                )
            }
            return (-1, Data("Node.js with npm or pnpm is required to install the pinned Lattice Agent package into Lattice's private runtime folder.".utf8))
        }
    }
    func installHermes() {
        requestRuntimeAction(.firstUseInstall, runtime: .hermes)
    }
    func installAntigravity() {
        requestCLIInstall("antigravity")
    }

    func requestCLIInstall(_ provider: String) {
        guard !cliBusyProviders.contains(provider) else { return }
        pendingCLIInstallProvider = provider
    }

    func cancelCLIInstall() {
        pendingCLIInstallProvider = nil
    }

    func requestRuntimeAction(_ action: RuntimeLifecycleAction, runtime: LatticeRuntimeID) {
        guard !cliBusyProviders.contains(runtime.rawValue) else { return }
        pendingRuntimeConfirmation = RuntimeConfirmationRequest(runtime: runtime, action: action)
        runtimeLifecycleStates[runtime] = RuntimeLifecycleState(
            runtime: runtime,
            phase: .awaitingConfirmation,
            detail: "Waiting for confirmation.",
            installedVersion: runtime == .pi ? piCLIVersion : hermesCLIInfo.currentVersion
        )
    }

    func cancelRuntimeAction() {
        guard let request = pendingRuntimeConfirmation else { return }
        pendingRuntimeConfirmation = nil
        runtimeLifecycleStates[request.runtime] = RuntimeLifecycleState(
            runtime: request.runtime,
            phase: .cancelled,
            detail: "No changes were made.",
            installedVersion: request.runtime == .pi ? piCLIVersion : hermesCLIInfo.currentVersion
        )
    }

    func confirmRuntimeAction() {
        guard let request = pendingRuntimeConfirmation else { return }
        pendingRuntimeConfirmation = nil
        switch request.action {
        case .firstUseInstall, .update:
            runtimeLifecycleStates[request.runtime] = RuntimeLifecycleState(
                runtime: request.runtime,
                phase: request.action == .update ? .updating : .installing,
                detail: "Using the exact pinned source shown in the confirmation.",
                installedVersion: request.runtime == .pi ? piCLIVersion : hermesCLIInfo.currentVersion
            )
            if request.runtime == .pi { performPiInstall() }
            else { performHermesInstall() }
        case .uninstall:
            performRuntimeUninstall(request.runtime)
        case .rollback:
            runtimeLifecycleStates[request.runtime] = RuntimeLifecycleState(
                runtime: request.runtime,
                phase: .failed,
                detail: "No previously installed Lattice runtime version is recorded for rollback.",
                installedVersion: request.runtime == .pi ? piCLIVersion : hermesCLIInfo.currentVersion
            )
        case .cancel, .interruptUpdate:
            runtimeLifecycleStates[request.runtime] = RuntimeLifecycleState(
                runtime: request.runtime,
                phase: request.action == .interruptUpdate ? .updateInterrupted : .cancelled,
                detail: "No additional runtime change was started.",
                installedVersion: request.runtime == .pi ? piCLIVersion : hermesCLIInfo.currentVersion
            )
        }
    }

    func performRuntimeUninstall(_ runtime: LatticeRuntimeID) {
        guard RuntimeOwnershipPolicy.canUninstall(runtime, managedRuntimeIDs: latticeManagedRuntimeIDs) else {
            runtimeLifecycleStates[runtime] = RuntimeLifecycleState(
                runtime: runtime,
                phase: .failed,
                detail: "This runtime was not installed by Lattice, so Lattice will not remove it.",
                installedVersion: runtime == .pi ? piCLIVersion : hermesCLIInfo.currentVersion
            )
            return
        }
        let provider = runtime.rawValue
        guard beginCLIAction(provider: provider, progress: "Removing \(runtime.displayName)…", estimatedSeconds: 60) else { return }
        runtimeLifecycleStates[runtime] = RuntimeLifecycleState(runtime: runtime, phase: .uninstalling)
        Task {
            let result: (status: Int32, output: Data)
            switch runtime {
            case .pi:
                // Only remove Lattice-managed install; never touch a user global `pi`.
                let managedRoot = LatticeAgentExecutable.managedInstallRoot()
                if FileManager.default.fileExists(atPath: managedRoot.path) {
                    do {
                        try FileManager.default.removeItem(at: managedRoot)
                        result = (0, Data())
                    } catch {
                        result = (-1, Data("Could not remove Lattice Agent: \(error.localizedDescription)".utf8))
                    }
                } else {
                    result = (0, Data("No Lattice-managed Lattice Agent install was present.".utf8))
                }
            case .hermes:
                result = ExecutableDiscovery.locate("uv") == nil
                    ? (-1, Data("uv is required to remove the Lattice-installed Hermes tool.".utf8))
                    : await Self.runCommand("uv", ["tool", "uninstall", "hermes-agent"], deadline: 120)
            }
            await refreshConnections(refreshProviderCatalogs: true)
            let removed: Bool = {
                switch runtime {
                case .pi: LatticeAgentExecutable.managedExecutableURL() == nil && LatticeAgentExecutable.bundledExecutableURL() == nil
                case .hermes: ExecutableDiscovery.locate(runtime.executableName) == nil
                }
            }()
            let detail = removed
                ? "Removed. Lattice-owned profile data remains available for rollback until you remove it manually."
                : CLIActionStatusPolicy.failureMessage(prefix: "Removal incomplete", output: result.output)
            runtimeLifecycleStates[runtime] = RuntimeLifecycleState(
                runtime: runtime,
                phase: removed ? .completed : .failed,
                detail: detail,
                installedVersion: removed ? nil : (runtime == .pi ? piCLIVersion : hermesCLIInfo.currentVersion)
            )
            if removed {
                latticeManagedRuntimeIDs.remove(runtime)
                UserDefaults.standard.set(latticeManagedRuntimeIDs.map(\.rawValue).sorted(), forKey: Self.managedRuntimeIDsKey)
            }
            cliActionMessages[provider] = detail
            finishCLIAction(provider)
        }
    }

    func confirmCLIInstall() {
        guard let provider = pendingCLIInstallProvider else { return }
        pendingCLIInstallProvider = nil
        switch provider {
        case "codex": performCodexInstall()
        case "grok": performGrokInstall()
        case "opencode": performOpenCodeInstall()
        case "antigravity": performAntigravityInstall()
        default: break
        }
    }

    func performHermesInstall() {
        runCLIInstall(provider: "hermes", progress: "Installing pinned Hermes…", executableName: "hermes") {
            guard ExecutableDiscovery.locate("uv") != nil else {
                return (-1, Data("uv is required to install the pinned Hermes source revision.".utf8))
            }
            return await Self.runCommand(
                "uv",
                ["tool", "install", "--force", RuntimeInstallDescriptor.hermes.installReference],
                deadline: 300
            )
        }
    }

    func performAntigravityInstall() {
        runCLIInstall(provider: "antigravity", progress: "Installing Antigravity…", executableName: "agy") {
            guard ExecutableDiscovery.locate("brew") != nil else {
                return (-1, Data("Homebrew is required to install the official Antigravity CLI cask.".utf8))
            }
            return await Self.runCommand("brew", ["install", "--cask", "antigravity-cli"])
        }
    }
    func connectHermes() {
        openHermesAuthentication()
    }

    func openPiAuthentication() {
        guard piInstalled, let executable = LatticeAgentExecutable.resolve() else {
            runtimeAuthenticationPhases[.pi] = .signInRequired
            cliActionMessages["pi"] = "Install Lattice Agent before signing in."
            return
        }
        validatedPiCodexModels.removeAll()
        let profile = PiRPCHarness(executableURL: executable).sharedProfileDirectory
        guard openRuntimeTerminal(
            name: "lattice-agent-login",
            executable: executable,
            arguments: [],
            environment: ["PI_CODING_AGENT_DIR": profile.path]
        ) else {
            runtimeAuthenticationPhases[.pi] = .signInRequired
            cliActionMessages["pi"] = "Lattice could not open the isolated Lattice Agent login terminal."
            return
        }
        runtimeAuthenticationPhases[.pi] = .validationPending
        cliActionMessages["pi"] = "In Lattice Agent, run /login and choose ChatGPT. Return here, then choose Check Code."
    }

    func runtimeAuthenticationAction(for runtime: LatticeRuntimeID) -> HarnessReadinessAuthenticationAction {
        (runtimeAuthenticationPhases[runtime] ?? .signInRequired).action
    }

    func validatePiAuthentication(providerID: String) {
        guard piInstalled,
              !isRefreshingConnections,
              !cliBusyProviders.contains("pi-\(providerID)") else { return }
        let candidates = piModelIDs.sorted().compactMap { identifier -> (provider: String, model: String)? in
            if providerID == "codex", identifier.hasPrefix("openai-codex/") {
                return ("codex", String(identifier.dropFirst("openai-codex/".count)))
            }
            if providerID == "opencode",
               identifier.hasPrefix("opencode-go/") || identifier.hasPrefix("opencode-zen/") {
                return ("opencode", identifier)
            }
            return nil
        }
        guard let candidate = candidates.first else {
            runtimeAuthenticationPhases[.pi] = .signInRequired
            cliActionMessages["pi"] = "Lattice Agent did not report a compatible \(providerID) model."
            return
        }
        let actionID = "pi-\(providerID)"
        guard beginCLIAction(provider: actionID, progress: "Checking Lattice Agent \(providerID)…", estimatedSeconds: 30) else { return }
        let refreshGeneration = connectionRefreshGeneration.current()
        Task {
            let key: String?
            if providerID == "opencode" && openCodeCredentialEnabledModes.contains(.code) {
                let readResult = KeychainStore.read(account: OpenCodeCredentialPolicy.keychainAccount)
                applyOpenCodeCredentialReadResult(readResult)
                guard case .value(let rawValue) = readResult,
                      !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    cliActionMessages["pi"] = openCodeCredentialReadFailureMessage(readResult)
                    finishCLIAction(actionID)
                    return
                }
                key = rawValue
            } else {
                key = nil
            }
            let valid = await pi.validateIsolatedAuthentication(
                provider: candidate.provider,
                model: candidate.model,
                openCodeAPIKey: key
            )
            guard connectionRefreshGeneration.isCurrent(refreshGeneration), !isRefreshingConnections else {
                finishCLIAction(actionID)
                return
            }
            if valid {
                if providerID == "codex" {
                    validatedPiCodexModels = Set(candidates.map(\.model))
                } else {
                    validatedPiOpenCodeModels = Set(candidates.map(\.model))
                }
                cliActionMessages["pi"] = "Lattice Agent \(providerID) sign-in and models are available."
            } else {
                if providerID == "codex" { validatedPiCodexModels.removeAll() }
                else { validatedPiOpenCodeModels.removeAll() }
                cliActionMessages["pi"] = "Lattice Agent could not verify \(providerID). Sign in again or check the enabled key, then validate once more."
            }
            runtimeAuthenticationPhases[.pi] = .afterValidation()
            finishCLIAction(actionID)
        }
    }

    func openHermesAuthentication() {
        guard hermesInstalled, let executable = ExecutableDiscovery.locate("hermes") else {
            runtimeAuthenticationPhases[.hermes] = .signInRequired
            cliActionMessages["hermes"] = "Install Hermes before signing in."
            return
        }
        validatedHermesProviders.removeAll()
        validatedHermesOpenCodeModels.removeAll()
        let profile = LatticeHermesProfile().homeURL
        guard openRuntimeTerminal(
            name: "hermes-model",
            executable: executable,
            arguments: ["model"],
            environment: ["HOME": profile.path, "HERMES_HOME": profile.path]
        ) else {
            runtimeAuthenticationPhases[.hermes] = .signInRequired
            cliActionMessages["hermes"] = "Lattice could not open the isolated Hermes model setup terminal."
            return
        }
        runtimeAuthenticationPhases[.hermes] = .validationPending
        cliActionMessages["hermes"] = "Choose and sign in to the Work provider in Hermes, then choose Check Work here."
    }

    func validateHermesAuthentication(providerID: String) {
        let provider: String
        switch providerID {
        case "codex": provider = LatticeHermesProvider.openAICodex.rawValue
        case "grok": provider = LatticeHermesProvider.xAIOAuth.rawValue
        default:
            cliActionMessages["hermes"] = "OpenCode uses the explicitly enabled Keychain credential."
            return
        }
        let actionID = "hermes-\(providerID)"
        guard hermesInstalled,
              !isRefreshingConnections,
              beginCLIAction(provider: actionID, progress: "Checking Hermes \(providerID)…", estimatedSeconds: 20) else { return }
        let refreshGeneration = connectionRefreshGeneration.current()
        Task {
            let valid = await hermes.validateHermesAuthentication(provider: provider)
            guard connectionRefreshGeneration.isCurrent(refreshGeneration), !isRefreshingConnections else {
                finishCLIAction(actionID)
                return
            }
            if valid { validatedHermesProviders.insert(provider) }
            else { validatedHermesProviders.remove(provider) }
            cliActionMessages["hermes"] = valid
                ? "Hermes \(providerID) sign-in is available."
                : "Hermes did not report an authenticated \(providerID) session. Sign in again, then validate once more."
            runtimeAuthenticationPhases[.hermes] = .afterValidation()
            finishCLIAction(actionID)
        }
    }

    func validateHermesOpenCodeAuthentication() {
        let candidates = hermesModels.filter {
            $0.id.hasPrefix("opencode-go:") || $0.id.hasPrefix("opencode-zen:")
        }
        guard hermesInstalled,
              !isRefreshingConnections,
              openCodeAPIKeySaved,
              openCodeCredentialEnabledModes.contains(.work),
              let candidate = candidates.first,
              let route = ExecutionRouteResolver.resolve(
                mode: .work,
                providerID: "opencode",
                modelID: candidate.id
              ),
              let provider = hermesProvider(for: route) else {
            cliActionMessages["hermes"] = "Enable the saved OpenCode key for Work and discover a Hermes OpenCode model first."
            return
        }
        let readResult = KeychainStore.read(account: OpenCodeCredentialPolicy.keychainAccount)
        applyOpenCodeCredentialReadResult(readResult)
        guard case .value(let rawValue) = readResult,
              !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            cliActionMessages["hermes"] = openCodeCredentialReadFailureMessage(readResult)
            return
        }
        let key = rawValue
        guard beginCLIAction(provider: "hermes-opencode", progress: "Checking Hermes OpenCode…", estimatedSeconds: 30) else { return }
        let refreshGeneration = connectionRefreshGeneration.current()
        Task {
            let result = await hermes.modelsResult(
                workspace: URL(fileURLWithPath: selectedWorkspacePath),
                provider: provider,
                model: candidate.id,
                systemIdentity: LatticeProductInstructions.current,
                opencodeAPIKey: key
            )
            let valid = result.status == .loaded
                && HermesACPHarness.exactMatch(for: candidate.id, in: result.models) != nil
            guard connectionRefreshGeneration.isCurrent(refreshGeneration), !isRefreshingConnections else {
                finishCLIAction("hermes-opencode")
                return
            }
            if valid { validatedHermesOpenCodeModels = Set(candidates.map(\.id)) }
            else { validatedHermesOpenCodeModels.removeAll() }
            cliActionMessages["hermes"] = valid
                ? "Hermes OpenCode sign-in and models are available for Work."
                : "Hermes could not verify the OpenCode Work route."
            finishCLIAction("hermes-opencode")
        }
    }

    func openRuntimeTerminal(
        name: String,
        executable: URL,
        arguments: [String],
        environment: [String: String]
    ) -> Bool {
        let directory = LatticeApplicationSupport.productRootURL()
            .appendingPathComponent("RuntimeLaunchers", isDirectory: true)
        let scriptURL = directory.appendingPathComponent("\(name).command")
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let exports = environment.sorted(by: { $0.key < $1.key }).map { key, value in
                "export \(key)=\(Self.shellQuote(value))"
            }
            let command = (["exec", Self.shellQuote(executable.path)] + arguments.map(Self.shellQuote)).joined(separator: " ")
            let body = (["#!/bin/zsh", "set -eu"] + exports + [command, ""]).joined(separator: "\n")
            try Data(body.utf8).write(to: scriptURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
            return NSWorkspace.shared.open(scriptURL)
        } catch {
            return false
        }
    }

    nonisolated private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    func installOllama() { NSWorkspace.shared.open(URL(string: "https://ollama.com/download/mac")!) }
    func openOllama() {
        guard let appURL = Self.ollamaAppURL() else { installOllama(); return }
        NSWorkspace.shared.open(appURL)
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await refreshConnections()
        }
    }
    func isCLIBusy(_ provider: String) -> Bool { cliBusyProviders.contains(provider) }
    func activeCLIActionID(for provider: String) -> String? {
        if cliBusyProviders.contains(provider) { return provider }
        return cliBusyProviders.sorted().first { $0.hasPrefix("\(provider)-") }
    }
    func cliActionMessage(_ provider: String) -> String? { cliActionMessages[provider] }

    func refreshExtensions() {
        prepareSelfEditWorkspace()
        refreshSkills()
        let loaded = extensionStore.load()
        let known = Set(UserDefaults.standard.stringArray(forKey: Self.knownExtensionIDsKey) ?? [])
        let refreshedEnablement = LatticeExtensionEnablementPolicy.refresh(
            records: loaded,
            storedEnabledIDs: enabledExtensionIDs,
            knownIDs: known
        )
        extensions = loaded
        enabledExtensionIDs = refreshedEnablement.enabledIDs
        UserDefaults.standard.set(Array(refreshedEnablement.knownIDs).sorted(), forKey: Self.knownExtensionIDsKey)
        UserDefaults.standard.set(Array(enabledExtensionIDs).sorted(), forKey: Self.enabledExtensionIDsKey)
        activeStylePatches = loaded
            .filter { enabledExtensionIDs.contains($0.id) && $0.isValid && $0.hasRuntimePatches }
            .flatMap(\.stylePatches)
        activeLayoutPatches = loaded
            .filter { enabledExtensionIDs.contains($0.id) && $0.isValid && $0.hasRuntimePatches }
            .flatMap(\.layoutPatches)
        activeCopyPatches = loaded
            .filter { enabledExtensionIDs.contains($0.id) && $0.isValid && $0.hasRuntimePatches }
            .flatMap(\.copyPatches)
        activePromptTemplates = loaded
            .filter { enabledExtensionIDs.contains($0.id) && $0.isValid && $0.hasRuntimePatches }
            .flatMap(\.promptTemplates)
    }

    func refreshSkills() {
        do {
            let previousSkillIDs = Set(skills.map(\.id))
            try skillStore.importGlobalSkills()
            let seed = try skillStore.seedBundledCodeSkills()
            applyBundledSkillDefaultDisablement(seed)
            skills = skillStore.load()
            // Newly imported globals start disabled (safer defaults; match panel import behavior).
            applyNewGlobalSkillDefaultDisablement(previousIDs: previousSkillIDs)
            disabledSkillIDs = disabledSkillIDs.intersection(Set(skills.map(\.id)))
            UserDefaults.standard.set(Array(disabledSkillIDs).sorted(), forKey: Self.disabledSkillIDsKey)
        } catch {
            skills = skillStore.load()
            setError(error.localizedDescription)
        }
    }

    /// Lightweight reload without re-importing globals (toggle path).
    func reloadSkillsFromDisk() {
        skills = skillStore.load()
        disabledSkillIDs = disabledSkillIDs.intersection(Set(skills.map(\.id)))
        UserDefaults.standard.set(Array(disabledSkillIDs).sorted(), forKey: Self.disabledSkillIDsKey)
    }

    /// First-time seed only: mark default-off bundled skills disabled without re-disabling
    /// skills the user later enabled. Tracked via UserDefaults seeded-id set.
    private func applyBundledSkillDefaultDisablement(_ seed: LatticeBundledCodeSkills.SeedResult) {
        let key = Self.bundledSkillDefaultsAppliedKey
        var applied = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        let skillIDs = Set(skillStore.load().map(\.id))
        for id in seed.defaultDisabledIDs where skillIDs.contains(id) && !applied.contains(id) {
            disabledSkillIDs.insert(id)
            applied.insert(id)
        }
        // Newly seeded default-off ids also get a one-shot disable even if already listed.
        for id in seed.seededIDs where seed.defaultDisabledIDs.contains(id) && !applied.contains(id) {
            disabledSkillIDs.insert(id)
            applied.insert(id)
        }
        UserDefaults.standard.set(Array(applied).sorted(), forKey: key)
    }

    /// One-shot disable for skills that appear after a global import and were not previously known.
    private func applyNewGlobalSkillDefaultDisablement(previousIDs: Set<String>) {
        let key = Self.globalSkillDefaultsAppliedKey
        var applied = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        let newlyImported = skills.filter { record in
            record.source == .importedGlobal
                && !previousIDs.contains(record.id)
                && !applied.contains(record.id)
        }
        for record in newlyImported {
            disabledSkillIDs.insert(record.id)
            applied.insert(record.id)
        }
        UserDefaults.standard.set(Array(applied).sorted(), forKey: key)
    }

    private static let bundledSkillDefaultsAppliedKey = "latticeBundledSkillDefaultsApplied"
    private static let globalSkillDefaultsAppliedKey = "latticeGlobalSkillDefaultsApplied"

    func startExtensionMonitoring() {
        try? extensionStore.prepareDirectory()
        if extensionDirectoryFileDescriptor >= 0 { close(extensionDirectoryFileDescriptor) }
        extensionDirectoryFileDescriptor = open(extensionStore.rootURL.path, O_EVTONLY)
        guard extensionDirectoryFileDescriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: extensionDirectoryFileDescriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.refreshExtensions()
            }
        }
        source.setCancelHandler { [weak self] in
            guard let self, self.extensionDirectoryFileDescriptor >= 0 else { return }
            close(self.extensionDirectoryFileDescriptor)
            self.extensionDirectoryFileDescriptor = -1
        }
        source.resume()
        extensionDirectorySource = source
    }

    func workspaceURL(for session: LatticeSession, isExtensionSelfEdit: Bool) -> URL {
        if isExtensionSelfEdit {
            prepareSelfEditWorkspace()
            return extensionStore.rootURL
        }
        return URL(fileURLWithPath: session.workspacePath ?? selectedWorkspacePath)
    }

    func prepareSelfEditWorkspace() {
        do {
            try extensionStore.prepareDirectory()
            try skillStore.prepareDirectory()
            try writeSelfEditGuide()
            try writeSelfMap()
        } catch {
            setError(error.localizedDescription)
        }
    }

    func writeSelfEditGuide() throws {
        let guideURL = extensionStore.rootURL.appendingPathComponent("LATTICE_SELF_EDIT.md")
        // Prefer lattice guide name; leave any legacy NISA_SELF_EDIT.md in place for manual reference only.
        let guide = """
        # Lattice self-edit workspace

        This folder is Lattice's user-owned modification layer. Shipped builds must create or update extensions here instead of editing the installed app bundle or requiring a source checkout.

        ## Editable surfaces

        Read `lattice-self-map.json` for the current app surface map.

        ## Extension manifest

        Create one folder per change. Each folder must contain `lattice-extension.json`.

        Minimal manifest:

        ```json
        {
          "schemaVersion": 1,
          "id": "letters-numbers-dots-underscores-or-hyphens",
          "name": "Short user-facing name",
          "version": "1.0.0",
          "summary": "What this changes",
          "permissions": ["editUI"],
          "uiTargets": ["overlay", "composer", "chat", "sidebar"],
          "stylePatches": [
            { "target": "overlay", "tintHex": "#FFFFFF", "accentHex": "#FF7AA2", "cornerRadius": 18 }
          ],
          "layoutPatches": [
            { "target": "composer", "density": "compact" }
          ],
          "copyPatches": [
            { "target": "askButton", "text": "Ask softly" }
          ],
          "promptTemplates": [
            {
              "invocation": "/summarize",
              "title": "Summarize",
              "detail": "Insert a concise summarization prompt",
              "prompt": "Summarize the selected context in five bullets."
            }
          ],
          "skillPatches": [
            {
              "id": "subagents",
              "title": "Subagents",
              "summary": "Use parallel helper agents for independent subtasks.",
              "markdown": \(Self.subagentsSkillMarkdownJSONString)
            }
          ],
          "operationPreviews": [
            {
              "targetSurfaceID": "extensions",
              "operation": "addSkill",
              "summary": "Add a reusable subagents skill.",
              "detail": "Executable when backed by a skill patch."
            }
          ]
        }
        ```

        Valid `stylePatches.target` values are `overlay`, `composer`, `search`, `card`, and `all`.
        Valid `layoutPatches.target` is currently `composer`; valid `layoutPatches.density` values are `compact`, `comfortable`, and `spacious`. Composer relayout previews are executable when backed by a composer layout patch.
        Valid `copyPatches.target` values are `askButton`, `promptPlaceholder`, and `emptyChatTitle`.
        Valid `promptTemplates.invocation` values start with slash and use letters, numbers, hyphens, or underscores. Prompt templates are real runtime slash commands.
        Valid `skillPatches.id` values are lowercase letters, numbers, hyphens, and underscores, and cannot be `self-edit`. Skill patches write real `SKILL.md` files into Lattice's shared skills folder. Generated skill frontmatter `name` must exactly match `skillPatches.id`, and `description` must explain when the skill should be used.
        Valid `operationPreviews.operation` values come from `lattice-self-map.json`. `restyle`, `relayout`, `rewriteCopy`, `addControl`, and `addSkill` previews are executable only when backed by matching `stylePatches`, `layoutPatches`, `copyPatches`, `promptTemplates`, or `skillPatches`; model recommendation, harness route, and automation previews remain recorded-only.
        Every operation preview requires `editUI`; `addAutomation` also requires `automation`.

        Lattice watches this folder and refreshes valid enabled extensions and skills automatically.
        """
        guard let data = guide.data(using: .utf8) else { return }
        try writeIfChanged(data, to: guideURL)
    }

    static var subagentsSkillMarkdownJSONString: String {
        let data = try? JSONEncoder().encode(LatticeGeneratedSkillTemplate.subagentsMarkdown)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    func writeSelfMap() throws {
        let mapURL = extensionStore.rootURL.appendingPathComponent("lattice-self-map.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(LatticeSelfMap())
        try writeIfChanged(data, to: mapURL)
    }

    func writeIfChanged(_ data: Data, to url: URL) throws {
        if let existing = try? Data(contentsOf: url), existing == data { return }
        try data.write(to: url, options: .atomic)
    }

    func preparedSubmissionPreview(_ text: String) -> PreparedSubmission? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let prompt = LatticeSelfEditCommand.prompt(in: trimmed) {
            guard !prompt.isEmpty else { return nil }
            return PreparedSubmission(userText: prompt, runText: prompt, startsSelfEdit: true)
        }
        if let skillInvocation = LatticeSkillPromptBuilder.invocation(in: trimmed, records: skills, disabledSkillIDs: effectiveDisabledSkillIDs) {
            return PreparedSubmission(
                userText: trimmed,
                runText: LatticeSkillPromptBuilder.prompt(for: skillInvocation),
                startsSelfEdit: false
            )
        }
        return PreparedSubmission(userText: trimmed, runText: trimmed, startsSelfEdit: false)
    }

    func prepareSubmission(_ text: String) -> PreparedSubmission? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let prompt = LatticeSelfEditCommand.prompt(in: trimmed) {
            guard !prompt.isEmpty else {
                setError("Type what you want Lattice to change after /self-edit.", sessionID: selectedSessionID)
                composerState = .expanded
                overlayControlState = .expanded
                return nil
            }
        }
        return preparedSubmissionPreview(trimmed)
    }

    func isExtensionSelfEditThread(_ session: LatticeSession, submittedText: String) -> Bool {
        session.intent == .selfEdit || LatticeSelfEditCommand.prompt(in: submittedText) != nil
    }

    func backendAdditionalContext(for session: LatticeSession, submittedText: String, forceSelfEdit: Bool = false) -> String {
        let isExtensionSelfEdit = forceSelfEdit || isExtensionSelfEditThread(session, submittedText: submittedText)
        // Images cross the typed execution boundary; never downgrade them to a path claim in prompt text.
        let liveAttachmentPaths = session.attachments.filter { !$0.isMissing && !$0.isImage }.map(\.path)
        let attachmentContext = liveAttachmentPaths.isEmpty
            ? ""
            : "\n\nAttached paths:\n" + liveAttachmentPaths.joined(separator: "\n")
        let taskContext: String
        if session.executionRoute.runtimeID == "pi" || session.executionRoute.runtimeID == "hermes" || session.executionRoute.mode == .local {
            // Lattice Agent / Hermes get system-level envelope instructions; avoid duplicating FAQ every turn.
            taskContext = ""
        } else {
            let includeProduct = LatticeProductInstructions.shouldIncludeProductContext(
                mode: session.executionRoute.mode,
                submittedText: submittedText,
                isExtensionSelfEdit: isExtensionSelfEdit
            )
            let guidance: String
            if session.executionRoute.runtimeID == "codex" {
                guidance = includeProduct
                    ? LatticeProductInstructions.current
                    : LatticeProductInstructions.codeMode
            } else {
                guidance = LatticeProductInstructions.taskContext(
                    for: session.executionRoute.mode,
                    includeProductContext: includeProduct
                )
            }
            taskContext = "\n\nLattice task context (visible task guidance; not a system prompt):\n" + guidance
        }
        return taskContext
            + selfEditContext(for: submittedText, isExtensionSelfEdit: isExtensionSelfEdit, sessionID: session.id)
            + attachmentContext
    }

    func imageInputCapability(for session: LatticeSession) -> ImageInputCapability {
        let model = session.executionRoute.modelID.flatMap { modelID in
            codexModels.first { $0.id == modelID }
        }
        return ImageInputCapability.resolve(
            route: session.executionRoute,
            model: model,
            protocolSupport: session.executionRoute.runtimeID == "codex" ? codexImageInputProtocolSupport : .unsupported
        )
    }

    func attachmentUnavailableReason(for session: LatticeSession) -> String? {
        ExecutionInputAttachmentPolicy.unavailableReason(
            attachments: session.attachments,
            capability: imageInputCapability(for: session)
        )
    }

    static func selfEditTitle(for prompt: String) -> String {
        "Lattice self-edit: \(prompt.prefix(32))"
    }

    static func isLegacySelfEditSession(_ session: LatticeSession) -> Bool {
        LegacySelfEditMigrationPolicy.shouldClassify(session)
    }

    static func legacyLooksLikeSelfEditRequest(_ text: String) -> Bool {
        LegacySelfEditMigrationPolicy.looksLikeSelfEditRequest(text)
    }

    func selfEditContext(for text: String, isExtensionSelfEdit: Bool, sessionID: UUID) -> String {
        guard isExtensionSelfEdit else { return "" }
        let root = extensionStore.rootURL.path
        let skillsRoot = skillStore.rootURL.path
        let pendingManifestContext: String = {
            guard let preview = visibleSelfEditPreviews(for: sessionID).first,
                  let data = try? JSONEncoder().encode(preview.manifest),
                  let json = String(data: data, encoding: .utf8) else { return "" }
            return """

            - This chat already has a pending review. Treat the user's message as a request to revise that proposal. Return one complete replacement manifest with the same id, preserve every unchanged patch, and alter only what the user requested. Do not apply or discard it yourself.
            - Current pending manifest:
              <lattice-current-pending-manifest>
              \(json)
              </lattice-current-pending-manifest>
            """
        }()
        return """


Lattice self-edit rules:
- This is a user-facing customization request. Do not edit source files or the installed app bundle.
- Prefer a user-owned Lattice modification under: \(root)
- Skill requests should create skillPatches. Lattice writes those to the shared skills folder: \(skillsRoot)
- Do not use tools, search files, inspect source code, or write files. Lattice applies the manifest itself.
- Return exactly one manifest wrapped in <lattice-extension-manifest> and </lattice-extension-manifest>, with no other text.
- Use this complete manifest schema:
  <lattice-extension-manifest>
  {
    "schemaVersion": 1,
    "id": "letters-numbers-dots-underscores-or-hyphens",
    "name": "Short user-facing name",
    "version": "1.0.0",
    "summary": "What this changes",
    "permissions": ["editUI"],
    "uiTargets": ["overlay", "composer", "chat", "sidebar", "models", "connections"],
    "stylePatches": [
      { "target": "overlay|composer|search|card|all", "tintHex": "#RRGGBB", "accentHex": "#RRGGBB", "cornerRadius": 18 }
    ],
    "layoutPatches": [
      { "target": "composer", "density": "compact|comfortable|spacious" }
    ],
    "copyPatches": [
      { "target": "askButton|promptPlaceholder|emptyChatTitle", "text": "One-line replacement copy" }
    ],
    "promptTemplates": [
      {
        "invocation": "/letters-numbers-hyphens-or_underscores",
        "title": "Short template title",
        "detail": "Short user-facing explanation",
        "prompt": "Prompt text to insert into the composer when selected."
      }
    ],
    "skillPatches": [
      {
        "id": "subagents",
        "title": "Subagents",
        "summary": "Use parallel helper agents for independent subtasks.",
        "markdown": \(Self.subagentsSkillMarkdownJSONString)
      }
    ],
    "operationPreviews": [
      {
        "targetSurfaceID": "surface id from lattice-self-map.json",
        "operation": "restyle|relayout|rewriteCopy|addControl|addModelRecommendation|addHarnessRoute|addSkill|addAutomation",
        "summary": "Short preview of the requested operation",
        "detail": "Optional detail. State when this is recorded-only."
      }
    ]
  }
  </lattice-extension-manifest>
- Choose a stable lowercase id. Include only requested changes. Valid targets are overlay, composer, search, card, and all.
- Use stylePatches for real runtime styling changes, layoutPatches for real composer density changes, copyPatches for real copy changes, and promptTemplates for real slash-command prompt templates.
- Use skillPatches for real reusable skill creation. Do not create a skill with id `self-edit`; `/self-edit` is Lattice's app-customization command. Generated SKILL.md must be substantive, not a short generic prompt: include YAML frontmatter with only name and description, make frontmatter name exactly match the skill id, then Quick start, Workflow, Guardrails, and Verification sections. Quick start must give concrete trigger/use guidance; Workflow must include at least three numbered decision steps with edge cases and failure recovery; Guardrails must state concrete safety, scope, and permission limits; Verification must require evidence-producing checks. Keep it focused and under 500 lines, but at least 600 characters. If the user says something like "/self-edit Add a skill to use subagents better", create a complete subagents workflow rather than a few sentences, and include an addSkill operation preview targeting "extensions".
- Use operationPreviews to summarize the user's requested operation. The manifest summary and operation summaries must explain in plain language what applying the review will change, what it will not change, and any important consequence needed for a decision without reading the full manifest. restyle previews are executable only when backed by matching stylePatches; relayout previews are executable only when backed by composer layoutPatches; rewriteCopy previews are executable only when backed by copyPatches; addControl previews are executable only when backed by promptTemplates; addSkill previews are executable only when backed by skillPatches. addModelRecommendation, addHarnessRoute, and addAutomation are recorded-only until Lattice implements those runtimes.
- Every operation preview requires the editUI permission. addAutomation previews also require the automation permission.
- Prompt template invocations must start with slash, cannot replace /self-edit, and may only contain letters, numbers, hyphens, or underscores after the slash.
- For an undo or revert, reuse the prior manifest id and return it with empty uiTargets, stylePatches, copyPatches, promptTemplates, skillPatches, and operationPreviews.
- The response is machine-consumed. Do not add Markdown fences, explanations, status text, or future-tense commentary.
\(pendingManifestContext)
"""
    }

    func prepareGeneratedExtensionPreview(at index: Int, request: String?) -> Bool {
        guard let response = sessions[index].messages.last?.text else {
            setError("The model did not return a Lattice modification manifest.", sessionID: sessions[index].id)
            return false
        }
        let manifest: LatticeExtensionManifest
        do {
            manifest = try LatticeExtensionManifestEnvelope.decode(from: response)
        } catch {
            setError(error.localizedDescription, sessionID: sessions[index].id)
            return false
        }
        let validation = extensionStore.validate(manifest)
        let generatedSkillValidation = LatticeSelfEditGeneratedSkillValidationPolicy.validationMessages(for: manifest)
        let combinedValidation = validation + generatedSkillValidation
        guard combinedValidation.isEmpty else {
            setError(combinedValidation.joined(separator: " "), sessionID: sessions[index].id)
            return false
        }
        do {
            let previousManifestData = extensionStore.manifestData(for: manifest.id)
            let previousManifest = previousManifestData.flatMap { try? JSONDecoder().decode(LatticeExtensionManifest.self, from: $0) }
            let review = LatticeExtensionChangeReviewBuilder.review(current: manifest, previous: previousManifest)
            guard review.hasChanges else {
                setError("The proposed Lattice change does not change anything. Ask for a revision or discard it.", sessionID: sessions[index].id)
                return false
            }
            let previousSkillSnapshots = manifest.skillPatches.map { skillStore.snapshotSkill(id: $0.id) }
            let affectedSkillIDs = Set(manifest.skillPatches.map(\.id))
            let previousDisabledSkillIDs = LatticeSkillEnablementRollbackPolicy.disabledSnapshot(
                affectedSkillIDs: affectedSkillIDs,
                disabledSkillIDs: disabledSkillIDs
            )
            let previousEnabled = enabledExtensionIDs.contains(manifest.id)
            let preview = LatticeExtensionPreviewRecord(
                sessionID: sessions[index].id,
                harnessThreadID: sessions[index].harnessThreadID,
                request: request ?? "Lattice self-edit",
                manifest: manifest,
                previousManifestData: previousManifestData,
                previousSkillSnapshots: previousSkillSnapshots,
                previousDisabledSkillIDs: previousDisabledSkillIDs,
                previousEnabled: previousEnabled
            )
            selfEditPreviews = try extensionPreviewStore.record(preview, in: selfEditPreviews)
            sessions[index].messages[sessions[index].messages.count - 1].text = LatticeSelfEditReviewCopy.readyStatus
            return true
        } catch {
            setError(error.localizedDescription, sessionID: sessions[index].id)
            return false
        }
    }

    func visibleSelfEditPreviews(for sessionID: UUID) -> [LatticeExtensionPreviewRecord] {
        selfEditPreviews.filter { $0.sessionID == sessionID }
    }

}
