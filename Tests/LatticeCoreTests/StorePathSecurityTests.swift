import Foundation
import Darwin
import Testing
@testable import LatticeCore

@Suite("Store path security")
struct StorePathSecurityTests {
    private func uniqueRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-store-security-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func rejectsDotAndDotDotBeforeContainment() throws {
        let root = try uniqueRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let dotDot = URL(fileURLWithPath: root.path + "/nested/../outside.json")
        let dot = URL(fileURLWithPath: root.path + "/./inside.json")
        for candidate in [dotDot, dot] {
            do {
                try LatticeStorePathSecurity.writeDataAtomically(Data("blocked".utf8), to: candidate, under: root)
                Issue.record("Traversal component must be rejected: \(candidate.path)")
            } catch LatticeStorePathError.invalidPath {
                // expected
            } catch {
                Issue.record("Expected invalidPath, got \(error)")
            }
        }
        #expect(!FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("outside.json").path))
    }

    @Test func hiddenFilesRemainSupported() throws {
        let root = try uniqueRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let hidden = root.appendingPathComponent(".lattice-state.json")
        try LatticeStorePathSecurity.writeDataAtomically(Data("ok".utf8), to: hidden, under: root)
        #expect(try LatticeStorePathSecurity.readData(at: hidden, under: root) == Data("ok".utf8))
        let existing = try #require(try LatticeStorePathSecurity.existingEntry(named: hidden.lastPathComponent, under: root))
        #expect(existing.resolvingSymlinksInPath().standardizedFileURL == hidden.resolvingSymlinksInPath().standardizedFileURL)
    }

    @Test func removeRootIsRejectedAndRootSurvives() throws {
        let root = try uniqueRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("keep.json")
        try LatticeStorePathSecurity.writeDataAtomically(Data("keep".utf8), to: child, under: root)

        do {
            try LatticeStorePathSecurity.removeItem(at: root, under: root)
            Issue.record("Removing store root must fail")
        } catch {
            // expected
        }
        #expect(FileManager.default.fileExists(atPath: root.path))
        #expect(try LatticeStorePathSecurity.readData(at: child, under: root) == Data("keep".utf8))
    }

    @Test func siblingTraversalCannotReadWriteOrRemoveOutsideSentinel() throws {
        let root = try uniqueRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sibling = root.deletingLastPathComponent()
            .appendingPathComponent("lattice-store-sibling-\(UUID().uuidString).txt")
        let sentinel = Data("outside-sentinel".utf8)
        try sentinel.write(to: sibling)
        defer { try? FileManager.default.removeItem(at: sibling) }
        let escaped = URL(fileURLWithPath: root.path + "/../" + sibling.lastPathComponent)

        do {
            _ = try LatticeStorePathSecurity.readData(at: escaped, under: root)
            Issue.record("Sibling traversal read must fail")
        } catch { }
        do {
            try LatticeStorePathSecurity.writeDataAtomically(Data("changed".utf8), to: escaped, under: root)
            Issue.record("Sibling traversal write must fail")
        } catch { }
        do {
            try LatticeStorePathSecurity.removeItem(at: escaped, under: root)
            Issue.record("Sibling traversal remove must fail")
        } catch { }
        #expect(try Data(contentsOf: sibling) == sentinel)
    }

    @Test func canonicalTempDescendantSupportsReadWrite() throws {
        let root = try uniqueRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("data.json")
        try LatticeStorePathSecurity.writeDataAtomically(Data("nested".utf8), to: file, under: root)
        #expect(try LatticeStorePathSecurity.readData(at: file, under: root) == Data("nested".utf8))
    }

