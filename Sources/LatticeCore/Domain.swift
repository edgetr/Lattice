import Foundation

// Domain types previously lived in this single file. Ownership is now split:
// - SessionModels.swift — sessions, messages, routes, backends, actions
// - AgentEvents.swift — AgentEvent and related activity types
// - Attachments.swift — ContextAttachment* multimodal types
// - CommandPaletteModels.swift — command palette models/matcher
// - ComposerPresentation.swift — MorphingControlState and catalog descriptors
//
// SwiftPM compiles all files in the LatticeCore target; no re-export is required.
