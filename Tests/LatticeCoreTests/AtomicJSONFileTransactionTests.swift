import Testing
import Foundation
@testable import LatticeCore

private final class AtomicResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AtomicJSONFileWriteResult] = []

    func append(_ value: AtomicJSONFileWriteResult) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return values.count
    }
}

@Suite("Atomic JSON file transaction")
struct AtomicJSONFileTransactionTests {
    private func uniqueRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-atomic-json-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func missingFileReadsAsEmptyObject() throws {
        let root = try uniqueRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("auth.json")
        let result = AtomicJSONFileTransaction.readObject(at: url)
        guard case .success(let snapshot) = result else {
            Issue.record("Missing file must succeed as empty")
            return
        }
        #expect(!snapshot.exists)
        #expect(snapshot.object?.isEmpty == true)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".lattice-atomic-json.lock").path))
    }

    @Test func malformedJSONIsNeverTreatedAsEmpty() throws {
        let root = try uniqueRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("auth.json")
        try Data("{not-json".utf8).write(to: url)
        let result = AtomicJSONFileTransaction.readObject(at: url)
        guard case .failure(let error) = result else {
            Issue.record("Malformed JSON must fail closed")
            return
        }
        #expect(error == .malformedJSON)

        // Mutation must also refuse to clobber a corrupt file with a fresh object.
        let write = AtomicJSONFileTransaction.mutateObject(at: url) { root in
            root["opencode-go"] = ["type": "api", "key": "x"]
        }
        #expect(!write.isSuccess)
        #expect((try Data(contentsOf: url)) == Data("{not-json".utf8))
    }

    @Test func nonObjectRootFailsClosed() throws {
        let root = try uniqueRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("auth.json")
        try Data("[1,2,3]".utf8).write(to: url)
        guard case .failure(.notAJSONObject) = AtomicJSONFileTransaction.readObject(at: url) else {
            Issue.record("Array root must be rejected")
            return
        }
    }

    @Test func mutatePreservesUnrelatedFieldsAndSetsMode() throws {
        let root = try uniqueRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("auth.json")
        let initial: [String: Any] = [
            "other-provider": ["type": "oauth", "token": "keep-me"],
            "meta": ["note": "stay"]
        ]
        let data = try JSONSerialization.data(withJSONObject: initial, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)

        let result = AtomicJSONFileTransaction.mutateObject(at: url) { object in
            object["opencode-go"] = ["type": "api", "key": "secret"]
        }
        #expect(result.isSuccess)

        guard case .success(let snapshot) = AtomicJSONFileTransaction.readObject(at: url),
              let object = snapshot.object else {
            Issue.record("Expected readable object after mutate")
            return
        }
        #expect(object["other-provider"] != nil)
        #expect(object["meta"] != nil)
        let go = object["opencode-go"] as? [String: Any]
        #expect(go?["key"] as? String == "secret")

        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(perms?.intValue == 0o600)
    }

    @Test func removeKeyPreservesSiblings() throws {
        let root = try uniqueRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("auth.json")
        let initial: [String: Any] = [
            "opencode-go": ["type": "api", "key": "secret"],
            "sibling": ["type": "api", "key": "other"]
        ]
        try JSONSerialization.data(withJSONObject: initial).write(to: url)

        let result = AtomicJSONFileTransaction.mutateObject(at: url) { object in
            object.removeValue(forKey: "opencode-go")
        }
        #expect(result.isSuccess)
        guard case .success(let snapshot) = AtomicJSONFileTransaction.readObject(at: url),
              let object = snapshot.object else {
            Issue.record("Expected object after remove")
            return
        }
        #expect(object["opencode-go"] == nil)
        #expect(object["sibling"] != nil)
    }

    @Test func writeConflictsWhenFingerprintChanges() throws {
        let root = try uniqueRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("auth.json")
        try JSONSerialization.data(withJSONObject: ["a": 1]).write(to: url)
        guard case .success(let baseline) = AtomicJSONFileTransaction.readObject(at: url) else {
            Issue.record("baseline read failed")
            return
        }

        // Concurrent writer changes the file after our snapshot.
        try JSONSerialization.data(withJSONObject: ["a": 2, "b": true]).write(to: url)

        let result = AtomicJSONFileTransaction.writeObject(["a": 3], to: url, expected: baseline)
        #expect(result == .conflict)

        // Disk still has concurrent writer content.
        guard case .success(let after) = AtomicJSONFileTransaction.readObject(at: url),
              let object = after.object else {
            Issue.record("post-conflict read failed")
            return
        }
        #expect(object["b"] as? Bool == true)
        #expect(object["a"] as? Int == 2)
    }

