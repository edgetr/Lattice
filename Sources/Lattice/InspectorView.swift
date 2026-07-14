import SwiftUI
import LatticeCore

struct InspectorView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ScrollView {
            if let session = state.selectedSession {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Inspector")
                        .font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    inspectorShell(session)
                }
                .padding(12)
            } else {
                ContentUnavailableView("No Chat Selected", systemImage: "bubble.left", description: Text("Select a chat to inspect its route, workspace, and context."))
                    .padding(20)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func inspectorShell(_ session: LatticeSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            InspectorOpaqueSection(title: "Route", systemImage: "point.3.connected.trianglepath.dotted") {
                InspectorFactRow(title: "Mode", value: session.executionRoute.mode.displayName)
                InspectorFactRow(title: "Provider", value: session.backend.harnessName)
                InspectorFactRow(title: "Model", value: session.backend.displayName)
                InspectorFactRow(title: "Runtime", value: session.executionRoute.runtimeID)
                if let reasoning = session.reasoningEffort {
                    InspectorFactRow(title: "Reasoning", value: reasoning.displayName)
                }
                Picker("Execution policy", selection: Binding(get: { session.policy }, set: { state.setSessionPolicy($0) })) {
                    ForEach(ExecutionPolicy.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .disabled(session.isStreaming)
                .accessibilityLabel("Execution policy")
                .accessibilityHint(session.isStreaming ? "Stop the current response before changing execution policy." : "Controls approvals and provider tool risk for this chat.")
                .help(session.isStreaming ? "Stop the current response before changing execution policy" : "Controls approvals and provider tool risk for this chat")
                Picker("Model privacy", selection: Binding(get: { session.privacyMode }, set: { state.setSessionPrivacyMode($0) })) {
                    ForEach(SessionPrivacyMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .disabled(session.isStreaming)
                .accessibilityLabel("Model privacy")
                .accessibilityHint(session.isStreaming ? "Stop the current response before changing model privacy." : "Controls whether this chat may use cloud providers.")
                .help(session.isStreaming ? "Stop the current response before changing model privacy" : "Controls whether this chat may use cloud providers")
                if state.selectedSessionUsesLegacyDirectOpenCode {
                    Button("Enable saved key for this legacy OpenCode chat") {
                        state.enableLegacyDirectOpenCodeCredential()
                    }
                    .disabled(!state.openCodeAPIKeySaved)
                    .help(state.openCodeAPIKeySaved ? "Compatibility only: copy the saved API key into OpenCode's provider-owned auth file for this persisted direct route" : "Save an OpenCode key in Connections first")
                }
                if session.privacyMode == .localOnly {
                    Label("Cloud routes blocked for this chat.", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !session.backend.isLocal && session.messages.contains(where: { $0.role == .user }) {
                        Text("This chat is locked to its cloud route. Start a separate local chat to continue without cloud requests.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button("Start New Local Chat") { state.startLocalOnlyChatFromSelected() }
                            .disabled(!state.canStartLocalOnlyChat)
                            .help(state.canStartLocalOnlyChat ? "Create a fresh chat with a local backend" : "Make Apple Intelligence or Ollama available in Connections first")
                    }
                }
            }

            inspectorWarnings(for: session)
            instructionEditor(for: session.executionRoute.mode)

            InspectorOpaqueDisclosure(title: "Workspace", systemImage: "folder") {
                Text(session.workspacePath ?? "No workspace selected")
                    .font(.caption.monospaced())
                    .foregroundStyle(session.workspacePath == nil ? .secondary : .primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Trust workspace instruction files", isOn: Binding(
                    get: { state.selectedWorkspaceInstructionsTrusted },
                    set: { state.setSelectedWorkspaceInstructionTrust($0) }
                ))
                .toggleStyle(.switch)
                .disabled(session.workspacePath == nil && state.selectedWorkspacePath.isEmpty)
                .accessibilityHint(session.workspacePath == nil && state.selectedWorkspacePath.isEmpty ? "Choose a workspace before trusting instruction files." : "Allows exact AGENTS.md, AGENTS.MD, CLAUDE.md, and CLAUDE.MD files to be applied as workspace guidance. Does not grant credentials or bypass policy.")
                .help(session.workspacePath == nil && state.selectedWorkspacePath.isEmpty ? "Choose a workspace before trusting instruction files" : "Apply recognized workspace instruction files as guidance")
                Text("Trust means Lattice may apply only these exact filenames as guidance. It does not make files safe, grant credentials, or change approval policy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                let names = state.selectedAppliedInstructionFileNames
                InspectorFactRow(title: "Applied files", value: names.isEmpty ? "None" : names.joined(separator: ", "))
                Button("Choose Workspace…") { state.chooseWorkspace() }
                    .disabled(!session.messages.isEmpty)
                    .help(session.messages.isEmpty ? "Choose this chat’s workspace" : "A chat workspace cannot change after messages are sent")
            }

            InspectorOpaqueDisclosure(title: "Context", systemImage: "paperclip") {
                if let estimate = state.selectedContextBudgetEstimate { ContextBudgetMeter(estimate: estimate) }
                if session.attachments.isEmpty {
                    Text("No attached paths. Drag files or use paperclip to add context.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(session.attachments) { attachment in
                        HStack(spacing: 8) {
                            Label(attachment.name, systemImage: attachment.isImage ? "photo" : "doc").lineLimit(1)
                            Spacer(minLength: 4)
                            if attachment.isMissing { Text("Missing").font(.caption2).foregroundStyle(.orange) }
                            Button { state.removeAttachment(attachment.id) } label: { Image(systemName: "xmark") }
                                .buttonStyle(LatticeIconButtonStyle(size: .compact))
                                .accessibilityLabel("Remove \(attachment.name)")
                        }
                    }
                }
            }

            if let snapshot = state.selectedHarnessCapabilities {
                let capability = snapshot.routeCapability
                InspectorOpaqueDisclosure(title: "Harness capabilities", systemImage: "switch.2") {
                    capabilityRow("Protocol · transport", snapshot.protocolTransport)
                    capabilityRow("Provider", snapshot.providerAvailability)
                    capabilityRow("Model", snapshot.modelAvailability)
                    InspectorFactRow(title: "Tool owner", value: capability.executionOwner.displayName)
                    InspectorFactRow(title: "Tool broker", value: capability.brokerMediation.displayName)
                    capabilityRow("Sandbox owner", snapshot.sandboxOwner)
                    capabilityRow("Write containment", capability.writeContainment)
                    capabilityRow("Approval path", capability.approvalBehavior)
                    capabilityRow("File reads", capability.fileReadRestriction)
                    capabilityRow("Network", capability.networkRestriction)
                    capabilityRow("Credential boundary", snapshot.credentialBoundary)
                    capabilityRow("Events", capability.structuredEvents)
                    capabilityRow("Resume", snapshot.resume)
                    capabilityRow("Cancel", capability.cancellation)
                }
            }
            if case .codex = session.backend, let usage = state.codexUsage {
                InspectorOpaqueDisclosure(title: "Usage", systemImage: "gauge.with.dots.needle.33percent") {
                    ForEach(usage.windows) { UsageWindowRow(window: $0) }
                    if let balance = usage.creditsBalance { InspectorFactRow(title: "Credits", value: balance) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chat inspector")
    }

    @ViewBuilder
    private func inspectorWarnings(for session: LatticeSession) -> some View {
        let warnings = (state.selectedRouteCapability?.warnings ?? []) + (state.activeRouteStatusText.map { [$0] } ?? [])
        if !warnings.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(Set(warnings)).sorted(), id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: LatticeMetrics.compactRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: LatticeMetrics.compactRadius, style: .continuous).strokeBorder(Color.orange.opacity(0.35)))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Inspector warnings")
        }
    }

    @ViewBuilder private func instructionEditor(for mode: ConversationMode) -> some View {
        if mode != .local {
            InspectorOpaqueDisclosure(title: "\(mode.displayName) instructions", systemImage: "text.quote") {
                Text("Optional guidance for every \(mode.displayName) chat. Maximum 8 KiB. Never put credentials here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ModeInstructionEditor(mode: mode, text: Binding(
                    get: { mode == .code ? state.codeInstructionAddOn : state.workInstructionAddOn },
                    set: { _ = state.setInstructionAddOn($0, for: mode) }
                ))
            }
        }
    }

    private func capabilityRow(_ title: String, _ capability: RouteCapabilityDetail) -> some View {
        InspectorFactRow(title: title, value: capability.displayValue)
            .accessibilityValue(capability.detail)
            .help(capability.detail)
    }
}

private struct InspectorOpaqueSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .latticeContentSurface(cornerRadius: LatticeMetrics.controlRadius)
    }
}

private struct InspectorOpaqueDisclosure<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 9) { content }
                .padding(.top, 8)
        } label: {
            Label(title, systemImage: systemImage)
                .font(.headline)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .latticeContentSurface(cornerRadius: LatticeMetrics.controlRadius)
    }
}

