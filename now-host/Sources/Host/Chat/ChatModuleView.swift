import AppKit
import SwiftUI

/* The Chat page, third pass. The shape every polished harness shares:
   a quiet toolbar (provider and model, the model list following the
   provider), a conversation that reads as one - the model's text plain
   and full width, the person's in a trailing bubble, tool use as small
   collapsed rows - and provider accounts in a settings sheet instead
   of furniture above the transcript. Native controls; the page should
   feel like this Mac. */

struct ChatModuleView: View {
    @ObservedObject var model: ChatModuleModel
    @State private var settingsShown = false
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            transcript
            Divider()
            composer
        }
        .onAppear { model.refresh() }
        .sheet(isPresented: $settingsShown) {
            ChatProvidersSheet(model: model)
        }
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
            .frame(maxWidth: 300)
            .disabled(model.models(of: model.selectedProviderID).isEmpty)

            Spacer()

            Button {
                model.newChat()
            } label: {
                Label("New Chat", systemImage: "square.and.pencil")
            }
            .disabled(model.isStreaming || model.transcript.isEmpty)
            .help("Start a fresh conversation")

            Button {
                model.refresh()
                settingsShown = true
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .help("Provider accounts and local runtimes")
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if model.transcript.isEmpty {
                        emptyState
                    }
                    ForEach(model.transcript) { row in
                        rowView(row).id(row.id)
                    }
                    if waitingForFirstText {
                        waitingRow.id("waiting")
                    }
                }
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: model.transcript.last?.text) { _ in
                if let last = model.transcript.last {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    /// The model accepted the turn and has said nothing yet — the
    /// stretch that read as "fails silently" on metal.
    private var waitingForFirstText: Bool {
        guard model.isStreaming else { return false }
        if case .model = model.transcript.last?.kind { return false }
        return true
    }

    private var waitingRow: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Waiting for \(currentModelName)...")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var currentModelName: String {
        model.models.first { $0.wireID == model.selectedWireModelID }?
            .displayName ?? "the model"
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Talk to a model about the connected Mac")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
            Text("It can look at the classic Mac's screen, files and "
                 + "processes - with the access its owner granted.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if model.models.isEmpty {
                Button("Set Up a Provider...") {
                    model.refresh()
                    settingsShown = true
                }
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
    }

    @ViewBuilder
    private func rowView(_ row: ChatDisplayRow) -> some View {
        switch row.kind {
        case .person:
            HStack {
                Spacer(minLength: 60)
                Text(row.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        case .model:
            // The model's words, plain and full width - the reading
            // surface, not a bubble fighting for it.
            Text(row.text)
                .textSelection(.enabled)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
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
                Text(toolTitle(name))
                    .font(.caption)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.5))
            .clipShape(Capsule())
            .foregroundStyle(.secondary)
            .help(name)
        case .note:
            Label(row.text, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        }
    }

    /// "now_capture_screen" reads as "Capture screen" in a capsule; the
    /// raw name stays in the tooltip.
    private func toolTitle(_ name: String) -> String {
        let stripped = name.hasPrefix("now_")
            ? String(name.dropFirst(4)) : name
        let words = stripped.split(separator: "_").joined(separator: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(spacing: 8) {
            TextField(
                model.models.isEmpty
                    ? "Set up a provider to start"
                    : "Ask about the connected Mac...",
                text: $draft)
                .textFieldStyle(.plain)
                .font(.body)
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background(.quaternary.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 17))
                .onSubmit(submit)
                .disabled(model.models.isEmpty)
            if model.isStreaming {
                Button {
                    model.cancel()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Stop the answer")
            } else {
                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(
                            canSend ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help("Send")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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

// MARK: - The providers sheet

/// Provider accounts and local runtimes, as cards. Anthropic leads
/// with the subscription sign-in — the flow the plan ships with — and
/// the API key sits behind a disclosure for the machines that need it.
struct ChatProvidersSheet: View {
    @ObservedObject var model: ChatModuleModel
    @Environment(\.dismiss) private var dismiss
    @State private var anthropicKey = ""
    @State private var openAIKey = ""
    @State private var pastedCode = ""
    @State private var keyEntryShown = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Providers").font(.title3.weight(.semibold))
                Spacer()
                Button("Refresh") { model.refresh() }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            ScrollView {
                VStack(spacing: 12) {
                    anthropicCard
                    openAICard
                    localsCard
                }
                .padding()
            }
        }
        .frame(width: 460, height: 480)
    }

    private func entry(_ id: String) -> ChatProviderEntry? {
        model.entries.first { $0.id == id }
    }

    private func cardHeader(
        _ title: String, _ entry: ChatProviderEntry?
    ) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(entry?.state == "serving"
                          ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            Text(title).fontWeight(.semibold)
            Spacer()
            Text(entry?.detail ?? "")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // MARK: Anthropic

    private var anthropicCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                cardHeader("Anthropic", entry("anthropic"))
                switch model.signIn {
                case .awaitingPaste:
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Approve in the browser, then paste the code "
                             + "it shows you:")
                            .font(.callout)
                        HStack(spacing: 6) {
                            TextField("code#state", text: $pastedCode)
                                .textFieldStyle(.roundedBorder)
                                .onAppear {
                                    // The code is usually already on the
                                    // clipboard - meet it there.
                                    if let candidate = Self.clipboardCode() {
                                        pastedCode = candidate
                                    }
                                }
                            Button("Finish") {
                                model.completeAnthropicSignIn(
                                    pasted: pastedCode)
                                pastedCode = ""
                            }
                            .disabled(pastedCode.isEmpty)
                            Button("Cancel") { model.cancelAnthropicSignIn() }
                        }
                    }
                case .failed(let reason):
                    HStack(spacing: 6) {
                        Text(reason)
                            .font(.callout)
                            .foregroundStyle(.red)
                        Spacer()
                        Button("Try Again") { model.beginAnthropicSignIn() }
                    }
                case .idle:
                    if model.hasAnthropicOAuth {
                        HStack {
                            Label("Signed in - using your Claude subscription",
                                  systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.callout)
                            Spacer()
                            Button("Sign Out") { model.signOutAnthropic() }
                        }
                    } else {
                        HStack {
                            Button("Sign in with Claude") {
                                model.beginAnthropicSignIn()
                            }
                            .controlSize(.large)
                            Text("Uses your Claude Pro or Max plan")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        DisclosureGroup(
                            "Use an API key instead",
                            isExpanded: $keyEntryShown
                        ) {
                            keyRow(
                                text: $anthropicKey,
                                hasKey: model.hasAnthropicKey,
                                save: {
                                    model.setAnthropicKey(anthropicKey)
                                    anthropicKey = ""
                                },
                                clear: { model.setAnthropicKey("") })
                        }
                        .font(.callout)
                    }
                }
            }
            .padding(6)
        }
    }

    /// A pasted authorization code, when the clipboard already holds
    /// one — the shape is distinctive enough to trust.
    static func clipboardCode() -> String? {
        guard let text = NSPasteboard.general
            .string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        let parts = text.split(separator: "#")
        guard parts.count == 2, text.count < 300,
            parts.allSatisfy({ part in
                part.allSatisfy {
                    $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
                }
            })
        else { return nil }
        return text
    }

    // MARK: OpenAI

    private var openAICard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                cardHeader("OpenAI", entry("openai"))
                keyRow(
                    text: $openAIKey,
                    hasKey: model.hasOpenAIKey,
                    save: {
                        model.setOpenAIKey(openAIKey)
                        openAIKey = ""
                    },
                    clear: { model.setOpenAIKey("") })
            }
            .padding(6)
        }
    }

    @ViewBuilder
    private func keyRow(
        text: Binding<String>, hasKey: Bool,
        save: @escaping () -> Void, clear: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            if hasKey {
                Label("Key saved in the Keychain",
                      systemImage: "key.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear Key", action: clear)
            } else {
                SecureField("API key", text: text)
                    .textFieldStyle(.roundedBorder)
                Button("Save", action: save)
                    .disabled(text.wrappedValue.isEmpty)
            }
        }
    }

    // MARK: Local runtimes

    private var localsCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Local Runtimes").fontWeight(.semibold)
                    Spacer()
                    Text("Found automatically when running")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(["ollama", "lmstudio", "omlx"], id: \.self) { id in
                    if let local = entry(id) {
                        HStack(spacing: 7) {
                            Circle()
                                .fill(local.state == "serving"
                                          ? Color.green : Color.secondary)
                                .frame(width: 7, height: 7)
                            Text(local.label)
                            Spacer()
                            Text(local.detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(6)
        }
    }
}
