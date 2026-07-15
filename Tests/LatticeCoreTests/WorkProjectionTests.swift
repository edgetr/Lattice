import Foundation
import Testing
@testable import LatticeCore

@Suite("Work projection and work semantics")
struct WorkProjectionTests {
    private let messageID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let originMessageID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let approvalID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let questionID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    private let taskID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
    private let failureID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
    private let artifactID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
    private let fixed = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Mode depth

    @Test func richProjectionIsWorkOnlyCodeConciseLocalCollapsed() {
        let actions = [waitingApproval()]
        let work = WorkProjection.project(
            mode: .work,
            actions: actions,
            liveApprovalIDs: [approvalID]
        )
        #expect(work.depth == .rich)
        #expect(work.isRich)
        #expect(work.actionable?.kind == .liveApproval)

        let code = WorkProjection.project(
            mode: .code,
            actions: actions,
            liveApprovalIDs: [approvalID]
        )
        #expect(code.depth == .concise)
        #expect(code.actionable == nil)
        #expect(code.log.isEmpty)

        let local = WorkProjection.project(
            mode: .local,
            actions: actions,
            liveApprovalIDs: [approvalID]
        )
        #expect(local.depth == .collapsed)
        #expect(local.actionable == nil)
        #expect(local.log.isEmpty)
    }

    // MARK: - Actionable ranking

    @Test func ranksLiveApprovalAboveQuestionTaskFailureAndArtifact() {
        let actions = [
            completedArtifact(createdAt: fixed),
            retryableFailure(createdAt: fixed.addingTimeInterval(1)),
            userTask(createdAt: fixed.addingTimeInterval(2)),
            waitingQuestion(createdAt: fixed.addingTimeInterval(3)),
            waitingApproval(createdAt: fixed.addingTimeInterval(4))
        ]

        let withApproval = WorkProjection.project(
            mode: .work,
            actions: actions,
            liveApprovalIDs: [approvalID],
            liveQuestionIDs: [questionID],
            retryableActionIDs: [failureID]
        )
        #expect(withApproval.actionable?.id == approvalID)
        #expect(withApproval.actionable?.kind == .liveApproval)
        #expect(withApproval.actionable?.allowsMarkConfirm == false)

        let withoutApproval = WorkProjection.project(
            mode: .work,
            actions: actions,
            liveApprovalIDs: [],
            liveQuestionIDs: [questionID],
            retryableActionIDs: [failureID]
        )
        #expect(withoutApproval.actionable?.id == questionID)
        #expect(withoutApproval.actionable?.kind == .liveQuestion)

        let withoutLive = WorkProjection.project(
            mode: .work,
            actions: actions,
            liveApprovalIDs: [],
            liveQuestionIDs: [],
            retryableActionIDs: [failureID]
        )
        #expect(withoutLive.actionable?.id == taskID)
        #expect(withoutLive.actionable?.kind == .userTaskConfirmation)
        #expect(withoutLive.actionable?.allowsMarkConfirm == true)

        let tasksConfirmed = actions.map { action -> SessionAction in
            guard action.id == taskID else { return action }
            return WorkProjection.applyingTaskMark(.confirmed, to: action) ?? action
        }
        let afterConfirm = WorkProjection.project(mode: .work, actions: tasksConfirmed, retryableActionIDs: [failureID])
        #expect(afterConfirm.actionable?.id == failureID)
        #expect(afterConfirm.actionable?.kind == .retryableFailure)

        let withoutFailure = tasksConfirmed.filter { $0.id != failureID }
        let artifactOnly = WorkProjection.project(mode: .work, actions: withoutFailure)
        #expect(artifactOnly.actionable?.id == artifactID)
        #expect(artifactOnly.actionable?.kind == .artifactOperation)
        #expect(artifactOnly.actionable?.artifactLocator == "Deliverables/report.md")
    }

