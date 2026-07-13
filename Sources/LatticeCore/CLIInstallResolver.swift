import Foundation

public enum CLIInstallSource: String, Hashable, Codable, Sendable {
    case direct
    case homebrewFormula
    case homebrewCask
    case npmGlobal
    case pnpmGlobal
    case selfUpdater
    case unknown
}

public struct CLIInstallSnapshot: Hashable, Codable, Sendable {
    public let executablePath: String
    public let homebrewPrefix: String?
    public let npmPrefix: String?
    public let pnpmBin: String?
    public let homebrewFormulaInstalled: Bool
    public let homebrewCaskInstalled: Bool
    public let npmPackageInstalled: Bool
    public let pnpmPackageInstalled: Bool

    public init(
        executablePath: String,
        homebrewPrefix: String? = nil,
        npmPrefix: String? = nil,
        pnpmBin: String? = nil,
        homebrewFormulaInstalled: Bool = false,
        homebrewCaskInstalled: Bool = false,
        npmPackageInstalled: Bool = false,
        pnpmPackageInstalled: Bool = false
    ) {
        self.executablePath = executablePath
        self.homebrewPrefix = homebrewPrefix
        self.npmPrefix = npmPrefix
        self.pnpmBin = pnpmBin
        self.homebrewFormulaInstalled = homebrewFormulaInstalled
        self.homebrewCaskInstalled = homebrewCaskInstalled
        self.npmPackageInstalled = npmPackageInstalled
        self.pnpmPackageInstalled = pnpmPackageInstalled
    }
}

public struct CLIUpdateCommandPlan: Hashable, Codable, Sendable {
    public let source: CLIInstallSource
    public let executable: String
    public let arguments: [String]

    public init(source: CLIInstallSource, executable: String, arguments: [String]) {
        self.source = source
        self.executable = executable
        self.arguments = arguments
    }
}

public enum CLIInstallResolver {
    public static func codexInstallPlan(
        homebrewAvailable: Bool,
        npmAvailable: Bool,
        pnpmAvailable: Bool
    ) -> CLIUpdateCommandPlan? {
        if homebrewAvailable {
            return CLIUpdateCommandPlan(source: .homebrewCask, executable: "brew", arguments: ["install", "--cask", "codex"])
        }
        return packageInstallPlan(
            npmPackage: "@openai/codex",
            npmAvailable: npmAvailable,
            pnpmAvailable: pnpmAvailable
        )
    }

    public static func packageInstallPlan(
        npmPackage: String,
        pnpmPackage: String? = nil,
        npmAvailable: Bool,
        pnpmAvailable: Bool
    ) -> CLIUpdateCommandPlan? {
        if npmAvailable {
            return CLIUpdateCommandPlan(source: .npmGlobal, executable: "npm", arguments: ["install", "-g", "\(npmPackage)@latest"])
        }
        if pnpmAvailable {
            let package = pnpmPackage ?? npmPackage
            return CLIUpdateCommandPlan(source: .pnpmGlobal, executable: "pnpm", arguments: ["add", "-g", "\(package)@latest"])
        }
        return nil
    }

    public static func source(
        for snapshot: CLIInstallSnapshot,
        directPathMarkers: [String] = []
    ) -> CLIInstallSource {
        let path = snapshot.executablePath
        if directPathMarkers.contains(where: { path.contains($0) }) { return .direct }
        if let prefix = snapshot.homebrewPrefix, path.hasPrefix(prefix) {
            if snapshot.homebrewCaskInstalled { return .homebrewCask }
            if snapshot.homebrewFormulaInstalled { return .homebrewFormula }
        }
        if path.hasPrefix("/opt/homebrew/") || path.hasPrefix("/usr/local/") {
            if snapshot.homebrewCaskInstalled { return .homebrewCask }
            if snapshot.homebrewFormulaInstalled { return .homebrewFormula }
        }
        if let prefix = snapshot.npmPrefix, path.hasPrefix(prefix), snapshot.npmPackageInstalled { return .npmGlobal }
        if let bin = snapshot.pnpmBin, path.hasPrefix(bin), snapshot.pnpmPackageInstalled { return .pnpmGlobal }
        if snapshot.homebrewCaskInstalled { return .homebrewCask }
        if snapshot.homebrewFormulaInstalled { return .homebrewFormula }
        if snapshot.npmPackageInstalled { return .npmGlobal }
        if snapshot.pnpmPackageInstalled { return .pnpmGlobal }
        return .unknown
    }

    public static func updatePlan(
        executableName: String,
        source: CLIInstallSource,
        homebrewFormula: String? = nil,
        homebrewCask: String? = nil,
        npmPackage: String? = nil,
        pnpmPackage: String? = nil,
        selfUpdateArguments: [String]? = nil,
        directArguments: [String]? = nil
    ) -> CLIUpdateCommandPlan? {
        switch source {
        case .direct:
            if let directArguments { return CLIUpdateCommandPlan(source: .direct, executable: executableName, arguments: directArguments) }
            if let selfUpdateArguments { return CLIUpdateCommandPlan(source: .direct, executable: executableName, arguments: selfUpdateArguments) }
            return nil
        case .homebrewCask:
            guard let homebrewCask else { return nil }
            return CLIUpdateCommandPlan(source: source, executable: "brew", arguments: ["upgrade", "--cask", homebrewCask])
        case .homebrewFormula:
            guard let homebrewFormula else { return nil }
            return CLIUpdateCommandPlan(source: source, executable: "brew", arguments: ["upgrade", homebrewFormula])
        case .npmGlobal:
            guard let npmPackage else { return nil }
            return CLIUpdateCommandPlan(source: source, executable: "npm", arguments: ["install", "-g", "\(npmPackage)@latest"])
        case .pnpmGlobal:
            guard let pnpmPackage else { return nil }
            return CLIUpdateCommandPlan(source: source, executable: "pnpm", arguments: ["add", "-g", "\(pnpmPackage)@latest"])
        case .selfUpdater:
            guard let selfUpdateArguments else { return nil }
            return CLIUpdateCommandPlan(source: source, executable: executableName, arguments: selfUpdateArguments)
        case .unknown:
            return nil
        }
    }
}
