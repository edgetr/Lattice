import Testing
import Foundation
@testable import LatticeCore

@Suite("Session portable archive")
struct SessionPortableArchiveTests {
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
    private let messageA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let messageB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    private let actionID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
    private let attachmentID = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
    private let queuedID = UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!
    private let sessionID = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
    private let threadID = "provider-thread-SECRET-99"

    private func sampleSession(includeQueued: Bool = true, includeDraft: Bool = true) -> LatticeSession {
        LatticeSession(
            id: sessionID,
            title: "Portable chat",
            messages: [
                ChatMessage(id: messageA, role: .user, text: "Hello lattice", date: fixedDate, isPinned: true),
                ChatMessage(id: messageB, role: .assistant, text: "Hi there", date: fixedDate.addingTimeInterval(10), isPinned: false)
            ],
            backend: .codex(model: "gpt-5.5"),
            harnessID: "codex",
            reasoningEffort: .medium,
            harnessThreadID: threadID,
            workspacePath: "/Users/secret/project",
            attachments: [
                ContextAttachment(id: attachmentID, path: "/Users/secret/docs/notes.txt")
            ],
            policy: .smart,
            // cloudAllowed + codex is a consistent triple; localOnly + cloud is rejected at import.
            privacyMode: .cloudAllowed,
            actions: [
                SessionAction(
                    id: actionID,
                    messageID: messageB,
                    kind: .tool,
                    toolKind: .read,
                    title: "Read notes",
                    detail: "read notes.txt",
                    status: .completed,
                    workspaceScoped: true,
                    createdAt: fixedDate,
                    updatedAt: fixedDate.addingTimeInterval(1)
                ),
                SessionAction(
                    id: UUID(),
                    messageID: messageB,
                    kind: .tool,
                    toolKind: .command,
                    title: "Running",
                    detail: "should not export",
                    status: .running,
                    createdAt: fixedDate,
                    updatedAt: fixedDate
                ),
                SessionAction(
                    id: UUID(),
                    messageID: messageB,
                    kind: .approval,
                    title: "Waiting approval",
                    detail: "token=replay-me",
                    status: .waiting,
                    createdAt: fixedDate,
                    updatedAt: fixedDate,
                    approvalProvenance: .init(
                        harnessID: "provider-only-harness-secret",
                        providerName: "provider-only-name",
                        requestID: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!,
                        requestedOptionKinds: ["allow_once"],
                        toolKind: .write,
                        workspaceScoped: true,
                        policy: .ask,
                        policyReason: "provider-only-policy-evidence",
                        actor: .user
                    )
                ),
                SessionAction(
                    id: UUID(),
                    messageID: messageB,
                    kind: .reasoning,
                    title: "Thinking",
                    detail: "User-visible summary only",
                    status: .completed,
                    createdAt: fixedDate,
                    updatedAt: fixedDate
                )
            ],
            queuedFollowUps: includeQueued ? [
                QueuedFollowUp(id: queuedID, text: "Follow up later", date: fixedDate.addingTimeInterval(20))
            ] : [],
            draft: includeDraft ? "unsent composer draft secret" : "",
            isPinned: true,
            isStreaming: true,
            lastUpdated: fixedDate.addingTimeInterval(30)
        )
    }

    // 1. JSON export/import round trip
    @Test func jsonRoundTripPreservesVisibleCanonicalFields() throws {
        let source = sampleSession(includeQueued: true)
        let data = try SessionPortableArchiveExporter.exportData(
            from: source,
            options: .init(includeQueuedFollowUps: true, format: .jsonArchive, exportedAt: fixedDate)
        )
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("lattice.session.archive"))
        let archiveObject = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(archiveObject["version"] as? Int == 2)
        let chatObject = try #require(archiveObject["chat"] as? [String: Any])
        #expect(chatObject["mode"] as? String == "code")
        let routeObject = try #require(chatObject["executionRoute"] as? [String: Any])
        #expect(routeObject["providerID"] as? String == "codex")
        #expect(routeObject["runtimeID"] as? String == "codex")
        #expect(!text.contains(threadID))
        #expect(!text.contains("provider-only-harness-secret"))
        #expect(!text.contains("provider-only-name"))
        #expect(!text.contains("99999999-9999-9999-9999-999999999999"))
        #expect(!text.contains("unsent composer draft"))
        #expect(!text.contains("/Users/secret"))
        #expect(!text.contains(sessionID.uuidString))
        #expect(!text.contains("isStreaming"))
        #expect(!text.contains("\"running\""))
        #expect(!text.contains("\"waiting\""))

