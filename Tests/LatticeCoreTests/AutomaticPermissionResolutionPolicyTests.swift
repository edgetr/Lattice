import Testing
@testable import LatticeCore

@Suite struct AutomaticPermissionResolutionPolicyTests {
    private let allow = ApprovalOption(id: "allow", name: "Allow", kind: "allow_once")
    private let reject = ApprovalOption(id: "reject", name: "Reject", kind: "reject_once")

    @Test func denialWithoutRejectFailsClosed() {
        #expect(AutomaticPermissionResolutionPolicy.resolve(
            decision: .deny(reason: "Credentials stay blocked."),
            policy: .yolo,
            options: [allow]
        ) == .denyFailClosed(reason: "Credentials stay blocked."))
    }

    @Test func denialUsesRejectWithoutOfferingAllow() {
        #expect(AutomaticPermissionResolutionPolicy.resolve(
            decision: .deny(reason: "Blocked."),
            policy: .ask,
            options: [allow, reject]
        ) == .forward(optionID: "reject", allowed: false))
    }

    @Test func automaticDenialNeverChoosesPersistentReject() {
        #expect(AutomaticPermissionResolutionPolicy.resolve(
            decision: .deny(reason: "Credentials stay blocked."),
            policy: .smart,
            options: [ApprovalOption(id: "always", name: "Always deny", kind: "reject_always")]
        ) == .denyFailClosed(reason: "Credentials stay blocked."))
    }

    @Test func automaticAllowRequiresAllowOnce() {
        #expect(AutomaticPermissionResolutionPolicy.resolve(
            decision: .allow(reason: "Safe workspace read."),
            policy: .smart,
            options: [allow]
        ) == .forward(optionID: "allow", allowed: true))
        #expect(AutomaticPermissionResolutionPolicy.resolve(
            decision: .allow(reason: "Safe workspace read."),
            policy: .smart,
            options: [reject]
        ) == .requestUser)
    }

    @Test func explicitApprovalNeverAutoAllows() {
        #expect(AutomaticPermissionResolutionPolicy.resolve(
            decision: .requireApproval(reason: "Confirm."),
            policy: .yolo,
            options: [allow, reject]
        ) == .requestUser)
    }

    @Test func yoloKeepsLegacyNoToolRequestAutoAllow() {
        #expect(AutomaticPermissionResolutionPolicy.resolve(
            decision: nil,
            policy: .yolo,
            options: [allow]
        ) == .forward(optionID: "allow", allowed: true))
    }
}