    @Test func providerBoundApprovalsAndQuestionsRequireLiveIDs() {
        let actions = [waitingApproval(), waitingQuestion()]
        let restored = WorkProjection.project(mode: .work, actions: actions)
        #expect(restored.actionable == nil)

        let liveApproval = WorkProjection.project(
            mode: .work,
            actions: actions,
            liveApprovalIDs: [approvalID]
        )
        #expect(liveApproval.actionable?.id == approvalID)

        let liveQuestion = WorkProjection.project(
            mode: .work,
            actions: actions,
            liveQuestionIDs: [questionID]
        )
        #expect(liveQuestion.actionable?.id == questionID)
    }

    @Test func markConfirmOnlyUserOwnedTaskSteps() throws {
        let task = userTask()
        let plan = SessionAction(
            id: UUID(),
            messageID: messageID,
            kind: .plan,
            title: "Plan",
            detail: "",
            status: .waiting,
            work: SessionWorkSemantics(kind: .planStep, ownership: .userOwned, stepKey: "1")
        )
        let providerTask = SessionAction(
            id: UUID(),
            messageID: messageID,
            kind: .plan,
            title: "Provider task",
            detail: "",
            status: .waiting,
            work: SessionWorkSemantics(kind: .taskStep, ownership: .providerBound, stepKey: "p1")
        )
        let approval = waitingApproval()

        #expect(WorkProjection.canMarkOrConfirm(task))
        #expect(!WorkProjection.canMarkOrConfirm(plan))
        #expect(!WorkProjection.canMarkOrConfirm(providerTask))
        #expect(!WorkProjection.canMarkOrConfirm(approval))
        #expect(WorkProjection.applyingTaskMark(.checked, to: plan) == nil)
        #expect(WorkProjection.applyingTaskMark(.confirmed, to: approval) == nil)

        let marked = try #require(WorkProjection.applyingTaskMark(.confirmed, to: task, at: fixed))
        #expect(marked.work?.taskMark == .confirmed)
        #expect(marked.status == .completed)
        #expect(marked.updatedAt == fixed)
    }

    @Test func userOwnedQuestionCanBeAnsweredExactlyOnce() throws {
        let answerID = UUID(uuidString: "12121212-1212-1212-1212-121212121212")!
        let question = SessionAction(
            id: questionID,
            messageID: messageID,
            kind: .harness,
            title: "Choose a format",
            detail: "PDF or Markdown",
            status: .waiting,
            work: .init(kind: .question, ownership: .userOwned)
        )
        #expect(WorkProjection.canAnswer(question))
        let answered = try #require(WorkProjection.applyingAnswer(messageID: answerID, to: question, at: fixed))
        #expect(answered.status == .completed)
        #expect(answered.work?.resolutionMessageID == answerID)
        #expect(WorkProjection.applyingAnswer(messageID: UUID(), to: answered) == nil)

        let providerQuestion = waitingQuestion()
        #expect(!WorkProjection.canAnswer(providerQuestion))
        #expect(WorkProjection.applyingAnswer(messageID: answerID, to: providerQuestion) == nil)
    }

    @Test func exposesOriginIDsAndExplicitArtifactOnly() {
        let originAction = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let action = SessionAction(
            id: artifactID,
            messageID: messageID,
            kind: .tool,
            title: "Deliverable",
            detail: "/secret/should-not-be-used-as-path",
            status: .completed,
            createdAt: fixed,
            updatedAt: fixed,
            work: SessionWorkSemantics(
                kind: .artifact,
                ownership: .userOwned,
                artifactLocator: "out/result.pdf",
                originMessageID: originMessageID,
                originActionID: originAction
            )
        )
        let snapshot = WorkProjection.project(mode: .work, actions: [action])
        #expect(snapshot.actionable?.originMessageID == originMessageID)
        #expect(snapshot.actionable?.originActionID == originAction)
        #expect(snapshot.actionable?.artifactLocator == "out/result.pdf")
        // Compact log excludes the current actionable entry to avoid double-rendering.
        #expect(snapshot.log.allSatisfy { $0.id != artifactID })

        // Without explicit work artifact locator, detail is never treated as a path.
        let legacyTool = SessionAction(
            messageID: messageID,
            kind: .tool,
            title: "Edit",
            detail: "Sources/App.swift",
            status: .completed
        )
        let legacy = WorkProjection.project(mode: .work, actions: [legacyTool])
        #expect(legacy.actionable == nil)
        #expect(legacy.log.isEmpty)
    }

