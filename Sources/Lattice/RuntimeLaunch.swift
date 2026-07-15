import Foundation
import LatticeCore

// MARK: - Typed launch payloads (secrets may be present; never log)

struct CodexRuntimeLaunch: Equatable {
    let sessionID: UUID
    let prompt: String
    let attachments: [ContextAttachment]
    let imageInputCapability: ImageInputCapability
    let threadID: String?
    let workspace: URL
    let model: String
    let reasoningEffort: ReasoningEffort?
    let policy: ExecutionPolicy
    let workspaceWrite: Bool
    let developerInstructions: String?
}

struct ACPRuntimeLaunch: Equatable {
    enum Provider: String, Equatable {
        case grok
        case openCode
        case hermes
    }

    let provider: Provider
    let sessionID: UUID
    let prompt: String
    let threadID: String?
    let workspace: URL
    let requestedModel: String
    let allowFileModification: Bool
    let recoveryPrompt: String?
    let recoveryUsesVisibleTranscriptHandoff: Bool
    let recoveryDeliveryIssue: String?
    /// Hermes-only structured route fields.
    let hermesProvider: String?
    let hermesSystemIdentity: String?
    let openCodeAPIKey: String?
}

struct PiRuntimeLaunch: Equatable {
    let sessionID: UUID
    let prompt: String
    let threadID: String?
    let workspace: URL
    let provider: String
    let model: String
    let reasoningEffort: ReasoningEffort?
    let allowFileModification: Bool
    let mode: ConversationMode
    let workspaceInstructionsTrusted: Bool
    let instructionEnvelope: LatticeInstructionEnvelope?
    let openCodeAPIKey: String?
}

struct AntigravityRuntimeLaunch: Equatable {
    let sessionID: UUID
    let prompt: String
    let threadID: String?
    let workspace: URL
    let model: String
    let policy: ExecutionPolicy
}

struct OllamaRuntimeLaunch: Equatable {
    let sessionID: UUID
    let messages: [ChatMessage]
    let model: String
    let keepAliveSeconds: Int
}

struct AppleRuntimeLaunch: Equatable {
    let sessionID: UUID
    let transcript: String
}

/// Typed runtime launch authority. Replaces optional kitchen-sink bags at the coordinator boundary.
enum RuntimeLaunch: Equatable {
    case codex(CodexRuntimeLaunch)
    case acp(ACPRuntimeLaunch)
    case pi(PiRuntimeLaunch)
    case antigravity(AntigravityRuntimeLaunch)
    case ollama(OllamaRuntimeLaunch)
    case apple(AppleRuntimeLaunch)
    case failed(String)