    @Test func privateVarAliasDoesNotBreakContainedDescendantWhenAvailable() throws {
        let root = try uniqueRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let canonicalRoot = root.resolvingSymlinksInPath()
        guard canonicalRoot.path.hasPrefix("/private/var/"),
              FileManager.default.fileExists(atPath: "/var") else { return }
        let aliasPath = "/var/" + String(canonicalRoot.path.dropFirst("/private/var/".count))
        let aliasRoot = URL(fileURLWithPath: aliasPath, isDirectory: true)
        let aliasFile = aliasRoot.appendingPathComponent("alias.json")
        try LatticeStorePathSecurity.writeDataAtomically(Data("alias".utf8), to: aliasFile, under: aliasRoot)
        #expect(try LatticeStorePathSecurity.readData(at: canonicalRoot.appendingPathComponent("alias.json"), under: canonicalRoot) == Data("alias".utf8))
    }

    @Test func rejectsSymlinkFifoAndBoundsReads() throws {
        let root = try uniqueRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let regular = root.appendingPathComponent("regular.json")
        try Data("safe".utf8).write(to: regular)
        let link = root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: regular)
        #expect(!LatticeStorePathSecurity.isRegularFileWithoutFollowingSymlinks(at: link))
        #expect(throws: Error.self) { try LatticeStorePathSecurity.readDataWithoutFollowingSymlinks(at: link) }

        let fifo = root.appendingPathComponent("pipe.json")
        #expect(mkfifo(fifo.path, mode_t(0o600)) == 0)
        #expect(throws: Error.self) { try LatticeStorePathSecurity.readDataWithoutFollowingSymlinks(at: fifo) }

        let oversized = root.appendingPathComponent("oversized.json")
        try Data(repeating: 0x61, count: LatticeStorePathSecurity.maximumReadByteCount + 1).write(to: oversized)
        #expect(throws: Error.self) { try LatticeStorePathSecurity.readDataWithoutFollowingSymlinks(at: oversized) }
    }

    @Test func atomicWritesUsePrivateFileModeAndDirectoryMode() throws {
        let root = try uniqueRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        let file = nested.appendingPathComponent("state.json")
        try LatticeStorePathSecurity.writeDataAtomicallyWithoutFollowingSymlinks(Data("ok".utf8), to: file)
        let fileAttrs = try FileManager.default.attributesOfItem(atPath: file.path)
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: nested.path)
        #expect(((fileAttrs[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777 == 0o600)
        #expect(((dirAttrs[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777 == 0o700)
    }

    @Test func nonblockingGateTransitionReportsBusyAndLinearizes() throws {
        let gate = DurableStoreWriteGate()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            gate.withExclusiveWrite {
                entered.signal()
                _ = release.wait(timeout: .now() + 2)
            }
        }
        #expect(entered.wait(timeout: .now() + 1) == .success)
        #expect(!gate.tryBlock())
        release.signal()
        var transitioned = false
        for _ in 0..<20 where !transitioned {
            transitioned = gate.tryBlock()
            if !transitioned { usleep(1_000) }
        }
        #expect(transitioned)
        #expect(gate.isBlocked)
        #expect(gate.tryUnblock())
        #expect(!gate.isBlocked)
    }

    @Test func directoryEnumerationAndRemovalArePinnedAndRegularOnly() throws {
        let root = try uniqueRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let keep = root.appendingPathComponent("keep.json")
        let remove = root.appendingPathComponent("remove.json")
        try Data("keep".utf8).write(to: keep)
        try Data("remove".utf8).write(to: remove)
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        let link = root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: keep)
        let names = try LatticeStorePathSecurity.directoryEntriesWithoutFollowingSymlinks(in: root).map(\.name)
        #expect(names.contains("keep.json"))
        #expect(names.contains("nested"))
        #expect(!names.contains("link.json"))
        try LatticeStorePathSecurity.removeRegularFilesWithoutFollowingSymlinks(in: root, keeping: [keep.lastPathComponent])
        #expect(FileManager.default.fileExists(atPath: keep.path))
        #expect(!FileManager.default.fileExists(atPath: remove.path))
        #expect(FileManager.default.fileExists(atPath: nested.path))
    }
}