    @Test func logIsChronologicalAndBounded() {
        var actions: [SessionAction] = []
        for index in 0..<30 {
            actions.append(
                SessionAction(
                    id: UUID(),
                    messageID: messageID,
                    kind: .plan,
                    title: "Step \(index)",
                    detail: "",
                    status: .completed,
                    createdAt: fixed.addingTimeInterval(TimeInterval(index)),
                    updatedAt: fixed.addingTimeInterval(TimeInterval(index)),
                    work: SessionWorkSemantics(
                        kind: .planStep,
                        ownership: .userOwned,
                        stepKey: "s\(index)"
                    )
                )
            )
        }
        let snapshot = WorkProjection.project(mode: .work, actions: actions, logLimit: 5)
        #expect(snapshot.log.count == 5)
        #expect(snapshot.log.map(\.createdAt) == snapshot.log.map(\.createdAt).sorted())
        #expect(snapshot.log.first?.createdAt == fixed.addingTimeInterval(25))
    }

    @Test func actionableItemIsNotDuplicatedInCompactLog() {
        let snapshot = WorkProjection.project(
            mode: .work,
            actions: [userTask(), completedArtifact()],
            logLimit: 10
        )
        #expect(snapshot.actionable?.id == taskID)
        #expect(!snapshot.log.contains { $0.id == taskID })
        #expect(snapshot.log.contains { $0.id == artifactID })
    }