private struct ModeInstructionEditor: View {
    let mode: ConversationMode
    @Binding var text: String

    private var byteCount: Int { text.utf8.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("\(mode.displayName) add-on")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(byteCount) / \(LatticeInstructionEnvelope.maximumUserAddOnBytes) bytes")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(byteCount > LatticeInstructionEnvelope.maximumUserAddOnBytes ? .red : .secondary)
            }
            TextEditor(text: $text)
                .font(.callout.monospaced())
                .scrollContentBackground(.hidden)
                .padding(5)
                .frame(minHeight: 58, maxHeight: 130)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.secondary.opacity(0.25)))
                .accessibilityLabel("\(mode.displayName) mode instruction add-on")
            Text("Do not paste passwords, API keys, tokens, or other credentials.")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }
}

private struct InspectorFactRow: View {
    let title: String
    let value: String
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title).foregroundStyle(.secondary); Spacer(minLength: 8); Text(value).multilineTextAlignment(.trailing)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary); Text(value).fixedSize(horizontal: false, vertical: true)
            }
        }.font(.caption).accessibilityElement(children: .combine)
    }
}

struct ModelsView: View {
    @ObservedObject var state: AppState
    @AppStorage("lattice.models.showOnlyFittingLocalRecommendations") private var showOnlyFittingLocalRecommendations = true
    var installedTags: Set<String> {
        isOllamaCatalogAuthoritative ? Set(state.ollamaModels.map(\.name)) : []
    }

    private var displayedInstalledTags: Set<String> { Set(state.ollamaModels.map(\.name)) }

    private var isOllamaCatalogAuthoritative: Bool {
        state.ollamaCatalogStatus == .loaded || state.ollamaCatalogStatus == .empty
    }

