import Foundation

// MARK: - Assurance + detail primitives

/// Whether a control is present, absent, unknown, or not applicable for a route.
public enum RouteCapabilityAssurance: String, Equatable, Sendable {
    case enforced
    case present
    case absent
    case notApplicable
    case unknown

    public var displayName: String {
        switch self {
        case .enforced: "Enforced"
        case .present: "Present"
        case .absent: "Absent"
        case .notApplicable: "Not applicable"
        case .unknown: "Unknown"
        }
    }
}

public struct RouteCapabilityDetail: Equatable, Sendable {
    public let assurance: RouteCapabilityAssurance
    public let summary: String
    public let detail: String

    public init(assurance: RouteCapabilityAssurance, summary: String, detail: String) {
        self.assurance = assurance
        self.summary = summary
        self.detail = detail
    }

    public var displayValue: String { summary }
}

// MARK: - Typed capability dimensions

public enum RouteExecutionOwner: String, Equatable, Sendable {
    case providerOwned
    case latticeOwned
    case noDelegatedTools

    public var displayName: String {
        switch self {
        case .providerOwned: "Provider-owned tools"
        case .latticeOwned: "Lattice-owned tools"
        case .noDelegatedTools: "No delegated tools"
        }
    }
}

public enum RouteBrokerMediation: String, Equatable, Sendable {
    /// Live tools authorize and execute through `LocalToolBroker`.
    case mediatedByLocalToolBroker
    /// Live tools dispatch from the harness path without the broker (current provider routes).
    case notMediated
    /// Route has no delegated tool execution to mediate.
    case notApplicable

    public var displayName: String {
        switch self {
        case .mediatedByLocalToolBroker: "Mediated by LocalToolBroker"
        case .notMediated: "Not mediated by LocalToolBroker"
        case .notApplicable: "Not applicable"
        }
    }
}

public enum RouteWriteContainmentKind: String, Equatable, Sendable {
    case latticeMacOSWriteContainment
    case providerConfiguredSandbox
    case providerDeclaredSandbox
    case readOnly
    case none
    case notApplicable
}

public enum RouteApprovalBehaviorKind: String, Equatable, Sendable {
    case providerRequestForwarding
    case automaticPolicyDecisionsAfterRequest
    case planOnly
    case disabled
    case notApplicable
}

// MARK: - Connection captions (invariant; policy detail lives in Inspector)

public enum RouteConnectionCaption: Sendable {
    /// Invariant Connections caption for a harness ID. Policy-specific claims belong in Inspector.
    public static func caption(forHarnessID harnessID: String) -> String? {
        switch harnessID {
        case "codex":
            "Provider-owned tools · policy-dependent sandbox"
        case "grok", "opencode", "hermes", "pi":
            "Lattice write containment · provider-owned tools"
        case "antigravity":
            "Provider sandbox option · runtime-probed events"
        default:
            nil
        }
    }
}

// MARK: - Route capability snapshot

/// Deterministic, display-ready description of what a selected harness + execution policy truly enforces.
///
/// Not Codable and not persisted. Keyed by harness route ID and `ExecutionPolicy`.
public struct RouteCapability: Equatable, Sendable {
    public let harnessID: String
    public let policy: ExecutionPolicy
    public let executionOwner: RouteExecutionOwner
    public let brokerMediation: RouteBrokerMediation
    public let writeContainment: RouteCapabilityDetail
    public let writeContainmentKind: RouteWriteContainmentKind
    public let approvalBehavior: RouteCapabilityDetail
    public let approvalBehaviorKind: RouteApprovalBehaviorKind
    public let fileReadRestriction: RouteCapabilityDetail
    public let networkRestriction: RouteCapabilityDetail
    public let credentialReadProtection: RouteCapabilityDetail
    public let structuredEvents: RouteCapabilityDetail
    public let providerSessionResume: RouteCapabilityDetail
    public let cancellation: RouteCapabilityDetail
    public let warnings: [String]

