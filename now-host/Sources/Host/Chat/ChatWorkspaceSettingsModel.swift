import Foundation
import SwiftUI

/// The Settings tab's editable view of `ChatWorkspaceLaneStore`.
///
/// A model rather than three `@AppStorage` properties because the lane is
/// not a preference: the state a person needs to see is what the lane
/// currently IS — including "the folder you chose is gone", which no
/// toggle can express — and that answer comes from the store, which
/// checks the filesystem.
@MainActor
final class ChatWorkspaceSettingsModel: ObservableObject {
    @Published private(set) var state: ChatWorkspaceLaneState = .off
    @Published var permission: ChatWorkspaceLane.Permission = .acceptEdits {
        didSet {
            guard permission != oldValue else { return }
            store.setPermission(permission)
            reload()
        }
    }
    @Published var attachesNOWTools = true {
        didSet {
            guard attachesNOWTools != oldValue else { return }
            store.setAttachesNOWTools(attachesNOWTools)
            reload()
        }
    }
    /// The person's standing instructions, carried into every turn of
    /// every provider — not lane state, so it works with the lane off.
    @Published var instructions = "" {
        didSet {
            guard instructions != oldValue else { return }
            store.setInstructions(instructions)
        }
    }

    private let store: ChatWorkspaceLaneStore

    init(store: ChatWorkspaceLaneStore = ChatWorkspaceLaneStore()) {
        self.store = store
        instructions = store.instructions()
        reload()
    }

    /// The chosen folder even when it is unusable, so the row can show
    /// what was chosen beside the reason it does not work — a person who
    /// sees only "missing" cannot tell which folder they lost.
    var chosenPath: String? {
        switch state {
        case .ready(let lane): return lane.root.path
        case .unusable(let reason): return reason
        case .off: return nil
        }
    }

    var isOn: Bool { state.lane != nil }

    func choose(_ url: URL?) {
        store.setRoot(url)
        reload()
    }

    func reload() {
        state = store.state()
        if case .ready(let lane) = state {
            if permission != lane.permission { permission = lane.permission }
            if attachesNOWTools != lane.attachesNOWTools {
                attachesNOWTools = lane.attachesNOWTools
            }
        }
    }
}