    var body: some View {
        AdaptiveCatalogPage { contentWidth in
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Local Models", subtitle: "Recommended for \(state.hardware.chipName) · \(state.hardware.physicalMemoryGB) GB unified memory · \(state.hardware.thermalState)")
                ControlActionFeedback(state: state.localModelRefreshAction)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Built into macOS").font(.headline)
                    appleIntelligenceCard
                }

                if !state.ollamaModels.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(state.ollamaCatalogStatus == .loaded ? "Installed" : "Last known installed models")
                            .font(.headline)
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
                                    VStack(alignment: .trailing, spacing: 6) {
                                        Button("Start Chat") { state.startNewChat(with: backend) }
                                            .disabled(!runnable)
                                            .accessibilityHint(runnable ? "Start a new chat with \(model.name)." : (state.backendUnavailableMessage(for: backend) ?? "This local model is unavailable."))
                                            .help(runnable ? "Start a new chat with \(model.name)." : (state.backendUnavailableMessage(for: backend) ?? "This local model is unavailable."))
                                        Button("Delete", role: .destructive) { state.requestDeleteLocalModel(named: model.name) }
                                            .buttonStyle(.link)
                                            .disabled(!state.canDeleteLocalModel(named: model.name))
                                            .accessibilityHint("Remove \(model.name) from Ollama on this Mac.")
                                            .help(state.canDeleteLocalModel(named: model.name) ? "Delete \(model.name) from this Mac" : "A model can be deleted after Ollama finishes refreshing or running it")
                                    }
                                }
                                .padding(LatticeMetrics.cardPadding)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .latticeGlass(cornerRadius: LatticeMetrics.cardRadius, interactive: true)
                            }
                        }
                    }
                }

                if !state.ollamaReady || state.ollamaCatalogStatus != .loaded {
                    ollamaStatusCard
                }

                if let status = state.localModelStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(status.hasPrefix("Deleted ") ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.updatesFrequently)
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
                        .filter { !displayedInstalledTags.contains($0.ollamaTag) }
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
                                    RecommendationRow(
                                        model: model,
                                        installed: installedTags.contains(model.ollamaTag),
                                        catalogAuthoritative: isOllamaCatalogAuthoritative,
                                        state: state
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Local Models")
        .toolbar {
            Button { state.requestLocalModelRefresh() } label: { Label("Refresh Local Models", systemImage: "arrow.clockwise") }
                .disabled(!state.canRequestLocalModelRefresh)
                .help(state.localModelRefreshDisabledReason ?? "Refresh locally discovered Ollama models")
        }
    }

    private var catalogProblemState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Provider models unavailable", systemImage: "exclamationmark.triangle").font(.headline)
            Text(state.providerCatalogProblemMessage ?? "Check the provider connection again.")
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
                Button(copy.secondaryActionTitle ?? "Check Again") {
                    state.requestConnectionRefresh()
                }
                .buttonStyle(.link)
                .disabled(!state.canRequestConnectionRefresh)
                .help(state.connectionRefreshDisabledReason ?? "Check provider sign-in, runtimes, and models")
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
                Button("Start Chat") { state.startNewChat(with: backend) }
                    .disabled(!runnable)
                    .accessibilityHint(runnable ? "Start a new chat with Apple Intelligence." : (state.backendUnavailableMessage(for: backend) ?? "Apple Intelligence is unavailable."))
                    .help(runnable ? "Start a new chat with Apple Intelligence." : (state.backendUnavailableMessage(for: backend) ?? "Apple Intelligence is unavailable."))
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
                Text(ollamaStatusDetail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(ollamaStatusActionTitle) {
                if !state.ollamaInstalled {
                    state.installOllama()
                } else if !state.ollamaReady {
                    state.openOllama()
                } else {
                    state.requestLocalModelRefresh()
                }
            }
            .disabled(state.ollamaReady && !state.canRequestLocalModelRefresh)
            .help(state.ollamaReady ? (state.localModelRefreshDisabledReason ?? ollamaStatusDetail) : ollamaStatusDetail)
        }
        .padding(LatticeMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .latticeGlass(cornerRadius: LatticeMetrics.cardRadius, interactive: true)
        .frame(maxWidth: LatticeCatalogPageLayout.featureCardMaximum, alignment: .leading)
    }

    private var ollamaStatusDetail: String {
        if !state.ollamaInstalled { return "Required for local model installs" }
        if !state.ollamaReady { return "Installed · not running" }
        switch state.ollamaCatalogStatus {
        case .loading: return "Running · refreshing local model catalog"
        case .failed: return "Running · local model catalog unavailable"
        case .unknown: return "Running · local model catalog not checked"
        case .empty: return "Running · no chat-capable models reported"
        case .loaded: return state.ollamaModels.isEmpty ? "Running · no chat-capable models reported" : "Running"
        }
    }

    private var ollamaStatusActionTitle: String {
        if !state.ollamaInstalled { return "Install" }
        if !state.ollamaReady { return "Start" }
        return "Refresh"
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
        guard !models.isEmpty else { return "No models reported" }
        guard !visibleModels.isEmpty else { return "All models hidden" }
        guard visibleModels.contains(where: { state.canUseBackendInNewChat(backend($0)) }) else {
            return "Unavailable for this chat"
        }
        return "Available"
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
                Text("No \(providerName) models have been reported yet. Check again in Connections.")
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
    let catalogAuthoritative: Bool
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
                Button("Install Ollama") { state.installOllama() }.fixedSize(horizontal: true, vertical: false)
            } else if !state.ollamaReady {
                Button("Start Ollama") { state.openOllama() }.fixedSize(horizontal: true, vertical: false)
            } else if !catalogAuthoritative {
                Button("Refresh") { state.requestConnectionRefresh() }
                    .fixedSize(horizontal: true, vertical: false)
                    .disabled(!state.canRequestConnectionRefresh)
                    .accessibilityHint("Refresh the local model catalog before installing or using this recommendation.")
                    .help("Refresh the local model catalog before installing or using this recommendation.")
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
            Text("\(provider) models are unavailable. Check again in Connections.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Check Again") {
                state.requestConnectionRefresh()
            }
            .buttonStyle(.borderless)
            .disabled(!state.canRequestConnectionRefresh)
        }
        .padding(10)
        .latticeGlass(cornerRadius: 10, tint: Color.orange.opacity(0.08))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(provider) models unavailable")
        .accessibilityHint("Check \(provider) models again")
    }
}

