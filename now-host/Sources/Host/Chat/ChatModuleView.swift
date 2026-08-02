import SwiftUI

/* The Chat page: providers above, a working chat below. The providers
   section is the harness's entire configuration surface; the chat pane
   drives the exact loop the wire serves, so "it works here" means the
   guest's page has only the wire left to prove. */

struct ChatModuleView: View {
    @ObservedObject var model: ChatModuleModel
    @State private var anthropicKey = ""
    @State private var openAIKey = ""
    @State private var pastedCode = ""
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            providers
            Divider()
            chat
        }
        .onAppear { model.refresh() }
    }

    // MARK: - Providers

    private var providers: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Providers").font(.headline)
                Spacer()
                Button("Refresh") { model.refresh() }
            }
            ForEach(model.entries, id: \.id) { entry in
                providerRow(entry)
            }
        }
        .padding()
    }

    @ViewBuilder
    private func providerRow(_ entry: ChatProviderEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(entry.state == "serving" ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            Text(entry.label)
                .frame(width: 90, alignment: .leading)
            Text(entry.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            providerControls(entry)
        }
    }

    @ViewBuilder
    private func providerControls(_ entry: ChatProviderEntry) -> some View {
        switch entry.id {
        case "anthropic":
            anthropicControls
        case "openai":
            keyField(
                text: $openAIKey,
                hasKey: model.hasOpenAIKey,
                save: { model.setOpenAIKey(openAIKey); openAIKey = "" },
                clear: { model.setOpenAIKey("") })
        default:
            EmptyView()  // local runtimes configure themselves by running
        }
    }

    @ViewBuilder
    private var anthropicControls: some View {
        switch model.signIn {
        case .awaitingPaste:
            HStack(spacing: 6) {
                TextField("Paste the code from the browser",
                          text: $pastedCode)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                Button("Finish") {
                    model.completeAnthropicSignIn(pasted: pastedCode)
                    pastedCode = ""
                }
                Button("Cancel") { model.cancelAnthropicSignIn() }
            }
        case .failed(let reason):
            HStack(spacing: 6) {
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                Button("Try Again") { model.beginAnthropicSignIn() }
            }
        case .idle:
            HStack(spacing: 6) {
                keyField(
                    text: $anthropicKey,
                    hasKey: model.hasAnthropicKey,
                    save: {
                        model.setAnthropicKey(anthropicKey)
                        anthropicKey = ""
                    },
                    clear: { model.setAnthropicKey("") })
                if model.hasAnthropicOAuth {
                    Button("Sign Out") { model.signOutAnthropic() }
                } else {
                    Button("Sign in with Claude") {
                        model.beginAnthropicSignIn()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func keyField(
        text: Binding<String>, hasKey: Bool,
        save: @escaping () -> Void, clear: @escaping () -> Void
    ) -> some View {
        if hasKey {
            Button("Clear Key", action: clear)
        } else {
            SecureField("API key", text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
            Button("Save", action: save)
                .disabled(text.wrappedValue.isEmpty)
        }
    }

    // MARK: - Chat

    private var chat: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("Model", selection: $model.selectedWireModelID) {
                    ForEach(model.models, id: \.wireID) { served in
                        Text("\(served.displayName) (\(served.providerID))")
                            .tag(served.wireID)
                    }
                }
                .frame(maxWidth: 380)
                Spacer()
                Button("New Chat") { model.newChat() }
                    .disabled(model.isStreaming)
            }
            transcriptView
            HStack(spacing: 8) {
                TextField("Ask about the connected Mac...", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                if model.isStreaming {
                    Button("Stop") { model.cancel() }
                } else {
                    Button("Send", action: submit)
                        .disabled(draft.trimmingCharacters(
                            in: .whitespaces).isEmpty)
                }
            }
        }
        .padding()
    }

    private func submit() {
        model.send(draft)
        draft = ""
    }

    private var transcriptView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(model.transcript) { row in
                        rowView(row).id(row.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .onChange(of: model.transcript.last?.text) { _ in
                if let last = model.transcript.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: ChatDisplayRow) -> some View {
        switch row.kind {
        case .person:
            Text(row.text)
                .textSelection(.enabled)
                .padding(8)
                .background(Color.accentColor.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        case .model:
            Text(row.text)
                .textSelection(.enabled)
        case .tool(let name, let ok):
            Label {
                Text(name).font(.callout.monospaced())
            } icon: {
                switch ok {
                case .none:
                    ProgressView().controlSize(.small)
                case .some(true):
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.green)
                case .some(false):
                    Image(systemName: "minus.circle")
                        .foregroundStyle(.orange)
                }
            }
            .foregroundStyle(.secondary)
        case .note:
            Text(row.text)
                .font(.callout)
                .foregroundStyle(.orange)
        }
    }
}
