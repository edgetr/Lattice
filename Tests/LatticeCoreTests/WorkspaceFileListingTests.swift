import Foundation
import Testing
@testable import LatticeCore

@Suite("Workspace file listing policy")
struct WorkspaceFileListingTests {
    @Test func boundsMaximumEntries() throws {
        let root = try makeTempWorkspace(fileCount: 12)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try WorkspaceFileLister().list(
            WorkspaceFileListingRequest(rootPath: root.path, maximumEntries: 5)
        )
        #expect(result.nodes.count == 5)
        #expect(result.truncated)
    }

    @Test func rejectsPathEscapeAndAbsoluteRelative() {
        #expect({
            if case .failure(let error) = WorkspaceFileListingPolicy.normalizeRelativeDirectory("../outside") {
                return error == .pathEscapesRoot
            }
            return false
        }())
        #expect({
            if case .failure(let error) = WorkspaceFileListingPolicy.normalizeRelativePath("/abs") {
                return error == .pathEscapesRoot
            }
            return false
        }())
    }

    @Test func emptyRootFails() {
        #expect(throws: WorkspaceFileListingError.emptyRoot) {
            _ = try WorkspaceFileLister().list(WorkspaceFileListingRequest(rootPath: ""))
        }
    }

    @Test func marksSecretPathsAndBlocksPreview() throws {
        let root = try makeTempWorkspace(fileCount: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let secret = root.appendingPathComponent(".env")
        try "SECRET=1".write(to: secret, atomically: true, encoding: .utf8)

        let listing = try WorkspaceFileLister().list(
            WorkspaceFileListingRequest(rootPath: root.path, includeIgnored: true)
        )
        let node = try #require(listing.nodes.first(where: { $0.name == ".env" }))
        #expect(node.isSecretPath)

        let preview = try WorkspaceFileLister().preview(rootPath: root.path, relativePath: ".env")
        #expect(preview.kind == .secretBlocked)
        #expect(preview.text == nil)
        #expect(preview.data == nil)
    }

    @Test func secretFalsePositivesDoNotBlockTokenizer() {
        #expect(!WorkspaceFileListingPolicy.isSecretPath(relativePath: "Sources/Tokenizer.swift", name: "Tokenizer.swift"))
        #expect(!WorkspaceFileListingPolicy.isSecretPath(relativePath: "docs/secret-sauce.md", name: "secret-sauce.md"))
        #expect(WorkspaceFileListingPolicy.isSecretPath(relativePath: "secrets/app.json", name: "app.json"))
        #expect(WorkspaceFileListingPolicy.isSecretPath(relativePath: "id_rsa", name: "id_rsa"))
    }

    @Test func ignoresNodeModulesByDefaultAndIncludesWhenRequested() throws {
        let root = try makeTempWorkspace(fileCount: 1)
        defer { try? FileManager.default.removeItem(at: root) }
        let ignored = root.appendingPathComponent("node_modules", isDirectory: true)
        try FileManager.default.createDirectory(at: ignored, withIntermediateDirectories: true)
        try "x".write(to: ignored.appendingPathComponent("pkg.js"), atomically: true, encoding: .utf8)

        let listing = try WorkspaceFileLister().list(WorkspaceFileListingRequest(rootPath: root.path))
        #expect(!listing.nodes.contains(where: { $0.name == "node_modules" }))

        let included = try WorkspaceFileLister().list(
            WorkspaceFileListingRequest(rootPath: root.path, includeIgnored: true)
        )
        #expect(included.nodes.contains(where: { $0.name == "node_modules" && $0.isIgnored }))
    }

    @Test func intermediateSymlinkEscapeIsRejected() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-symlink-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("root", isDirectory: true)
        let outside = parent.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "leak".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        let vendor = root.appendingPathComponent("vendor")
        try FileManager.default.createSymbolicLink(at: vendor, withDestinationURL: outside)

        #expect(throws: WorkspaceFileListingError.pathEscapesRoot) {
            _ = try WorkspaceFileLister().list(
                WorkspaceFileListingRequest(rootPath: root.path, relativeDirectory: "vendor")
            )
        }
        #expect(throws: WorkspaceFileListingError.pathEscapesRoot) {
            _ = try WorkspaceFileLister().preview(rootPath: root.path, relativePath: "vendor/secret.txt")
        }
    }

    @Test func leafSymlinkIsNotFollowedForPreview() throws {
        let root = try makeTempWorkspace(fileCount: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).txt")
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let preview = try WorkspaceFileLister().preview(rootPath: root.path, relativePath: "link.txt")
        #expect(preview.kind == .binary)
        #expect(preview.text == nil)
        #expect(preview.message?.contains("Symlink") == true)
    }

    @Test func textPreviewAndTooLarge() throws {
        let root = try makeTempWorkspace(fileCount: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        try "hello".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let big = String(repeating: "x", count: WorkspaceFileListingPolicy.maximumPreviewBytes + 10)
        try big.write(to: root.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)

        let text = try WorkspaceFileLister().preview(rootPath: root.path, relativePath: "a.txt")
        #expect(text.kind == .text)
        #expect(text.text == "hello")

        let large = try WorkspaceFileLister().preview(rootPath: root.path, relativePath: "big.txt")
        #expect(large.kind == .tooLarge)
    }

    @Test func cancelledListingThrows() throws {
        let root = try makeTempWorkspace(fileCount: 3)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: WorkspaceFileListingError.cancelled) {
            _ = try WorkspaceFileLister().list(
                WorkspaceFileListingRequest(rootPath: root.path),
                isCancelled: { true }
            )
        }
    }

    private func makeTempWorkspace(fileCount: Int) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-file-listing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0..<fileCount {
            let url = root.appendingPathComponent("file-\(index).txt")
            try "content \(index)".write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }
}