    public init(
        harnessID: String,
        policy: ExecutionPolicy,
        executionOwner: RouteExecutionOwner,
        brokerMediation: RouteBrokerMediation,
        writeContainment: RouteCapabilityDetail,
        writeContainmentKind: RouteWriteContainmentKind,
        approvalBehavior: RouteCapabilityDetail,
        approvalBehaviorKind: RouteApprovalBehaviorKind,
        fileReadRestriction: RouteCapabilityDetail,
        networkRestriction: RouteCapabilityDetail,
        credentialReadProtection: RouteCapabilityDetail,
        structuredEvents: RouteCapabilityDetail,
        providerSessionResume: RouteCapabilityDetail,
        cancellation: RouteCapabilityDetail,
        warnings: [String]
    ) {
        self.harnessID = harnessID
        self.policy = policy
        self.executionOwner = executionOwner
        self.brokerMediation = brokerMediation
        self.writeContainment = writeContainment
        self.writeContainmentKind = writeContainmentKind
        self.approvalBehavior = approvalBehavior
        self.approvalBehaviorKind = approvalBehaviorKind
        self.fileReadRestriction = fileReadRestriction
        self.networkRestriction = networkRestriction
        self.credentialReadProtection = credentialReadProtection
        self.structuredEvents = structuredEvents
        self.providerSessionResume = providerSessionResume
        self.cancellation = cancellation
        self.warnings = warnings
    }

    public var primaryWarning: String? { warnings.first }

    public var lifecycleSummary: String {
        [
            "Events: \(structuredEvents.summary)",
            "Resume: \(providerSessionResume.summary)",
            "Cancel: \(cancellation.summary)"
        ].joined(separator: " · ")
    }

    /// Known harness route IDs with first-class capability tables.
    public static let knownHarnessIDs: [String] = [
        "codex", "grok", "opencode", "pi", "hermes", "antigravity", "lattice"
    ]

    /// Resolve truthful controls for a harness route ID and execution policy.
    ///
    /// - Parameter workspaceWrite: Codex Ask-only override for explicit workspace write; defaults false.
    ///   Does not apply to other harnesses.
    public static func resolve(
        harnessID: String,
        policy: ExecutionPolicy,
        workspaceWrite: Bool = false
    ) -> RouteCapability {
        switch harnessID {
        case "codex":
            return codex(policy: policy, workspaceWrite: workspaceWrite)
        case "grok", "opencode", "hermes":
            return acpProviderOwned(harnessID: harnessID, policy: policy)
        case "pi":
            return pi(policy: policy)
        case "antigravity":
            return antigravity(policy: policy)
        case "lattice":
            return latticeLocal(policy: policy)
        default:
            return unknown(harnessID: harnessID, policy: policy)
        }
    }

    // MARK: Codex

