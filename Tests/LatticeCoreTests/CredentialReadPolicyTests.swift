import Testing
@testable import LatticeCore

struct CredentialReadPolicyTests {
    @Test func onlyMissingConsultsLegacy() {
        #expect(CredentialReadPolicy.shouldConsultLegacy(after: .missing))
        for state in [CredentialReadState.value, .locked, .denied, .unavailable, .invalidData] {
            #expect(!CredentialReadPolicy.shouldConsultLegacy(after: state))
        }
    }

    @Test func failureStatesMapToSecretFreeAvailabilityAndMessages() {
        #expect(CredentialReadPolicy.availability(for: .value) == .present)
        #expect(CredentialReadPolicy.availability(for: .missing) == .missing)
        #expect(CredentialReadPolicy.availability(for: .locked) == .locked)
        #expect(CredentialReadPolicy.availability(for: .denied) == .denied)
        #expect(CredentialReadPolicy.availability(for: .unavailable) == .unavailable)
        #expect(CredentialReadPolicy.availability(for: .invalidData) == .unavailable)
        for state in [CredentialReadState.missing, .locked, .denied, .unavailable, .invalidData] {
            let message = CredentialReadPolicy.failureMessage(for: state, provider: "OpenCode")
            #expect(!message.isEmpty)
            #expect(message.contains("OpenCode"))
            #expect(!message.contains("secret"))
            #expect(!message.contains("token"))
        }
    }
}
