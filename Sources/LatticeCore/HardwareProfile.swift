import Foundation
import Darwin
import Metal

public struct HardwareProfile: Hashable, Sendable {
    public let chipName: String
    public let physicalMemoryBytes: UInt64
    public let recommendedWorkingSetBytes: UInt64
    public let thermalState: String
    public var physicalMemoryGB: Int { Int(physicalMemoryBytes / 1_073_741_824) }
    public var safeModelBudgetBytes: UInt64 {
        let base = min(UInt64(Double(physicalMemoryBytes) * 0.75), UInt64(Double(recommendedWorkingSetBytes) * 0.90))
        let multiplier: Double
        switch thermalState.lowercased() {
        case "serious": multiplier = 0.70
        case "critical": multiplier = 0.50
        default: multiplier = 1.0
        }
        return UInt64(Double(base) * multiplier)
    }

    public static func current() -> HardwareProfile {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0)
        let chip = String(cString: bytes).replacingOccurrences(of: "Apple ", with: "")
        let workingSet = MTLCreateSystemDefaultDevice()?.recommendedMaxWorkingSetSize ?? UInt64(Double(ProcessInfo.processInfo.physicalMemory) * 0.75)
        let thermal = switch ProcessInfo.processInfo.thermalState {
        case .nominal: "Nominal"; case .fair: "Fair"; case .serious: "Serious"; case .critical: "Critical"; @unknown default: "Unknown"
        }
        return HardwareProfile(chipName: chip.isEmpty ? "Apple silicon" : chip, physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory, recommendedWorkingSetBytes: workingSet, thermalState: thermal)
    }

    public init(chipName: String, physicalMemoryBytes: UInt64, recommendedWorkingSetBytes: UInt64? = nil, thermalState: String = "Nominal") {
        self.chipName = chipName; self.physicalMemoryBytes = physicalMemoryBytes
        self.recommendedWorkingSetBytes = recommendedWorkingSetBytes ?? UInt64(Double(physicalMemoryBytes) * 0.75)
        self.thermalState = thermalState
    }
}

public enum LocalModelServeProfile: String, CaseIterable, Hashable, Codable, Sendable {
    case quick
    case balanced
    case coding
    case toolUse
    case reasoning
    case vision
    case longContext

    public var displayName: String {
        switch self {
        case .quick: "Quick"
        case .balanced: "Balanced"
        case .coding: "Coding"
        case .toolUse: "Tools"
        case .reasoning: "Reasoning"
        case .vision: "Vision"
        case .longContext: "Long context"
        }
    }
}

public struct LocalModelLifecyclePlan: Hashable, Sendable {
    public let serveProfile: LocalModelServeProfile
    public let fit: ModelDescriptor.Fit
    public let estimatedBytes: UInt64
    public let hardwareBudgetBytes: UInt64
    public let idleUnloadMinutes: Int
    public let preloadAllowed: Bool

    public init(serveProfile: LocalModelServeProfile, fit: ModelDescriptor.Fit, estimatedBytes: UInt64, hardwareBudgetBytes: UInt64, idleUnloadMinutes: Int, preloadAllowed: Bool) {
        self.serveProfile = serveProfile
        self.fit = fit
        self.estimatedBytes = estimatedBytes
        self.hardwareBudgetBytes = hardwareBudgetBytes
        self.idleUnloadMinutes = idleUnloadMinutes
        self.preloadAllowed = preloadAllowed
    }

    public var summary: String {
        let unload = idleUnloadMinutes == 0 ? "manual unload" : "\(idleUnloadMinutes)m idle"
        return "\(serveProfile.displayName) · \(unload)"
    }
}

