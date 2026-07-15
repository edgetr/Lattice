import Foundation

// Extension runtime types previously lived in this single file. Ownership is now split:
// - ExtensionManifest.swift — permissions, manifests, change review
// - ExtensionPatches.swift — style/layout/copy/prompt/operation patches and self-map
// - ExtensionRecords.swift — extension/job/preview records and enablement policy
// - ExtensionStores.swift — durable extension and job stores
// - ExtensionPreviewEditor.swift — preview editor + preview store
//
// SwiftPM compiles all files in the LatticeCore target; no re-export is required.
