import Foundation

/// Provider launch restrictions for preview-only Lattice self-edit runs.
/// Prompt instructions are not enforcement; the launch boundary is.
public enum SelfEditProviderLaunchPolicy {
    public static let codexExecutionPolicy: ExecutionPolicy = .ask
    public static let codexWorkspaceWrite = false
}