        let plan = try SessionPortableArchiveImporter.prepareImport(data: data, existingSessions: [])
        let imported = plan.session
        #expect(imported.id != source.id)
        #expect(imported.title == "Portable chat")
        #expect(imported.messages.count == 2)
        #expect(imported.messages[0].text == "Hello lattice")
        #expect(imported.messages[0].isPinned)
        #expect(imported.messages[0].id != messageA)
        #expect(imported.messages[1].role == .assistant)
        #expect(imported.backend == .codex(model: "gpt-5.5"))
        #expect(imported.harnessID == "codex")
        #expect(imported.executionRoute == ExecutionRoute(mode: .code, providerID: "codex", modelID: "gpt-5.5", runtimeID: "codex"))
        #expect(imported.reasoningEffort == .medium)
        #expect(imported.policy == .smart)
        #expect(imported.privacyMode == .cloudAllowed)
        #expect(imported.isPinned)
        #expect(imported.harnessThreadID == nil)
        #expect(imported.isStreaming == false)
        #expect(imported.draft.isEmpty)
        #expect(imported.workspacePath == nil)
        #expect(imported.attachments.count == 1)
        #expect(imported.attachments[0].isMissing)
        #expect(imported.attachments[0].name == "notes.txt")
        #expect(imported.attachments[0].path.hasPrefix(SessionPortableArchive.missingAttachmentScheme))
        #expect(imported.actions.count == 2) // completed tool + reasoning; running/waiting excluded
        #expect(imported.actions.allSatisfy { $0.status != .running && $0.status != .waiting })
        #expect(imported.actions.contains { $0.kind == .reasoning && $0.title == "Reasoning summary" && $0.detail.isEmpty })
        #expect(imported.queuedFollowUps.count == 1)
        #expect(imported.queuedFollowUps[0].text == "Follow up later")
        #expect(imported.queuedFollowUps[0].id != queuedID)
        #expect(imported.portableArchiveFingerprint != nil)
        #expect(imported.lastUpdated == source.lastUpdated)

