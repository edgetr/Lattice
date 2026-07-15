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

/// Transitional bag still assembled by AppState; resolved to `RuntimeLaunch` at the coordinator boundary.
struct LatticeExecutionLaunch {
    let sessionID: UUID
    let route: ExecutionRoute
    let legacyHarnessID: String
    let backend: ChatBackend
    let prompt: String
    let attachments: [ContextAttachment]
    let imageInputCapability: ImageInputCapability
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
    let developerInstructions: String?
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
        stream(RuntimeLaunch.resolve(from: launch), runtimes: runtimes)
    }

    func stream(_ launch: RuntimeLaunch, runtimes: LatticeExecutionRuntimes) -> AsyncStream<AgentEvent> {
        switch launch {
        case .failed(let message):
            return failure(message)
        case .pi(let pi):
            if let envelope = pi.instructionEnvelope {
                return runtimes.pi.stream(
                    prompt: pi.prompt,
                    sessionID: pi.sessionID,
                    threadID: pi.threadID,
                    workspace: pi.workspace,
                    provider: pi.provider,
                    model: pi.model,
                    reasoningEffort: pi.reasoningEffort,
                    allowFileModification: pi.allowFileModification,
                    mode: pi.mode,
                    workspaceInstructionsTrusted: envelope.workspaceInstructionsTrusted,
                    instructionEnvelope: envelope,
                    openCodeAPIKey: pi.openCodeAPIKey
                )
            }
            return runtimes.pi.stream(
                prompt: pi.prompt,
                sessionID: pi.sessionID,
                threadID: pi.threadID,
                workspace: pi.workspace,
                provider: pi.provider,
                model: pi.model,
                reasoningEffort: pi.reasoningEffort,
                allowFileModification: pi.allowFileModification
            )
        case .codex(let codex):
            return runtimes.codex.stream(
                prompt: codex.prompt,
                sessionID: codex.sessionID,
                threadID: codex.threadID,
                workspace: codex.workspace,
                model: codex.model,
                reasoningEffort: codex.reasoningEffort,
                policy: codex.policy,
                workspaceWrite: codex.workspaceWrite,
                developerInstructions: codex.developerInstructions,
                attachments: codex.attachments,
                imageInputCapability: codex.imageInputCapability
            )
        case .antigravity(let ag):
            return runtimes.antigravity.stream(
                prompt: ag.prompt,
                sessionID: ag.sessionID,
                threadID: ag.threadID,
                workspace: ag.workspace,
                model: ag.model,
                policy: ag.policy
            )
        case .apple(let apple):
            return runtimes.appleIntelligence.stream(prompt: apple.transcript, sessionID: apple.sessionID)
        case .ollama(let ollama):
            return runtimes.ollama.stream(
                messages: ollama.messages,
                model: ollama.model,
                sessionID: ollama.sessionID,
                keepAliveSeconds: ollama.keepAliveSeconds
            )
        case .acp(let acp):
            switch acp.provider {
            case .hermes:
                if let provider = acp.hermesProvider,
                   let systemIdentity = acp.hermesSystemIdentity {
                    return runtimes.hermes.stream(
                        prompt: acp.prompt,
                        sessionID: acp.sessionID,
                        threadID: acp.threadID,
                        workspace: acp.workspace,
                        provider: provider,
                        model: acp.requestedModel,
                        systemIdentity: systemIdentity,
                        opencodeAPIKey: acp.openCodeAPIKey,
                        allowFileModification: acp.allowFileModification,
                        recoveryPrompt: acp.recoveryPrompt,
                        recoveryUsesVisibleTranscriptHandoff: acp.recoveryUsesVisibleTranscriptHandoff,
                        recoveryDeliveryIssue: acp.recoveryDeliveryIssue
                    )
                }
                return runtimes.hermes.stream(
                    prompt: acp.prompt,
                    sessionID: acp.sessionID,
                    threadID: acp.threadID,
                    workspace: acp.workspace,
                    requestedModel: acp.requestedModel,
                    allowFileModification: acp.allowFileModification,
                    recoveryPrompt: acp.recoveryPrompt,
                    recoveryUsesVisibleTranscriptHandoff: acp.recoveryUsesVisibleTranscriptHandoff,
                    recoveryDeliveryIssue: acp.recoveryDeliveryIssue
                )
            case .grok:
                return runtimes.grok.stream(
                    prompt: acp.prompt,
                    sessionID: acp.sessionID,
                    threadID: acp.threadID,
                    workspace: acp.workspace,
                    requestedModel: acp.requestedModel,
                    allowFileModification: acp.allowFileModification,
                    recoveryPrompt: acp.recoveryPrompt,
                    recoveryUsesVisibleTranscriptHandoff: acp.recoveryUsesVisibleTranscriptHandoff,
                    recoveryDeliveryIssue: acp.recoveryDeliveryIssue
                )
            case .openCode:
                return runtimes.openCode.stream(
                    prompt: acp.prompt,
                    sessionID: acp.sessionID,
                    threadID: acp.threadID,
                    workspace: acp.workspace,
                    requestedModel: acp.requestedModel,
                    allowFileModification: acp.allowFileModification,
                    recoveryPrompt: acp.recoveryPrompt,
                    recoveryUsesVisibleTranscriptHandoff: acp.recoveryUsesVisibleTranscriptHandoff,
                    recoveryDeliveryIssue: acp.recoveryDeliveryIssue
                )
            }
        }
    }

    func cancel(
        sessionID: UUID,
        route: ExecutionRoute,
        legacyHarnessID: String,
        backend: ChatBackend,
        runtimes: LatticeExecutionRuntimes
    ) {
        let runtimeID = RouteRuntimeMap.cancelTarget(for: route, legacyHarnessID: legacyHarnessID)
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

    private func failure(_ message: String) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            continuation.yield(.failed(message))
            continuation.finish()
        }
    }
}