    private static func codex(policy: ExecutionPolicy, workspaceWrite: Bool) -> RouteCapability {
        let route = CodexProviderExecutionRoute.resolve(policy: policy, workspaceWrite: workspaceWrite)
        var warnings: [String] = [
            "Codex tools are provider-owned and are not mediated by LocalToolBroker."
        ]

        let writeResolved: (RouteWriteContainmentKind, RouteCapabilityDetail)
        switch route.sandbox {
        case "read-only":
            writeResolved = (
                .readOnly,
                RouteCapabilityDetail(
                    assurance: .present,
                    summary: "Provider read-only sandbox",
                    detail: "Codex sandbox=\(route.sandbox). Provider-configured; not Lattice sandbox-exec."
                )
            )
        case "workspace-write":
            writeResolved = (
                .providerConfiguredSandbox,
                RouteCapabilityDetail(
                    assurance: .present,
                    summary: "Provider workspace-write sandbox",
                    detail: "Codex sandbox=\(route.sandbox). Provider-configured workspace write; not Lattice sandbox-exec."
                )
            )
        case "danger-full-access":
            writeResolved = (
                .none,
                RouteCapabilityDetail(
                    assurance: .absent,
                    summary: "Write containment absent",
                    detail: "Codex sandbox=\(route.sandbox). Provider has danger-full-access; Lattice does not add write containment."
                )
            )
            warnings.append("Codex YOLO disables provider approvals and uses danger-full-access with no write containment.")
        default:
            writeResolved = (
                .none,
                RouteCapabilityDetail(
                    assurance: .unknown,
                    summary: "Unknown Codex sandbox",
                    detail: "Unrecognized Codex sandbox value \(route.sandbox)."
                )
            )
        }

        let approvalResolved: (RouteApprovalBehaviorKind, RouteCapabilityDetail)
        switch route.approvalPolicy {
        case "on-request":
            approvalResolved = (
                .providerRequestForwarding,
                RouteCapabilityDetail(
                    assurance: .present,
                    summary: "Provider on-request approvals",
                    detail: "Codex approvalPolicy=\(route.approvalPolicy). Provider permission requests can be forwarded into Lattice; automatic Lattice decisions apply only after a request arrives when policy allows."
                )
            )
        case "never":
            approvalResolved = (
                .disabled,
                RouteCapabilityDetail(
                    assurance: .absent,
                    summary: "Approval disabled",
                    detail: "Codex approvalPolicy=\(route.approvalPolicy). Provider approvals are disabled for this policy."
                )
            )
        default:
            approvalResolved = (
                .disabled,
                RouteCapabilityDetail(
                    assurance: .unknown,
                    summary: "Unknown approval policy",
                    detail: "Unrecognized Codex approvalPolicy \(route.approvalPolicy)."
                )
            )
        }

        return RouteCapability(
            harnessID: "codex",
            policy: policy,
            executionOwner: .providerOwned,
            brokerMediation: .notMediated,
            writeContainment: writeResolved.1,
            writeContainmentKind: writeResolved.0,
            approvalBehavior: approvalResolved.1,
            approvalBehaviorKind: approvalResolved.0,
            fileReadRestriction: unrestrictedReads(owner: "Codex"),
            networkRestriction: unrestrictedNetwork(owner: "Codex"),
            credentialReadProtection: noCredentialProtection(owner: "Codex provider tools"),
            structuredEvents: presentStructuredEvents(detail: "Codex app-server projects typed tool, plan, and permission events when the provider emits them."),
            providerSessionResume: RouteCapabilityDetail(
                assurance: .present,
                summary: "Provider thread resume",
                detail: "Codex can resume a provider thread ID when Lattice still holds it."
            ),
            cancellation: RouteCapabilityDetail(
                assurance: .present,
                summary: "Cancellable",
                detail: "Lattice can interrupt the active Codex turn and terminate the app-server process."
            ),
            warnings: warnings
        )
    }

    // MARK: ACP (Grok / OpenCode / Hermes)

    private static func acpProviderOwned(harnessID: String, policy: ExecutionPolicy) -> RouteCapability {
        let name: String = {
            switch harnessID {
            case "grok": return "Grok"
            case "opencode": return "OpenCode"
            case "hermes": return "Hermes"
            default: return harnessID
            }
        }()

        let approval = acpOrPiApproval(policy: policy, surfaceName: name)
        return RouteCapability(
            harnessID: harnessID,
            policy: policy,
            executionOwner: .providerOwned,
            brokerMediation: .notMediated,
            writeContainment: RouteCapabilityDetail(
                assurance: .enforced,
                summary: "Lattice macOS write containment",
                detail: "\(name) launches under Lattice sandbox-exec write containment for the selected workspace, scratch, and provider runtime state. Reads and network remain allowed by the sandbox profile."
            ),
            writeContainmentKind: .latticeMacOSWriteContainment,
            approvalBehavior: approval.1,
            approvalBehaviorKind: approval.0,
            fileReadRestriction: unrestrictedReads(owner: name),
            networkRestriction: unrestrictedNetwork(owner: name),
            credentialReadProtection: noCredentialProtection(owner: "\(name) provider tools"),
            structuredEvents: presentStructuredEvents(detail: "\(name) ACP projects structured tool and permission events when the provider emits them."),
            providerSessionResume: RouteCapabilityDetail(
                assurance: .present,
                summary: "Provider session resume",
                detail: "\(name) can resume a provider session ID when Lattice still holds it."
            ),
            cancellation: RouteCapabilityDetail(
                assurance: .present,
                summary: "Cancellable",
                detail: "Lattice can cancel the active \(name) process."
            ),
            warnings: [
                "\(name) tools are provider-owned and are not mediated by LocalToolBroker.",
                "Lattice write containment limits writes only; file reads and network remain allowed."
            ]
        )
    }

    // MARK: Pi

