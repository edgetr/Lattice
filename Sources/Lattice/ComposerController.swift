import Foundation
import LatticeCore
import Combine

/// Owns composer mode/model selection and related popover state.
@MainActor
final class ComposerController: ObservableObject {
    @Published private(set) var isTransientNewChat = false
    @Published private(set) var selectionMode: ConversationMode?
    @Published private(set) var selectionBackend: ChatBackend?
    @Published var routePopoverPresented = false
    @Published var modelSearchText = ""

    func selectMode(_ mode: ConversationMode) {
        selectionMode = mode
        selectionBackend = nil
        isTransientNewChat = true
    }

    func selectModel(mode: ConversationMode, backend: ChatBackend) {
        selectionMode = mode
        selectionBackend = backend
        isTransientNewChat = true
    }

    func clearTransientSelection() {
        isTransientNewChat = false
        selectionMode = nil
        selectionBackend = nil
        modelSearchText = ""
        routePopoverPresented = false
    }

    /// Single setter for the transient-new-chat flag (and optional mode/backend pair).
    func setTransientNewChat(_ value: Bool, mode: ConversationMode? = nil, backend: ChatBackend? = nil) {
        isTransientNewChat = value
        if let mode {
            selectionMode = mode
        }
        if let backend {
            selectionBackend = backend
        }
        if !value {
            // Clearing transient does not wipe mode/backend unless caller clears via clearTransientSelection.
        }
    }

    func setSelection(mode: ConversationMode?, backend: ChatBackend?) {
        selectionMode = mode
        selectionBackend = backend
    }
}