public struct LocalModelRecommendation: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let ollamaTag: String
    public let engineID: String
    public let harnessID: String
    public let parameterCountB: Double
    public let quantizationBits: Double
    public let category: String
    public let useCases: Set<String>
    public let contextTokens: Int
    public let contextPolicy: String
    public let downloadBytes: UInt64?
    public let kvCacheBytes: UInt64
    public let scratchBytes: UInt64
    public let serveProfile: LocalModelServeProfile

    public init(id: String, name: String, ollamaTag: String, parameterCountB: Double, quantizationBits: Double, category: String, contextTokens: Int, engineID: String = "ollama", harnessID: String = "lattice", useCases: Set<String> = [], contextPolicy: String = "default", downloadBytes: UInt64? = nil, kvCacheBytes: UInt64 = 2_147_483_648, scratchBytes: UInt64 = 1_073_741_824, serveProfile: LocalModelServeProfile? = nil) {
        let resolvedUseCases = useCases.isEmpty ? [category.lowercased()] : useCases
        self.id = id; self.name = name; self.ollamaTag = ollamaTag; self.parameterCountB = parameterCountB; self.quantizationBits = quantizationBits
        self.engineID = engineID; self.harnessID = harnessID; self.category = category; self.useCases = resolvedUseCases
        self.contextTokens = contextTokens; self.contextPolicy = contextPolicy; self.downloadBytes = downloadBytes; self.kvCacheBytes = kvCacheBytes; self.scratchBytes = scratchBytes
        self.serveProfile = serveProfile ?? Self.inferServeProfile(category: category, contextTokens: contextTokens, useCases: resolvedUseCases)
    }

    public var estimatedBytes: UInt64 {
        let weights = downloadBytes ?? UInt64(parameterCountB * 1_000_000_000 * quantizationBits / 8)
        return UInt64(Double(weights + kvCacheBytes + scratchBytes) * 1.15)
    }
    public func fit(on hardware: HardwareProfile) -> ModelDescriptor.Fit {
        let ratio = Double(estimatedBytes) / Double(hardware.safeModelBudgetBytes)
        if ratio < 0.75 { return .comfortable }
        if ratio <= 0.90 { return .tight }
        if ratio <= 1 { return .risky }
        return .unsupported
    }

    public func canInstall(on hardware: HardwareProfile) -> Bool {
        let fit = fit(on: hardware)
        return fit == .comfortable || fit == .tight
    }

    public func lifecyclePlan(on hardware: HardwareProfile) -> LocalModelLifecyclePlan {
        let fit = fit(on: hardware)
        let ratio = Double(estimatedBytes) / Double(max(hardware.safeModelBudgetBytes, 1))
        let idleUnloadMinutes: Int
        switch fit {
        case .comfortable:
            idleUnloadMinutes = serveProfile == .quick ? 3 : 5
        case .tight:
            idleUnloadMinutes = 2
        case .risky:
            idleUnloadMinutes = 1
        case .unsupported, .unknown:
            idleUnloadMinutes = 0
        }
        let preloadAllowed = fit == .comfortable && ratio < 0.55 && (serveProfile == .quick || serveProfile == .balanced)
        return LocalModelLifecyclePlan(
            serveProfile: serveProfile,
            fit: fit,
            estimatedBytes: estimatedBytes,
            hardwareBudgetBytes: hardware.safeModelBudgetBytes,
            idleUnloadMinutes: idleUnloadMinutes,
            preloadAllowed: preloadAllowed
        )
    }

    public func recommendationScore(on hardware: HardwareProfile, preferredCategory: String) -> Int {
        let plan = lifecyclePlan(on: hardware)
        var score = category == preferredCategory ? 24 : 0
        score += useCases.contains(preferredCategory.lowercased()) ? 12 : 0
        score += contextTokens >= 128_000 ? 4 : 0
        score += contextTokens >= 256_000 ? 4 : 0
        score += serveProfileScore
        switch plan.fit {
        case .comfortable: score += 32
        case .tight: score += 18
        case .risky: score -= 8
        case .unsupported: score -= 100
        case .unknown: score -= 20
        }
        score -= Int(parameterCountB / 8)
        return score
    }

    public var tupleSummary: String {
        "\(serveProfile.displayName) · Q\(String(format: "%.1f", quantizationBits)) · \(contextTokens / 1000)K context"
    }

    private var serveProfileScore: Int {
        switch serveProfile {
        case .quick: 10
        case .balanced: 9
        case .coding, .toolUse, .reasoning: 8
        case .vision, .longContext: 6
        }
    }

    private static func inferServeProfile(category: String, contextTokens: Int, useCases: Set<String>) -> LocalModelServeProfile {
        let tags = Set(useCases.map { $0.lowercased() } + [category.lowercased()])
        if tags.contains("coding") { return .coding }
        if tags.contains("tool use") || tags.contains("tools") { return .toolUse }
        if tags.contains("reasoning") { return .reasoning }
        if tags.contains("vision") { return .vision }
        if tags.contains("fast") || tags.contains("low memory") { return .quick }
        if tags.contains("private general") || tags.contains("balanced") { return .balanced }
        if tags.contains("long context") || contextTokens >= 256_000 { return .longContext }
        return .balanced
    }
}