    private static func pi(policy: ExecutionPolicy) -> RouteCapability {
        let approval = piApproval(policy: policy)
        return RouteCapability(
            harnessID: "pi",
            policy: policy,
            executionOwner: .providerOwned,
            brokerMediation: .notMediated,
            writeContainment: RouteCapabilityDetail(
                assurance: .enforced,
                summary: "Lattice macOS write containment",
                detail: "Pi launches under Lattice sandbox-exec allowing the selected workspace, Pi session directory, scratch, and settings lock path. Reads and network remain allowed."
            ),
            writeContainmentKind: .latticeMacOSWriteContainment,
            approvalBehavior: approval.1,
            approvalBehaviorKind: approval.0,
            fileReadRestriction: unrestrictedReads(owner: "Pi"),
            networkRestriction: unrestrictedNetwork(owner: "Pi"),
            credentialReadProtection: noCredentialProtection(owner: "Pi provider tools"),
            structuredEvents: presentStructuredEvents(detail: "Pi RPC projects tool and permission-gate events when the agent emits them."),
            providerSessionResume: RouteCapabilityDetail(
                assurance: .present,
                summary: "Provider session resume",
                detail: "Pi can resume a session ID when Lattice still holds it."
            ),
            cancellation: RouteCapabilityDetail(
                assurance: .present,
                summary: "Cancellable",
                detail: "Lattice can abort and terminate the active Pi process."
            ),
            warnings: [
                "Pi tools are provider-owned and are not mediated by LocalToolBroker.",
                "Lattice write containment limits writes only; file reads and network remain allowed."
            ]
        )
    }

    // MARK: Antigravity

    private static func antigravity(policy: ExecutionPolicy) -> RouteCapability {
        switch policy {
        case .ask, .smart:
            return RouteCapability(
                harnessID: "antigravity",
                policy: policy,
                executionOwner: .providerOwned,
                brokerMediation: .notMediated,
                writeContainment: RouteCapabilityDetail(
                    assurance: .present,
                    summary: "Provider-declared sandbox option",
                    detail: "Antigravity receives provider --sandbox. Lattice does not independently verify provider sandbox containment."
                ),
                writeContainmentKind: .providerDeclaredSandbox,
                approvalBehavior: RouteCapabilityDetail(
                    assurance: .present,
                    summary: "Plan-only",
                    detail: "Ask and Smart use provider plan mode because interactive permission requests cannot be forwarded from the non-interactive CLI."
                ),
                approvalBehaviorKind: .planOnly,
                fileReadRestriction: unrestrictedReads(owner: "Antigravity"),
                networkRestriction: unrestrictedNetwork(owner: "Antigravity"),
                credentialReadProtection: noCredentialProtection(owner: "Antigravity provider tools"),
                structuredEvents: RouteCapabilityDetail(
                    assurance: .unknown,
                    summary: "Runtime-probed",
                    detail: "Lattice uses structured Antigravity events only when the installed CLI explicitly advertises stream-json; otherwise this route reports degraded transcript output."
                ),
                providerSessionResume: RouteCapabilityDetail(
                    assurance: .unknown,
                    summary: "Runtime-probed",
                    detail: "Lattice resumes only a provider session ID received from a declared structured init event. Transcript output is never scraped for session identity."
                ),
                cancellation: RouteCapabilityDetail(
                    assurance: .present,
                    summary: "Cancellable",
                    detail: "Lattice can terminate the Antigravity process."
                ),
                warnings: [
                    "Antigravity tools are provider-owned and are not mediated by LocalToolBroker.",
                    "Lattice does not independently verify provider --sandbox containment."
                ]
            )
        case .yolo:
            return RouteCapability(
                harnessID: "antigravity",
                policy: policy,
                executionOwner: .providerOwned,
                brokerMediation: .notMediated,
                writeContainment: RouteCapabilityDetail(
                    assurance: .present,
                    summary: "Provider-declared sandbox option",
                    detail: "Antigravity receives provider --sandbox with accept-edits. Lattice does not independently verify provider sandbox containment."
                ),
                writeContainmentKind: .providerDeclaredSandbox,
                approvalBehavior: RouteCapabilityDetail(
                    assurance: .absent,
                    summary: "Provider permissions disabled",
                    detail: "YOLO uses accept-edits and --dangerously-skip-permissions so provider interactive permissions are skipped."
                ),
                approvalBehaviorKind: .disabled,
                fileReadRestriction: unrestrictedReads(owner: "Antigravity"),
                networkRestriction: unrestrictedNetwork(owner: "Antigravity"),
                credentialReadProtection: noCredentialProtection(owner: "Antigravity provider tools"),
                structuredEvents: RouteCapabilityDetail(
                    assurance: .unknown,
                    summary: "Runtime-probed",
                    detail: "Lattice uses structured Antigravity events only when the installed CLI explicitly advertises stream-json; otherwise this route reports degraded transcript output."
                ),
                providerSessionResume: RouteCapabilityDetail(
                    assurance: .unknown,
                    summary: "Runtime-probed",
                    detail: "Lattice resumes only a provider session ID received from a declared structured init event. Transcript output is never scraped for session identity."
                ),
                cancellation: RouteCapabilityDetail(
                    assurance: .present,
                    summary: "Cancellable",
                    detail: "Lattice can terminate the Antigravity process."
                ),
                warnings: [
                    "Antigravity YOLO skips provider permissions and is not broker-mediated.",
                    "Lattice does not independently verify provider --sandbox containment."
                ]
            )
        }
    }

