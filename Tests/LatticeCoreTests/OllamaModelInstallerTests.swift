import Foundation
import Testing
@testable import LatticeCore

@Suite("Ollama model installer")
struct OllamaModelInstallerTests {
    @Test func modelTagValidationRejectsOptionAndControlInjection() {
        #expect(OllamaModelInstaller.isValidTag("qwen3:8b"))
        #expect(OllamaModelInstaller.isValidTag("library/model@sha256:abc123"))
        #expect(!OllamaModelInstaller.isValidTag("--help"))
        #expect(!OllamaModelInstaller.isValidTag(" model"))
        #expect(!OllamaModelInstaller.isValidTag("model\nother"))
        #expect(!OllamaModelInstaller.isValidTag(String(repeating: "a", count: OllamaModelInstaller.maximumTagBytes + 1)))
    }

    @Test func progressTextIsBoundedAndSanitized() {
        let raw = "\u{001B}[31mprogress\u{0000} " + String(repeating: "x", count: 8_000)
        let value = OllamaModelInstaller.progressText(from: raw)
        #expect(value?.contains("\u{001B}") == false)
        #expect(value?.contains("\u{0000}") == false)
        #expect((value?.count ?? 0) <= OllamaModelInstaller.maximumProgressCharacters)
    }

    @Test func invalidTagFailsWithoutLaunching() async {
        let installer = OllamaModelInstaller(executableURL: URL(fileURLWithPath: "/path/that/must/not/run"))
        var events: [ModelInstallEvent] = []
        for await event in installer.pull("--version") { events.append(event) }
        #expect(events == [.failed("The Ollama model tag is invalid.")])
    }

    @Test func concurrentPullIsRejectedAndCancellationIsBounded() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-ollama-installer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("fake-ollama")
        try Data("#!/bin/sh\nsleep 5\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let installer = OllamaModelInstaller(executableURL: executable)
        let first = installer.pull("qwen3:8b")
        var secondEvents: [ModelInstallEvent] = []
        for await event in installer.pull("other:latest") { secondEvents.append(event) }
        #expect(secondEvents == [.failed("Another Ollama model download is already running.")])

        installer.cancel()
        var firstEvents: [ModelInstallEvent] = []
        for await event in first { firstEvents.append(event) }
        #expect(firstEvents.last == .cancelled)
    }
}
