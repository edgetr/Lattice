import Foundation
import Testing
@testable import LatticeCore

@Suite("Command palette chat navigation")
struct CommandPaletteChatNavigationTests {
    private let backend = ChatBackend.codex(model: "gpt-5")

    @Test func emptySearchShowsBoundedChatsBeforeCommands() {
        let sessions = (0..<8).map { index in
            LatticeSession(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!,
                title: "Chat \(index)",
                backend: backend,
                lastUpdated: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        let chats = LatticeCommandPaletteChatNavigation.items(
            sessions: sessions,
            activityLanes: ThreadActivityLaneStore(),
            selectedSessionID: nil
        )
        let command = LatticeCommandPaletteItem(id: "new-chat", title: "New Chat")

        let visible = LatticeCommandPaletteChatNavigation.visibleItems(
            chats: chats,
            commands: [command],
            query: ""
        )

        #expect(visible.count == LatticeCommandPaletteChatNavigation.recentLimit + 1)
        #expect(visible.first?.title == "Chat 7")
        #expect(visible.last?.id == "new-chat")
    }

    @Test func searchReachesChatsOutsideRecentLimitByTitleAndWorkspace() {
        let oldID = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        var sessions = (0..<7).map { index in
            LatticeSession(
                title: "Recent \(index)",
                backend: backend,
                lastUpdated: Date(timeIntervalSince1970: TimeInterval(100 + index))
            )
        }
        sessions.append(
            LatticeSession(
                id: oldID,
                title: "Repair navigation",
                backend: backend,
                workspacePath: "/Users/example/Projects/Lattice",
                lastUpdated: .distantPast
            )
        )
        let chats = LatticeCommandPaletteChatNavigation.items(
            sessions: sessions,
            activityLanes: ThreadActivityLaneStore(),
            selectedSessionID: nil
        )

        let titleMatches = LatticeCommandPaletteChatNavigation.visibleItems(
            chats: chats,
            commands: [],
            query: "repair navigation"
        )
        let workspaceMatches = LatticeCommandPaletteChatNavigation.visibleItems(
            chats: chats,
            commands: [],
            query: "projects lattice"
        )

        #expect(titleMatches.map(\.kind) == [.chat(oldID)])
        #expect(workspaceMatches.map(\.kind) == [.chat(oldID)])
    }

    @Test func failedChatStateIsVisibleAndRecoversWhenWorkRestarts() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
        let session = LatticeSession(
            id: id,
            title: "Background repair",
            backend: backend,
            workspacePath: "/tmp/Lattice"
        )
        var lanes = ThreadActivityLaneStore()
        lanes.apply(.failed("Provider exited"), to: id)

        let failed = LatticeCommandPaletteChatNavigation.items(
            sessions: [session],
            activityLanes: lanes,
            selectedSessionID: nil
        )[0]
        #expect(failed.chatState?.activityStatus == .failed)
        #expect(failed.chatState?.requiresAttention == true)
        #expect(failed.chatState?.hasUnreadActivity == true)
        #expect(failed.detail.contains("Failed"))
        #expect(failed.detail.contains("Needs attention"))

        lanes.apply(.started, to: id)
        let recovered = LatticeCommandPaletteChatNavigation.items(
            sessions: [session],
            activityLanes: lanes,
            selectedSessionID: id
        )[0]
        #expect(recovered.chatState?.activityStatus == .running)
        #expect(recovered.chatState?.requiresAttention == false)
        #expect(recovered.chatState?.isCurrent == true)
        #expect(recovered.detail == "Current chat · Running · Lattice")
    }

    @Test func metadataOnlyChatDoesNotRequireTranscriptHydration() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000777")!
        let session = LatticeSession(
            id: id,
            title: "Cold transcript",
            messages: [],
            transcriptStorage: SessionTranscriptStorage(
                fileName: "cold.json",
                messageCount: 42,
                contentFingerprint: "synthetic-fingerprint",
                lastMessagePreview: "Stored elsewhere"
            ),
            isTranscriptLoaded: false,
            backend: backend,
            workspacePath: "/tmp/Cold"
        )

        let item = LatticeCommandPaletteChatNavigation.items(
            sessions: [session],
            activityLanes: ThreadActivityLaneStore(),
            selectedSessionID: nil
        )[0]

        #expect(item.kind == .chat(id))
        #expect(item.title == "Cold transcript")
        #expect(item.detail == "Cold")
    }
}
