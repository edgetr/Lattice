import Foundation

public enum MorphingControlState: Equatable, Sendable {
    case compact
    case expanded
    case context
    case progress(Double)
    case approval
    case success
    case failure(String)
}

public struct ModelDescriptor: Identifiable, Hashable, Codable, Sendable {
    public enum Engine: String, Codable, Sendable { case mlx, llamaCPP, remote, unavailable }
    public enum Fit: String, Codable, Sendable { case comfortable, tight, risky, unsupported, unknown }

    public let id: String
    public let name: String
    public let provider: String
    public let engine: Engine
    public let quantization: String
    public let contextWindow: Int
    public let capabilities: Set<String>
    public let fit: Fit
    public let isLocal: Bool

    public init(id: String, name: String, provider: String, engine: Engine, quantization: String, contextWindow: Int, capabilities: Set<String>, fit: Fit, isLocal: Bool) {
        self.id = id; self.name = name; self.provider = provider; self.engine = engine
        self.quantization = quantization; self.contextWindow = contextWindow
        self.capabilities = capabilities; self.fit = fit; self.isLocal = isLocal
    }
}

public struct HarnessProfile: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    public let executable: String?
    public let protocolName: String
    public let supportsTools: Bool
    public let isQualifiedForActions: Bool

    public init(id: String, name: String, executable: String?, protocolName: String, supportsTools: Bool, isQualifiedForActions: Bool) {
        self.id = id; self.name = name; self.executable = executable; self.protocolName = protocolName
        self.supportsTools = supportsTools; self.isQualifiedForActions = isQualifiedForActions
    }
}
