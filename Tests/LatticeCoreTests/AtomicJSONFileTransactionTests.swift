import Testing
import Foundation
@testable import LatticeCore

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
}
