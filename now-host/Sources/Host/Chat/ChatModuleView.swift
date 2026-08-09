import AppKit
import SwiftUI

/* The Chat page, fourth pass — the shape a modern harness has settled
   on, in this Mac's own materials.

   What each part is answering, since a chat pane looks arbitrary until
   you know: ONE model button rather than a provider picker and a model
   picker, because nobody knows which company sells which model and
   the group heading says it anyway (ChatModelMenu). The model's answer
   rendered as real blocks, since it writes markdown and `Text` renders
   none of it (ChatMarkdownText). A composer with the keyboard model
   people already have — Return sends, Shift-Return breaks the line —
   which is why it is an NSTextView (ChatComposer). Per-row copy, retry
   and edit, because the first thing anyone does with a wrong answer is
   ask again slightly differently (ChatRewind).

   And the scroll follows the answer only while the person is already
   at the bottom: yanking someone back down while they are reading what
   the model said four paragraphs ago is the single most-hated
   behaviour in this class of application. */

struct ChatModuleView: View {
    @ObservedObject var model: ChatModuleModel
    @State private var settingsShown = false
    @State private var draft = ""
    /// Following the tail, as opposed to reading further up.
    @State private var pinnedToBottom = true

    private static let column: CGFloat = 720

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            transcript
            Divider()
            ChatComposer(
                draft: $draft, state: composerState,
                placeholder: model.models.isEmpty
                    ? "Set up a provider to start"
                    : "Ask about the connected machine...",
                send: submit, stop: model.cancel)
        }
        .onAppear { model.refresh() }
        .sheet(isPresented: $settingsShown) {
            ChatProvidersSheet(model: model)
        }
    }

    private var composerState: ChatComposerState {
        ChatComposerState.state(
            draft: draft, isStreaming: model.isStreaming,
            hasModels: !model.models.isEmpty,
            hasSelection: !model.selectedWireModelID.isEmpty)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            ChatModelButton(
                models: model.models, providers: model.providersWithModels,
                selection: $model.selectedWireModelID,
                configure: openSettings)

            Spacer()

            Button {
                model.newChat()
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.borderless)
            .disabled(model.isStreaming || model.transcript.isEmpty)
            .help("Start a fresh conversation")

            Button(action: openSettings) {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            .help("Provider accounts and local runtimes")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func openSettings() {
        model.refresh()
        settingsShown = true
    }

    // MARK: - Transcript

    private var transcript: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if model.transcript.isEmpty {
                            emptyState
                        }
                        ForEach(model.transcript) { row in
                            ChatMessageRow(
                                row: row,
                                isLast: row.id == model.transcript.last?.id,
                                isStreaming: model.isStreaming,
                                retry: model.retryLastPrompt,
                                resend: { text in
                                    model.resend(promptID: row.id, as: text)
                                })
                                .id(row.id)
                        }
                        if waitingForFirstText {
                            waitingRow.id("waiting")
                        }
                        tailSensor(viewport: outer.size.height)
                    }
                    .frame(maxWidth: Self.column)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 18)
                }
                .coordinateSpace(name: Self.scrollSpace)
                .onPreferenceChange(TailOffsetKey.self) { slack in
                    pinnedToBottom = slack < 80
                }
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(alignment: .bottom) {
                    if !pinnedToBottom && !model.transcript.isEmpty {
                        jumpToLatest(proxy)
                    }
                }
                .onChange(of: model.transcript.last?.text) { _ in
                    follow(proxy)
                }
                .onChange(of: model.transcript.count) { _ in
                    follow(proxy)
                }
            }
        }
    }

    private static let scrollSpace = "chat.transcript"

    /// How much transcript is left below the fold, measured by a
    /// zero-height marker at the very end of the content.
    private func tailSensor(viewport: CGFloat) -> some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: TailOffsetKey.self,
                value: geo.frame(in: .named(Self.scrollSpace)).maxY
                    - viewport)
        }
        .frame(height: 1)
    }

    private func follow(_ proxy: ScrollViewProxy) {
        guard pinnedToBottom, let last = model.transcript.last else { return }
        withAnimation(.easeOut(duration: 0.12)) {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    private func jumpToLatest(_ proxy: ScrollViewProxy) -> some View {
        Button {
            pinnedToBottom = true
            follow(proxy)
        } label: {
            Label("Jump to Latest", systemImage: "arrow.down")
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        // The one part of this page that floats over the transcript, so
        // the one part that takes the app's glass — through GlassStyle's
        // vocabulary, which owns both the version and the
        // Reduce-Transparency question.
        .nowGlassPanel(cornerRadius: 13)
        .padding(.bottom, 10)
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

    // MARK: - Empty state

    /// Openers, not decoration: what this harness can do is not
    /// guessable from a blinking cursor, and every one of these is a
    /// question the tools can actually answer about the machine being
    /// driven.
    static let openers = [
        "What Mac is connected right now?",
        "Show me what is on its screen.",
        "What software is installed on it?",
        "How much free space is left on its disk?",
    ]

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("How can I help with "
                 + "\(MachineNaming.simpleReference)?")
                .font(.system(size: 26, weight: .semibold))
                .padding(.bottom, 6)
            Text("I can look at "
                 + "\(MachineNaming.possessive(String?.none)) screen, files "
                 + "and processes - with the access its owner granted.")
                .foregroundStyle(.secondary)
                .padding(.bottom, 18)
            if model.models.isEmpty {
                Button("Set Up a Provider...", action: openSettings)
                    .controlSize(.large)
            } else {
                ForEach(Self.openers, id: \.self) { opener in
                    Divider()
                    Button {
                        draft = opener
                        submit()
                    } label: {
                        HStack {
                            Text(opener)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                }
                Divider()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 40)
        .padding(.bottom, 10)
    }

    private func submit() {
        guard case .send = composerState else { return }
        model.send(draft)
        draft = ""
        pinnedToBottom = true
    }
}

/// The distance from the end of the transcript to the bottom of the
/// viewport — negative or small means the person is at the tail.
private struct TailOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - The providers sheet

/// Provider accounts and local runtimes, as cards. Direct API access
/// and separately authenticated subscription runtimes stay visibly
/// distinct so their billing and credential ownership cannot blur.
struct ChatProvidersSheet: View {
    @ObservedObject var model: ChatModuleModel
    @Environment(\.dismiss) private var dismiss
    @State private var anthropicKey = ""
    @State private var openAIKey = ""

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
            if let notice = model.credentialNotice {
                HStack(spacing: 10) {
                    Image(systemName: "key.horizontal")
                        .foregroundStyle(.secondary)
                    Text(notice)
                        .font(.callout)
                    Spacer()
                    if model.canAuthorizeSavedCredentials {
                        Button(model.isAuthorizingCredentials
                                   ? "Authorizing..." : "Authorize") {
                            model.authorizeSavedCredentials()
                        }
                        .disabled(model.isAuthorizingCredentials)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor))
                Divider()
            }
            ScrollView {
                VStack(spacing: 12) {
                    anthropicCard
                    claudeCard
                    openAICard
                    codexCard
                    localsCard
                }
                .padding()
            }
        }
        .frame(width: 500, height: 620)
    }

    private var claudeCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                cardHeader("Claude (Experimental)", entry("claude"))
                Text("Uses an independently installed Claude Code runtime. "
                     + "Anthropic has not approved this as a third-party "
                     + "subscription integration, and programmatic use may "
                     + "draw from separate Agent SDK credit.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if entry("claude")?.state != "serving" {
                    HStack {
                        Text("Authenticate outside NOW:  claude auth login")
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .accessibilityLabel(
                                "Authenticate outside New Old World with "
                                + "claude auth login")
                        Spacer()
                        Button("Check Again") { model.refresh() }
                    }
                }
            }
            .padding(6)
        }
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
                Text("Public API access billed through an Anthropic Console account.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                keyRow(
                    text: $anthropicKey,
                    hasKey: model.hasAnthropicKey,
                    save: {
                        model.setAnthropicKey(anthropicKey)
                        anthropicKey = ""
                    },
                    clear: { model.setAnthropicKey("") })
            }
            .padding(6)
        }
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

    private var codexCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 9) {
                cardHeader("Codex (ChatGPT)", entry("codex"))
                Text("ChatGPT subscription access through the installed "
                     + "Codex runtime. Codex owns the browser callback and "
                     + "credentials; NOW never receives the tokens.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let account = model.codexAccount, account.isChatGPT {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.email ?? "ChatGPT account")
                                .font(.callout.weight(.medium))
                            if let plan = account.planType {
                                Text("\(plan.capitalized) plan")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Sign Out") { model.signOutCodex() }
                    }
                    if let usage = model.codexUsage {
                        HStack(spacing: 14) {
                            quotaLabel("Current", usage.primary)
                            quotaLabel("Secondary", usage.secondary)
                            if let tokens = usage.lifetimeTokens {
                                Text("\(tokens.formatted()) lifetime tokens")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                } else {
                    switch model.codexSignIn {
                    case .idle:
                        Button("Sign in with ChatGPT") {
                            model.beginCodexSignIn()
                        }
                        .accessibilityHint(
                            "Opens the Codex browser sign-in and returns "
                            + "automatically after authorization")
                    case .signingIn:
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Waiting for the browser callback…")
                                .font(.callout)
                        }
                        .accessibilityElement(children: .combine)
                    case .failed(let reason):
                        HStack {
                            Text(reason).font(.callout).foregroundStyle(.red)
                            Spacer()
                            Button("Try Again") { model.beginCodexSignIn() }
                        }
                    }
                }
            }
            .padding(6)
        }
    }

    private func quotaLabel(
        _ title: String, _ window: CodexQuotaWindow?
    ) -> some View {
        Group {
            if let window {
                Text("\(title): \(window.usedPercent)% used")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
