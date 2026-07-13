import Foundation
import Testing
@testable import LatticeCore

@Suite("Workspace path scope")
struct WorkspacePathScopeTests {
    private func uniqueWorkspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-scope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func relativeAndAbsoluteInsidePathsAreScoped() throws {
        let workspace = try uniqueWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let nested = workspace.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("main.swift")
        try Data("print(1)".utf8).write(to: file)

        #expect(WorkspacePathScope.isScoped("src/main.swift", under: workspace))
        #expect(WorkspacePathScope.isScoped(file.path, under: workspace))
        #expect(WorkspacePathScope.isScoped("src", under: workspace))
    }

    @Test func dotRepresentsWorkspaceItself() throws {
        let workspace = try uniqueWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        #expect(WorkspacePathScope.isScoped(".", under: workspace))
    }

    @Test func traversalAndAbsoluteOutsideAreUnscoped() throws {
        let workspace = try uniqueWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        #expect(!WorkspacePathScope.isScoped("../outside.txt", under: workspace))
        #expect(!WorkspacePathScope.isScoped("/tmp", under: workspace))
        #expect(!WorkspacePathScope.isScoped("/private/tmp", under: workspace))
    }

    @Test func nilEmptyWhitespaceNulAndURLLikeAreUnscoped() throws {
        let workspace = try uniqueWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        #expect(!WorkspacePathScope.isScoped(nil, under: workspace))
        #expect(!WorkspacePathScope.isScoped("", under: workspace))
        #expect(!WorkspacePathScope.isScoped("   ", under: workspace))
        #expect(!WorkspacePathScope.isScoped("\t\n", under: workspace))
        #expect(!WorkspacePathScope.isScoped("src\0main.swift", under: workspace))
        #expect(!WorkspacePathScope.isScoped("file:///tmp/x", under: workspace))
        #expect(!WorkspacePathScope.isScoped("https://example.com/x", under: workspace))
        #expect(!WorkspacePathScope.isScoped("path://not-a-file", under: workspace))
    }

    @Test func nonexistentOrInvalidWorkspaceIsUnscoped() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-scope-missing-\(UUID().uuidString)", isDirectory: true)
        #expect(!WorkspacePathScope.isScoped("file.txt", under: missing))

        let fileAsWorkspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-scope-file-\(UUID().uuidString)")
        try Data("not-a-dir".utf8).write(to: fileAsWorkspace)
        defer { try? FileManager.default.removeItem(at: fileAsWorkspace) }
        #expect(!WorkspacePathScope.isScoped("file.txt", under: fileAsWorkspace))
    }

    @Test func existingOutsideSymlinkIsUnscoped() throws {
        let workspace = try uniqueWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-scope-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }

        let link = workspace.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        #expect(!WorkspacePathScope.isScoped(link.path, under: workspace))
        #expect(!WorkspacePathScope.isScoped("escape", under: workspace))
    }

    @Test func nonexistentChildUnderOutsideSymlinkIsUnscoped() throws {
        let workspace = try uniqueWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-scope-out-child-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }

        let link = workspace.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        // /work/link/new.txt where link -> /outside must not remain lexically under /work.
        #expect(!WorkspacePathScope.isScoped("link/new.txt", under: workspace))
        #expect(!WorkspacePathScope.isScoped(link.appendingPathComponent("new.txt").path, under: workspace))
    }

    @Test func brokenSymlinkAndSymlinkLoopAreUnscoped() throws {
        let workspace = try uniqueWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let broken = workspace.appendingPathComponent("broken")
        try FileManager.default.createSymbolicLink(
            atPath: broken.path,
            withDestinationPath: "does-not-exist-\(UUID().uuidString)"
        )
        #expect(!WorkspacePathScope.isScoped(broken.path, under: workspace))
        #expect(!WorkspacePathScope.isScoped("broken", under: workspace))

        let loopA = workspace.appendingPathComponent("loop-a")
        let loopB = workspace.appendingPathComponent("loop-b")
        try FileManager.default.createSymbolicLink(atPath: loopA.path, withDestinationPath: loopB.path)
        try FileManager.default.createSymbolicLink(atPath: loopB.path, withDestinationPath: loopA.path)
        #expect(!WorkspacePathScope.isScoped(loopA.path, under: workspace))
        #expect(!WorkspacePathScope.isScoped("loop-a", under: workspace))
    }

    @Test func existingSymlinkResolvingInsideIsScoped() throws {
        let workspace = try uniqueWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let targetDir = workspace.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let targetFile = targetDir.appendingPathComponent("inside.txt")
        try Data("ok".utf8).write(to: targetFile)

        let link = workspace.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: targetDir)

        #expect(WorkspacePathScope.isScoped(link.path, under: workspace))
        #expect(WorkspacePathScope.isScoped("alias", under: workspace))
        #expect(WorkspacePathScope.isScoped("alias/inside.txt", under: workspace))
        #expect(WorkspacePathScope.isScoped("alias/new.txt", under: workspace))
    }

    @Test func dotDotAfterOutsideSymlinkCannotLexicallyCollapseIntoWorkspace() throws {
        let workspace = try uniqueWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let outsideParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-scope-dotdot-\(UUID().uuidString)", isDirectory: true)
        let outsideDirectory = outsideParent.appendingPathComponent("directory", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideParent) }
        let outsideSibling = outsideParent.appendingPathComponent("sibling.txt")
        try Data("outside".utf8).write(to: outsideSibling)

        let link = workspace.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideDirectory)

        #expect(!WorkspacePathScope.isScoped("escape/../sibling.txt", under: workspace))
    }

    @Test func prefixBoundaryIsNotNaive() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-scope-boundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let workspace = parent.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let sibling = parent.appendingPathComponent("proj-evil", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let siblingFile = sibling.appendingPathComponent("secret.txt")
        try Data("no".utf8).write(to: siblingFile)

        #expect(!WorkspacePathScope.isScoped(siblingFile.path, under: workspace))
        #expect(!WorkspacePathScope.isScoped(sibling.path, under: workspace))
    }
}
