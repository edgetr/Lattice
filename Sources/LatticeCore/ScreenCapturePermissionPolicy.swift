import Foundation

// MARK: - Permission statuses

/// Screen Recording permission as observed by Lattice. Distinct from Accessibility.
public enum ScreenRecordingPermissionStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case notDetermined
    case denied
    case authorized
    case restricted
    case unavailable
}

/// Accessibility permission for optional UI text context. Distinct from Screen Recording.
public enum AccessibilityPermissionStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case notDetermined
    case denied
    case authorized
    case restricted
    case unavailable
}

public enum ScreenCaptureCapability: Equatable, Sendable {
    case ready
    case needsScreenRecordingPermission
    case screenRecordingDenied(reason: String)
    case screenRecordingRestricted(reason: String)
    case screenRecordingUnavailable(reason: String)
    case accessibilityOptionalDenied(reason: String)
    case blocked(reason: String)

    public var allowsImageCapture: Bool {
        switch self {
        case .ready, .accessibilityOptionalDenied:
            return true
        case .needsScreenRecordingPermission, .screenRecordingDenied, .screenRecordingRestricted,
                .screenRecordingUnavailable, .blocked:
            return false
        }
    }

    public var allowsAuthorizedAccessibilityText: Bool {
        if case .ready = self { return true }
        return false
    }
}

public enum ScreenCapturePermissionPolicy {
    public static let screenRecordingRequiredReason =
        "Screen Recording permission is required for region and window capture."
    public static let accessibilityOptionalReason =
        "Accessibility permission was not granted. Capture continues as image-only without UI text context."

    /// Evaluates capture capability. Screen Recording and Accessibility are never conflated.
    public static func capability(
        screenRecording: ScreenRecordingPermissionStatus,
        accessibility: AccessibilityPermissionStatus,
        includeAccessibilityText: Bool
    ) -> ScreenCaptureCapability {
        switch screenRecording {
        case .notDetermined:
            return .needsScreenRecordingPermission
        case .denied:
            return .screenRecordingDenied(reason: "Screen Recording permission is denied. Enable it in System Settings to capture.")
        case .restricted:
            return .screenRecordingRestricted(reason: "Screen Recording is restricted on this Mac and cannot be used for capture.")
        case .unavailable:
            return .screenRecordingUnavailable(reason: "Screen Recording is unavailable on this system.")
        case .authorized:
            break
        }

        guard includeAccessibilityText else {
            return .ready
        }

        switch accessibility {
        case .authorized:
            return .ready
        case .notDetermined:
            return .accessibilityOptionalDenied(reason: "Accessibility permission is not determined. Capture can continue as image-only.")
        case .denied:
            return .accessibilityOptionalDenied(reason: accessibilityOptionalReason)
        case .restricted:
            return .accessibilityOptionalDenied(reason: "Accessibility is restricted. Capture continues as image-only.")
        case .unavailable:
            return .accessibilityOptionalDenied(reason: "Accessibility is unavailable. Capture continues as image-only.")
        }
    }

    public static func mayRequestScreenRecording(_ status: ScreenRecordingPermissionStatus) -> Bool {
        status == .notDetermined
    }

    public static func mayRequestAccessibility(_ status: AccessibilityPermissionStatus) -> Bool {
        status == .notDetermined
    }
}

// MARK: - Capture lifecycle

/// User-visible capture lifecycle. Hidden and continuous capture are never valid states.
public enum CaptureLifecyclePhase: String, Codable, Sendable, Hashable, Equatable {
    case idle
    /// Explicit user action started a capture flow.
    case userInitiated
    case requestingPermission
    case capturing
    case completedImageOnly
    case completedWithAuthorizedContext
    case cancelled
    case failed
}

public struct CaptureLifecycleState: Equatable, Sendable, Hashable {
    public var phase: CaptureLifecyclePhase
    public var failureReason: String?
    public var includeAccessibilityText: Bool

    public init(
        phase: CaptureLifecyclePhase = .idle,
        failureReason: String? = nil,
        includeAccessibilityText: Bool = false
    ) {
        self.phase = phase
        self.failureReason = failureReason
        self.includeAccessibilityText = includeAccessibilityText
    }

    public var isTerminal: Bool {
        switch phase {
        case .completedImageOnly, .completedWithAuthorizedContext, .cancelled, .failed:
            return true
        case .idle, .userInitiated, .requestingPermission, .capturing:
            return false
        }
    }