    @Test func accessibilityCopyNamesStatusAndOperations() throws {
        let action = waitingApproval()
        let request = try #require(WorkProjection.project(
            mode: .work,
            actions: [action],
            liveApprovalIDs: [approvalID]
        ).actionable)
        let copy = WorkItemPresentationPolicy.presentation(for: request, action: action)
        #expect(copy.heading == "Approval required")
        #expect(copy.status == "Waiting for your decision")
        #expect(copy.accessibilityLabel == "Approval required, Allow write, Waiting for your decision")
        #expect(copy.secondaryAction == "Jump to originating message")
        #expect(WorkItemPresentationPolicy.statusLabel(for: .interrupted) == "Interrupted")
    }

    @Test func dockLayoutStacksAtCompactWidths() {
        #expect(WorkDockLayoutPolicy.actionLayout(forAvailableWidth: 360) == .stacked)
        #expect(WorkDockLayoutPolicy.actionLayout(forAvailableWidth: 519) == .stacked)
        #expect(WorkDockLayoutPolicy.actionLayout(forAvailableWidth: 520) == .horizontal)
        #expect(WorkDockLayoutPolicy.actionLayout(forAvailableWidth: 760) == .horizontal)
    }

    @Test func artifactPolicyAllowsOnlyExplicitSafeWorkspaceDocuments() {
        let workspace = URL(fileURLWithPath: "/tmp")
        #expect(WorkArtifactAccessPolicy.canOpen(locator: "Lattice/Deliverables/report.pdf", workspace: workspace))
        #expect(!WorkArtifactAccessPolicy.canOpen(locator: "bin/tool", workspace: workspace))
        #expect(!WorkArtifactAccessPolicy.canOpen(locator: "/Applications/Unsafe.app", workspace: workspace))
        #expect(!WorkArtifactAccessPolicy.canOpen(locator: "https://example.com/report.pdf", workspace: workspace))
        #expect(WorkArtifactAccessPolicy.resolvedFileURL(locator: "out/result.md", workspace: workspace)?.path == "/tmp/out/result.md")
    }

    // MARK: - Codable migration

    @Test func legacySessionActionJSONDecodesWithoutWorkPayload() throws {
        let id = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        let message = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
        // Pre-work-payload shape: no `work` key. decodeIfPresent must keep compatibility.
        let legacyObject: [String: Any] = [
            "id": id.uuidString,
            "messageID": message.uuidString,
            "kind": "tool",
            "title": "Read",
            "detail": "README.md",
            "status": "completed",
            "workspaceScoped": true,
            "createdAt": fixed.timeIntervalSinceReferenceDate,
            "updatedAt": fixed.addingTimeInterval(1).timeIntervalSinceReferenceDate
        ]
        let data = try JSONSerialization.data(withJSONObject: legacyObject)
        let decoded = try JSONDecoder().decode(SessionAction.self, from: data)
        #expect(decoded.id == id)
        #expect(decoded.work == nil)
        #expect(decoded.approvalProvenance == nil)
        #expect(decoded.status == .completed)

        let encoded = try JSONEncoder().encode(
            SessionAction(
                id: id,
                messageID: message,
                kind: .tool,
                title: "Read",
                detail: "README.md",
                status: .completed
            )
        )
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["work"] == nil)
    }

    @Test func workSemanticsRoundTripThroughSessionActionJSON() throws {
        let work = SessionWorkSemantics(
            kind: .question,
            ownership: .providerBound,
            stepKey: "q1\n" + String(repeating: "x", count: 100),
            originMessageID: originMessageID
        )
        #expect(work.stepKey?.contains("\n") == false)
        #expect((work.stepKey?.count ?? 0) <= 64)

        let action = SessionAction(
            id: questionID,
            messageID: messageID,
            kind: .harness,
            title: "Question",
            detail: "bounded prompt summary",
            status: .waiting,
            work: work
        )
        let data = try JSONEncoder().encode(action)
        let decoded = try JSONDecoder().decode(SessionAction.self, from: data)
        #expect(decoded.work == action.work)
        #expect(decoded.work?.kind == .question)
        #expect(decoded.work?.originMessageID == originMessageID)

        // Outcome and artifact fields are role-gated.
        let artifact = SessionWorkSemantics(
            kind: .artifact,
            ownership: .userOwned,
            artifactLocator: "docs/out.md",
            outcomeKind: .succeeded
        )
        #expect(artifact.artifactLocator == "docs/out.md")
        #expect(artifact.outcomeKind == nil)

        let outcome = SessionWorkSemantics(
            kind: .outcome,
            ownership: .userOwned,
            artifactLocator: "should-drop",
            outcomeKind: .partial
        )
        #expect(outcome.artifactLocator == nil)
        #expect(outcome.outcomeKind == .partial)
    }

    // MARK: - Restore reconciliation

    @Test func restoreInterruptsProviderLiveStateButKeepsUserTasksAndTerminals() throws {
        let pendingTask = userTask(status: .waiting, createdAt: fixed)
        let liveApproval = waitingApproval(createdAt: fixed.addingTimeInterval(1))
        let liveQuestion = waitingQuestion(createdAt: fixed.addingTimeInterval(2))
        let runningTool = SessionAction(
            id: UUID(),
            messageID: messageID,
            kind: .tool,
            title: "running",
            detail: "",
            status: .running,
            createdAt: fixed.addingTimeInterval(3),
            updatedAt: fixed.addingTimeInterval(3)
        )
        let terminalArtifact = completedArtifact(createdAt: fixed.addingTimeInterval(4))
        let terminalOutcome = SessionAction(
            id: UUID(),
            messageID: messageID,
            kind: .plan,
            title: "Done",
            detail: "",
            status: .completed,
            createdAt: fixed.addingTimeInterval(5),
            updatedAt: fixed.addingTimeInterval(5),
            work: SessionWorkSemantics(kind: .outcome, ownership: .userOwned, outcomeKind: .succeeded)
        )

        let session = LatticeSession(
            title: "work restore",
            backend: .openCode(model: "m"),
            executionRoute: ExecutionRoute(mode: .work, providerID: "opencode", modelID: "m", runtimeID: "hermes"),
            actions: [pendingTask, liveApproval, liveQuestion, runningTool, terminalArtifact, terminalOutcome],
            isStreaming: true
        )
        let restored = SessionPersistence.restoreRuntimeState([session])
        let actions = restored[0].actions
        #expect(restored[0].isStreaming == false)

        let task = try #require(actions.first { $0.id == taskID })
        #expect(task.status == .waiting)

        let approval = try #require(actions.first { $0.id == approvalID })
        #expect(approval.status == .interrupted)

        let question = try #require(actions.first { $0.id == questionID })
        #expect(question.status == .interrupted)

        let tool = try #require(actions.first { $0.id == runningTool.id })
        #expect(tool.status == .interrupted)

        #expect(actions.first { $0.id == artifactID }?.status == .completed)
        #expect(actions.first { $0.id == terminalOutcome.id }?.status == .completed)

        // Restored approvals/questions are never actionable without live runtime IDs.
        let projection = WorkProjection.project(
            mode: .work,
            actions: actions,
            liveApprovalIDs: [],
            liveQuestionIDs: []
        )
        #expect(projection.actionable?.kind == .userTaskConfirmation)
        #expect(projection.actionable?.id == taskID)
    }

    @Test func completedTurnLeavesPendingPlanStepExplicitlyInterrupted() {
        var actions = [
            SessionAction(
                id: taskID,
                messageID: messageID,
                kind: .plan,
                title: "Pending provider step",
                detail: "",
                status: .waiting,
                work: .init(kind: .planStep, ownership: .providerBound, stepKey: "pending")
            ),
            waitingApproval()
        ]
        _ = SessionActionTrail.finishCompletedTurn(for: messageID, in: &actions, at: fixed)
        #expect(actions.first { $0.id == taskID }?.status == .interrupted)
        #expect(actions.first { $0.id == approvalID }?.status == .cancelled)
    }

    @Test func boundedActionTrailPrefersKeepingDurableDeliverables() {
        let artifact = completedArtifact()
        var actions = [artifact]
        for index in 0..<5 {
            SessionActionTrail.upsert(
                SessionAction(
                    messageID: messageID,
                    kind: .tool,
                    title: "Tool \(index)",
                    detail: "",
                    status: .completed,
                    createdAt: fixed.addingTimeInterval(TimeInterval(index + 1))
                ),
                in: &actions,
                limit: 5
            )
        }
        #expect(actions.count == 5)
        #expect(actions.contains { $0.id == artifactID })
        #expect(!actions.contains { $0.title == "Tool 0" })
    }

    @Test func restoredSessionProjectionsRemainThreadIsolated() {
        let first = LatticeSession(
            id: UUID(uuidString: "13131313-1313-1313-1313-131313131313")!,
            title: "First",
            backend: .openCode(model: "m"),
            executionRoute: .init(mode: .work, providerID: "opencode", modelID: "m", runtimeID: "hermes"),
            actions: [userTask()]
        )
        let secondTask = SessionAction(
            id: UUID(uuidString: "14141414-1414-1414-1414-141414141414")!,
            messageID: messageID,
            kind: .plan,
            title: "Second task",
            detail: "",
            status: .waiting,
            work: .init(kind: .taskStep, ownership: .userOwned, stepKey: "second", taskMark: .unchecked)
        )
        let second = LatticeSession(
            id: UUID(uuidString: "15151515-1515-1515-1515-151515151515")!,
            title: "Second",
            backend: .openCode(model: "m"),
            executionRoute: .init(mode: .work, providerID: "opencode", modelID: "m", runtimeID: "hermes"),
            actions: [secondTask]
        )
        let restored = SessionPersistence.restoreRuntimeState([first, second])
        let projections = Dictionary(uniqueKeysWithValues: restored.map {
            ($0.id, WorkProjection.project(mode: $0.executionRoute.mode, actions: $0.actions))
        })
        #expect(projections[first.id]?.actionable?.id == taskID)
        #expect(projections[second.id]?.actionable?.id == secondTask.id)
    }

    // MARK: - Portable archive safety

    @Test func portableArchiveOmitsWorkPayloadAnswersAndArtifactLocators() throws {
        let session = LatticeSession(
            title: "portable work",
            messages: [ChatMessage(id: messageID, role: .assistant, text: "done", date: fixed)],
            backend: .openCode(model: "m"),
            executionRoute: ExecutionRoute(mode: .work, providerID: "opencode", modelID: "m", runtimeID: "hermes"),
            actions: [
                SessionAction(
                    id: questionID,
                    messageID: messageID,
                    kind: .harness,
                    title: "Need input",
                    detail: "should not export answer surface",
                    status: .completed,
                    createdAt: fixed,
                    updatedAt: fixed,
                    work: SessionWorkSemantics(
                        kind: .question,
                        ownership: .providerBound,
                        stepKey: "secret-question-key"
                    )
                ),
                SessionAction(
                    id: artifactID,
                    messageID: messageID,
                    kind: .tool,
                    title: "Artifact",
                    detail: "ignored detail path",
                    status: .completed,
                    createdAt: fixed,
                    updatedAt: fixed,
                    work: SessionWorkSemantics(
                        kind: .artifact,
                        ownership: .userOwned,
                        artifactLocator: "/Users/secret/project/out/report.pdf"
                    )
                )
            ],
            lastUpdated: fixed
        )

        let data = try SessionPortableArchiveExporter.exportData(
            from: session,
            options: .init(includeQueuedFollowUps: false, format: .jsonArchive, exportedAt: fixed)
        )
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("secret-question-key"))
        #expect(!text.contains("/Users/secret/project/out/report.pdf"))
        #expect(!text.contains("artifactLocator"))
        #expect(!text.contains("\"work\""))
        #expect(!text.contains("should not export answer surface"))

        let plan = try SessionPortableArchiveImporter.prepareImport(data: data, existingSessions: [])
        #expect(plan.session.actions.allSatisfy { $0.work == nil })
        #expect(plan.session.actions.allSatisfy { $0.detail.isEmpty })
    }

    // MARK: - Fixtures

    private func waitingApproval(createdAt: Date? = nil) -> SessionAction {
        let date = createdAt ?? fixed
        return SessionAction(
            id: approvalID,
            messageID: messageID,
            kind: .approval,
            title: "Allow write",
            detail: "Sources/App.swift",
            status: .waiting,
            createdAt: date,
            updatedAt: date,
            work: SessionWorkSemantics(kind: .approval, ownership: .providerBound)
        )
    }

    private func waitingQuestion(createdAt: Date? = nil) -> SessionAction {
        let date = createdAt ?? fixed
        return SessionAction(
            id: questionID,
            messageID: messageID,
            kind: .harness,
            title: "Question",
            detail: "Choose option",
            status: .waiting,
            createdAt: date,
            updatedAt: date,
            work: SessionWorkSemantics(kind: .question, ownership: .providerBound)
        )
    }

    private func userTask(status: SessionAction.Status = .waiting, createdAt: Date? = nil) -> SessionAction {
        let date = createdAt ?? fixed
        return SessionAction(
            id: taskID,
            messageID: messageID,
            kind: .plan,
            title: "Confirm deliverable",
            detail: "",
            status: status,
            createdAt: date,
            updatedAt: date,
            work: SessionWorkSemantics(
                kind: .taskStep,
                ownership: .userOwned,
                stepKey: "confirm",
                taskMark: .unchecked,
                originMessageID: originMessageID
            )
        )
    }

    private func retryableFailure(createdAt: Date? = nil) -> SessionAction {
        let date = createdAt ?? fixed
        return SessionAction(
            id: failureID,
            messageID: messageID,
            kind: .tool,
            title: "Build failed",
            detail: "",
            status: .failed,
            createdAt: date,
            updatedAt: date,
            work: SessionWorkSemantics(kind: .taskStep, ownership: .providerBound, stepKey: "build")
        )
    }

    private func completedArtifact(createdAt: Date? = nil) -> SessionAction {
        let date = createdAt ?? fixed
        return SessionAction(
            id: artifactID,
            messageID: messageID,
            kind: .tool,
            title: "Report",
            detail: "must-not-be-parsed",
            status: .completed,
            createdAt: date,
            updatedAt: date,
            work: SessionWorkSemantics(
                kind: .artifact,
                ownership: .userOwned,
                artifactLocator: "Deliverables/report.md"
            )
        )
    }
}