    // MARK: Local lattice chat (Apple Intelligence / Ollama)

    private static func latticeLocal(policy: ExecutionPolicy) -> RouteCapability {
        RouteCapability(
            harnessID: "lattice",
            policy: policy,
            executionOwner: .noDelegatedTools,
            brokerMediation: .notApplicable,
            writeContainment: RouteCapabilityDetail(
                assurance: .notApplicable,
                summary: "Not applicable",
                detail: "Local chat routes have no delegated tool execution in this product path, so write containment does not apply."
            ),
            writeContainmentKind: .notApplicable,
            approvalBehavior: RouteCapabilityDetail(
                assurance: .notApplicable,
                summary: "Not applicable",
                detail: "No delegated tool approvals on the local lattice chat path."
            ),
            approvalBehaviorKind: .notApplicable,
            fileReadRestriction: RouteCapabilityDetail(
                assurance: .notApplicable,
                summary: "Not applicable",
                detail: "No delegated file tools on this path."
            ),
            networkRestriction: RouteCapabilityDetail(
                assurance: .notApplicable,
                summary: "Not applicable",
                detail: "No delegated network tools on this path. Cloud-classified routes are still blocked only by session privacy mode, not by a tool broker."
            ),
            credentialReadProtection: RouteCapabilityDetail(
                assurance: .notApplicable,
                summary: "Not applicable",
                detail: "No delegated credential tools on this path. Do not treat the lattice harness ID as LocalToolBroker mediation."
            ),
            structuredEvents: RouteCapabilityDetail(
                assurance: .present,
                summary: "Stream deltas",
                detail: "Local routes stream assistant text; they do not run provider tool-call loops."
            ),
            providerSessionResume: RouteCapabilityDetail(
                assurance: .absent,
                summary: "No provider tool session",
                detail: "Local lattice chat does not resume a provider-owned tool session."
            ),
            cancellation: RouteCapabilityDetail(
                assurance: .present,
                summary: "Cancellable",
                detail: "Lattice can cancel the local generation stream when the runtime supports it."
            ),
            warnings: [
                "Local lattice routes have no delegated tool execution in this product path.",
                "Do not treat Apple Intelligence or Ollama as broker-mediated merely because the harness ID is lattice."
            ]
        )
    }

    // MARK: Unknown fallback

    private static func unknown(harnessID: String, policy: ExecutionPolicy) -> RouteCapability {
        RouteCapability(
            harnessID: harnessID,
            policy: policy,
            executionOwner: .providerOwned,
            brokerMediation: .notMediated,
            writeContainment: RouteCapabilityDetail(
                assurance: .unknown,
                summary: "Unknown write containment",
                detail: "No capability table for harness “\(harnessID)”. Assume writes are not Lattice-contained."
            ),
            writeContainmentKind: .none,
            approvalBehavior: RouteCapabilityDetail(
                assurance: .unknown,
                summary: "Unknown approval behavior",
                detail: "No capability table for harness “\(harnessID)”. Do not assume approval forwarding."
            ),
            approvalBehaviorKind: .disabled,
            fileReadRestriction: RouteCapabilityDetail(
                assurance: .unknown,
                summary: "Reads unknown",
                detail: "No proven file-read restriction for harness “\(harnessID)”."
            ),
            networkRestriction: RouteCapabilityDetail(
                assurance: .unknown,
                summary: "Network unknown",
                detail: "No proven network restriction for harness “\(harnessID)”."
            ),
            credentialReadProtection: RouteCapabilityDetail(
                assurance: .absent,
                summary: "Credential protection not claimed",
                detail: "Lattice does not claim credential-read protection for unknown harness “\(harnessID)”."
            ),
            structuredEvents: RouteCapabilityDetail(
                assurance: .unknown,
                summary: "Events unknown",
                detail: "Structured event support is unknown for harness “\(harnessID)”."
            ),
            providerSessionResume: RouteCapabilityDetail(
                assurance: .unknown,
                summary: "Resume unknown",
                detail: "Provider session resume is unknown for harness “\(harnessID)”."
            ),
            cancellation: RouteCapabilityDetail(
                assurance: .unknown,
                summary: "Cancel unknown",
                detail: "Cancellation support is unknown for harness “\(harnessID)”."
            ),
            warnings: [
                "Unknown harness “\(harnessID)”: treat controls as unproven. Tools are not assumed to be LocalToolBroker-mediated."
            ]
        )
    }

