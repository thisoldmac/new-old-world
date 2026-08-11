import SwiftUI

/* The model selector. Two pickers — provider, then model — asked a
   person to know which company sells which model before they could
   pick one, and hid every local runtime behind a menu they had no
   reason to open. This is the shape a harness converges on instead:
   one button naming the current model, opening a searchable list
   GROUPED by provider, where the group heading is the only place the
   provider is ever named. */

/// Grouping and search, pure — the part with rules worth pinning.
enum ChatModelMenu {
    struct Group: Equatable {
        let providerID: String
        let label: String
        let models: [ChatModel]
    }

    /// Groups in registry order, providers with nothing to show
    /// dropped. A query matching a PROVIDER's label keeps that whole
    /// group: someone typing "ollama" is asking for its models, not
    /// for the models that happen to spell it in their own name.
    static func groups(
        models: [ChatModel], providers: [ChatProviderEntry], query: String
    ) -> [Group] {
        let needle = normalized(query)
        var groups: [Group] = []
        for provider in providers {
            let owned = models.filter { $0.providerID == provider.id }
            guard !owned.isEmpty else { continue }
            let matches: [ChatModel]
            if needle.isEmpty || normalized(provider.label).contains(needle)
                || normalized(provider.id).contains(needle) {
                matches = owned
            } else {
                matches = owned.filter {
                    normalized($0.displayName).contains(needle)
                        || normalized($0.modelID).contains(needle)
                }
            }
            guard !matches.isEmpty else { continue }
            groups.append(Group(providerID: provider.id,
                                label: provider.label, models: matches))
        }
        return groups
    }

    /// What the button says when nothing is chosen or the chosen model
    /// has gone away — never an empty button.
    static func buttonTitle(
        selection: String, models: [ChatModel]
    ) -> String {
        models.first { $0.wireID == selection }?.displayName
            ?? (selection.isEmpty ? "No model" : selection)
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive],
                     locale: nil)
    }
}

struct ChatModelButton: View {
    let models: [ChatModel]
    let providers: [ChatProviderEntry]
    @Binding var selection: String
    var configure: () -> Void

    @State private var listShown = false
    @State private var query = ""

    var body: some View {
        Button {
            query = ""
            listShown = true
        } label: {
            HStack(spacing: 5) {
                Text(ChatModelMenu.buttonTitle(
                    selection: selection, models: models))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Choose the model to answer with")
        .popover(isPresented: $listShown, arrowEdge: .bottom) { list }
    }

    private var groups: [ChatModelMenu.Group] {
        ChatModelMenu.groups(
            models: models, providers: providers, query: query)
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search models", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groups, id: \.providerID) { group in
                        Text(group.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.top, 9)
                            .padding(.bottom, 3)
                        ForEach(group.models, id: \.wireID) { model in
                            row(model)
                        }
                    }
                    if groups.isEmpty { nothing }
                }
                .padding(.bottom, 6)
            }
        }
        .frame(width: 320, height: 340)
    }

    private func row(_ model: ChatModel) -> some View {
        Button {
            selection = model.wireID
            listShown = false
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .opacity(model.wireID == selection ? 1 : 0)
                Text(model.displayName).lineLimit(1)
                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .help(model.wireID)
    }

    private var nothing: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(models.isEmpty
                 ? "No provider is serving models yet."
                 : "No model matches \"\(query)\".")
                .foregroundStyle(.secondary)
            if models.isEmpty {
                Button("Set Up a Provider...") {
                    listShown = false
                    configure()
                }
            }
        }
        .padding(12)
    }
}
