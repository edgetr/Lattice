import Foundation
import Testing
@testable import LatticeCore

@Suite("Harness terminal status decoding")
struct HarnessTerminalStatusTests {
    private let workspace = URL(fileURLWithPath: "/tmp/Lattice")

    @Test("Pi requires explicit boolean error status")
    func piMalformedStatusFails() {
        let missing: [String: Any] = [
            "type": "tool_execution_end",
            "toolCallId": "pi-tool"
        ]
        let wrongType: [String: Any] = [
            "type": "tool_execution_end",
            "toolCallId": "pi-tool",
            "isError": "false"
        ]

        #expect(toolDetail(HarnessToolEventDecoder.piEvent(from: missing, workspace: workspace)) == "Failed")
        #expect(toolDetail(HarnessToolEventDecoder.piEvent(from: wrongType, workspace: workspace)) == "Failed")
        #expect(toolDetail(HarnessToolEventDecoder.piEvent(from: [
            "type": "tool_execution_end", "toolCallId": "pi-tool", "isError": false
        ], workspace: workspace)) == "Completed")
        #expect(toolDetail(HarnessToolEventDecoder.piEvent(from: [
            "type": "tool_execution_end", "toolCallId": "pi-tool", "isError": true
        ], workspace: workspace)) == "Failed")
    }

    @Test("Hermes accepts only known terminal statuses")
    func hermesStatuses() {
        for status in [Any?(nil), 1, "unknown"] {
            #expect(hermesDetail(status) == "Failed")
        }
        #expect(hermesDetail("completed") == "Completed")
        #expect(hermesDetail("failed") == "Failed")
        #expect(hermesDetail("cancelled") == "Cancelled")
        #expect(hermesDetail("in_progress") == "Running")
    }

    @Test("Codex turn preserves completion, failure, and cancellation")
    func codexTurnStatuses() {
        #expect(CodexExecHarness.turnCompletionEvent(from: turn(status: "completed")) == .completed)
        #expect(CodexExecHarness.turnCompletionEvent(from: turn(status: "interrupted")) == .cancelled)
        #expect(CodexExecHarness.turnCompletionEvent(from: turn(status: "failed")) == .failed("Codex could not complete the turn."))

        for malformed in [turn(status: nil), turn(status: 1), turn(status: "unknown")] {
            guard case .failed = CodexExecHarness.turnCompletionEvent(from: malformed) else {
                Issue.record("Malformed Codex turn status must fail")
                continue
            }
        }
    }

    @Test("Codex item completion requires known status for every tool type")
    func codexItemStatuses() {
        for type in ["commandExecution", "fileChange", "webSearch"] {
            for status in [Any?(nil), 1, "unknown"] {
                #expect(toolDetail(CodexExecHarness.appServerEvent(from: codexItem(type: type, status: status), workspace: workspace)) == "Failed")
            }
            #expect(toolDetail(CodexExecHarness.appServerEvent(from: codexItem(type: type, status: "completed"), workspace: workspace)) == "Completed")
            #expect(toolDetail(CodexExecHarness.appServerEvent(from: codexItem(type: type, status: "failed"), workspace: workspace)) == "Failed")
            #expect(toolDetail(CodexExecHarness.appServerEvent(from: codexItem(type: type, status: "interrupted"), workspace: workspace)) == "Cancelled")
        }
    }

    private func hermesDetail(_ status: Any?) -> String? {
        var nested: [String: Any] = [
            "sessionUpdate": "tool_call_update",
            "toolCallId": "hermes-tool"
        ]
        if let status { nested["status"] = status }
        let update: [String: Any] = [
            "method": "session/update",
            "params": ["update": nested]
        ]
        return toolDetail(HarnessToolEventDecoder.hermesEvent(from: update, workspace: workspace))
    }

    private func turn(status: Any?) -> [String: Any] {
        var turn: [String: Any] = [:]
        if let status { turn["status"] = status }
        return ["method": "turn/completed", "params": ["turn": turn]]
    }

    private func codexItem(type: String, status: Any?) -> [String: Any] {
        var item: [String: Any] = ["type": type, "id": "codex-tool"]
        if let status { item["status"] = status }
        if type == "webSearch" { item["query"] = "status test" }
        return ["method": "item/completed", "params": ["item": item]]
    }

    private func toolDetail(_ event: AgentEvent?) -> String? {
        guard case .toolProgress(_, _, let detail) = event else { return nil }
        return detail
    }
}
