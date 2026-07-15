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

    func markTransientNewChat(_ value: Bool = true) {
        isTransientNewChat = value
    }

    func setTransientNewChat(_ value: Bool) {
        isTransientNewChat = value
    }

    func setSelection(mode: ConversationMode?, backend: ChatBackend?) {
        selectionMode = mode
        selectionBackend = backend
    }
}