    @Test func mutateRetriesThroughTransientConflict() throws {
        let root = try uniqueRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("auth.json")
        try JSONSerialization.data(withJSONObject: ["counter": 0, "keep": true]).write(to: url)

        // Single successful mutation path (no forced conflict) still works under retry budget.
        let result = AtomicJSONFileTransaction.mutateObject(at: url, maxAttempts: 3) { object in
            let current = object["counter"] as? Int ?? 0
            object["counter"] = current + 1
            object["opencode-go"] = ["type": "api", "key": "k"]
        }
        #expect(result.isSuccess)
        guard case .success(let snapshot) = AtomicJSONFileTransaction.readObject(at: url),
              let object = snapshot.object else {
            Issue.record("retry path read failed")
            return
        }
        #expect(object["counter"] as? Int == 1)
        #expect(object["keep"] as? Bool == true)
        #expect(object["opencode-go"] != nil)
    }

    @Test func atomicReplaceLeavesNoTempResidueOnSuccess() throws {
        let root = try uniqueRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("auth.json")
        let result = AtomicJSONFileTransaction.mutateObject(at: url) { object in
            object["fresh"] = true
        }
        #expect(result.isSuccess)
        let leftovers = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".tmp-") }
        #expect(leftovers.isEmpty)
    }

    @Test func concurrentInProcessMutationsDoNotLoseUpdates() throws {
        let root = try uniqueRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("auth.json")
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        let results = AtomicResultBox()
        let queue = DispatchQueue(label: "lattice.atomic-json.concurrent", attributes: .concurrent)

        group.enter()
        queue.async {
            let result = AtomicJSONFileTransaction.mutateObject(at: url) { object in
                entered.signal()
                _ = release.wait(timeout: .now() + 2)
                object["first"] = true
            }
            results.append(result)
            group.leave()
        }
        #expect(entered.wait(timeout: .now() + 2) == .success)

        group.enter()
        queue.async {
            let result = AtomicJSONFileTransaction.mutateObject(at: url) { object in
                object["second"] = true
            }
            results.append(result)
            group.leave()
        }
        // The second mutation must wait for the first transaction's publish.
        release.signal()
        #expect(group.wait(timeout: .now() + 3) == .success)
        #expect(results.count == 2)

        guard case .success(let snapshot) = AtomicJSONFileTransaction.readObject(at: url),
              let object = snapshot.object else {
            Issue.record("Expected both concurrent mutations to publish")
            return
        }
        #expect(object["first"] as? Bool == true)
        #expect(object["second"] as? Bool == true)
    }

    @Test func symlinkedPathIsRejected() throws {
        let root = try uniqueRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.json")
        let link = root.appendingPathComponent("auth.json")
        try Data("{\"safe\":true}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        guard case .failure(.unreadable) = AtomicJSONFileTransaction.readObject(at: link) else {
            Issue.record("Symlinked JSON path must be rejected")
            return
        }
        let result = AtomicJSONFileTransaction.mutateObject(at: link) { object in
            object["unsafe"] = true
        }
        #expect(!result.isSuccess)
        #expect((try Data(contentsOf: target)) == Data("{\"safe\":true}".utf8))
    }

    @Test func danglingParentSymlinkAndSpecialFilesFailClosed() throws {
        let root = try uniqueRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.deletingLastPathComponent().appendingPathComponent("lattice-atomic-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let danglingParent = root.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(at: danglingParent, withDestinationURL: outside.appendingPathComponent("missing"))
        let nested = danglingParent.appendingPathComponent("auth.json")
        guard case .failure(.unreadable) = AtomicJSONFileTransaction.readObject(at: nested) else {
            Issue.record("Dangling parent symlink must be rejected")
            return
        }

        let directoryURL = root.appendingPathComponent("directory.json", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false)
        guard case .failure(.unreadable) = AtomicJSONFileTransaction.readObject(at: directoryURL) else {
            Issue.record("Directories must not be parsed as JSON")
            return
        }
    }

    @Test func boundedReadAndIncompleteBaselineFailClosed() throws {
        let root = try uniqueRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("auth.json")
        let oversized = Data(repeating: 0x20, count: AtomicJSONFileTransaction.maximumFileBytes + 1)
        try oversized.write(to: url)
        guard case .failure(.unreadable) = AtomicJSONFileTransaction.readObject(at: url) else {
            Issue.record("Oversized files must be rejected before reading")
            return
        }
        let incomplete = JSONFileSnapshot(exists: true, object: [:])
        let result = AtomicJSONFileTransaction.writeObject(["a": 1], to: url, expected: incomplete)
        guard case .failure = result else {
            Issue.record("Incomplete existing snapshots must not authorize writes")
            return
        }
    }

    @Test func fileURLAndFingerprintContractsAreExplicit() throws {
        let root = try uniqueRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("auth.json")
        guard case .failure(.unreadable) = AtomicJSONFileTransaction.readObject(at: URL(string: "https://example.com/auth.json")!) else {
            Issue.record("Non-file URLs must be rejected")
            return
        }
        #expect(AtomicJSONFileTransaction.fingerprint(for: Data("hello".utf8)).count == 64)
        #expect(AtomicJSONFileTransaction.mutateObject(at: url) { $0["ok"] = true }.isSuccess)
    }

    @Test func privateVarAndVarAliasesShareTheCanonicalTransactionPath() throws {
        #if os(macOS)
        let name = "lattice-atomic-alias-\(UUID().uuidString)"
        let canonicalRoot = URL(fileURLWithPath: "/private/var/tmp/\(name)", isDirectory: true)
        let aliasRoot = URL(fileURLWithPath: "/var/tmp/\(name)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: canonicalRoot) }
        try FileManager.default.createDirectory(at: canonicalRoot, withIntermediateDirectories: true)
        let aliasURL = aliasRoot.appendingPathComponent("auth.json")
        let canonicalURL = canonicalRoot.appendingPathComponent("auth.json")
        #expect(AtomicJSONFileTransaction.mutateObject(at: aliasURL, maxAttempts: Int.max) { $0["alias"] = true }.isSuccess)
        guard case .success(let snapshot) = AtomicJSONFileTransaction.readObject(at: canonicalURL),
              let object = snapshot.object else {
            Issue.record("/var and /private/var aliases must address the same JSON file")
            return
        }
        #expect(object["alias"] as? Bool == true)
        #endif
    }

    @Test func interprocessLockMustBeOwnedRegularFile() throws {
        let root = try uniqueRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lockURL = root.appendingPathComponent(".lattice-atomic-json.lock", isDirectory: true)
        try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: false)
        let result = AtomicJSONFileTransaction.mutateObject(at: root.appendingPathComponent("auth.json")) { $0["blocked"] = true }
        guard case .failure(let detail) = result else {
            Issue.record("A non-regular interprocess lock path must fail closed")
            return
        }
        #expect(detail.contains("lock"))
    }

    @Test func reservedInterprocessLockLeafCannotBeTargeted() throws {
        let root = try uniqueRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent(".lattice-atomic-json.lock")
        let result = AtomicJSONFileTransaction.mutateObject(at: target) { $0["blocked"] = true }
        guard case .failure(let detail) = result else {
            Issue.record("The advisory lock filename must be reserved")
            return
        }
        #expect(detail.contains("reserved"))
        let mixedCase = root.appendingPathComponent(".LATTICE-ATOMIC-JSON.LOCK")
        #expect(!AtomicJSONFileTransaction.mutateObject(at: mixedCase) { $0["blocked"] = true }.isSuccess)
        #expect(AtomicJSONFileWriteResult.publishedButDurabilityUnconfirmed("warning").isSuccess)
    }

    @Test func existingInterprocessLockAllowsSharedRead() throws {
        let root = try uniqueRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("auth.json")
        try Data("{\"safe\":true}".utf8).write(to: target)
        try Data().write(to: root.appendingPathComponent(".lattice-atomic-json.lock"))
        guard case .success(let snapshot) = AtomicJSONFileTransaction.readObject(at: target) else {
            Issue.record("An existing safe interprocess lock must permit shared reads")
            return
        }
        #expect(snapshot.object?["safe"] as? Bool == true)
    }
}