        // Explicit exclusion of queued
        let excluded = try SessionPortableArchiveExporter.exportData(
            from: source,
            options: .init(includeQueuedFollowUps: false, format: .jsonArchive, exportedAt: fixedDate)
        )
        let planExcluded = try SessionPortableArchiveImporter.prepareImport(data: excluded, existingSessions: [])
        #expect(planExcluded.session.queuedFollowUps.isEmpty)
        #expect(planExcluded.preview.includesQueuedFollowUps == false)
    }

    // 2. Markdown readability and privacy
    @Test func markdownIsReadableAndNotAnImportArchive() throws {
        let source = sampleSession()
        let markdown = SessionPortableArchiveExporter.exportMarkdown(
            from: source,
            options: .init(includeQueuedFollowUps: false, format: .markdown, exportedAt: fixedDate)
        )
        #expect(markdown.contains("Lattice Chat Export"))
        #expect(markdown.contains("not") && markdown.lowercased().contains("import"))
        #expect(markdown.contains("Hello lattice"))
        #expect(markdown.contains("notes.txt"))
        #expect(markdown.contains("not embedded") || markdown.contains("unavailable"))
        #expect(markdown.contains("Ordinary unsent composer drafts are never included"))
        #expect(!markdown.contains(threadID))
        #expect(!markdown.contains("unsent composer draft secret"))
        #expect(!markdown.contains("/Users/secret/docs/notes.txt"))
        #expect(!markdown.contains("Follow up later")) // queued excluded by default

        let withQueued = SessionPortableArchiveExporter.exportMarkdown(
            from: source,
            options: .init(includeQueuedFollowUps: true, format: .markdown, exportedAt: fixedDate)
        )
        #expect(withQueued.contains("Follow up later"))
        #expect(withQueued.contains("explicitly included"))

        #expect(throws: SessionPortableArchive.ArchiveError.markdownNotImportable) {
            _ = try SessionPortableArchiveImporter.prepareImport(
                data: Data(markdown.utf8),
                existingSessions: []
            )
        }
    }

    @Test func providerFallbackProvenanceSurvivesPortableRoundTrip() throws {
        var source = sampleSession()
        source.executionRoute = ExecutionRoute(
            mode: .code,
            providerID: "codex",
            modelID: "gpt-5.5",
            runtimeID: "codex",
            fallbackFromRuntimeID: "pi"
        )
        source.harnessID = "codex"
        let data = try SessionPortableArchiveExporter.exportData(from: source)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\"fallbackFromRuntimeID\" : \"pi\""))
        let imported = try SessionPortableArchiveImporter.prepareImport(data: data, existingSessions: []).session
        #expect(imported.executionRoute == source.executionRoute)
        #expect(!LegacyOpenCodeBridgePolicy.allows(imported.executionRoute))
    }

    @Test func exportsCodePhaseAndPlanButNeverCompactFlag() throws {
        var source = sampleSession(includeQueued: false)
        source.codePhase = .planAwaitingApproval
        source.codePlan = CodePlanArtifact(title: "Ship feature", body: "1. Read\n2. Edit")
        source.compactContextOnNextSend = true
        let data = try SessionPortableArchiveExporter.exportData(
            from: source,
            options: .init(includeQueuedFollowUps: false, format: .jsonArchive, exportedAt: fixedDate)
        )
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("planAwaitingApproval"))
        #expect(text.contains("Ship feature"))
        #expect(!text.contains("compactContextOnNextSend"))

        let plan = try SessionPortableArchiveImporter.prepareImport(data: data, existingSessions: [])
        #expect(plan.session.codePhase == .planAwaitingApproval)
        #expect(plan.session.codePlan?.title == "Ship feature")
        #expect(plan.session.codePlan?.body.contains("Read") == true)
        #expect(!plan.session.compactContextOnNextSend)

        let withCompact = """
        {"format":"lattice.session.archive","version":2,"exportedAt":"2024-01-01T00:00:00Z","includeQueuedFollowUps":false,"chat":{"title":"x","backendRoute":"codex","backendModel":"gpt-5.5","policy":"Ask","privacyMode":"cloudAllowed","mode":"code","executionRoute":{"mode":"code","providerID":"codex","modelID":"gpt-5.5","runtimeID":"codex"},"messages":[],"attachments":[],"actions":[],"queuedFollowUps":[],"compactContextOnNextSend":true}}
        """
        #expect(throws: SessionPortableArchive.ArchiveError.self) {
            _ = try SessionPortableArchiveImporter.prepareImport(data: Data(withCompact.utf8), existingSessions: [])
        }
    }

    @Test func acceptsAcceptEditsPolicyAndRejectsUnknownPolicy() throws {
        let acceptEdits = """
        {"format":"lattice.session.archive","version":1,"exportedAt":"2024-01-01T00:00:00Z","includeQueuedFollowUps":false,"chat":{"title":"Accept","backendRoute":"codex","backendModel":"gpt-test","policy":"Accept Edits","privacyMode":"cloudAllowed","messages":[],"attachments":[],"actions":[],"queuedFollowUps":[]}}
        """
        let plan = try SessionPortableArchiveImporter.prepareImport(data: Data(acceptEdits.utf8), existingSessions: [])
        #expect(plan.session.policy == .acceptEdits)

        let unknown = """
        {"format":"lattice.session.archive","version":1,"exportedAt":"2024-01-01T00:00:00Z","includeQueuedFollowUps":false,"chat":{"title":"x","backendRoute":"ollama","backendModel":"m","policy":"Mystery Mode","privacyMode":"cloudAllowed","messages":[],"attachments":[],"actions":[],"queuedFollowUps":[]}}
        """
        do {
            _ = try SessionPortableArchiveImporter.prepareImport(data: Data(unknown.utf8), existingSessions: [])
            Issue.record("Unknown policy must fail closed at import validate")
        } catch let error as SessionPortableArchive.ArchiveError {
            #expect(error == .invalidEnum(field: "chat.policy", value: "Mystery Mode") || String(describing: error).contains("chat.policy"))
        }
        #expect(ExecutionPolicy(rawValue: "Mystery Mode") == nil)
        #expect(ExecutionPolicy.decoding("Mystery Mode") == .ask)
    }

    // 3. Malicious archives
    @Test func rejectsMaliciousAndMalformedArchives() throws {
        // Future version
        let future = """
        {"format":"lattice.session.archive","version":99,"exportedAt":"2024-01-01T00:00:00Z","includeQueuedFollowUps":false,"chat":{"title":"x","backendRoute":"ollama","backendModel":"m","policy":"Ask","privacyMode":"cloudAllowed","messages":[],"attachments":[],"actions":[],"queuedFollowUps":[]}}
        """
        #expect(throws: SessionPortableArchive.ArchiveError.unsupportedVersion(99)) {
            _ = try SessionPortableArchiveImporter.prepareImport(data: Data(future.utf8), existingSessions: [])
        }

        // Provider thread / sensitive fields
        let withThread = """
        {"format":"lattice.session.archive","version":1,"exportedAt":"2024-01-01T00:00:00Z","includeQueuedFollowUps":false,"harnessThreadID":"abc","chat":{"title":"x","backendRoute":"ollama","backendModel":"m","policy":"Ask","privacyMode":"cloudAllowed","messages":[],"attachments":[],"actions":[],"queuedFollowUps":[]}}
        """
        do {
            _ = try SessionPortableArchiveImporter.prepareImport(data: Data(withThread.utf8), existingSessions: [])
            Issue.record("Expected sensitive field rejection")
        } catch let error as SessionPortableArchive.ArchiveError {
            #expect(error == .unknownSensitiveField("harnessThreadID") || String(describing: error).contains("harnessThreadID"))
        }

        // Running/waiting actions
        let running = """
        {"format":"lattice.session.archive","version":1,"exportedAt":"2024-01-01T00:00:00Z","includeQueuedFollowUps":false,"chat":{"title":"x","backendRoute":"ollama","backendModel":"m","policy":"Ask","privacyMode":"cloudAllowed","messages":[{"role":"user","text":"hi","date":"2024-01-01T00:00:00Z","isPinned":false}],"attachments":[],"actions":[{"kind":"tool","title":"t","detail":"d","status":"running","workspaceScoped":false,"createdAt":"2024-01-01T00:00:00Z","updatedAt":"2024-01-01T00:00:00Z","messageIndex":0}],"queuedFollowUps":[]}}
        """
        #expect(throws: SessionPortableArchive.ArchiveError.self) {
            _ = try SessionPortableArchiveImporter.prepareImport(data: Data(running.utf8), existingSessions: [])
        }

        // Bad enum / date / UUID-like invalid role
        let badRole = """
        {"format":"lattice.session.archive","version":1,"exportedAt":"2024-01-01T00:00:00Z","includeQueuedFollowUps":false,"chat":{"title":"x","backendRoute":"ollama","backendModel":"m","policy":"Ask","privacyMode":"cloudAllowed","messages":[{"role":"hacker","text":"hi","date":"2024-01-01T00:00:00Z","isPinned":false}],"attachments":[],"actions":[],"queuedFollowUps":[]}}
        """
        #expect(throws: SessionPortableArchive.ArchiveError.self) {
            _ = try SessionPortableArchiveImporter.prepareImport(data: Data(badRole.utf8), existingSessions: [])
        }

        let badDate = """
        {"format":"lattice.session.archive","version":1,"exportedAt":"not-a-date","includeQueuedFollowUps":false,"chat":{"title":"x","backendRoute":"ollama","backendModel":"m","policy":"Ask","privacyMode":"cloudAllowed","messages":[],"attachments":[],"actions":[],"queuedFollowUps":[]}}
        """
        #expect(throws: SessionPortableArchive.ArchiveError.invalidDate("exportedAt")) {
            _ = try SessionPortableArchiveImporter.prepareImport(data: Data(badDate.utf8), existingSessions: [])
        }

        // Oversized string
        let huge = String(repeating: "a", count: SessionPortableArchive.maxStringLength + 10)
        let hugeJSON = """
        {"format":"lattice.session.archive","version":1,"exportedAt":"2024-01-01T00:00:00Z","includeQueuedFollowUps":false,"chat":{"title":"x","backendRoute":"ollama","backendModel":"m","policy":"Ask","privacyMode":"cloudAllowed","messages":[{"role":"user","text":"\(huge)","date":"2024-01-01T00:00:00Z","isPinned":false}],"attachments":[],"actions":[],"queuedFollowUps":[]}}
        """
        #expect(throws: SessionPortableArchive.ArchiveError.self) {
            _ = try SessionPortableArchiveImporter.prepareImport(data: Data(hugeJSON.utf8), existingSessions: [])
        }

        // Hidden/secret-like raw fields
        let secretField = """
        {"format":"lattice.session.archive","version":1,"exportedAt":"2024-01-01T00:00:00Z","includeQueuedFollowUps":false,"apiKey":"sk-secret","chat":{"title":"x","backendRoute":"ollama","backendModel":"m","policy":"Ask","privacyMode":"cloudAllowed","messages":[],"attachments":[],"actions":[],"queuedFollowUps":[]}}
        """
        #expect(throws: SessionPortableArchive.ArchiveError.self) {
            _ = try SessionPortableArchiveImporter.prepareImport(data: Data(secretField.utf8), existingSessions: [])
        }

        // Deep nesting
        var deep: Any = ["leaf": true]
        for _ in 0..<(SessionPortableArchive.maxJSONNestingDepth + 5) {
            deep = ["n": deep]
        }
        let deepRoot: [String: Any] = [
            "format": SessionPortableArchive.formatID,
            "version": 1,
            "exportedAt": "2024-01-01T00:00:00Z",
            "includeQueuedFollowUps": false,
            "chat": deep
        ]
        let deepData = try JSONSerialization.data(withJSONObject: deepRoot)
        #expect(throws: SessionPortableArchive.ArchiveError.self) {
            _ = try SessionPortableArchiveImporter.prepareImport(data: deepData, existingSessions: [])
        }

        // Present-but-wrong types never receive legacy defaults.
        let wrongTypes = [
            #"{"format":"lattice.session.archive","version":1,"exportedAt":"2024-01-01T00:00:00Z","includeQueuedFollowUps":"false","chat":{"title":"x","backendRoute":"ollama","backendModel":"m","policy":"Ask","privacyMode":"cloudAllowed"}}"#,
            #"{"format":"lattice.session.archive","version":1,"exportedAt":"2024-01-01T00:00:00Z","chat":{"title":"x","isPinned":1,"backendRoute":"ollama","backendModel":"m","policy":"Ask","privacyMode":"cloudAllowed"}}"#,
            #"{"format":"lattice.session.archive","version":1,"exportedAt":"2024-01-01T00:00:00Z","chat":{"title":"x","backendRoute":"ollama","backendModel":"m","policy":"Ask","privacyMode":"cloudAllowed","messages":{}}}"#
        ]
        for archive in wrongTypes {
            #expect(throws: SessionPortableArchive.ArchiveError.self) {
                _ = try SessionPortableArchiveImporter.prepareImport(data: Data(archive.utf8), existingSessions: [])
            }
        }

        let hiddenQueue = #"{"format":"lattice.session.archive","version":1,"exportedAt":"2024-01-01T00:00:00Z","includeQueuedFollowUps":false,"chat":{"title":"x","backendRoute":"ollama","backendModel":"m","policy":"Ask","privacyMode":"cloudAllowed","queuedFollowUps":[{"text":"send me","date":"2024-01-01T00:00:00Z"}]}}"#
        #expect(throws: SessionPortableArchive.ArchiveError.self) {
            _ = try SessionPortableArchiveImporter.prepareImport(data: Data(hiddenQueue.utf8), existingSessions: [])
        }
    }

    // 4. Oversize file rejection
    @Test func rejectsOversizeBeforeDecode() {
        let oversize = Data(repeating: 0x41, count: SessionPortableArchive.maxArchiveBytes + 1)
        do {
            _ = try SessionPortableArchiveImporter.prepareImport(data: oversize, existingSessions: [])
            Issue.record("Expected oversize rejection")
        } catch let error as SessionPortableArchive.ArchiveError {
            if case .fileTooLarge(let bytes, let limit) = error {
                #expect(bytes == oversize.count)
                #expect(limit == SessionPortableArchive.maxArchiveBytes)
            } else {
                Issue.record("Expected fileTooLarge, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    // 5. Attachment path traversal / no path open
    @Test func attachmentPathsAreNeverResolvedAndMarkedMissing() throws {
        let traversalNames = [
            "../../etc/passwd",
            "/etc/passwd",
            #"C:\Windows\System32\config"#,
            "file:///etc/passwd",
            "notes.txt"
        ]
        for name in traversalNames {
            let json = """
            {"format":"lattice.session.archive","version":1,"exportedAt":"2024-01-01T00:00:00Z","includeQueuedFollowUps":false,"chat":{"title":"x","backendRoute":"ollama","backendModel":"m","policy":"Ask","privacyMode":"cloudAllowed","messages":[],"attachments":[{"name":\(jsonString(name)),"kind":"file","availability":"metadata-only"}],"actions":[],"queuedFollowUps":[]}}
            """
            let plan = try SessionPortableArchiveImporter.prepareImport(data: Data(json.utf8), existingSessions: [])
            let attachment = try #require(plan.session.attachments.first)
            #expect(attachment.isMissing)
            #expect(!attachment.path.hasPrefix("/"))
            #expect(!attachment.path.contains(".."))
            #expect(attachment.path.hasPrefix(SessionPortableArchive.missingAttachmentScheme))
            // Proof: imported path is not a real filesystem location that FileManager would open as a local path.
            #expect(!FileManager.default.fileExists(atPath: attachment.path))
        }

        // Explicit path field is rejected
        let withPath = """
        {"format":"lattice.session.archive","version":1,"exportedAt":"2024-01-01T00:00:00Z","includeQueuedFollowUps":false,"chat":{"title":"x","backendRoute":"ollama","backendModel":"m","policy":"Ask","privacyMode":"cloudAllowed","messages":[],"attachments":[{"name":"a.txt","path":"/tmp/secret","kind":"file"}],"actions":[],"queuedFollowUps":[]}}
        """
        #expect(throws: SessionPortableArchive.ArchiveError.self) {
            _ = try SessionPortableArchiveImporter.prepareImport(data: Data(withPath.utf8), existingSessions: [])
        }
    }

    // 6. Legacy-compatible safe defaults
    @Test func legacyCompatibleOmissionsUseSafeDefaults() throws {
        // Minimal chat object without optional collections / flags.
        let minimal = """
        {"format":"lattice.session.archive","version":1,"exportedAt":"2024-01-01T00:00:00Z","chat":{"title":"Legacy","backendRoute":"appleIntelligence","policy":"Ask","privacyMode":"cloudAllowed"}}
        """
        let plan = try SessionPortableArchiveImporter.prepareImport(data: Data(minimal.utf8), existingSessions: [])
        #expect(plan.session.title == "Legacy")
        #expect(plan.session.messages.isEmpty)
        #expect(plan.session.actions.isEmpty)
        #expect(plan.session.attachments.isEmpty)
        #expect(plan.session.queuedFollowUps.isEmpty)
        #expect(plan.session.isPinned == false)
        #expect(plan.session.isStreaming == false)
        #expect(plan.session.draft.isEmpty)
        #expect(plan.session.backend == .appleIntelligence)
        #expect(plan.session.harnessThreadID == nil)
    }

    @Test func modelLessArchivesPreserveMissingAndEmptyModelForEveryModelRoute() throws {
        let routes = ["codex", "grok", "opencode", "antigravity", "ollama"]
        for model in [String?.none, ""] {
            for route in routes {
                let modelField = model.map { "\"backendModel\":\(jsonString($0))," } ?? ""
                let archive = """
                {"format":"lattice.session.archive","version":1,"exportedAt":"2024-01-01T00:00:00Z","chat":{"title":"Model-less","backendRoute":"\(route)",\(modelField)"policy":"Ask","privacyMode":"cloudAllowed"}}
                """
                let plan = try SessionPortableArchiveImporter.prepareImport(data: Data(archive.utf8), existingSessions: [])
                switch route {
                case "codex": #expect(plan.session.backend == .codex(model: ""))
                case "grok": #expect(plan.session.backend == .grok(model: ""))
                case "opencode": #expect(plan.session.backend == .openCode(model: ""))
                case "antigravity": #expect(plan.session.backend == .antigravity(model: ""))
                case "ollama": #expect(plan.session.backend == .ollama(model: ""))
                default: Issue.record("Unexpected route \(route)")
                }
            }
        }
    }

    // 7. Collision-safe remapped IDs + no overwrite
    @Test func remapsIDsAndNeverOverwritesExistingSessions() throws {
        let existing = sampleSession()
        let data = try SessionPortableArchiveExporter.exportData(
            from: existing,
            options: .init(includeQueuedFollowUps: true, format: .jsonArchive, exportedAt: fixedDate)
        )
        var counter = 0
        let plan = try SessionPortableArchiveImporter.prepareImport(
            data: data,
            existingSessions: [existing],
            now: fixedDate,
            idGenerator: {
                counter += 1
                return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", counter))!
            }
        )
        #expect(plan.session.id != existing.id)
        #expect(Set(plan.session.messages.map(\.id)).isDisjoint(with: Set(existing.messages.map(\.id))))
        #expect(Set(plan.session.actions.map(\.id)).isDisjoint(with: Set(existing.actions.map(\.id))))

        let commit = SessionPortableArchiveImporter.commit(
            plan: plan,
            into: [existing],
            selectedSessionID: existing.id
        )
        #expect(commit.sessions.count == 2)
        #expect(commit.sessions.contains(where: { $0.id == existing.id }))
        #expect(commit.sessions.contains(where: { $0.id == plan.session.id }))
        #expect(commit.selectedSessionID == existing.id) // selection unchanged by pure commit
        #expect(commit.sessions.first(where: { $0.id == existing.id })?.title == existing.title)

        // Even a broken/repeating injected generator cannot collide with existing or newly allocated IDs.
        let repeated = existing.id
        let collisionPlan = try SessionPortableArchiveImporter.prepareImport(
            data: data,
            existingSessions: [existing],
            idGenerator: { repeated }
        )
        let allImportedIDs = [collisionPlan.session.id]
            + collisionPlan.session.messages.map(\.id)
            + collisionPlan.session.actions.map(\.id)
            + collisionPlan.session.attachments.map(\.id)
            + collisionPlan.session.queuedFollowUps.map(\.id)
        #expect(Set(allImportedIDs).count == allImportedIDs.count)
        #expect(!allImportedIDs.contains(repeated))
    }

    // 8. Duplicate fingerprint detection
    @Test func duplicateFingerprintDetectionIsDeterministicAndPrivacySafe() throws {
        let source = sampleSession()
        let data = try SessionPortableArchiveExporter.exportData(
            from: source,
            options: .init(includeQueuedFollowUps: false, format: .jsonArchive, exportedAt: fixedDate)
        )
        let first = try SessionPortableArchiveImporter.prepareImport(data: data, existingSessions: [])
        let fingerprint = try #require(first.session.portableArchiveFingerprint)
        #expect(fingerprint.count == 64) // sha256 hex
        #expect(!fingerprint.contains(threadID))
        #expect(!fingerprint.contains(sessionID.uuidString))

        let sourceDuplicate = try SessionPortableArchiveImporter.prepareImport(data: data, existingSessions: [source])
        #expect(sourceDuplicate.preview.isDuplicate)
        #expect(sourceDuplicate.preview.duplicateSessionIDs == [source.id])

        let storedSession = first.session
        let second = try SessionPortableArchiveImporter.prepareImport(data: data, existingSessions: [storedSession])
        #expect(second.preview.isDuplicate)
        #expect(second.preview.duplicateSessionIDs == [storedSession.id])
        #expect(second.preview.contentFingerprint == fingerprint)

        // Distinct content is not a duplicate
        var other = source
        other.title = "Different chat"
        let otherData = try SessionPortableArchiveExporter.exportData(
            from: other,
            options: .init(includeQueuedFollowUps: false, format: .jsonArchive, exportedAt: fixedDate)
        )
        let otherPlan = try SessionPortableArchiveImporter.prepareImport(data: otherData, existingSessions: [storedSession])
        #expect(!otherPlan.preview.isDuplicate)
    }

    // 9. Preview before confirm + non-destructive commit boundary
    @Test func previewIsNonMutatingAndCommitIsAdditiveOnly() throws {
        let existing = LatticeSession(title: "Keep me", backend: .ollama(model: "llama3.2:latest"))
        let existingID = existing.id
        let source = sampleSession()
        let data = try SessionPortableArchiveExporter.exportData(
            from: source,
            options: .init(includeQueuedFollowUps: true, format: .jsonArchive, exportedAt: fixedDate)
        )

        let before = [existing]
        let plan = try SessionPortableArchiveImporter.prepareImport(data: data, existingSessions: before)
        // prepareImport must not require mutation of caller's array — we only passed a copy value.
        #expect(before.count == 1)
        #expect(before[0].id == existingID)
        #expect(plan.preview.messageCount == 2)
        #expect(plan.preview.actionCount == 2)
        #expect(plan.preview.attachmentCount == 1)
        #expect(plan.preview.queuedFollowUpCount == 1)
        #expect(plan.preview.policy == "Smart")
        #expect(plan.preview.privacyMode == "cloudAllowed")
        #expect(plan.preview.summaryLines.contains(where: { $0.contains("new chat") || $0.contains("Import creates") }))

        let commit = SessionPortableArchiveImporter.commit(plan: plan, into: before, selectedSessionID: existingID)
        #expect(commit.sessions.count == 2)
        #expect(commit.sessions.contains(where: { $0.id == existingID && $0.title == "Keep me" }))
        #expect(commit.importedSessionID == plan.session.id)
        #expect(commit.sessions.first(where: { $0.id == plan.session.id })?.isStreaming == false)
        #expect(commit.sessions.first(where: { $0.id == plan.session.id })?.queuedFollowUps.isEmpty == false)
    }

    // 10. Privacy proof for archives and Markdown
    @Test func privacyProofNoSecretsThreadsOrHiddenReasoning() throws {
        var source = sampleSession()
        source.actions.append(
            SessionAction(
                id: UUID(),
                messageID: messageB,
                kind: .tool,
                title: "Leak",
                detail: "api_key=sk-supersecret token=abc",
                status: .completed,
                createdAt: fixedDate,
                updatedAt: fixedDate
            )
        )
        let json = try SessionPortableArchiveExporter.exportData(
            from: source,
            options: .init(includeQueuedFollowUps: true, format: .jsonArchive, exportedAt: fixedDate)
        )
        let md = try SessionPortableArchiveExporter.exportData(
            from: source,
            options: .init(includeQueuedFollowUps: true, format: .markdown, exportedAt: fixedDate)
        )
        for data in [json, md] {
            #expect(SessionPortableArchivePrivacy.assertExportPrivacy(in: data).isEmpty)
            #expect(!SessionPortableArchivePrivacy.containsProviderThreadID(in: data, threadID: threadID))
            let text = try #require(String(data: data, encoding: .utf8))
            #expect(!text.contains("sk-supersecret"))
            #expect(!text.contains("User-visible summary only"))
            #expect(!text.contains("read notes.txt"))
            #expect(!text.contains("unsent composer draft secret"))
            #expect(!text.contains("/Users/secret/project"))
            #expect(!text.lowercased().contains(sessionID.uuidString.lowercased()))
            #expect(!text.contains("provider-thread-SECRET-99"))
        }
        // Attachment file contents never embedded
        #expect(!String(data: json, encoding: .utf8)!.contains("attachment bytes"))
    }

    @Test func sessionPersistenceDecodesMissingFingerprintAndAttachmentFlags() throws {
        // Encode a real session, then drop new keys so decoder defaults are exercised.
        let session = LatticeSession(title: "Legacy", backend: .ollama(model: "m"))
        let encoded = try JSONEncoder().encode([session])
        var object = try JSONSerialization.jsonObject(with: encoded) as! [[String: Any]]
        object[0].removeValue(forKey: "portableArchiveFingerprint")
        if var attachments = object[0]["attachments"] as? [[String: Any]], !attachments.isEmpty {
            attachments[0].removeValue(forKey: "isMissing")
            object[0]["attachments"] = attachments
        } else {
            object[0]["attachments"] = [[
                "id": UUID().uuidString,
                "path": "/tmp/legacy.txt"
            ]]
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode([LatticeSession].self, from: data)
        #expect(decoded[0].portableArchiveFingerprint == nil)
        #expect(decoded[0].attachments.allSatisfy { $0.isMissing == false })
    }

    @Test func importerRejectsHarnessRouteMismatch() throws {
        let archive = #"{"format":"lattice.session.archive","version":1,"exportedAt":"2024-01-01T00:00:00Z","includeQueuedFollowUps":false,"chat":{"title":"Mismatch","backendRoute":"codex","backendModel":"gpt-5.5","harnessID":"hermes","policy":"Ask","privacyMode":"cloudAllowed","messages":[],"attachments":[],"actions":[],"queuedFollowUps":[]}}"#.data(using: .utf8)!
        #expect(throws: SessionPortableArchive.ArchiveError.invalidEnum(field: "chat.harnessID", value: "hermes")) {
            _ = try SessionPortableArchiveImporter.prepareImport(data: archive, existingSessions: [])
        }
    }

    private func jsonString(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)
        return String(data: data, encoding: .utf8)!
    }
}