    public var isActive: Bool {
        switch phase {
        case .userInitiated, .requestingPermission, .capturing:
            return true
        case .idle, .completedImageOnly, .completedWithAuthorizedContext, .cancelled, .failed:
            return false
        }
    }
}

public enum CaptureLifecycleEvent: Equatable, Sendable {
    case userInitiatedCapture(includeAccessibilityText: Bool)
    case permissionRequestStarted
    case permissionResolved
    case captureStarted
    case completedImageOnly
    case completedWithAuthorizedContext
    case cancelled
    case failed(String)
    case reset
}

public enum CaptureLifecycleTransitionResult: Equatable, Sendable {
    case applied(CaptureLifecycleState)
    case rejected(reason: String)
}

/// Pure lifecycle policy. Never allows hidden or continuous background capture.
public enum CaptureLifecyclePolicy {
    public static let continuousCaptureDeniedReason =
        "Lattice only allows explicit, user-initiated single captures. Continuous or hidden capture is not supported."

    public static func reduce(
        _ event: CaptureLifecycleEvent,
        into state: CaptureLifecycleState
    ) -> CaptureLifecycleTransitionResult {
        switch event {
        case .userInitiatedCapture(let includeAccessibilityText):
            // Active capture cannot be stacked into continuous capture.
            if state.isActive {
                return .rejected(reason: continuousCaptureDeniedReason)
            }
            return .applied(CaptureLifecycleState(
                phase: .userInitiated,
                failureReason: nil,
                includeAccessibilityText: includeAccessibilityText
            ))

        case .permissionRequestStarted:
            guard state.phase == .userInitiated || state.phase == .requestingPermission else {
                return .rejected(reason: "Permission prompts require an explicit user-initiated capture.")
            }
            return .applied(CaptureLifecycleState(
                phase: .requestingPermission,
                includeAccessibilityText: state.includeAccessibilityText
            ))

        case .permissionResolved:
            guard state.phase == .requestingPermission || state.phase == .userInitiated else {
                return .rejected(reason: "Permission resolution is only valid during a user-initiated capture.")
            }
            return .applied(CaptureLifecycleState(
                phase: .userInitiated,
                includeAccessibilityText: state.includeAccessibilityText
            ))

        case .captureStarted:
            guard state.phase == .userInitiated || state.phase == .requestingPermission else {
                return .rejected(reason: "Capture can start only after an explicit user-initiated action.")
            }
            return .applied(CaptureLifecycleState(
                phase: .capturing,
                includeAccessibilityText: state.includeAccessibilityText
            ))

        case .completedImageOnly:
            guard state.phase == .capturing || state.phase == .userInitiated else {
                return .rejected(reason: "Image-only completion requires an in-progress capture.")
            }
            return .applied(CaptureLifecycleState(
                phase: .completedImageOnly,
                includeAccessibilityText: state.includeAccessibilityText
            ))

        case .completedWithAuthorizedContext:
            guard state.phase == .capturing || state.phase == .userInitiated else {
                return .rejected(reason: "Authorized-context completion requires an in-progress capture.")
            }
            guard state.includeAccessibilityText else {
                return .rejected(reason: "Authorized accessibility context requires the user to opt into UI text inclusion.")
            }
            return .applied(CaptureLifecycleState(
                phase: .completedWithAuthorizedContext,
                includeAccessibilityText: true
            ))

        case .cancelled:
            guard state.isActive || state.phase == .idle else {
                // Terminal states stay terminal; cancel is a no-op acceptance for already finished flows.
                if state.isTerminal {
                    return .applied(state)
                }
                return .rejected(reason: "Nothing to cancel.")
            }
            return .applied(CaptureLifecycleState(
                phase: .cancelled,
                includeAccessibilityText: state.includeAccessibilityText
            ))

        case .failed(let reason):
            guard state.isActive else {
                if state.isTerminal {
                    return .applied(state)
                }
                return .rejected(reason: "Nothing to fail.")
            }
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            return .applied(CaptureLifecycleState(
                phase: .failed,
                failureReason: trimmed.isEmpty ? "Capture failed." : trimmed,
                includeAccessibilityText: state.includeAccessibilityText
            ))

        case .reset:
            return .applied(CaptureLifecycleState())
        }
    }

    /// Continuous / hidden capture is always denied regardless of permissions.
    public static func allowsHiddenOrContinuousCapture() -> Bool { false }
}
