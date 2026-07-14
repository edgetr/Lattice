import Foundation
import LatticeCore

struct LatticeExecutionRuntimes {
    let codex: CodexExecHarness
    let grok: ACPHarness
    let openCode: ACPHarness
    let antigravity: AntigravityCLIHarness
    let pi: PiRPCHarness
    let hermes: ACPHarness
    let appleIntelligence: AppleIntelligenceClient
    let ollama: OllamaClient
}

struct LatticeExecutionLaunch {
    let sessionID: UUID
    let route: ExecutionRoute
    let legacyHarnessID: String
    let backend: ChatBackend
    let prompt: String
    let threadID: String?
    let workspace: URL
    let reasoningEffort: ReasoningEffort?
    let policy: ExecutionPolicy
    let allowFileModification: Bool
    let workspaceWrite: Bool
    let recoveryPrompt: String?
    let recoveryUsesVisibleTranscriptHandoff: Bool
    let recoveryDeliveryIssue: String?
    let instructionEnvelope: LatticeInstructionEnvelope?
    let hermesProvider: String?
    let hermesSystemIdentity: String?
    let openCodeAPIKey: String?
    let appleTranscript: String?
    let ollamaMessages: [ChatMessage]?
    let localModelKeepAliveSeconds: Int
}

@MainActor
protocol LatticeExecutionCoordinating {
    func stream(_ launch: LatticeExecutionLaunch, runtimes: LatticeExecutionRuntimes) -> AsyncStream<AgentEvent>
    func cancel(sessionID: UUID, route: ExecutionRoute, legacyHarnessID: String, backend: ChatBackend, runtimes: LatticeExecutionRuntimes)
}