public enum LocalModelCatalog {
    public static let recommendations: [LocalModelRecommendation] = [
        .init(id: "qwen35-08b", name: "Qwen 3.5 0.8B", ollamaTag: "qwen3.5:0.8b", parameterCountB: 0.8, quantizationBits: 4.5, category: "Low memory", contextTokens: 262_144),
        .init(id: "lfm25-thinking", name: "LFM 2.5 Thinking 1.2B", ollamaTag: "lfm2.5-thinking:1.2b", parameterCountB: 1.2, quantizationBits: 4.5, category: "Low memory", contextTokens: 32_768),
        .init(id: "granite4-3b", name: "Granite 4 3B", ollamaTag: "granite4:3b", parameterCountB: 3, quantizationBits: 4.5, category: "Tool use", contextTokens: 128_000),
        .init(id: "phi4-mini", name: "Phi-4 Mini 3.8B", ollamaTag: "phi4-mini:3.8b", parameterCountB: 3.8, quantizationBits: 4.5, category: "Fast", contextTokens: 128_000),
        .init(id: "qwen35-4b", name: "Qwen 3.5 4B", ollamaTag: "qwen3.5:4b", parameterCountB: 4, quantizationBits: 4.5, category: "Fast", contextTokens: 262_144),
        .init(id: "gemma3-4b", name: "Gemma 3 4B", ollamaTag: "gemma3:4b", parameterCountB: 4, quantizationBits: 4.5, category: "Vision", contextTokens: 128_000),
        .init(id: "ministral3-8b", name: "Ministral 3 8B", ollamaTag: "ministral-3:8b", parameterCountB: 8, quantizationBits: 4.5, category: "Private general", contextTokens: 256_000),
        .init(id: "qwen3vl-8b", name: "Qwen 3 VL 8B", ollamaTag: "qwen3-vl:8b", parameterCountB: 8, quantizationBits: 4.5, category: "Vision", contextTokens: 262_144),
        .init(id: "qwen35-9b", name: "Qwen 3.5 9B", ollamaTag: "qwen3.5:9b", parameterCountB: 9, quantizationBits: 4.5, category: "Balanced", contextTokens: 262_144),
        .init(id: "gemma4-12b", name: "Gemma 4 12B", ollamaTag: "gemma4:12b", parameterCountB: 12, quantizationBits: 4.5, category: "Tool use", contextTokens: 131_072),
        .init(id: "gemma3-12b", name: "Gemma 3 12B", ollamaTag: "gemma3:12b", parameterCountB: 12, quantizationBits: 4.5, category: "Vision", contextTokens: 128_000),
        .init(id: "deepseek-r1-14b", name: "DeepSeek R1 14B", ollamaTag: "deepseek-r1:14b", parameterCountB: 14, quantizationBits: 4.5, category: "Reasoning", contextTokens: 128_000),
        .init(id: "ministral3-14b", name: "Ministral 3 14B", ollamaTag: "ministral-3:14b", parameterCountB: 14, quantizationBits: 4.5, category: "Long context", contextTokens: 256_000),
        .init(id: "gpt-oss-20b", name: "GPT-OSS 20B", ollamaTag: "gpt-oss:20b", parameterCountB: 20, quantizationBits: 4.25, category: "Reasoning", contextTokens: 131_072, kvCacheBytes: 4_294_967_296, scratchBytes: 2_147_483_648),
        .init(id: "mistral-small32", name: "Mistral Small 3.2 24B", ollamaTag: "mistral-small3.2:24b", parameterCountB: 24, quantizationBits: 4.5, category: "Tool use", contextTokens: 128_000),
        .init(id: "gemma4-26b", name: "Gemma 4 26B", ollamaTag: "gemma4:26b", parameterCountB: 26, quantizationBits: 4.5, category: "Balanced", contextTokens: 131_072),
        .init(id: "qwen35-27b", name: "Qwen 3.5 27B", ollamaTag: "qwen3.5:27b", parameterCountB: 27, quantizationBits: 4.5, category: "Private general", contextTokens: 262_144),
        .init(id: "qwen36-27b", name: "Qwen 3.6 27B", ollamaTag: "qwen3.6:27b", parameterCountB: 27, quantizationBits: 4.5, category: "Tool use", contextTokens: 262_144),
        .init(id: "gemma3-27b", name: "Gemma 3 27B", ollamaTag: "gemma3:27b", parameterCountB: 27, quantizationBits: 4.5, category: "Vision", contextTokens: 128_000),
        .init(id: "qwen3-coder-30b", name: "Qwen 3 Coder 30B", ollamaTag: "qwen3-coder:30b", parameterCountB: 30, quantizationBits: 4.5, category: "Coding", contextTokens: 262_144),
        .init(id: "qwen3vl-30b", name: "Qwen 3 VL 30B", ollamaTag: "qwen3-vl:30b", parameterCountB: 30, quantizationBits: 4.5, category: "Vision", contextTokens: 262_144),
        .init(id: "deepseek-r1-32b", name: "DeepSeek R1 32B", ollamaTag: "deepseek-r1:32b", parameterCountB: 32, quantizationBits: 4.5, category: "Reasoning", contextTokens: 128_000),
        .init(id: "qwen35-35b", name: "Qwen 3.5 35B", ollamaTag: "qwen3.5:35b", parameterCountB: 35, quantizationBits: 4.5, category: "Long context", contextTokens: 262_144),
        .init(id: "qwen36-35b", name: "Qwen 3.6 35B", ollamaTag: "qwen3.6:35b", parameterCountB: 35, quantizationBits: 4.5, category: "Coding", contextTokens: 262_144)
    ]

    public static let categories = ["Fast", "Private general", "Balanced", "Coding", "Tool use", "Reasoning", "Vision", "Long context", "Low memory"]

    public static func recommendations(for hardware: HardwareProfile, category: String, fitOnly: Bool = false) -> [LocalModelRecommendation] {
        recommendations
            .filter { $0.category == category }
            .filter { !fitOnly || $0.canInstall(on: hardware) }
            .sorted {
                let lhsFitRank = $0.fit(on: hardware).sortRank
                let rhsFitRank = $1.fit(on: hardware).sortRank
                if lhsFitRank != rhsFitRank { return lhsFitRank < rhsFitRank }
                return $0.recommendationScore(on: hardware, preferredCategory: category) > $1.recommendationScore(on: hardware, preferredCategory: category)
            }
    }

    public static func hiddenOversizedRecommendationCount(for hardware: HardwareProfile, category: String) -> Int {
        recommendations
            .filter { $0.category == category }
            .filter { !$0.canInstall(on: hardware) }
            .count
    }
}

private extension ModelDescriptor.Fit {
    var sortRank: Int {
        switch self {
        case .comfortable: 0
        case .tight: 1
        case .risky: 2
        case .unknown: 3
        case .unsupported: 4
        }
    }
}
