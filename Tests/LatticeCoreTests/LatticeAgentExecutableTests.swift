import Foundation
import Testing
@testable import LatticeCore

@Suite("Lattice Agent executable discovery")
struct LatticeAgentExecutableTests {
    @Test func productDisplayNameIsLatticeAgent() {
        #expect(LatticeAgentExecutable.productDisplayName == "Lattice Agent")
        #expect(LatticeRuntimeID.pi.displayName == "Lattice Agent")
        #expect(RuntimeInstallDescriptor.pi.displayName == "Lattice Agent")
    }

    @Test func catalogTitlesUseLatticeAgent() {
        let entries = ExecutionRouteResolver.catalog().entries(for: .code)
        let titles = Set(entries.map(\.title))
        #expect(titles.contains("Codex · Lattice Agent"))
        #expect(titles.contains("OpenCode · Lattice Agent"))
        #expect(!titles.contains("Codex · Pi"))
        #expect(!titles.contains("OpenCode · Pi"))
    }

    @Test func environmentOverrideWinsWhenExecutable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-agent-exec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let binary = directory.appendingPathComponent("fake-agent")
        try Data("#!/bin/sh\necho ok\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let resolved = LatticeAgentExecutable.resolve(
            environment: [LatticeAgentExecutable.envOverrideKey: binary.path],
            allowPathFallback: false,
            pathLocator: { _ in nil }
        )
        #expect(resolved?.path == binary.standardizedFileURL.path)
    }

    @Test func releaseStyleDiscoveryIgnoresPathWhenNoManagedOrBundle() {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-agent-as-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }

        var pathHit = false
        let resolved = LatticeAgentExecutable.resolve(
            applicationSupport: support,
            environment: [:],
            allowPathFallback: false,
            pathLocator: { name in
                pathHit = name == "pi"
                return URL(fileURLWithPath: "/usr/bin/pi")
            }
        )
        #expect(resolved == nil)
        #expect(pathHit == false)
    }

    @Test func debugStylePathFallbackUsedWhenAllowed() {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-agent-as-path-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }

        let pathURL = URL(fileURLWithPath: "/tmp/fake-path-pi-\(UUID().uuidString)")
        let resolved = LatticeAgentExecutable.resolve(
            applicationSupport: support,
            environment: [:],
            allowPathFallback: true,
            pathLocator: { name in
                name == "pi" ? pathURL : nil
            }
        )
        #expect(resolved == pathURL)
    }

    @Test func managedInstallRootIsUnderApplicationSupport() {
        let support = URL(fileURLWithPath: "/tmp/lattice-as", isDirectory: true)
        let root = LatticeAgentExecutable.managedInstallRoot(applicationSupport: support)
        #expect(root.path.hasSuffix("Runtimes/LatticeAgent"))
        #expect(root.path.hasPrefix(support.path))
    }

    @Test func harnessLabelUsesLatticeAgent() {
        #expect(ChatRouteProvenancePresentationPolicy.harnessDisplayName(for: "pi") == "Lattice Agent")
    }
}

