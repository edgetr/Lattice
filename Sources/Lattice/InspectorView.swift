import SwiftUI
import LatticeCore

struct InspectorView: View {
    @ObservedObject var state: AppState
    var body: some View {
        Form {
            if let session = state.selectedSession {
                Section("Chat") {
                    LabeledContent("Provider", value: session.backend.harnessName)
                    LabeledContent("Model", value: session.backend.displayName)
                    if let reasoning = session.reasoningEffort { LabeledContent("Reasoning", value: reasoning.displayName) }
                    Picker("Execution policy", selection: Binding(
                        get: { session.policy },
                        set: { state.setSessionPolicy($0) }
                    )) {
                        ForEach(ExecutionPolicy.allCases, id: \.self) { policy in
                            Text(policy.rawValue).tag(policy)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(session.isStreaming)
                    .accessibilityLabel("Execution policy")
                    .accessibilityHint("Controls how this chat handles approvals and provider tool risk for the selected harness.")
                    Picker("Model privacy", selection: Binding(
                        get: { session.privacyMode },
                        set: { state.setSessionPrivacyMode($0) }
                    )) {
                        ForEach(SessionPrivacyMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(session.isStreaming)
                    if session.privacyMode == .localOnly {
                        Text("Cloud provider routes are blocked for this chat.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !session.backend.isLocal && session.messages.contains(where: { $0.role == .user }) {
                            Text("This chat is locked to its cloud route. Start a separate local chat to continue without sending cloud requests.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Button("Start New Local Chat") {
                                state.startLocalOnlyChatFromSelected()
                            }
                            .disabled(!state.canStartLocalOnlyChat)
                            .help(state.canStartLocalOnlyChat ? "Create a fresh chat with a local backend" : "Make Apple Intelligence or Ollama available in Connections first")
                        }
                    }
                }
                if let capability = state.selectedRouteCapability {
                    Section("Route controls") {
                        LabeledContent("Owner", value: capability.executionOwner.displayName)
                        LabeledContent("Tool broker", value: capability.brokerMediation.displayName)
                        LabeledContent("Write containment", value: capability.writeContainment.displayValue)
                            .accessibilityValue(capability.writeContainment.detail)
                            .help(capability.writeContainment.detail)
                        LabeledContent("Approvals", value: capability.approvalBehavior.displayValue)
                            .accessibilityValue(capability.approvalBehavior.detail)
                            .help(capability.approvalBehavior.detail)
                        capabilityRow("File reads", capability.fileReadRestriction)
                        capabilityRow("Network", capability.networkRestriction)
                        capabilityRow("Credentials", capability.credentialReadProtection)
                        capabilityRow("Events", capability.structuredEvents)
                        capabilityRow("Resume", capability.providerSessionResume)
                        capabilityRow("Cancel", capability.cancellation)
                        if let warning = capability.primaryWarning {
                            Text(warning)
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityLabel("Route warning")
                                .accessibilityValue(warning)
                        }
                        if capability.warnings.count > 1 {
                            ForEach(Array(capability.warnings.dropFirst().enumerated()), id: \.offset) { _, warning in
                                Text(warning)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Route controls")
                    .accessibilityHint("What the selected harness and execution policy actually enforce before a run.")
                }
                if case .codex = session.backend, let usage = state.codexUsage {
                    Section("Usage") {
                        ForEach(usage.windows) { window in UsageWindowRow(window: window) }
                        if let balance = usage.creditsBalance { LabeledContent("Credits", value: balance) }
                    }
                }
                Section("Workspace") {
                    Text(session.workspacePath ?? "None").font(.caption).textSelection(.enabled)
                    Button("Choose…") { state.chooseWorkspace() }.disabled(!session.messages.isEmpty)
                }
                Section("Context") {
                    if let estimate = state.selectedContextBudgetEstimate {
                        ContextBudgetMeter(estimate: estimate)
                    }
                    if session.attachments.isEmpty {
                        Text("No attached paths. Drag files or use the paperclip to add context.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(session.attachments) { attachment in
                            HStack {
                                Label(attachment.name, systemImage: attachment.isImage ? "photo" : "doc")
                                Spacer()
                                Text(attachment.isMissing ? "Missing" : "Path")
                                    .font(.caption2)
                                    .foregroundStyle(attachment.isMissing ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                                    .accessibilityLabel(attachment.isMissing ? "Attachment unavailable" : "Local path")
                                Button { state.removeAttachment(attachment.id) } label: { Image(systemName: "xmark") }
                                    .buttonStyle(LatticeIconButtonStyle(size: .compact))
                                    .accessibilityLabel("Remove \(attachment.name)")
                                    .help("Remove \(attachment.name)")
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped).padding(.top, 8)
    }

    private func capabilityRow(_ title: String, _ capability: RouteCapabilityDetail) -> some View {
        LabeledContent(title, value: capability.displayValue)
            .accessibilityValue(capability.detail)
            .help(capability.detail)
    }
}

struct ModelsView: View {
    @ObservedObject var state: AppState
    @AppStorage("lattice.models.showOnlyFittingLocalRecommendations") private var showOnlyFittingLocalRecommendations = true
    var installedTags: Set<String> { Set(state.ollamaModels.map(\.name)) }

    var body: some View {
        AdaptiveCatalogPage { contentWidth in
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Models", subtitle: "\(state.hardware.chipName) · \(state.hardware.physicalMemoryGB) GB unified memory · \(state.hardware.thermalState)")

                VStack(alignment: .leading, spacing: 10) {
                    Text("Built into macOS").font(.headline)
                    appleIntelligenceCard
                }

                if state.isRefreshingConnections {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Refreshing connected provider models…")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Refreshing connected provider models")
                    .accessibilityAddTraits(.updatesFrequently)
                } else if state.codexModels.isEmpty,
                          state.grokModels.isEmpty,
                          state.openCodeModels.isEmpty,
                          state.antigravityModels.isEmpty,
                          state.hasProviderCatalogProblem {
                    catalogProblemState
                } else if state.hasConnectedProviderCatalog
                            || [state.codexCatalogStatus, state.grokCatalogStatus, state.openCodeCatalogStatus]
                                .contains(where: { $0 == .loading || $0 == .failed }) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Connected provider models").font(.headline)
                        if state.codexModels.isEmpty, state.codexCatalogStatus == .failed {
                            ModelsCatalogNotice(provider: "Codex", state: state)
                        }
                        if state.grokModels.isEmpty, state.grokCatalogStatus == .failed {
                            ModelsCatalogNotice(provider: "Grok", state: state)
                        }
                        if state.openCodeModels.isEmpty, state.openCodeCatalogStatus == .failed {
                            ModelsCatalogNotice(provider: "OpenCode", state: state)
                        }
                        CatalogCardGrid(contentWidth: contentWidth, minimum: LatticeCatalogPageLayout.providerCardMinimum, maximum: LatticeCatalogPageLayout.providerCardMaximum) {
                            if state.codexReady || state.codex.isInstalled || !state.codexModels.isEmpty {
                                ProviderModelSection(
                                    providerName: "Codex",
                                    providerID: "codex",
                                    models: state.codexModels,
                                    ready: state.codexReady,
                                    unavailableDetail: state.codex.isInstalled ? "Sign in required" : "Not installed",
                                    state: state
                                ) { .codex(model: $0.id) }
                            }
                            if state.grokReady || state.grok.isInstalled || !state.grokModels.isEmpty {
                                ProviderModelSection(
                                    providerName: "Grok",
                                    providerID: "grok",
                                    models: state.grokModels,
                                    ready: state.grokReady,
                                    unavailableDetail: state.grok.isInstalled ? "Sign in or ACP unavailable" : "Not installed",
                                    state: state
                                ) { .grok(model: $0.id) }
                            }
                            if state.openCodeReady || state.openCode.isInstalled || !state.openCodeModels.isEmpty {
                                ProviderModelSection(
                                    providerName: "OpenCode",
                                    providerID: "opencode",
                                    models: state.openCodeModels,
                                    ready: state.openCodeReady,
                                    unavailableDetail: state.openCode.isInstalled ? "Sign in or ACP unavailable" : "Not installed",
                                    state: state
                                ) { .openCode(model: $0.id) }
                            }
                            if state.antigravityAuthenticated || state.antigravityInstalled || !state.antigravityModels.isEmpty {
                                ProviderModelSection(
                                    providerName: "Antigravity",
                                    providerID: "antigravity",
                                    models: state.antigravityModels,
                                    ready: state.antigravityAuthenticated,
                                    unavailableDetail: state.antigravityInstalled ? "Sign in required" : "Not installed",
                                    state: state
                                ) { .antigravity(model: $0.id) }
                            }
                        }
                    }
                } else if state.hasProviderCatalogProblem {
                    catalogProblemState
                } else {
                    catalogEmptyState
                }

                if !state.ollamaModels.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Installed").font(.headline)
                        CatalogCardGrid(contentWidth: contentWidth, minimum: LatticeCatalogPageLayout.modelCardMinimum, maximum: LatticeCatalogPageLayout.modelCardMaximum) {
                            ForEach(state.ollamaModels) { model in
                                let backend = ChatBackend.ollama(model: model.name)
                                let runnable = state.canUseBackendInNewChat(backend)
                                HStack {
                                    Image(systemName: "internaldrive")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(model.name).fontWeight(.medium)
                                        Text(ByteCountFormatter.string(fromByteCount: model.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 8)
                                    Button("Use") { state.useBackendInChat(backend) }
                                        .disabled(!runnable)
                                        .accessibilityHint(runnable ? "Use \(model.name) in a chat." : "Start Ollama before using this local model.")
                                        .help(runnable ? "Use \(model.name) in a chat." : "Start Ollama before using this local model.")
                                }
                                .padding(LatticeMetrics.cardPadding)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .latticeGlass(cornerRadius: LatticeMetrics.cardRadius, interactive: true)
                            }
                        }
                    }
                }

                if !state.ollamaReady {
                    ollamaStatusCard
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Recommended local models").font(.headline)
                            Text(showOnlyFittingLocalRecommendations ? "Showing models that fit this Mac’s safe memory budget." : "Showing the full catalog, including risky or unsupported installs.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        Toggle("Fits this Mac", isOn: $showOnlyFittingLocalRecommendations)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .help("Hide local recommendations that exceed the safe memory budget.")
                    }
                    .padding(LatticeMetrics.cardPadding)
                    .latticeGlass(cornerRadius: LatticeMetrics.cardRadius, interactive: true)
                }

                ForEach(LocalModelCatalog.categories, id: \.self) { category in
                    let values = LocalModelCatalog.recommendations(for: state.hardware, category: category, fitOnly: showOnlyFittingLocalRecommendations)
                    let hiddenCount = LocalModelCatalog.hiddenOversizedRecommendationCount(for: state.hardware, category: category)
                    if !values.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(category).font(.headline)
                                if showOnlyFittingLocalRecommendations && hiddenCount > 0 {
                                    Text("\(hiddenCount) oversized hidden")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            CatalogCardGrid(contentWidth: contentWidth, minimum: LatticeCatalogPageLayout.modelCardMinimum, maximum: LatticeCatalogPageLayout.modelCardMaximum) {
                                ForEach(values) { model in
                                    RecommendationRow(model: model, installed: installedTags.contains(model.ollamaTag), state: state)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Models")
        .toolbar { Button { Task { await state.refreshConnections(refreshProviderCatalogs: true) } } label: { Label("Refresh", systemImage: "arrow.clockwise") } }
    }

    private var catalogProblemState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Provider catalog unavailable", systemImage: "exclamationmark.triangle").font(.headline)
            Text(state.providerCatalogProblemMessage ?? "Refresh the provider connection to try again.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Connections") { state.selectedSection = .connections }
        }
        .padding(LatticeMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .latticeGlass(cornerRadius: LatticeMetrics.cardRadius, interactive: true)
        .accessibilityElement(children: .contain)
    }

    private var catalogEmptyState: some View {
        let copy = CatalogEmptyStatePolicy.copy(for: .noConnectedProviderModels)
        return VStack(alignment: .leading, spacing: 8) {
            Label(copy.title, systemImage: "square.stack.3d.up.slash").font(.headline)
            Text(copy.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(copy.primaryActionTitle ?? "Open Connections") { state.selectedSection = .connections }
                Button(copy.secondaryActionTitle ?? "Refresh") {
                    Task { await state.refreshConnections(refreshProviderCatalogs: true) }
                }
                .buttonStyle(.link)
            }
        }
        .padding(LatticeMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .latticeGlass(cornerRadius: LatticeMetrics.cardRadius, interactive: true)
        .accessibilityElement(children: .contain)
    }

    private var appleIntelligenceCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "apple.intelligence").font(.title2).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text("Apple Intelligence").fontWeight(.semibold)
                Text(state.appleIntelligenceStatus).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if state.appleIntelligenceReady {
                let backend = ChatBackend.appleIntelligence
                let runnable = state.canUseBackendInNewChat(backend)
                Button("Use") { state.useBackendInChat(backend) }
                    .disabled(!runnable)
                    .accessibilityHint(runnable ? "Use Apple Intelligence in a chat." : (state.backendUnavailableMessage(for: backend) ?? "Apple Intelligence is unavailable."))
                    .help(runnable ? "Use Apple Intelligence in a chat." : (state.backendUnavailableMessage(for: backend) ?? "Apple Intelligence is unavailable."))
            }
        }
        .padding(LatticeMetrics.cardPadding)
        .frame(maxWidth: LatticeCatalogPageLayout.featureCardMaximum, alignment: .leading)
        .latticeGlass(cornerRadius: LatticeMetrics.cardRadius, interactive: true)
    }

    private var ollamaStatusCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "cpu").font(.title2).foregroundStyle(.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text("Ollama").fontWeight(.semibold)
                Text(state.ollamaInstalled ? "Installed · not running" : "Required for local model installs").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(state.ollamaInstalled ? "Start" : "Get") {
                state.ollamaInstalled ? state.openOllama() : state.installOllama()
            }
        }
        .padding(LatticeMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .latticeGlass(cornerRadius: LatticeMetrics.cardRadius, interactive: true)
        .frame(maxWidth: LatticeCatalogPageLayout.featureCardMaximum, alignment: .leading)
    }
}

struct ProviderModelSection: View {
    let providerName: String
    let providerID: String
    let models: [ProviderModel]
    let ready: Bool
    let unavailableDetail: String
    @ObservedObject var state: AppState
    let backend: (ProviderModel) -> ChatBackend
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var visibleModels: [ProviderModel] {
        models.filter { state.isModelEnabled("\(providerID):\($0.id)") }
    }

    private var statusText: String {
        guard ready else { return unavailableDetail }
        guard !visibleModels.isEmpty else { return "No models reported" }
        guard visibleModels.contains(where: { state.canUseBackendInNewChat(backend($0)) }) else {
            return "Unavailable for this chat"
        }
        return "Ready"
    }

    private var isReadyForCurrentChat: Bool {
        ready && visibleModels.contains(where: { state.canUseBackendInNewChat(backend($0)) })
    }

    private var displayedModels: [ProviderModel] {
        state.expandedProviderModelIDs.contains(providerID) ? visibleModels : Array(visibleModels.prefix(3))
    }

    private var disclosureAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.18)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let identity = LatticeProviderIdentity(providerID: providerID) {
                    ProviderIdentityMark(identity: identity, size: 22)
                }
                Text(providerName).font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Image(systemName: isReadyForCurrentChat ? "checkmark.circle.fill" : "minus.circle")
                    .font(.caption.weight(.semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isReadyForCurrentChat ? Color.green : Color.secondary)
                    .accessibilityHidden(true)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(isReadyForCurrentChat ? Color.green : Color.secondary)
                    .multilineTextAlignment(.trailing)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(providerName)
            .accessibilityValue(statusText)

            if models.isEmpty {
                Text("No \(providerName) models have been reported yet. Retry discovery in Connections.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else if visibleModels.isEmpty {
                Text("All discovered \(providerName) models are hidden in Connections.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(displayedModels) { model in
                    let modelBackend = backend(model)
                    let runnable = state.canUseBackendInNewChat(modelBackend)
                    ProviderModelRow(
                        providerName: providerName,
                        model: model,
                        ready: ready && runnable,
                        state: state,
                        backend: modelBackend
                    )
                }
                if visibleModels.count > displayedModels.count {
                    Button("Show \(visibleModels.count - displayedModels.count) more") {
                        withAnimation(disclosureAnimation) { state.setProviderModelsExpanded(providerID, expanded: true) }
                    }
                    .buttonStyle(.link)
                    .font(.caption.weight(.medium))
                } else if state.expandedProviderModelIDs.contains(providerID) && visibleModels.count > 3 {
                    Button("Show less") {
                        withAnimation(disclosureAnimation) { state.setProviderModelsExpanded(providerID, expanded: false) }
                    }
                    .buttonStyle(.link)
                    .font(.caption.weight(.medium))
                }
            }
        }
        .padding(LatticeMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .latticeGlass(cornerRadius: LatticeMetrics.controlRadius, interactive: true)
    }
}

struct ProviderModelRow: View {
    let providerName: String
    let model: ProviderModel
    let ready: Bool
    @ObservedObject var state: AppState
    let backend: ChatBackend

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.name)
                        .fontWeight(.medium)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                    if model.isDefault {
                        Text("Default")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.12), in: Capsule())
                    }
                }
                Text(model.description.isEmpty ? "\(providerName) · provider-owned runtime" : model.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                let supportedReasoningOptions = state.reasoningOptions(for: backend)
                if !supportedReasoningOptions.isEmpty {
                    Text("Reasoning: \(supportedReasoningOptions.map { $0.effort.displayName }.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let contextWindow = model.contextWindow {
                    Text("Context: \(Self.formatContextWindow(contextWindow)) tokens")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            Button("Use") { state.useBackendInChat(backend) }
                .fixedSize(horizontal: true, vertical: false)
                .disabled(!ready)
                .accessibilityHint(ready ? "Use \(model.name) in a chat." : (state.backendUnavailableMessage(for: backend) ?? "\(providerName) cannot run this model through its current structured runtime."))
                .help(ready ? "Use \(model.name) in a chat." : (state.backendUnavailableMessage(for: backend) ?? "\(providerName) cannot run this model through its current structured runtime."))
        }
        .padding(.vertical, 5)
    }

    private static func formatContextWindow(_ value: Int) -> String {
        if value >= 1_000_000 { return "\(value / 1_000_000)M" }
        if value >= 1_000 { return "\(value / 1_000)K" }
        return "\(value)"
    }
}

struct RecommendationRow: View {
    let model: LocalModelRecommendation
    let installed: Bool
    @ObservedObject var state: AppState
    var body: some View {
        let fit = model.fit(on: state.hardware)
        let canInstall = model.canInstall(on: state.hardware)
        let lifecycle = model.lifecyclePlan(on: state.hardware)
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "cpu").font(.title2).foregroundStyle(.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.name)
                    .fontWeight(.semibold)
                    .fixedSize(horizontal: false, vertical: true)
                Text(model.category)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("~\(ByteCountFormatter.string(fromByteCount: Int64(model.estimatedBytes), countStyle: .memory)) · \(model.fit(on: state.hardware).rawValue.capitalized) fit")
                    .font(.caption).foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                Text(lifecycle.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(model.tupleSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if state.installingModelTag == model.ollamaTag, let status = state.installStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            if state.installingModelTag == model.ollamaTag {
                ProgressView().controlSize(.small)
                Button("Cancel") { state.cancelModelInstall() }.fixedSize(horizontal: true, vertical: false)
            } else if installed {
                let backend = ChatBackend.ollama(model: model.ollamaTag)
                let runnable = state.canUseBackendInNewChat(backend)
                Button("Use") { state.useBackendInChat(backend) }
                    .fixedSize(horizontal: true, vertical: false)
                    .disabled(!runnable)
                    .accessibilityHint(runnable ? "Use \(model.name) in a chat." : "Start Ollama before using this local model.")
                    .help(runnable ? "Use \(model.name) in a chat." : "Start Ollama before using this local model.")
            } else if !state.ollamaInstalled {
                Button("Get Ollama") { state.installOllama() }.fixedSize(horizontal: true, vertical: false)
            } else if !state.ollamaReady {
                Button("Start Ollama") { state.openOllama() }.fixedSize(horizontal: true, vertical: false)
            } else {
                let installHint = fit == .risky ? "This model is too close to the safe memory budget." : fit == .unsupported ? "This model exceeds the safe memory budget." : "Install with Ollama."
                Button(canInstall ? "Install" : "Too large") { state.installModel(model) }
                    .fixedSize(horizontal: true, vertical: false)
                    .disabled(state.installingModelTag != nil || !canInstall)
                    .accessibilityHint(installHint)
                    .help(fit == .risky ? "This model is too close to the safe memory budget." : fit == .unsupported ? "This model exceeds the safe memory budget." : "Install with Ollama.")
            }
        }
        .padding(LatticeMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .latticeGlass(cornerRadius: LatticeMetrics.cardRadius, interactive: true)
    }
}

private struct ModelsCatalogNotice: View {
    let provider: String
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text("\(provider) model catalog unavailable. Connections can retry discovery.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Retry") {
                Task { await state.refreshConnections(refreshProviderCatalogs: true) }
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .latticeGlass(cornerRadius: 10, tint: Color.orange.opacity(0.08))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(provider) model catalog unavailable")
        .accessibilityHint("Retry model discovery")
    }
}

struct ConnectionsView: View {
    @ObservedObject var state: AppState
    var body: some View {
        AdaptiveCatalogPage { contentWidth in
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Connections", subtitle: "Providers and model visibility")

                CatalogCardGrid(contentWidth: contentWidth, minimum: LatticeCatalogPageLayout.connectionCardMinimum, maximum: LatticeCatalogPageLayout.connectionCardMaximum) {
                    ConnectionCard(
                        identity: .provider(.codex),
                        name: "Codex",
                        detail: state.codexReadinessCopy.detail,
                        ready: state.codexReady
                    ) {
                        if state.codex.isInstalled {
                            CatalogRefreshButton(status: state.codexCatalogStatus, state: state)
                            if !state.codexAuthenticated {
                                CLIActionButton(title: "Sign In", provider: "codex", state: state) { state.connectCodex() }
                            }
                            if CLIVersionDisplayPolicy.isUpdateAvailable(currentVersion: state.codexCLIVersion, latestVersion: state.codexLatestCLIVersion) {
                                CLIActionButton(title: CLIVersionDisplayPolicy.updateActionTitle("Update CLI", currentVersion: state.codexCLIVersion, latestVersion: state.codexLatestCLIVersion), provider: "codex", state: state) { state.updateCodex() }
                            }
                        } else {
                            CLIActionButton(title: "Install CLI", provider: "codex", state: state) { state.installCodex() }
                        }
                    } content: {
                        VStack(alignment: .leading, spacing: 12) {
                            CLIMetadata(version: state.codexCLIVersion, latestVersion: state.codexLatestCLIVersion, updateInfo: nil)
                            if let caption = RouteConnectionCaption.caption(forHarnessID: "codex") {
                                Text(caption)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            CLIActionMessage(provider: "codex", state: state)
                            ModelChecklist(providerID: "codex", models: state.codexModels, state: state)
                        }
                    }

                    ConnectionCard(
                        identity: .provider(.grok),
                        name: "Grok",
                        detail: state.grokReadinessCopy.detail,
                        ready: state.grokReady
                    ) {
                        if state.grok.isInstalled {
                            CatalogRefreshButton(status: state.grokCatalogStatus, state: state)
                            if !state.grokAuthenticated {
                                CLIActionButton(title: "Sign In", provider: "grok", state: state) { state.connectGrok() }
                            }
                            CLIActionButton(title: CLIVersionDisplayPolicy.updateActionTitle(state.grokCLIInfo.updateAvailable == true ? "Update CLI" : "Check Update", currentVersion: state.grokCLIInfo.currentVersion, latestVersion: state.grokCLIInfo.updateAvailable == true ? state.grokCLIInfo.latestVersion : nil), provider: "grok", state: state) {
                                if state.grokCLIInfo.updateAvailable == true { state.updateGrok() } else { state.checkGrokUpdate() }
                            }
                        } else {
                            CLIActionButton(title: "Install CLI", provider: "grok", state: state) { state.installGrok() }
                        }
                    } content: {
                        VStack(alignment: .leading, spacing: 12) {
                            CLIMetadata(version: state.grokCLIInfo.currentVersion, latestVersion: nil, updateInfo: state.grokCLIInfo)
                            if state.grokReady, let caption = RouteConnectionCaption.caption(forHarnessID: "grok") {
                                Text(caption)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            CLIActionMessage(provider: "grok", state: state)
                            ModelChecklist(providerID: "grok", models: state.grokModels, state: state)
                        }
                    }

                    ConnectionCard(
                        identity: .provider(.opencode),
                        name: "OpenCode",
                        detail: state.openCodeReadinessCopy.detail,
                        ready: state.openCodeReady
                    ) {
                        if state.openCode.isInstalled {
                            CatalogRefreshButton(status: state.openCodeCatalogStatus, state: state)
                            if !state.openCodeAuthenticated {
                                CLIActionButton(title: "Sign In", provider: "opencode", state: state) { state.connectOpenCode() }
                            }
                            if CLIVersionDisplayPolicy.isUpdateAvailable(currentVersion: state.openCodeCLIVersion, latestVersion: state.openCodeLatestCLIVersion) {
                                CLIActionButton(title: CLIVersionDisplayPolicy.updateActionTitle("Update CLI", currentVersion: state.openCodeCLIVersion, latestVersion: state.openCodeLatestCLIVersion), provider: "opencode", state: state) { state.updateOpenCode() }
                            }
                        } else {
                            CLIActionButton(title: "Install CLI", provider: "opencode", state: state) { state.installOpenCode() }
                        }
                    } content: {
                        VStack(alignment: .leading, spacing: 14) {
                            CLIMetadata(version: state.openCodeCLIVersion, latestVersion: state.openCodeLatestCLIVersion, updateInfo: nil)
                            if state.openCodeReady, let caption = RouteConnectionCaption.caption(forHarnessID: "opencode") {
                                Text(caption)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            CLIActionMessage(provider: "opencode", state: state)
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("OpenCode Go API key").font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                                    Spacer()
                                    if state.openCodeAPIKeySaved {
                                        Label("Saved", systemImage: "checkmark.circle.fill")
                                            .labelStyle(.titleAndIcon)
                                            .font(.caption)
                                            .foregroundStyle(.green)
                                    }
                                }
                                if state.openCodeAPIKeySaved {
                                    Button("Remove key", role: .destructive) { state.clearOpenCodeAPIKey() }
                                } else {
                                    HStack(spacing: 8) {
                                        SecureField("Paste API key", text: $state.openCodeAPIKeyDraft)
                                            .textFieldStyle(.roundedBorder)
                                        Button("Save") { state.saveOpenCodeAPIKey() }
                                            .disabled(state.openCodeAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                    }
                                }
                            }
                            ModelChecklist(providerID: "opencode", models: state.openCodeModels, state: state)
                        }
                    }

                    ConnectionCard(identity: .systemImage("paperplane"), name: "Antigravity", detail: state.antigravityCatalogReady ? "Ready · CLI" : (state.antigravityAuthenticated ? "Connected · no models reported" : (state.antigravityInstalled ? "Sign in required" : "Not installed")), ready: state.antigravityCatalogReady) {
                        if state.antigravityInstalled {
                            if !state.antigravityAuthenticated { CLIActionButton(title: "Sign In", provider: "antigravity", state: state) { state.connectAntigravity() } }
                            if CLIVersionDisplayPolicy.isUpdateAvailable(currentVersion: state.antigravityCLIVersion, latestVersion: state.antigravityLatestCLIVersion) {
                                CLIActionButton(title: CLIVersionDisplayPolicy.updateActionTitle("Update CLI", currentVersion: state.antigravityCLIVersion, latestVersion: state.antigravityLatestCLIVersion), provider: "antigravity", state: state) { state.updateAntigravity() }
                            }
                        } else {
                            CLIActionButton(title: "Install CLI", provider: "antigravity", state: state) { state.installAntigravity() }
                        }
                    } content: {
                        VStack(alignment: .leading, spacing: 10) {
                            if state.antigravityInstalled {
                                CLIMetadata(version: state.antigravityCLIVersion, latestVersion: state.antigravityLatestCLIVersion, updateInfo: nil)
                                if let caption = RouteConnectionCaption.caption(forHarnessID: "antigravity") {
                                    Label(caption, systemImage: "shield.slash")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                Label("Official Homebrew cask", systemImage: "shippingbox")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            CLIActionMessage(provider: "antigravity", state: state)
                        }
                    }
                }

                SectionHeader("Agent runtimes")
                CatalogCardGrid(contentWidth: contentWidth, minimum: LatticeCatalogPageLayout.connectionCardMinimum, maximum: LatticeCatalogPageLayout.connectionCardMaximum) {
                    ConnectionCard(
                        identity: .systemImage("terminal"),
                        name: "Pi",
                        detail: state.piInstalled ? "Installed" : "Not installed",
                        ready: state.piInstalled
                    ) {
                        if state.piInstalled {
                            if CLIVersionDisplayPolicy.isUpdateAvailable(currentVersion: state.piCLIVersion, latestVersion: state.piLatestCLIVersion) {
                                CLIActionButton(title: CLIVersionDisplayPolicy.updateActionTitle("Update CLI", currentVersion: state.piCLIVersion, latestVersion: state.piLatestCLIVersion), provider: "pi", state: state) { state.updatePi() }
                            }
                        } else {
                            CLIActionButton(title: "Install CLI", provider: "pi", state: state) { state.installPi() }
                        }
                    } content: {
                        VStack(alignment: .leading, spacing: 10) {
                            if state.piInstalled {
                                CLIMetadata(version: state.piCLIVersion, latestVersion: state.piLatestCLIVersion, updateInfo: state.piCLIInfo)
                                if let caption = RouteConnectionCaption.caption(forHarnessID: "pi") {
                                    Label(caption, systemImage: "lock.shield")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            CLIActionMessage(provider: "pi", state: state)
                        }
                    }
                    ConnectionCard(
                        identity: .systemImage("shippingbox"),
                        name: "Hermes",
                        detail: state.hermesReadinessCopy.detail,
                        ready: state.hermesReady
                    ) {
                        if state.hermesInstalled {
                            CatalogRefreshButton(status: state.hermesCatalogStatus, state: state)
                            if state.hermesCatalogStatus == .unknown {
                                CLIActionButton(title: "Set Up", provider: "hermes", state: state) { state.connectHermes() }
                            }
                            CLIActionButton(title: CLIVersionDisplayPolicy.updateActionTitle(state.hermesCLIInfo.updateAvailable == true ? "Update CLI" : "Check Update", currentVersion: state.hermesCLIInfo.currentVersion, latestVersion: state.hermesCLIInfo.updateAvailable == true ? state.hermesCLIInfo.latestVersion : nil), provider: "hermes", state: state) {
                                if state.hermesCLIInfo.updateAvailable == true { state.updateHermes() } else { state.checkHermesUpdate() }
                            }
                        } else {
                            CLIActionButton(title: "Install CLI", provider: "hermes", state: state) { state.installHermes() }
                        }
                    } content: {
                        VStack(alignment: .leading, spacing: 10) {
                            if state.hermesInstalled {
                                CLIMetadata(version: state.hermesCLIInfo.currentVersion, latestVersion: nil, updateInfo: state.hermesCLIInfo)
                                if let caption = RouteConnectionCaption.caption(forHarnessID: "hermes") {
                                    Label(caption, systemImage: "lock.shield")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            CLIActionMessage(provider: "hermes", state: state)
                        }
                    }
                }

                SectionHeader("System")
                CatalogCardGrid(contentWidth: contentWidth, minimum: LatticeCatalogPageLayout.connectionCardMinimum, maximum: LatticeCatalogPageLayout.connectionCardMaximum) {
                    ConnectionCard(identity: .systemImage("apple.intelligence"), name: "Apple Intelligence", detail: state.appleIntelligenceStatus, ready: state.appleIntelligenceReady, showsContent: false) {
                        EmptyView()
                    } content: {
                        EmptyView()
                    }
                    ConnectionCard(identity: .systemImage("cpu"), name: "Ollama", detail: state.ollamaReady ? (state.ollamaModels.isEmpty ? "Running · no chat models" : "Running · \(state.ollamaModels.count) chat model\(state.ollamaModels.count == 1 ? "" : "s")") : (state.ollamaInstalled ? "Installed · not running" : "Not installed"), ready: state.ollamaReady, showsContent: false) {
                        if state.ollamaReady {
                            Button("Refresh") { Task { await state.refreshLocalModels() } }
                        } else if state.ollamaInstalled {
                            Button("Start") { state.openOllama() }
                        } else {
                            Button("Get") { state.installOllama() }
                        }
                    } content: {
                        EmptyView()
                    }
                }
            }
        }
        .navigationTitle("Connections")
        .toolbar { Button { Task { await state.refreshConnections(refreshProviderCatalogs: true) } } label: { Label("Refresh", systemImage: "arrow.clockwise") } }
    }
}

struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.headline)
            .padding(.top, 8)
    }
}

struct CatalogRefreshButton: View {
    let status: ProviderCatalogStatus
    @ObservedObject var state: AppState

    var body: some View {
        if status.isRefreshable {
            Button(status == .failed ? "Retry catalog" : "Refresh catalog") {
                Task { await state.refreshConnections(refreshProviderCatalogs: true) }
            }
        }
    }
}

struct ExtensionsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        AdaptiveCatalogPage { contentWidth in
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Extensions & Skills", subtitle: "User-owned Lattice customizations and shared harness skills")

                if LatticeCatalogPageLayout.usesSideBySideSections(forContentWidth: contentWidth) {
                    HStack(alignment: .top, spacing: LatticeCatalogPageLayout.cardSpacing) {
                        extensionsPanel
                            .frame(maxWidth: .infinity, alignment: .leading)
                        skillsPanel
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    extensionsPanel
                    skillsPanel
                }

                if !state.selfEditJobs.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Self-Edit History").font(.headline)
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(state.selfEditJobs.enumerated()), id: \.element.id) { index, job in
                                if index > 0 { Divider() }
                                SelfEditJobRow(job: job, state: state)
                            }
                        }
                    }
                    .padding(LatticeMetrics.panelPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .latticeGlass(cornerRadius: LatticeMetrics.cardRadius)
                }
            }
        }
        .navigationTitle("Extensions & Skills")
    }

    private var extensionsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Extensions").font(.headline)
                Spacer(minLength: 8)
                Button("Open Folder") { state.openExtensionsFolder() }
                Button("Refresh") { state.refreshExtensions() }
            }
            if state.extensions.isEmpty {
                Text("No extensions installed.")
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(state.extensions.enumerated()), id: \.element.id) { index, record in
                        if index > 0 { Divider() }
                        ExtensionRecordRow(record: record, state: state)
                    }
                }
            }
        }
        .padding(LatticeMetrics.panelPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .latticeGlass(cornerRadius: LatticeMetrics.cardRadius)
    }

    private var skillsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Skills").font(.headline)
                Spacer(minLength: 8)
                Button("Open Folder") { state.openSkillsFolder() }
                Button("Refresh") { state.refreshSkills() }
            }
            Text("Imported from ~/.codex/skills and ~/.agents/skills into Lattice’s shared skills folder. Generated /self-edit skills land here too.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if state.skills.isEmpty {
                Text("No skills imported.")
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(state.skills.enumerated()), id: \.element.id) { index, record in
                        if index > 0 { Divider() }
                        SkillRecordRow(record: record, state: state)
                    }
                }
            }
        }
        .padding(LatticeMetrics.panelPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .latticeGlass(cornerRadius: LatticeMetrics.cardRadius)
    }
}

