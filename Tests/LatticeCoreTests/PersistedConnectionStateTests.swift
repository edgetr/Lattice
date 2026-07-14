import Foundation
import Testing
@testable import LatticeCore

@Suite("Persisted connection hydration")
struct PersistedConnectionStateTests {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    @Test func relaunchHydratesOnlyFreshSecretFreeState() throws {
        let state = fixture(observedAt: now.addingTimeInterval(-30))
        let data = try #require(PersistedConnectionStatePolicy.encode(state))
        #expect(PersistedConnectionStatePolicy.hydrate(data, now: now) == .fresh(state))
        #expect(!PersistedConnectionStatePolicy.hydrate(data, now: now).canAuthorizeExecution)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.localizedCaseInsensitiveContains("apiKey"))
        #expect(!text.localizedCaseInsensitiveContains("token"))
        #expect(!text.localizedCaseInsensitiveContains("password"))
    }

    @Test func stalePersistedReadinessCannotBecomeAuthoritative() throws {
        let state = fixture(observedAt: now.addingTimeInterval(-3_600))
        let data = try #require(PersistedConnectionStatePolicy.encode(state))
        let hydration = PersistedConnectionStatePolicy.hydrate(data, now: now, maximumAge: 60)
        #expect(hydration == .stale(state))
        #expect(!hydration.canAuthorizeExecution)
    }

    @Test func malformedFutureAndOldSchemaCachesFailClosed() throws {
        #expect(PersistedConnectionStatePolicy.hydrate(Data("not-json".utf8), now: now) == .rejected)
        let future = fixture(observedAt: now.addingTimeInterval(1))
        #expect(PersistedConnectionStatePolicy.hydrate(try #require(PersistedConnectionStatePolicy.encode(future)), now: now) == .rejected)
        let old = PersistedConnectionState(
            schemaVersion: 0,
            observedAt: now,
            providers: [:],
            openCodeCredentialRecorded: true
        )
        #expect(PersistedConnectionStatePolicy.hydrate(try #require(PersistedConnectionStatePolicy.encode(old)), now: now) == .rejected)
    }

    @Test func removalPersistsCredentialAbsenceAndClearsRunnableCount() throws {
        let signedOut = PersistedConnectionState(
            observedAt: now,
            providers: ["opencode": .init(installed: true, authenticated: false, catalogStatus: .unknown, runnableModelCount: 0)],
            openCodeCredentialRecorded: false
        )
        let data = try #require(PersistedConnectionStatePolicy.encode(signedOut))
        guard case .fresh(let hydrated) = PersistedConnectionStatePolicy.hydrate(data, now: now) else {
            Issue.record("Expected fresh state")
            return
        }
        #expect(!hydrated.openCodeCredentialRecorded)
        #expect(hydrated.providers["opencode"]?.authenticated == false)
        #expect(hydrated.providers["opencode"]?.runnableModelCount == 0)
    }

    @Test func newestConcurrentObservationWinsAcrossSharedWindows() {
        let original = ConnectionObservation(generation: 4, value: "signed-in")
        let newer = ConnectionObservation(generation: 5, value: "signed-out")
        let lateOlder = ConnectionObservation(generation: 3, value: "stale-signed-in")
        #expect(original.accepting(newer) == newer)
        #expect(newer.accepting(lateOlder) == newer)
    }

    @Test func missingKeychainItemInvalidatesRecordedPresenceAndConsent() {
        let resolution = CredentialPresenceReconciler.resolve(.missing, previouslyRecorded: true)
        #expect(!resolution.recorded)
        #expect(resolution.shouldInvalidateConsent)
        #expect(!resolution.canReadSecret)
    }

    @Test func lockedKeychainRetainsPresenceWithoutClaimingSecretAccess() {
        let resolution = CredentialPresenceReconciler.resolve(.locked, previouslyRecorded: true)
        #expect(resolution.recorded)
        #expect(!resolution.shouldInvalidateConsent)
        #expect(!resolution.canReadSecret)
    }

    @Test func deniedKeychainRetainsPresenceWithoutPromptLoopOrAuthorization() {
        let resolution = CredentialPresenceReconciler.resolve(.denied, previouslyRecorded: true)
        #expect(resolution.recorded)
        #expect(!resolution.shouldInvalidateConsent)
        #expect(!resolution.canReadSecret)
    }

    private func fixture(observedAt: Date) -> PersistedConnectionState {
        PersistedConnectionState(
            observedAt: observedAt,
            providers: [
                "codex": .init(installed: true, authenticated: true, catalogStatus: .loaded, runnableModelCount: 2),
                "opencode": .init(installed: true, authenticated: true, catalogStatus: .loaded, runnableModelCount: 1)
            ],
            openCodeCredentialRecorded: true
        )
    }
}