    // MARK: Shared builders

    private static func acpOrPiApproval(
        policy: ExecutionPolicy,
        surfaceName: String
    ) -> (RouteApprovalBehaviorKind, RouteCapabilityDetail) {
        switch policy {
        case .ask:
            (
                .providerRequestForwarding,
                RouteCapabilityDetail(
                    assurance: .present,
                    summary: "Provider request forwarding",
                    detail: "\(surfaceName) permission requests can be forwarded into Lattice. Ask surfaces material or non-reversible work; automatic allow only applies after a request arrives and policy evaluates it."
                )
            )
        case .smart:
            (
                .automaticPolicyDecisionsAfterRequest,
                RouteCapabilityDetail(
                    assurance: .present,
                    summary: "Forwarded requests + Smart auto-decisions",
                    detail: "\(surfaceName) permission requests are forwarded. Smart may auto-allow a scoped read after a request arrives; current ACP write requests are conservatively non-reversible and still ask."
                )
            )
        case .yolo:
            (
                .automaticPolicyDecisionsAfterRequest,
                RouteCapabilityDetail(
                    assurance: .present,
                    summary: "Forwarded requests + YOLO auto-allow",
                    detail: "\(surfaceName) permission requests are still received, but YOLO may auto-allow after a request arrives. Tools remain provider-owned and unbrokered."
                )
            )
        }
    }

    private static func piApproval(policy: ExecutionPolicy) -> (RouteApprovalBehaviorKind, RouteCapabilityDetail) {
        switch policy {
        case .ask, .smart:
            (
                .providerRequestForwarding,
                RouteCapabilityDetail(
                    assurance: .present,
                    summary: "Permission-gated mutations",
                    detail: "Pi’s extension gates write/edit/bash. Ask and Smart surface these non-reversible requests in Lattice; automatic decisions apply only after a request arrives."
                )
            )
        case .yolo:
            (
                .automaticPolicyDecisionsAfterRequest,
                RouteCapabilityDetail(
                    assurance: .present,
                    summary: "YOLO may auto-allow mutations",
                    detail: "Pi still emits permission-gated mutation requests; YOLO may auto-allow after a request arrives. Reads and network remain allowed; tools stay provider-owned."
                )
            )
        }
    }

    private static func unrestrictedReads(owner: String) -> RouteCapabilityDetail {
        RouteCapabilityDetail(
            assurance: .absent,
            summary: "Reads unrestricted",
            detail: "\(owner) does not enforce a Lattice file-read restriction; the process may read outside the selected workspace."
        )
    }

    private static func unrestrictedNetwork(owner: String) -> RouteCapabilityDetail {
        RouteCapabilityDetail(
            assurance: .absent,
            summary: "Network unrestricted",
            detail: "\(owner) does not enforce a Lattice network restriction."
        )
    }

    private static func noCredentialProtection(owner: String) -> RouteCapabilityDetail {
        RouteCapabilityDetail(
            assurance: .absent,
            summary: "Credential protection not claimed",
            detail: "\(owner) are not covered by LocalToolBroker credential denial. Lattice does not claim credential-read protection on this live path."
        )
    }

    private static func presentStructuredEvents(detail: String) -> RouteCapabilityDetail {
        RouteCapabilityDetail(
            assurance: .present,
            summary: "Structured events",
            detail: detail
        )
    }
}