@MainActor
final class DefaultLatticeExecutionCoordinator: LatticeExecutionCoordinating {
    func stream(_ launch: LatticeExecutionLaunch, runtimes: LatticeExecutionRuntimes) -> AsyncStream<AgentEvent> {
        if ExecutionRouteResolver.isDeclared(launch.route) {
            switch launch.route.runtimeID {
            case "pi":
                guard let model = launch.route.modelID,
                      let envelope = launch.instructionEnvelope else {
                    return failure("The selected Pi route is incomplete.")
                }
                return runtimes.pi.stream(
                    prompt: launch.prompt,
                    sessionID: launch.sessionID,
                    threadID: launch.threadID,
                    workspace: launch.workspace,
                    provider: launch.route.providerID,
                    model: model,
                    reasoningEffort: launch.reasoningEffort,
                    allowFileModification: launch.allowFileModification,
                    mode: .code,
                    workspaceInstructionsTrusted: envelope.workspaceInstructionsTrusted,
                    instructionEnvelope: envelope,
                    openCodeAPIKey: launch.openCodeAPIKey
                )
            case "hermes":
                guard let provider = launch.hermesProvider,
                      let model = launch.route.modelID,
                      let systemIdentity = launch.hermesSystemIdentity else {
                    return failure("The selected Hermes route is incomplete.")
                }
                return runtimes.hermes.stream(
                    prompt: launch.prompt,
                    sessionID: launch.sessionID,
                    threadID: launch.threadID,
                    workspace: launch.workspace,
                    provider: provider,
                    model: model,
                    systemIdentity: systemIdentity,
                    opencodeAPIKey: launch.openCodeAPIKey,
                    allowFileModification: launch.allowFileModification,
                    recoveryPrompt: launch.recoveryPrompt,
                    recoveryUsesVisibleTranscriptHandoff: launch.recoveryUsesVisibleTranscriptHandoff,
                    recoveryDeliveryIssue: launch.recoveryDeliveryIssue
                )
            default:
                break
            }
        }

        if launch.legacyHarnessID == "pi", let route = legacyPiRoute(for: launch.backend) {
            return runtimes.pi.stream(
                prompt: launch.prompt,
                sessionID: launch.sessionID,
                threadID: launch.threadID,
                workspace: launch.workspace,
                provider: route.provider,
                model: route.model,
                reasoningEffort: launch.reasoningEffort,
                allowFileModification: launch.allowFileModification
            )
        }
        if launch.legacyHarnessID == "hermes" {
            return runtimes.hermes.stream(
                prompt: launch.prompt,
                sessionID: launch.sessionID,
                threadID: launch.threadID,
                workspace: launch.workspace,
                requestedModel: launch.backend.displayName,
                allowFileModification: launch.allowFileModification,
                recoveryPrompt: launch.recoveryPrompt,
                recoveryUsesVisibleTranscriptHandoff: launch.recoveryUsesVisibleTranscriptHandoff,
                recoveryDeliveryIssue: launch.recoveryDeliveryIssue
            )
        }

        switch launch.backend {
        case .codex(let model):
            return runtimes.codex.stream(
                prompt: launch.prompt,
                sessionID: launch.sessionID,
                threadID: launch.threadID,
                workspace: launch.workspace,
                model: model,
                reasoningEffort: launch.reasoningEffort,
                policy: launch.policy,
                workspaceWrite: launch.workspaceWrite
            )
        case .grok(let model):
            return runtimes.grok.stream(
                prompt: launch.prompt,
                sessionID: launch.sessionID,
                threadID: launch.threadID,
                workspace: launch.workspace,
                requestedModel: model,
                allowFileModification: launch.allowFileModification,
                recoveryPrompt: launch.recoveryPrompt,
                recoveryUsesVisibleTranscriptHandoff: launch.recoveryUsesVisibleTranscriptHandoff,
                recoveryDeliveryIssue: launch.recoveryDeliveryIssue
            )
        case .openCode(let model):
            return runtimes.openCode.stream(
                prompt: launch.prompt,
                sessionID: launch.sessionID,
                threadID: launch.threadID,
                workspace: launch.workspace,
                requestedModel: model,
                allowFileModification: launch.allowFileModification,
                recoveryPrompt: launch.recoveryPrompt,
                recoveryUsesVisibleTranscriptHandoff: launch.recoveryUsesVisibleTranscriptHandoff,
                recoveryDeliveryIssue: launch.recoveryDeliveryIssue
            )
        case .appleIntelligence:
            guard let transcript = launch.appleTranscript else { return failure("Apple Intelligence transcript is unavailable.") }
            return runtimes.appleIntelligence.stream(prompt: transcript, sessionID: launch.sessionID)
        case .antigravity(let model):
            return runtimes.antigravity.stream(
                prompt: launch.prompt,
                sessionID: launch.sessionID,
                workspace: launch.workspace,
                model: model,
                policy: launch.policy
            )
        case .ollama(let model):
            guard let messages = launch.ollamaMessages else { return failure("Ollama messages are unavailable.") }
            return runtimes.ollama.stream(
                messages: messages,
                model: model,
                sessionID: launch.sessionID,
                keepAliveSeconds: launch.localModelKeepAliveSeconds
            )
        }
    }

    func cancel(
        sessionID: UUID,
        route: ExecutionRoute,
        legacyHarnessID: String,
        backend: ChatBackend,
        runtimes: LatticeExecutionRuntimes
    ) {
        let runtimeID = ExecutionRouteResolver.isDeclared(route) ? route.runtimeID : legacyHarnessID
        switch runtimeID {
        case "pi": runtimes.pi.cancel(sessionID: sessionID)
        case "hermes": runtimes.hermes.cancel(sessionID: sessionID)
        case "codex": runtimes.codex.cancel(sessionID: sessionID)
        case "grok": runtimes.grok.cancel(sessionID: sessionID)
        case "opencode": runtimes.openCode.cancel(sessionID: sessionID)
        case "antigravity": runtimes.antigravity.cancel(sessionID: sessionID)
        case "lattice":
            switch backend {
            case .appleIntelligence: runtimes.appleIntelligence.cancel(sessionID: sessionID)
            case .ollama: runtimes.ollama.cancel(sessionID: sessionID)
            default: break
            }
        default: break
        }
    }

    private func legacyPiRoute(for backend: ChatBackend) -> (provider: String, model: String)? {
        switch backend {
        case .codex(let model): return ("openai-codex", model)
        case .openCode(let model):
            let parts = model.split(separator: "/", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        default: return nil
        }
    }

    private func failure(_ message: String) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            continuation.yield(.failed(message))
            continuation.finish()
        }
    }
}
