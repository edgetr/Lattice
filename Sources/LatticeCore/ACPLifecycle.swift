import Foundation

public struct ProviderPermissionDecision: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case selected(optionID: String, kind: String)
        case cancelled(AgentCancellationReason)
    }

    public let requestID: UUID
    public let outcome: Outcome

    public init(requestID: UUID, outcome: Outcome) {
        self.requestID = requestID
        self.outcome = outcome
    }
}

public enum AgentCancellationReason: String, Sendable, Equatable {
    case userRequested
    case permissionDeclined
    case permissionTimedOut
    case streamConsumerTerminated
    case providerRequested
    case superseded
}

public struct AgentCancellation: Sendable, Equatable {
    public let reason: AgentCancellationReason
    public let detail: String?

    public init(reason: AgentCancellationReason, detail: String? = nil) {
        self.reason = reason
        self.detail = detail.map { String($0.prefix(240)) }
    }
}

public enum ProviderSessionIssue: Sendable, Equatable {
    case disconnected(String)
    case sessionRejected(String)
    case protocolViolation(String)
    case unsupportedProvider(String)
    case authenticationRequired
}

public struct ACPReconnectState: Sendable, Equatable {
    public enum Disposition: Sendable, Equatable {
        case scheduled
        case exhausted
        case unsupported
    }

    public let attempt: Int
    public let maximumAttempts: Int
    public let delayNanoseconds: UInt64
    public let disposition: Disposition

    public init(attempt: Int, maximumAttempts: Int, delayNanoseconds: UInt64, disposition: Disposition) {
        self.attempt = max(0, attempt)
        self.maximumAttempts = max(0, maximumAttempts)
        self.delayNanoseconds = delayNanoseconds
        self.disposition = disposition
    }
}

public enum ProviderSessionHealth: Sendable, Equatable {
    case connecting
    case healthy
    case unhealthy(ProviderSessionIssue)
    case reconnecting(ACPReconnectState)
    case recovered
}

public struct ProviderSessionLifecycleEvent: Sendable, Equatable {
    public let provider: String
    public let providerSessionID: String?
    public let health: ProviderSessionHealth

    public init(provider: String, providerSessionID: String? = nil, health: ProviderSessionHealth) {
        self.provider = String(provider.prefix(80))
        self.providerSessionID = providerSessionID.map { String($0.prefix(256)) }
        self.health = health
    }
}

/// Per-harness deterministic reconnect policy. It has no shared mutable state and
/// bounds both attempts and delay before any provider session is recreated.
public struct ACPReconnectPolicy: Sendable, Equatable {
    public let maximumAttempts: Int
    public let initialDelayNanoseconds: UInt64
    public let maximumDelayNanoseconds: UInt64

    public init(
        maximumAttempts: Int = 1,
        initialDelayNanoseconds: UInt64 = 100_000_000,
        maximumDelayNanoseconds: UInt64 = 1_000_000_000
    ) {
        self.maximumAttempts = max(0, maximumAttempts)
        self.initialDelayNanoseconds = initialDelayNanoseconds
        self.maximumDelayNanoseconds = max(initialDelayNanoseconds, maximumDelayNanoseconds)
    }

    public func state(forAttempt attempt: Int, supported: Bool = true) -> ACPReconnectState {
        guard supported else {
            return ACPReconnectState(attempt: 0, maximumAttempts: maximumAttempts, delayNanoseconds: 0, disposition: .unsupported)
        }
        guard attempt > 0, attempt <= maximumAttempts else {
            return ACPReconnectState(attempt: max(0, attempt), maximumAttempts: maximumAttempts, delayNanoseconds: 0, disposition: .exhausted)
        }
        let shift = min(attempt - 1, 62)
        let multiplied = initialDelayNanoseconds.multipliedReportingOverflow(by: UInt64(1) << UInt64(shift))
        let delay = multiplied.overflow ? maximumDelayNanoseconds : min(multiplied.partialValue, maximumDelayNanoseconds)
        return ACPReconnectState(attempt: attempt, maximumAttempts: maximumAttempts, delayNanoseconds: delay, disposition: .scheduled)
    }
}
