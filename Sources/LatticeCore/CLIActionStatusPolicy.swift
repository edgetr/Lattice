import Foundation

public enum CLIActionStatusPolicy {
    private static let maximumFailureDetailLength = 140
    private static let maximumSanitizationInputLength = 4_096
    public static func signInMessage(
        providerName: String,
        commandSucceeded: Bool,
        readyAfterRefresh: Bool
    ) -> String {
        if readyAfterRefresh { return "" }
        if !commandSucceeded { return "Sign in failed for \(providerName)." }
        return "Sign in finished, but Lattice could not verify a runnable \(providerName) connection."
    }

    public static func messageIndicatesProblem(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("failed")
            || normalized.contains("could not verify")
            || normalized.contains("not on path")
            || normalized.contains("stayed on")
            || normalized.contains("incomplete")
            || normalized.contains("unavailable")
    }

    public static func installMessage(
        executableName: String,
        status: Int32,
        output: Data,
        executableAvailableAfterRefresh: Bool
    ) -> String {
        guard status == 0 else {
            return failureMessage(prefix: "Install failed", output: output)
        }
        if executableAvailableAfterRefresh { return "" }
        return "\(executableName) installed, but it is not on PATH yet."
    }

    public static func updateMessage(
        status: Int32,
        output: Data,
        beforeVersion: String?,
        afterVersion: String?
    ) -> String {
        guard status == 0 else {
            return failureMessage(prefix: "Update failed", output: output)
        }
        if outputLooksUpToDate(output) {
            return ""
        }
        switch (beforeVersion, afterVersion) {
        case let (before?, after?):
            if before != after { return "" }
            return "Active CLI stayed on \(after)."
        case (nil, _?):
            return ""
        case (_?, nil), (nil, nil):
            return "Update finished, but Lattice could not verify the active CLI version."
        }
    }

    public static func outputLooksUpToDate(_ data: Data) -> Bool {
        let output = String(decoding: data, as: UTF8.self).lowercased()
        return output.contains("up to date")
            || output.contains("up-to-date")
            || output.contains("already installed")
            || output.contains("already up-to-date")
            || output.contains("already at the latest")
    }

    public static func failureMessage(prefix: String, output: Data) -> String {
        let text = String(decoding: output, as: UTF8.self)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { !$0.isEmpty }
            ?? "No error details."
        return "\(prefix): \(redactedDetail(String(text), limit: maximumFailureDetailLength))"
    }

    public static func redactedDetail(_ text: String, limit: Int = 600) -> String {
        SessionActionTextPolicy.sanitize(
            text,
            maximumInputCharacters: maximumSanitizationInputLength,
            maximumOutputUTF8Bytes: max(0, limit)
        )
    }
}