struct ConnectionsView: View {
    @ObservedObject var state: AppState
    @AppStorage("lattice.connections.runtimeComponentsExpanded") private var runtimeComponentsExpanded = false
    @FocusState private var openCodeKeyFocused: Bool

    private var ollamaConnectionReady: Bool {
        state.ollamaReady && state.ollamaCatalogStatus == .loaded
    }

    private var ollamaConnectionDetail: String {
        guard state.ollamaInstalled else { return "Not installed" }
        guard state.ollamaReady else { return "Installed · not running" }
        switch state.ollamaCatalogStatus {
        case .unknown: return "Running · model catalog not checked"
        case .loading: return "Running · loading model catalog"
        case .failed: return "Running · model catalog unavailable"
        case .empty: return "Running · no chat models"
        case .loaded:
            return "Running · \(state.ollamaModels.count) chat model\(state.ollamaModels.count == 1 ? "" : "s")"
        }
    }

    var body: some View {
        AdaptiveCatalogPage { _ in
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Connections", subtitle: "Provider sign-in, runtime setup, and model availability")
                providerPanel
                runtimeComponents
                localPanel
                ControlActionFeedback(state: state.connectionRefreshAction)
                ControlActionFeedback(state: state.localModelRefreshAction)
            }
        }
        .navigationTitle("Connections")
        .toolbar {
            Button { state.requestConnectionRefresh() } label: {
                Label(state.connectionRefreshAction.isRunning ? "Checking" : "Check Connections", systemImage: "arrow.clockwise")
            }
            .disabled(!state.canRequestConnectionRefresh)
            .help(state.connectionRefreshDisabledReason ?? "Check provider sign-in, runtimes, and models")
        }
    }

    private var providerPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Providers", systemImage: "cloud")
                    .font(.headline)
                Spacer()
                Text("Mode · Runtime")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            providerRow(
                identity: .provider(.codex), name: "Codex", detail: "Code uses Pi · Work uses Hermes",
                modes: [
                    readinessMode(title: "Code", runtime: "Pi", readiness: state.modeReadiness(.code, providerID: "codex"), authenticationAction: state.runtimeAuthenticationAction(for: .pi)) { kind in
                        switch kind {
                        case .setupRuntime: state.installPi()
                        case .signIn: state.openPiAuthentication()
                        case .validate: state.validatePiAuthentication(providerID: "codex")
                        case .diagnostics: state.requestConnectionRefresh(diagnosticsRuntime: .pi)
                        default: break
                        }
                    },
                    readinessMode(title: "Work", runtime: "Hermes", readiness: state.modeReadiness(.work, providerID: "codex"), authenticationAction: state.runtimeAuthenticationAction(for: .hermes)) { kind in
                        switch kind {
                        case .setupRuntime: state.installHermes()
                        case .signIn: state.openHermesAuthentication()
                        case .validate: state.validateHermesAuthentication(providerID: "codex")
                        case .diagnostics: state.requestConnectionRefresh(diagnosticsRuntime: .hermes)
                        default: break
                        }
                    }
                ]
            ) {
                codexActions
            } content: {
                Text("Sign in separately for Code through Pi and Work through Hermes. Signing in to the Codex CLI does not enable either route.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ModelChecklist(providerID: "codex", modeNames: ["Code", "Work"], models: state.codexModels, state: state)
                CLIActionMessage(provider: "codex", state: state)
            }
            providerRow(
                identity: .provider(.grok), name: "Grok", detail: "Code uses Grok Build · Work uses Hermes",
                modes: [
                    readinessMode(title: "Code", runtime: "Grok Build", readiness: state.modeReadiness(.code, providerID: "grok")) { kind in
                        switch kind {
                        case .setupRuntime: state.installGrok()
                        case .signIn: state.connectGrok()
                        case .diagnostics: state.requestConnectionRefresh()
                        default: break
                        }
                    },
                    readinessMode(title: "Work", runtime: "Hermes", readiness: state.modeReadiness(.work, providerID: "grok"), authenticationAction: state.runtimeAuthenticationAction(for: .hermes)) { kind in
                        switch kind {
                        case .setupRuntime: state.installHermes()
                        case .signIn: state.openHermesAuthentication()
                        case .validate: state.validateHermesAuthentication(providerID: "grok")
                        case .diagnostics: state.requestConnectionRefresh(diagnosticsRuntime: .hermes)
                        default: break
                        }
                    }
                ]
            ) {
                grokActions
            } content: {
                ModelChecklist(providerID: "grok", modeNames: ["Code", "Work"], models: state.grokModels, state: state)
                CLIActionMessage(provider: "grok", state: state)
            }
            providerRow(
                identity: .provider(.opencode), name: "OpenCode", detail: "One Keychain credential · separate mode consent",
                modes: [
                    openCodeReadinessMode(.code, title: "Code", runtime: "Pi"),
                    openCodeReadinessMode(.work, title: "Work", runtime: "Hermes")
                ]
            ) {
                openCodeActions
            } content: {
                openCodeKeyControls
                ModelChecklist(providerID: "opencode", modeNames: ["Code", "Work"], models: state.openCodeModels, state: state)
                CLIActionMessage(provider: "opencode", state: state)
            }
            providerRow(
                identity: .systemImage("paperplane"), name: "Antigravity",
                detail: "Code uses the Antigravity runtime",
                modes: [readinessMode(title: "Code", runtime: "Antigravity", readiness: state.modeReadiness(.code, providerID: "antigravity")) { kind in
                    switch kind {
                    case .setupRuntime: state.installAntigravity()
                    case .signIn: state.connectAntigravity()
                    case .diagnostics: state.requestConnectionRefresh()
                    default: break
                    }
                }]
            ) {
                antigravityActions
            } content: {
                ModelChecklist(providerID: "antigravity", modeNames: ["Code"], models: state.antigravityModels, state: state)
                CLIActionMessage(provider: "antigravity", state: state)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var codexActions: some View {
        EmptyView()
    }

    @ViewBuilder private var grokActions: some View {
        providerUpdateAction(provider: "grok", title: "Update Build", installed: state.grok.isInstalled, authenticated: state.grokAuthenticated, version: state.grokCLIInfo.currentVersion, latest: state.grokCLIInfo.latestVersion, update: state.updateGrok)
    }

    @ViewBuilder private var openCodeActions: some View {
        EmptyView()
    }

    @ViewBuilder private var antigravityActions: some View {
        providerUpdateAction(provider: "antigravity", title: "Update", installed: state.antigravityInstalled, authenticated: state.antigravityAuthenticated, version: state.antigravityCLIVersion, latest: state.antigravityLatestCLIVersion, update: state.updateAntigravity)
    }

    @ViewBuilder private func providerUpdateAction(provider: String, title: String, installed: Bool, authenticated: Bool, version: String?, latest: String?, update: @escaping () -> Void) -> some View {
        if installed, authenticated, CLIVersionDisplayPolicy.isUpdateAvailable(currentVersion: version, latestVersion: latest) {
            CLIActionButton(title: title, provider: provider, state: state, isEnabled: state.canRequestConnectionRefresh, action: update)
                .disabled(!state.canRequestConnectionRefresh)
                .accessibilityHint(state.connectionRefreshDisabledReason ?? "Update the installed provider CLI.")
        }
    }

    private var openCodeKeyControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("OpenCode Go key")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(openCodeCredentialStatusLabel)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(state.openCodeAPIKeySaved ? .green : .secondary)
            }
            HStack(spacing: 10) {
                Toggle("Code", isOn: Binding(
                    get: { state.isOpenCodeCredentialEnabled(for: .code) },
                    set: { state.setOpenCodeCredentialEnabled($0, for: .code) }
                ))
                    .toggleStyle(.checkbox)
                    .disabled(!state.openCodeAPIKeySaved)
                    .accessibilityHint("Allow Pi Code routes to receive this key through their child environment.")
                    .help(state.openCodeAPIKeySaved ? "Allow Pi Code routes to use the saved key" : "Save the key before enabling Code")
                Toggle("Work", isOn: Binding(
                    get: { state.isOpenCodeCredentialEnabled(for: .work) },
                    set: { state.setOpenCodeCredentialEnabled($0, for: .work) }
                ))
                    .toggleStyle(.checkbox)
                    .disabled(!state.openCodeAPIKeySaved)
                    .accessibilityHint("Allow Hermes Work routes to receive this key through their child environment.")
                    .help(state.openCodeAPIKeySaved ? "Allow Hermes Work routes to use the saved key" : "Save the key before enabling Work")
            }
            if state.openCodeAPIKeySaved {
                Text("Code and Work are checked separately. The key is injected only for an enabled OpenCode route and is never written to command arguments.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("Check Code") { state.validatePiAuthentication(providerID: "opencode") }
                        .disabled(!state.isOpenCodeCredentialEnabled(for: .code) || !state.piInstalled)
                        .help(!state.piInstalled ? "Install Pi before checking Code" : (state.isOpenCodeCredentialEnabled(for: .code) ? "Check the saved key through Pi" : "Enable the saved key for Code first"))
                    Button("Check Work") { state.validateHermesOpenCodeAuthentication() }
                        .disabled(!state.isOpenCodeCredentialEnabled(for: .work) || !state.hermesInstalled)
                        .help(!state.hermesInstalled ? "Install Hermes before checking Work" : (state.isOpenCodeCredentialEnabled(for: .work) ? "Check the saved key through Hermes" : "Enable the saved key for Work first"))
                }
                .controlSize(.small)
            } else {
                Text("Save key before enabling either mode. Key never appears in this UI.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if state.openCodeAPIKeySaved {
                Button("Remove key", role: .destructive) { state.clearOpenCodeAPIKey() }
                    .controlSize(.small)
            } else {
                HStack(spacing: 8) {
                    SecureField("Paste API key", text: $state.openCodeAPIKeyDraft)
                        .textFieldStyle(.roundedBorder)
                        .focused($openCodeKeyFocused)
                        .accessibilityLabel("OpenCode API key")
                        .accessibilityHint("Paste a key to save securely in macOS Keychain.")
                    Button("Save") { state.saveOpenCodeAPIKey() }
                        .disabled(state.openCodeAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help(state.openCodeAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Paste an API key before saving" : "Save the key in macOS Keychain")
                }
            }
        }
        .disabled(!state.canRequestConnectionRefresh)
        .help(state.connectionRefreshDisabledReason ?? "Manage the OpenCode Keychain credential")
    }

    private var openCodeCredentialStatusLabel: String {
        switch state.openCodeCredentialAvailability {
        case .present:
            "Saved in Keychain"
        case .missing:
            "Not saved"
        case .locked:
            "Keychain locked · saved state retained"
        case .denied:
            "Keychain access denied · saved state retained"
        case .unavailable:
            state.openCodeAPIKeySaved ? "Keychain unavailable · saved state retained" : "Keychain unavailable"
        }
    }

    private var runtimeComponents: some View {
        DisclosureGroup(isExpanded: $runtimeComponentsExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                RuntimeComponentRow(name: "Pi", icon: "terminal", installed: state.piInstalled, version: state.piCLIVersion, latest: state.piLatestCLIVersion, provider: "pi", state: state)
                RuntimeComponentRow(name: "Hermes", icon: "shippingbox", installed: state.hermesInstalled, version: state.hermesCLIInfo.currentVersion, latest: state.hermesCLIInfo.latestVersion, provider: "hermes", state: state)
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Label("Runtimes", systemImage: "shippingbox")
                    .font(.headline)
                Spacer()
                Text("Pi · Hermes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: LatticeMetrics.surfaceRadius, style: .continuous))
    }

    private var localPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("On this Mac", systemImage: "desktopcomputer")
                .font(.headline)
            LocalConnectionRow(name: "Apple Intelligence", detail: state.appleIntelligenceStatus, ready: state.appleIntelligenceReady)
            LocalConnectionRow(name: "Ollama", detail: ollamaConnectionDetail, ready: ollamaConnectionReady) {
                if state.ollamaReady {
                    Button("Refresh") { state.requestLocalModelRefresh() }
                        .disabled(!state.canRequestLocalModelRefresh)
                } else if state.ollamaInstalled {
                    Button("Start") { state.openOllama() }
                } else {
                    Button("Install") { state.installOllama() }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: LatticeMetrics.surfaceRadius, style: .continuous))
    }

    private func providerRow<Actions: View, Content: View>(identity: ConnectionIdentity, name: String, detail: String, modes: [ModeReadiness], @ViewBuilder actions: () -> Actions, @ViewBuilder content: () -> Content) -> some View {
        ProviderConnectionRow(identity: identity, name: name, detail: detail, modes: modes, actions: actions, content: content)
    }

    private func readinessMode(
        title: String,
        runtime: String,
        readiness: ExecutionRouteReadiness,
        authenticationAction: HarnessReadinessAuthenticationAction = .signIn,
        perform: @escaping (HarnessReadinessActionKind) -> Void
    ) -> ModeReadiness {
        let resolution = HarnessReadinessActionPolicy.resolve(
            readiness: readiness,
            modeName: title,
            runtimeName: runtime,
            authenticationAction: authenticationAction,
            actionAvailable: state.canRequestConnectionRefresh
        )
        return ModeReadiness(title: title, runtime: runtime, readiness: readiness, resolution: resolution) {
            guard resolution.isEnabled else { return }
            perform(resolution.kind)
        }
    }

    private func openCodeReadinessMode(_ mode: ConversationMode, title: String, runtime: String) -> ModeReadiness {
        let authenticationAction: HarnessReadinessAuthenticationAction
        if !state.openCodeAPIKeySaved {
            authenticationAction = .configureCredential
        } else if !state.isOpenCodeCredentialEnabled(for: mode) {
            authenticationAction = .enableCredential
        } else {
            authenticationAction = .validate
        }

        return readinessMode(
            title: title,
            runtime: runtime,
            readiness: state.modeReadiness(mode, providerID: "opencode"),
            authenticationAction: authenticationAction
        ) { kind in
            switch kind {
            case .setupRuntime:
                if mode == .code { state.installPi() } else { state.installHermes() }
            case .configureCredential:
                openCodeKeyFocused = true
            case .enableCredential:
                state.setOpenCodeCredentialEnabled(true, for: mode)
            case .validate:
                if mode == .code { state.validatePiAuthentication(providerID: "opencode") }
                else { state.validateHermesOpenCodeAuthentication() }
            case .diagnostics:
                state.requestConnectionRefresh(diagnosticsRuntime: mode == .code ? .pi : .hermes)
            default:
                break
            }
        }
    }

}

private struct ControlActionFeedback: View {
    let state: ControlActionState

    var body: some View {
        if let message = state.message {
            HStack(spacing: 8) {
                if state.isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: state.phase == .failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(state.phase == .failed ? Color.orange : Color.green)
                }
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(state.isRunning ? "Action in progress" : (state.phase == .failed ? "Action failed" : "Action completed"))
            .accessibilityValue(message)
            .accessibilityAddTraits(state.isRunning ? .updatesFrequently : [])
        }
    }
}

private struct ModeReadiness: Identifiable {
    let title: String
    let runtime: String
    let readiness: ExecutionRouteReadiness
    let resolution: HarnessReadinessActionResolution
    let action: () -> Void
    var ready: Bool { readiness.isRunnable }
    var id: String { title }
}

private struct ModeReadinessBadge: View {
    let mode: ModeReadiness

    var body: some View {
        if mode.resolution.isInteractive {
            Button(mode.resolution.title, action: mode.action)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!mode.resolution.isEnabled)
                .accessibilityLabel(mode.resolution.accessibilityLabel)
                .accessibilityHint(mode.resolution.accessibilityHint)
                .help(mode.resolution.accessibilityHint)
        } else {
            HStack(spacing: 4) {
                if mode.readiness == .loading || mode.readiness == .validating {
                    ProgressView().controlSize(.mini).accessibilityHidden(true)
                } else {
                    Image(systemName: "checkmark.circle.fill").accessibilityHidden(true)
                }
                Text(mode.resolution.title)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(mode.resolution.accessibilityLabel)
            .accessibilityValue(mode.readiness.detail)
            .accessibilityHint(mode.resolution.accessibilityHint)
            .help(mode.readiness.detail)
        }
    }

    private var accentColor: Color {
        switch mode.readiness {
        case .runnable: .green
        case .loading, .validating: .blue
        case .missingRuntime, .authenticationRequired: .orange
        case .failed: .red
        }
    }

    private var foregroundColor: Color {
        mode.ready ? .green : .primary
    }

    private var statusImage: String {
        switch mode.readiness {
        case .runnable: "checkmark"
        case .loading, .validating: "arrow.clockwise"
        case .missingRuntime, .authenticationRequired: "exclamationmark"
        case .failed: "xmark"
        }
    }
}

private struct ProviderConnectionRow<Actions: View, Content: View>: View {
    let identity: ConnectionIdentity
    let name: String
    let detail: String
    let modes: [ModeReadiness]
    @ViewBuilder let actions: Actions
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                switch identity {
                case .provider(let provider): ProviderIdentityMark(identity: provider, size: 26)
                case .systemImage(let systemName): Image(systemName: systemName).font(.title3).foregroundStyle(.secondary).frame(width: 28, height: 28)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(.body.weight(.semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 5) { ForEach(modes) { ModeReadinessBadge(mode: $0) } }
                        VStack(alignment: .leading, spacing: 5) { ForEach(modes) { ModeReadinessBadge(mode: $0) } }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                actions
                    .fixedSize(horizontal: true, vertical: false)
            }
            content
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 9)
        .latticeContentSurface(cornerRadius: LatticeMetrics.controlRadius)
    }
}

private struct RuntimeComponentRow: View {
    let name: String
    let icon: String
    let installed: Bool
    let version: String?
    let latest: String?
    let provider: String
    @ObservedObject var state: AppState

    private var runtime: LatticeRuntimeID { provider == "pi" ? .pi : .hermes }
    private var descriptor: RuntimeInstallDescriptor { .firstUse(for: runtime) }
    private var managedByLattice: Bool { state.latticeManagedRuntimeIDs.contains(runtime) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.body.weight(.semibold))
                Text(installed ? "Installed · \(version ?? "version unknown")" : "Not installed")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Lattice version: \(descriptor.immutableVersion)")
                    .font(.caption2).foregroundStyle(.secondary)
                if installed, !managedByLattice {
                    Text("External install · Lattice will not remove it")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let lifecycle = state.runtimeLifecycleStates[runtime], let detail = lifecycle.detail {
                    Text(detail).font(.caption2)
                        .foregroundStyle(lifecycle.phase == .failed ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                CLIActionMessage(provider: provider, state: state)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                if state.isCLIBusy(provider) {
                    ProgressView().controlSize(.small).accessibilityLabel("Runtime action in progress")
                    Button("Cancel", role: .cancel) { state.cancelRunningRuntimeAction(runtime) }
                        .controlSize(.small)
                } else if installed {
                    Button(RuntimeLifecyclePresentationPolicy.actionTitle(
                        for: .update,
                        installedVersion: version,
                        targetVersion: descriptor.immutableVersion
                    )) {
                        if provider == "pi" { state.updatePi() } else { state.updateHermes() }
                    }
                    .controlSize(.small)
                    .disabled(!state.canRequestConnectionRefresh)
                    .help(state.connectionRefreshDisabledReason ?? "Repair or update this Lattice runtime after confirmation")
                    Button("Diagnose") { state.requestConnectionRefresh(diagnosticsRuntime: runtime) }
                        .controlSize(.small)
                        .disabled(!state.canRequestConnectionRefresh)
                        .help(state.connectionRefreshDisabledReason ?? "Diagnose this runtime, its sign-in status, and provider models")
                    Button("Remove", role: .destructive) { state.requestRuntimeAction(.uninstall, runtime: runtime) }
                        .controlSize(.small)
                        .disabled(!managedByLattice || !state.canRequestConnectionRefresh)
                        .help(!managedByLattice ? "Lattice can remove only runtimes it installed" : (state.connectionRefreshDisabledReason ?? "Remove this Lattice-installed runtime and its Lattice-owned profile after confirmation"))
                } else {
                    CLIActionButton(title: "Install", provider: provider, state: state, isEnabled: state.canRequestConnectionRefresh) {
                        if provider == "pi" { state.installPi() } else { state.installHermes() }
                    }
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: LatticeMetrics.controlRadius, style: .continuous))
    }
}

private struct LocalConnectionRow<Actions: View>: View {
    let name: String
    let detail: String
    let ready: Bool
    @ViewBuilder let actions: Actions

    init(name: String, detail: String, ready: Bool, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.name = name; self.detail = detail; self.ready = ready; self.actions = actions()
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            actions
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: LatticeMetrics.controlRadius, style: .continuous))
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
            Button(status == .failed ? "Check Again" : "Check Models") {
                state.requestConnectionRefresh()
            }
            .disabled(!state.canRequestConnectionRefresh)
        }
    }
}