struct SelfEditJobRow: View {
    let job: LatticeExtensionJobRecord
    @ObservedObject var state: AppState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName)
                .foregroundStyle(statusColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(job.manifestName).fontWeight(.semibold)
                    Text(job.status.rawValue.capitalized)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                }
                if !job.summary.isEmpty {
                    Text(job.summary).font(.caption).foregroundStyle(.secondary)
                }
                Text(job.request)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let detail = job.statusDetail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if job.canRollback {
                Button("Rollback") { state.rollbackSelfEditJob(job) }
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var iconName: String {
        switch job.status {
        case .applied: "wand.and.stars"
        case .recorded: "doc.text.magnifyingglass"
        case .reverted: "arrow.uturn.backward.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var statusColor: Color {
        switch job.status {
        case .applied: .green
        case .recorded: .blue
        case .reverted: .secondary
        case .failed: .orange
        }
    }
}

struct ExtensionRecordRow: View {
    let record: LatticeExtensionRecord
    @ObservedObject var state: AppState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: record.isValid ? "puzzlepiece.extension" : "exclamationmark.triangle")
                .foregroundStyle(record.isValid ? Color.secondary : Color.orange)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(record.name).fontWeight(.semibold)
                    if !record.version.isEmpty { Text(record.version).font(.caption).foregroundStyle(.secondary) }
                }
                if !record.summary.isEmpty {
                    Text(record.summary).font(.caption).foregroundStyle(.secondary)
                }
                if !record.permissions.isEmpty {
                    Text(record.permissions.map(\.displayName).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !record.copyPatches.isEmpty {
                    Text(record.copyPatches.map { "\($0.target.displayName): \($0.text)" }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !record.layoutPatches.isEmpty {
                    Text(record.layoutPatches.map { "\($0.target.displayName) density: \($0.density.displayName)" }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !record.promptTemplates.isEmpty {
                    Text(record.promptTemplates.map { "\($0.invocation): \($0.title)" }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !record.skillPatches.isEmpty {
                    Text(record.skillPatches.map { "Skill /\($0.id): \($0.title)" }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !record.operationPreviews.isEmpty {
                    Text(record.operationPreviews.map { "\($0.operation.displayName) · \($0.targetSurfaceID)" }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(record.validationMessages, id: \.self) { message in
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                if record.hasRuntimePatches {
                    Toggle("Enable \(record.name)", isOn: Binding(get: { state.isExtensionEnabled(record) }, set: { state.setExtension(record, enabled: $0) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .disabled(!record.isValid)
                        .accessibilityLabel("Enable \(record.name) extension")
                        .accessibilityValue(state.isExtensionEnabled(record) ? "Enabled" : "Disabled")
                        .accessibilityHint(record.isValid ? "Controls whether this extension's runtime patches are active" : "This extension cannot be enabled until validation errors are fixed")
                } else {
                    Text(record.isValid ? "Valid" : "Invalid")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(record.isValid ? .green : .orange)
                }
                Button("Delete", role: .destructive) { state.requestDeleteExtension(record) }
                    .disabled(record.id.hasPrefix("invalid:"))
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct SkillRecordRow: View {
    let record: LatticeSkillRecord
    @ObservedObject var state: AppState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: record.isValid ? "wand.and.stars" : "exclamationmark.triangle")
                .foregroundStyle(record.isValid ? Color.secondary : Color.orange)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(record.title).fontWeight(.semibold)
                    Text(record.source.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !record.summary.isEmpty {
                    Text(record.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let ownerMessage = state.skillOwnerDisabledMessage(record) {
                    Label(ownerMessage, systemImage: "puzzlepiece.extension")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                ForEach(record.validationMessages, id: \.self) { message in
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                Toggle("Enable \(record.title)", isOn: Binding(get: { state.isSkillEnabled(record) }, set: { state.setSkill(record, enabled: $0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(!state.canToggleSkill(record))
                    .help(state.skillOwnerDisabledMessage(record) ?? "Enable or disable this skill")
                    .accessibilityLabel("Enable \(record.title) skill")
                    .accessibilityValue(state.isSkillEnabled(record) ? "Enabled" : "Disabled")
                    .accessibilityHint(state.skillOwnerDisabledMessage(record) ?? "Controls whether this skill is available as a slash command")
                Button(role: .destructive) { state.requestDeleteSkill(record) } label: {
                    Image(systemName: "trash")
                }
                    .buttonStyle(LatticeIconButtonStyle(size: .compact, isDestructive: true))
                    .disabled(!record.canDelete)
                    .help("Delete \(record.title)")
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct CLIActionButton: View {
    let title: String
    let provider: String
    @ObservedObject var state: AppState
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        if state.isCLIBusy(provider) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("In progress").font(.caption.weight(.medium))
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 40)
        } else {
            Button(title, action: action)
                .disabled(!isEnabled)
        }
    }
}

struct CLIActionMessage: View {
    let provider: String
    @ObservedObject var state: AppState

    var body: some View {
        if state.isCLIBusy(provider) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini)
                    Text(state.cliProgressText(provider, at: context.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(2)
                }
            }
        } else if let message = state.cliActionMessage(provider), !message.isEmpty {
            let indicatesProblem = CLIActionStatusPolicy.messageIndicatesProblem(message)
            HStack(spacing: 6) {
                Image(systemName: indicatesProblem ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(indicatesProblem ? .orange : .green)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct CLIMetadata: View {
    let version: String?
    let latestVersion: String?
    let updateInfo: CLIUpdateInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let version, !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                MetadataLine(label: "CLI version", value: version)
            }
            if let target = CLIVersionDisplayPolicy.targetVersion(
                currentVersion: updateInfo?.currentVersion ?? version,
                latestVersion: updateInfo?.latestVersion ?? latestVersion
            ) {
                MetadataLine(label: "Target update", value: target)
            }
            if let notes = updateInfo?.releaseNotes, !notes.isEmpty {
                MetadataNote(label: "Release notes", text: notes)
            }
            if let detail = updateInfo?.detail, !detail.isEmpty, detail != updateInfo?.releaseNotes {
                MetadataNote(label: updateInfo?.updateAvailable == true ? "Update detail" : "Status detail", text: detail)
            }
        }
        .foregroundStyle(.secondary)
    }
}

struct MetadataLine: View {
    let label: String
    let value: String
    var body: some View {
        HStack(spacing: 4) {
            Text("\(label):").fontWeight(.medium)
            Text(value)
                .monospacedDigit()
        }
        .font(.caption)
    }
}

struct MetadataNote: View {
    let label: String
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .textSelection(.enabled)
        }
    }
}

struct ModelChecklist: View {
    let providerID: String
    let models: [ProviderModel]
    @ObservedObject var state: AppState
    private let columns = [GridItem(.adaptive(minimum: 210), spacing: 8, alignment: .leading)]

    var body: some View {
        if !models.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                Text("Models").font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 7) {
                    ForEach(models) { model in
                        Toggle(isOn: Binding(get: { state.isModelEnabled("\(providerID):\(model.id)") }, set: { state.setModelEnabled("\(providerID):\(model.id)", enabled: $0) })) {
                            Text(model.name)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                                .help(model.name)
                        }
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("No models reported yet. Refresh after signing in.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
        }
    }
}

struct UsageWindowRow: View {
    let window: UsageWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(window.name)
                Spacer()
                Text("\(window.remainingPercent)% remaining")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ProgressView(value: Double(window.remainingPercent), total: 100)
            if let reset = window.resetsAt {
                Text("Resets \(reset, style: .relative)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Visual identity for a Connections / Models card: custom provider mark or SF Symbol.
enum ConnectionIdentity {
    case provider(LatticeProviderIdentity)
    case systemImage(String)
}

struct ConnectionCard<Actions: View, Content: View>: View {
    let identity: ConnectionIdentity
    let name: String
    let detail: String
    let ready: Bool
    var showsContent = true
    @ViewBuilder let actions: () -> Actions
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                connectionIdentityMark
                    .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .fontWeight(.semibold)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(name)
                .accessibilityValue(detail)

                Spacer(minLength: 0)
                actions().fixedSize(horizontal: true, vertical: false)
                // Shape/symbol distinguishes readiness without color alone; detail already
                // carries the spoken status, so hide this chrome from VoiceOver.
                ReadinessStatusIndicator(ready: ready, accessibilityStatus: detail)
                    .accessibilityHidden(true)
                    .fixedSize(horizontal: true, vertical: false)
            }
            if showsContent {
                content()
            }
        }
        .padding(LatticeMetrics.panelPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .latticeGlass(cornerRadius: LatticeMetrics.surfaceRadius)
    }

    @ViewBuilder
    private var connectionIdentityMark: some View {
        switch identity {
        case .provider(let provider):
            ProviderIdentityMark(identity: provider, size: 28)
        case .systemImage(let systemName):
            Image(systemName: systemName)
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
        }
    }
}

struct PageHeader: View {
    let title: String; let subtitle: String
    @ScaledMetric(relativeTo: .title) private var titleFontSize: CGFloat = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: titleFontSize, weight: .semibold, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, LatticeMetrics.pageHeaderBottomSpacing)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Adaptive catalog page layout (Models / Connections / Extensions)

/// Content-relative layout rules for catalog pages. Thresholds use measured
/// available width, not hard-coded display or screen sizes.
private enum LatticeCatalogPageLayout {
    /// Comfortable fallback when host width is not yet measured.
    static let comfortableSingleColumn: CGFloat = 900
    /// Soft cap so ultra-wide windows keep modest side margins without empty gutters.
    static let absoluteContentCap: CGFloat = 1480
    /// Side-by-side Extensions + Skills when content region is this wide or more.
    static let sideBySideSectionBreakpoint: CGFloat = 1040
    static let cardSpacing: CGFloat = 14

    static let featureCardMaximum: CGFloat = 720
    static let modelCardMinimum: CGFloat = 340
    static let modelCardMaximum: CGFloat = 440
    static let providerCardMinimum: CGFloat = 420
    static let providerCardMaximum: CGFloat = 560
    static let connectionCardMinimum: CGFloat = 460
    static let connectionCardMaximum: CGFloat = 720

    static func horizontalPadding(forAvailableWidth width: CGFloat) -> CGFloat {
        if width > 0 && width < 720 { return 20 }
        if width > 0 && width < 1100 { return 32 }
        return 40
    }

    /// Grows with the host so wide windows fill gutters; capped to avoid endless stretch.
    static func contentMaxWidth(forAvailableWidth width: CGFloat) -> CGFloat {
        guard width > 0 else { return comfortableSingleColumn }
        let padding = horizontalPadding(forAvailableWidth: width)
        let usable = width - padding * 2
        return min(max(usable, 0), absoluteContentCap)
    }

    static func usesSideBySideSections(forContentWidth width: CGFloat) -> Bool {
        width >= sideBySideSectionBreakpoint
    }

    /// Adaptive columns for card collections. Falls back to a single flexible
    /// column until two minima fit with spacing.
    static func cardColumns(contentWidth: CGFloat, minimum: CGFloat, maximum: CGFloat) -> [GridItem] {
        if contentWidth >= minimum * 2 + cardSpacing {
            return [GridItem(.adaptive(minimum: minimum, maximum: maximum), spacing: cardSpacing, alignment: .top)]
        }
        return [GridItem(.flexible(minimum: 0, maximum: .infinity), spacing: cardSpacing, alignment: .top)]
    }
}

/// Shared scroll host for catalog pages: expands usable content width on large
/// windows while keeping ordinary/narrow layouts readable.
private struct AdaptiveCatalogPage<Content: View>: View {
    @ViewBuilder let content: (_ contentWidth: CGFloat) -> Content

    var body: some View {
        GeometryReader { proxy in
            let hostWidth = proxy.size.width
            let padding = LatticeCatalogPageLayout.horizontalPadding(forAvailableWidth: hostWidth)
            let maxWidth = LatticeCatalogPageLayout.contentMaxWidth(forAvailableWidth: hostWidth)
            ScrollView {
                content(maxWidth)
                    .frame(maxWidth: maxWidth, alignment: .leading)
                    .padding(.horizontal, padding)
                    .padding(.vertical, LatticeMetrics.pageVerticalPadding)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
    }
}

/// Responsive card grid: single column when narrow; adaptive multi-column when wide.
private struct CatalogCardGrid<Content: View>: View {
    let contentWidth: CGFloat
    let minimum: CGFloat
    let maximum: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        LazyVGrid(
            columns: LatticeCatalogPageLayout.cardColumns(contentWidth: contentWidth, minimum: minimum, maximum: maximum),
            alignment: .leading,
            spacing: LatticeCatalogPageLayout.cardSpacing
        ) {
            content()
        }
    }
}

struct SettingsView: View {
    @ObservedObject var state: AppState
    var body: some View {
        Form {
            Section("Overlay") {
                LabeledContent("Shortcut", value: "⌘⇧Space")
                Text("Use the global shortcut to open Lattice without leaving your current app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Local models") {
                Stepper(
                    "Idle unload: \(state.localModelIdleUnloadLabel)",
                    value: Binding(
                        get: { state.localModelIdleUnloadMinutes },
                        set: { state.setLocalModelIdleUnloadMinutes($0) }
                    ),
                    in: 0...60,
                    step: 1
                )
                if let status = state.localModelStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                Button("Refresh Models") { Task { await state.refreshLocalModels() } }
            }
            Section("Extensions & Skills") {
                Button("Open Extensions Folder") { state.openExtensionsFolder() }
                Button("Open Skills Folder") { state.openSkillsFolder() }
            }
            Section("Privacy & Security") {
                Text(LatticeSettingsCopy.privacySecurityBody)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Section("Help") {
                Button("Show Welcome Guide") { state.showOnboardingGuide() }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, idealWidth: 560, maxWidth: .infinity, minHeight: 280, idealHeight: 400, maxHeight: .infinity, alignment: .topLeading)
    }
}
