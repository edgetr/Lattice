import Foundation
import Testing
@testable import LatticeCore

@Suite("Computer frame path security")
struct ComputerFrameSecurityTests {
    @Test func admitsBoundedRegularImagesInsideAuthorizedRoot() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("frame.png")
        let bytes = Data([0x89, 0x50, 0x4e, 0x47])
        try bytes.write(to: image)

        let admitted = try #require(ComputerFrame.authorizedImage(from: image.path, under: [root]))
        #expect(admitted.url == image.standardizedFileURL)
        #expect(admitted.data == bytes)

        let frame = ComputerFrame(provider: "Codex", imagePath: image.path, imageData: admitted.data)
        #expect(frame.imageURL == image.standardizedFileURL)
        var accumulator = ComputerFrameAccumulator(minimumInterval: 0)
        #expect(accumulator.offer(frame) == .accepted)
    }

    @Test func rejectsOutsideRootSymlinkOversizeAndUnadmittedPaths() throws {
        let root = try temporaryDirectory()
        let outside = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let outsideImage = outside.appendingPathComponent("outside.png")
        try Data([1, 2, 3]).write(to: outsideImage)
        #expect(ComputerFrame.authorizedImage(from: outsideImage.path, under: [root]) == nil)

        let link = root.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideImage)
        #expect(ComputerFrame.authorizedImage(from: link.path, under: [root]) == nil)

        let large = root.appendingPathComponent("large.png")
        try Data(repeating: 7, count: 33).write(to: large)
        #expect(ComputerFrame.authorizedImage(from: large.path, under: [root], maximumByteCount: 32) == nil)

        let unsupported = root.appendingPathComponent("frame.txt")
        try Data([1]).write(to: unsupported)
        #expect(ComputerFrame.authorizedImage(from: unsupported.path, under: [root]) == nil)

        var accumulator = ComputerFrameAccumulator(minimumInterval: 0)
        #expect(accumulator.offer(ComputerFrame(provider: "Codex", imagePath: outsideImage.path)) == .rejectedInvalidPath)
    }

    @Test func codexEventEmbedsAuthorizedBytesAndRejectsExternalFrame() throws {
        let workspace = try temporaryDirectory()
        let outside = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: outside)
        }
        let insideImage = workspace.appendingPathComponent("inside.png")
        let outsideImage = outside.appendingPathComponent("outside.png")
        try Data([1, 2, 3]).write(to: insideImage)
        try Data([4, 5, 6]).write(to: outsideImage)

        let insideEvent = CodexExecHarness.appServerEvent(
            from: completedComputerEvent(imageURL: insideImage.absoluteString),
            workspace: workspace,
            applicationSupportRoot: workspace.appendingPathComponent("support", isDirectory: true)
        )
        if case .computerFrame(let frame)? = insideEvent {
            #expect(frame.imageData == Data([1, 2, 3]))
            #expect(frame.imageURL == insideImage.standardizedFileURL)
        } else {
            Issue.record("Expected an admitted computer frame")
        }

        let outsideEvent = CodexExecHarness.appServerEvent(
            from: completedComputerEvent(imageURL: outsideImage.absoluteString),
            workspace: workspace,
            applicationSupportRoot: workspace.appendingPathComponent("support", isDirectory: true)
        )
        if case .providerDiagnostic(let diagnostic)? = outsideEvent {
            #expect(diagnostic.detail.contains("outside the workspace"))
        } else {
            Issue.record("Expected a diagnostic for an unauthorized computer frame")
        }
    }

    private func completedComputerEvent(imageURL: String) -> [String: Any] {
        [
            "method": "item/completed",
            "params": ["item": [
                "type": "dynamicToolCall",
                "id": "computer-1",
                "tool": "computer_use",
                "status": "completed",
                "contentItems": [["type": "inputImage", "imageUrl": imageURL]]
            ]]
        ]
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-computer-frame-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