struct ExtensionsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        AdaptiveCatalogPage { contentWidth in
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Extensions & Skills", subtitle: "User-owned Lattice customizations and shared agent skills")

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

                if let message = state.folderActionMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Folder action result")
                        .accessibilityValue(message)
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
                        .accessibilityHint(record.isValid ? "Controls whether this extension's changes are active" : "This extension cannot be enabled until validation errors are fixed")
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
        if let actionID = state.activeCLIActionID(for: provider) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini)
                    Text(state.cliProgressText(actionID, at: context.date))
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
    let modeNames: [String]
    let models: [ProviderModel]
    @ObservedObject var state: AppState

    private var disclosure: ProviderModelDisclosureState {
        state.providerModelDisclosureState(for: providerID)
    }

    private var items: [ProviderModelConfigurationItem] {
        ProviderModelConfigurationPolicy.items(
            providerID: providerID,
            discoveredModels: models,
            disabledModelIDs: state.disabledModelIDs,
            selectedModelIDs: state.selectedModelIDs(for: providerID)
        )
    }

    private var filteredItems: [ProviderModelConfigurationItem] {
        ProviderModelConfigurationPolicy.filtered(items, query: disclosure.query)
    }

    private var providerDefault: ProviderModelConfigurationItem? {
        ProviderModelConfigurationPolicy.providerDefault(in: items)
    }

    private var modeSummary: String { modeNames.joined(separator: " and ") }

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                Text("Model visibility")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Enablement controls which models appear for \(modeSummary). Route readiness still depends on each runtime, sign-in, and current validation shown above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let providerDefault {
                    modelVisibilityRow(providerDefault, role: "Provider default")
                        .padding(10)
                        .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    Text("No default was reported by the provider. Choose visibility in All models.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                DisclosureGroup(isExpanded: Binding(
                    get: { disclosure.isExpanded },
                    set: { state.setProviderModelDisclosureExpanded(providerID, expanded: $0) }
                )) {
                    VStack(alignment: .leading, spacing: 8) {
                        if items.count >= ProviderModelConfigurationPolicy.searchThreshold {
                            TextField("Search model name or identifier", text: Binding(
                                get: { disclosure.query },
                                set: { state.setProviderModelSearchQuery(providerID, query: $0) }
                            ))
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Search all \(providerID) models")
                        }
                        if filteredItems.isEmpty {
                            Text("No models match “\(disclosure.query)”.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 6)
                        } else {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(filteredItems) { item in
                                    modelVisibilityRow(item, role: item.isProviderDefault ? "Provider default" : nil)
                                }
                            }
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Text("All models (\(items.count))")
                        .font(.callout.weight(.medium))
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

    @ViewBuilder
    private func modelVisibilityRow(_ item: ProviderModelConfigurationItem, role: String?) -> some View {
        Toggle(
            isOn: Binding(
                get: { state.isModelEnabled("\(providerID):\(item.id)") },
                set: { state.setModelEnabled("\(providerID):\(item.id)", enabled: $0) }
            )
        ) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                let statuses = [role, item.isSelected ? "Selected" : nil, item.isDiscovered ? nil : "Currently unavailable"].compactMap { $0 }
                if !statuses.isEmpty {
                    Text(statuses.joined(separator: " · "))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(item.isDiscovered ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(item.id)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("\(item.name) model")
        .accessibilityValue(item.isEnabled ? "Enabled" : "Hidden")
        .accessibilityHint(item.isDiscovered
            ? "Exact identifier: \(item.id). Changes model visibility only, not route readiness."
            : "Exact identifier: \(item.id). This selected model is not in the current discovered catalog; the preference is preserved.")
        .help(item.isDiscovered
            ? "\(item.id) · visibility does not guarantee route readiness"
            : "\(item.id) · selected but not currently discovered")
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

struct PageHeader: View {
    let title: String; let subtitle: String
    @ScaledMetric(relativeTo: .title) private var titleFontSize: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: titleFontSize, weight: .semibold))
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
    static let cardSpacing = CGFloat(LatticeResponsiveLayoutPolicy.cardSpacing)

    static let featureCardMaximum: CGFloat = 720
    static let modelCardMinimum: CGFloat = 340
    static let modelCardMaximum: CGFloat = 440
    static let providerCardMinimum: CGFloat = 420
    static let providerCardMaximum: CGFloat = 560
    static let connectionCardMinimum: CGFloat = 460
    static let connectionCardMaximum: CGFloat = 720

    static func horizontalPadding(forAvailableWidth width: CGFloat) -> CGFloat {
        CGFloat(LatticeResponsiveLayoutPolicy.horizontalPadding(forAvailableWidth: Double(width)))
    }

    /// Grows with the host so wide windows fill gutters; capped to avoid endless stretch.
    static func contentMaxWidth(forAvailableWidth width: CGFloat) -> CGFloat {
        CGFloat(LatticeResponsiveLayoutPolicy.contentWidth(forAvailableWidth: Double(width)))
    }

    static func usesSideBySideSections(forContentWidth width: CGFloat) -> Bool {
        LatticeResponsiveLayoutPolicy.usesSideBySideSections(forContentWidth: Double(width))
    }

    /// Adaptive columns for card collections. Falls back to a single flexible
    /// column until two minima fit with spacing.
    static func cardColumns(contentWidth: CGFloat, minimum: CGFloat, maximum: CGFloat) -> [GridItem] {
        if LatticeResponsiveLayoutPolicy.canFitMultipleCards(
            contentWidth: Double(contentWidth),
            minimumCardWidth: Double(minimum)
        ) {
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
                ControlActionFeedback(state: state.localModelRefreshAction)
                Button("Refresh Models") { state.requestLocalModelRefresh() }
                    .disabled(!state.canRequestLocalModelRefresh)
                    .help(state.localModelRefreshDisabledReason ?? "Refresh locally discovered Ollama models")
            }
            Section("Extensions & Skills") {
                Button("Open Extensions Folder") { state.openExtensionsFolder() }
                Button("Open Skills Folder") { state.openSkillsFolder() }
                if let message = state.folderActionMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
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
