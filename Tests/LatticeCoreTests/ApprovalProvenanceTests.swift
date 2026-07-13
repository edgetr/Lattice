import Foundation
import Testing
@testable import LatticeCore

@Suite("Approval provenance")
struct ApprovalProvenanceTests {
    @Test func provenanceRoundTripsThroughSessionActionJSON() throws {
        let requestID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let messageID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let provenance = ApprovalProvenance(
            harnessID: "hermes",
            providerName: "Hermes",
            requestID: requestID,
            requestedOptionKinds: ["allow_once", "reject_once"],
            toolKind: .write,
            workspaceScoped: true,
            policy: .smart,
            policyReason: "Material changes require confirmation.",
            actor: .user,
            selectedOptionKind: "allow_once",
            outcome: .forwarded,
            providerAcknowledgement: .acceptedByHarness
        )
        let action = SessionAction(
            messageID: messageID,
            kind: .approval,
            toolKind: .write,
            title: "Approval",
            detail: "bounded summary",
            status: .allowed,
            workspaceScoped: true,
            approvalProvenance: provenance
        )

        let data = try JSONEncoder().encode(action)
        let decoded = try JSONDecoder().decode(SessionAction.self, from: data)
        #expect(decoded.approvalProvenance == provenance)
        #expect(decoded.approvalProvenance?.requestID == requestID)
    }

    @Test func providerControlledStringsAreBoundedAndSingleLine() {
        let provenance = ApprovalProvenance(
            harnessID: "hermes\n" + String(repeating: "x", count: 200),
            providerName: "provider\r\n" + String(repeating: "y", count: 200),
            requestID: UUID(),
            requestedOptionKinds: [String(repeating: "z", count: 200)],
            toolKind: .unknown,
            workspaceScoped: false,
            policy: .ask,
            policyReason: "reason\n" + String(repeating: "q", count: 400),
            actor: .automatic
        )

        #expect(!provenance.harnessID.contains("\n"))
        #expect(!provenance.providerName.contains("\n"))
        #expect(provenance.harnessID.count <= 64)
        #expect(provenance.providerName.count <= 96)
        #expect(provenance.requestedOptionKinds[0].count <= 64)
        #expect(provenance.policyReason.count <= 240)
    }
}
