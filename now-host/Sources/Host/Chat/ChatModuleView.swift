import SwiftUI

/* The Chat page, second pass after the first metal run: provider and
   model pickers side by side (the model list follows the provider),
   provider setup folded away until it is needed, a transcript that
   reads as a conversation, and an input bar that says what it will do.
   Native controls throughout - the page should feel like this Mac,
   not like a web harness. */

struct ChatModuleView: View {
    @ObservedObject var model: ChatModuleModel
    @State private var providersShown = false
    @State private var anthropicKey = ""
    @State private var openAIKey = ""
    @State private var pastedCode = ""
    @State private var draft = ""
    @State private var anthropicKeyEntry = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if providersShown || model.models.isEmpty {
                providers
                    .transition(.opacity)
                Divider()
            }
            transcript
            Divider()
            inputBar
        }
        .onAppear { model.refresh() }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("Provider", selection: $model.selectedProviderID) {
                ForEach(model.providersWithModels, id: \.id) { entry in
                    Text(entry.label).tag(entry.id)
                }
            }
            .fixedSize()
            .disabled(model.providersWithModels.isEmpty)

            Picker("Model", selection: $model.selectedWireModelID) {
                ForEach(model.models(of: model.selectedProviderID),
                        id: \.wireID) { served in
                    Text(served.displayName).tag(served.wireID)
                }
            }
            .frame(maxWidth: 320)
            .disabled(model.models(of: model.selectedProviderID).isEmpty)

            if model.isStreaming {
                ProgressView()
                    .controlSize(.small)
                    .padding(.leading, 2)
            }

            Spacer()

            Button("New Chat") { model.newChat() }
                .disabled(model.isStreaming || model.transcript.isEmpty)

            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    providersShown.toggle()
                }
                model.refresh()
            } label: {
                Label("Providers", systemImage: "slider.horizontal.3")
            }
            .help("Provider accounts and local runtimes")
        }
        .pickerStyle(.menu)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Providers

    private var providers: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(model.entries, id: \.id) { entry in
                providerRow(entry)
                    .padding(.vertical, 5)
                if entry.id != model.entries.last?.id {
                    Divider()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.25))
    }

    @ViewBuilder
    private func providerRow(_ entry: ChatProviderEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(entry.state == "serving" ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)
            Text(entry.label)
                .fontWeight(.medium)
                .frame(width: 84, alignment: .leading)
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

    /* Subscription first: Sign In is the primary control, and the API
       key is a fallback behind a smaller affordance — a person who
       signed in should never be asked for a key (metal, 2026-08-02). */
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
                .keyboardShortcut(.defaultAction)
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
            if model.hasAnthropicOAuth {
                Button("Sign Out") { model.signOutAnthropic() }
            } else if anthropicKeyEntry || model.hasAnthropicKey {
                HStack(spacing: 6) {
                    keyField(
                        text: $anthropicKey,
                        hasKey: model.hasAnthropicKey,
                        save: {
                            model.setAnthropicKey(anthropicKey)
                            anthropicKey = ""
                            anthropicKeyEntry = false
                        },
                        clear: {
                            model.setAnthropicKey("")
                            anthropicKeyEntry = false
                        })
                    if !model.hasAnthropicKey {
                        Button("Cancel") { anthropicKeyEntry = false }
                    }
                }
            } else {
                HStack(spacing: 6) {
                    Button("Use API Key...") { anthropicKeyEntry = true }
                        .buttonStyle(.link)
                        .font(.callout)
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

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if model.transcript.isEmpty {
                        emptyState
                    }
                    ForEach(model.transcript) { row in
                        rowView(row).id(row.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: model.transcript.last?.text) { _ in
                if let last = model.transcript.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text("Talk to a model about the connected Mac")
                .foregroundStyle(.secondary)
            Text("It can look at the classic Mac's screen, files and "
                 + "processes - with the access its owner granted.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    @ViewBuilder
    private func rowView(_ row: ChatDisplayRow) -> some View {
        switch row.kind {
        case .person:
            HStack {
                Spacer(minLength: 80)
                Text(row.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.accentColor.opacity(0.9))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        case .model:
            HStack {
                Text(row.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.quaternary.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Spacer(minLength: 80)
            }
        case .tool(let name, let ok):
            HStack(spacing: 5) {
                switch ok {
                case .none:
                    ProgressView().controlSize(.mini)
                case .some(true):
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .some(false):
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.orange)
                }
                Text(name)
                    .font(.caption.monospaced())
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.4))
            .clipShape(Capsule())
            .foregroundStyle(.secondary)
        case .note:
            HStack {
                Spacer()
                Label(row.text, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                Spacer()
            }
        }
    }

    // MARK: - Input

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField(
                model.models.isEmpty
                    ? "Configure a provider first"
                    : "Ask about the connected Mac...",
                text: $draft)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.quaternary.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 15))
                .onSubmit(submit)
                .disabled(model.models.isEmpty)
            if model.isStreaming {
                Button {
                    model.cancel()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Stop the answer")
            } else {
                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(
                            canSend ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help("Send")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespaces).isEmpty
            && !model.selectedWireModelID.isEmpty
            && !model.models.isEmpty
    }

    private func submit() {
        guard canSend else { return }
        model.send(draft)
        draft = ""
    }
}