    /// Resolve a typed launch from the transitional bag used by AppState.
    static func resolve(from launch: LatticeExecutionLaunch) -> RuntimeLaunch {
        // Local-only fail closed: never stream a cloud backend under local-only privacy.
        if launch.route.mode == .local || !launch.backend.isLocal {
            // privacy is not on the launch bag; backend.isLocal is the fail-closed signal when
            // AppState already gated SessionPrivacyPolicy.allows. Refuse cloud when route is local.
            if launch.route.mode == .local && !launch.backend.isLocal {
                return .failed(SessionPrivacyPolicy.cloudBlockedMessage)
            }
        }

        if ExecutionRouteResolver.isDeclared(launch.route) {
            switch launch.route.runtimeID {
            case "pi":
                guard let model = launch.route.modelID else {
                    return .failed("The selected Pi route is incomplete: model is missing.")
                }
                guard let envelope = launch.instructionEnvelope else {
                    return .failed("The selected Pi route is incomplete: instruction envelope is missing.")
                }
                return .pi(PiRuntimeLaunch(
                    sessionID: launch.sessionID,
                    prompt: launch.prompt,
                    threadID: launch.threadID,
                    workspace: launch.workspace,
                    provider: launch.route.providerID,
                    model: model,
                    reasoningEffort: launch.reasoningEffort,
                    allowFileModification: launch.allowFileModification,
                    mode: launch.route.mode,
                    workspaceInstructionsTrusted: envelope.workspaceInstructionsTrusted,
                    instructionEnvelope: envelope,
                    openCodeAPIKey: launch.openCodeAPIKey
                ))
            case "hermes":
                guard let model = launch.route.modelID else {
                    return .failed("The selected Hermes route is incomplete: model is missing.")
                }
                // Prefer explicit hermesProvider; fall back to declared route.providerID mapping.
                let provider = launch.hermesProvider ?? Self.defaultHermesProvider(for: launch.route.providerID)
                guard let provider else {
                    return .failed("The selected Hermes route is incomplete: provider is missing.")
                }
                // Always supply a systemIdentity string so the structured Hermes stream path is used.
                let systemIdentity = launch.hermesSystemIdentity
                    ?? launch.developerInstructions
                    ?? "Lattice Hermes work route"
                return .acp(ACPRuntimeLaunch(
                    provider: .hermes,
                    sessionID: launch.sessionID,
                    prompt: launch.prompt,
                    threadID: launch.threadID,
                    workspace: launch.workspace,
                    requestedModel: model,
                    allowFileModification: launch.allowFileModification,
                    recoveryPrompt: launch.recoveryPrompt,
                    recoveryUsesVisibleTranscriptHandoff: launch.recoveryUsesVisibleTranscriptHandoff,
                    recoveryDeliveryIssue: launch.recoveryDeliveryIssue,
                    hermesProvider: provider,
                    hermesSystemIdentity: systemIdentity,
                    openCodeAPIKey: launch.openCodeAPIKey
                ))
            case "lattice":
                // Declared local runtimes must never fall through to a cloud backend switch.
                switch launch.backend {
                case .appleIntelligence:
                    guard let transcript = launch.appleTranscript else {
                        return .failed("Apple Intelligence transcript is unavailable.")
                    }
                    return .apple(AppleRuntimeLaunch(sessionID: launch.sessionID, transcript: transcript))
                case .ollama(let model):
                    guard let messages = launch.ollamaMessages else {
                        return .failed("Ollama messages are unavailable.")
                    }
                    return .ollama(OllamaRuntimeLaunch(
                        sessionID: launch.sessionID,
                        messages: messages,
                        model: model,
                        keepAliveSeconds: launch.localModelKeepAliveSeconds
                    ))
                default:
                    return .failed(SessionPrivacyPolicy.cloudBlockedMessage)
                }
            default:
                break
            }
        }

        if launch.legacyHarnessID == "pi" {
            let route: (provider: String, model: String)? = {
                switch launch.backend {
                case .codex(let model): return ("openai-codex", model)
                case .openCode(let model):
                    let parts = model.split(separator: "/", maxSplits: 1).map(String.init)
                    return parts.count == 2 ? (parts[0], parts[1]) : nil
                default: return nil
                }
            }()
            if let route {
                return .pi(PiRuntimeLaunch(
                    sessionID: launch.sessionID,
                    prompt: launch.prompt,
                    threadID: launch.threadID,
                    workspace: launch.workspace,
                    provider: route.provider,
                    model: route.model,
                    reasoningEffort: launch.reasoningEffort,
                    allowFileModification: launch.allowFileModification,
                    mode: .code,
                    workspaceInstructionsTrusted: false,
                    instructionEnvelope: nil,
                    openCodeAPIKey: nil
                ))
            }
        }

        if launch.legacyHarnessID == "hermes" {
            return .acp(ACPRuntimeLaunch(
                provider: .hermes,
                sessionID: launch.sessionID,
                prompt: launch.prompt,
                threadID: launch.threadID,
                workspace: launch.workspace,
                requestedModel: launch.backend.displayName,
                allowFileModification: launch.allowFileModification,
                recoveryPrompt: launch.recoveryPrompt,
                recoveryUsesVisibleTranscriptHandoff: launch.recoveryUsesVisibleTranscriptHandoff,
                recoveryDeliveryIssue: launch.recoveryDeliveryIssue,
                hermesProvider: nil,
                hermesSystemIdentity: nil,
                openCodeAPIKey: nil
            ))
        }

        switch launch.backend {
        case .codex(let model):
            return .codex(CodexRuntimeLaunch(
                sessionID: launch.sessionID,
                prompt: launch.prompt,
                attachments: launch.attachments,
                imageInputCapability: launch.imageInputCapability,
                threadID: launch.threadID,
                workspace: launch.workspace,
                model: model,
                reasoningEffort: launch.reasoningEffort,
                policy: launch.policy,
                workspaceWrite: launch.workspaceWrite,
                developerInstructions: launch.developerInstructions
            ))
        case .grok(let model):
            return .acp(ACPRuntimeLaunch(
                provider: .grok,
                sessionID: launch.sessionID,
                prompt: launch.prompt,
                threadID: launch.threadID,
                workspace: launch.workspace,
                requestedModel: model,
                allowFileModification: launch.allowFileModification,
                recoveryPrompt: launch.recoveryPrompt,
                recoveryUsesVisibleTranscriptHandoff: launch.recoveryUsesVisibleTranscriptHandoff,
                recoveryDeliveryIssue: launch.recoveryDeliveryIssue,
                hermesProvider: nil,
                hermesSystemIdentity: nil,
                openCodeAPIKey: nil
            ))
        case .openCode(let model):
            return .acp(ACPRuntimeLaunch(
                provider: .openCode,
                sessionID: launch.sessionID,
                prompt: launch.prompt,
                threadID: launch.threadID,
                workspace: launch.workspace,
                requestedModel: model,
                allowFileModification: launch.allowFileModification,
                recoveryPrompt: launch.recoveryPrompt,
                recoveryUsesVisibleTranscriptHandoff: launch.recoveryUsesVisibleTranscriptHandoff,
                recoveryDeliveryIssue: launch.recoveryDeliveryIssue,
                hermesProvider: nil,
                hermesSystemIdentity: nil,
                openCodeAPIKey: nil
            ))
        case .appleIntelligence:
            guard let transcript = launch.appleTranscript else {
                return .failed("Apple Intelligence transcript is unavailable.")
            }
            return .apple(AppleRuntimeLaunch(sessionID: launch.sessionID, transcript: transcript))
        case .antigravity(let model):
            return .antigravity(AntigravityRuntimeLaunch(
                sessionID: launch.sessionID,
                prompt: launch.prompt,
                threadID: launch.threadID,
                workspace: launch.workspace,
                model: model,
                policy: launch.policy
            ))
        case .ollama(let model):
            guard let messages = launch.ollamaMessages else {
                return .failed("Ollama messages are unavailable.")
            }
            return .ollama(OllamaRuntimeLaunch(
                sessionID: launch.sessionID,
                messages: messages,
                model: model,
                keepAliveSeconds: launch.localModelKeepAliveSeconds
            ))
        }
    }

    /// Maps Lattice provider IDs to Hermes provider strings for declared work routes.
    static func defaultHermesProvider(for providerID: String) -> String? {
        switch providerID {
        case "codex": LatticeHermesProvider.openAICodex.rawValue
        case "grok": LatticeHermesProvider.xAIOAuth.rawValue
        case "opencode": LatticeHermesProvider.openCodeGo.rawValue
        default: nil
        }
    }
}
