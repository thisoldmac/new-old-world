import SwiftUI

/* The saved-chats sidebar: a native List in the sidebar style, the
   same shape the Connections and Diagnostics pages already use, so a
   second list in this app does not read as a third idea.

   Chats are grouped under the projects they are filed under, with the
   loose ones last — a project being a folder on disk that may also
   point at a Projects-module project for its code. Selecting a row is
   the ONLY thing that reads a transcript from disk.

   Renaming is inline rather than a sheet: naming a chat is not a
   decision worth a modal, and the row is where the name is. */

struct ChatSidebar: View {
    @ObservedObject var model: ChatModuleModel
    @State private var renaming: ChatID?
    @State private var renamingProject: ChatProjectID?
    @State private var draftName = ""
    @FocusState private var nameFocused: Bool
    @State private var showingNewProject = false
    @State private var newProjectName = ""
    @State private var newProjectToolchain = ProjectGround.hostRetro68Token
    @State private var newProjectGuestQualified = false

    var body: some View {
        VStack(spacing: 0) {
            list
            Divider()
            footer
        }
        .frame(minWidth: 180, idealWidth: 220, maxWidth: 320,
               maxHeight: .infinity)
        .sheet(isPresented: $showingNewProject) { newProjectSheet }
    }

    private var list: some View {
        List(selection: selection) {
            ForEach(model.chatProjects) { project in
                Section {
                    rows(of: chats(in: project.id))
                } header: {
                    projectHeader(project)
                }
            }
            Section(model.chatProjects.isEmpty ? "Chats" : "Other chats") {
                rows(of: chats(in: nil))
            }
        }
        .listStyle(.sidebar)
        .overlay(alignment: .bottom) {
            if let notice = model.storageNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.thinMaterial)
            }
        }
    }

    private var selection: Binding<ChatID?> {
        Binding(get: { model.selectedChatID },
                set: { if let id = $0 { model.selectChat(id) } })
    }

    private func chats(in projectID: ChatProjectID?) -> [ChatSummary] {
        model.chats.filter { $0.projectID == projectID }
    }

    @ViewBuilder
    private func rows(of chats: [ChatSummary]) -> some View {
        if chats.isEmpty {
            Text("No chats")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            ForEach(chats) { chat in
                row(chat)
                    .tag(chat.id)
                    .contextMenu { menu(for: chat) }
            }
        }
    }

    @ViewBuilder
    private func row(_ chat: ChatSummary) -> some View {
        if renaming == chat.id {
            TextField("Name", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit { commitChatRename(chat) }
                .onExitCommand { renaming = nil }
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Text(chat.title).lineLimit(1)
                Text(chat.turnCount == 0
                     ? "Empty" : chat.updatedAt.formatted(
                        date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func projectHeader(_ project: ChatProjectRecord) -> some View {
        if renamingProject == project.id {
            TextField("Name", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit {
                    model.renameChatProject(project.id, to: draftName)
                    renamingProject = nil
                }
                .onExitCommand { renamingProject = nil }
        } else {
            HStack(spacing: 4) {
                Text(project.name)
                if project.linkedProjectID != nil {
                    Image(systemName: "hammer")
                        .help("Associated with a project in Projects")
                }
            }
            .contextMenu {
                Button("New Chat Here") {
                    model.newChat(in: project.id)
                }
                .disabled(model.isStreaming)
                Button("Rename\u{2026}") {
                    draftName = project.name
                    renamingProject = project.id
                    nameFocused = true
                }
                Button("Delete Folder") {
                    model.deleteChatProject(project.id)
                }
            }
        }
    }

    @ViewBuilder
    private func menu(for chat: ChatSummary) -> some View {
        Button("Rename\u{2026}") {
            draftName = chat.title
            renaming = chat.id
            nameFocused = true
        }
        if !model.chatProjects.isEmpty {
            Menu("Move To") {
                ForEach(model.chatProjects) { project in
                    Button(project.name) {
                        model.fileChat(chat.id, under: project.id)
                    }
                    .disabled(project.id == chat.projectID)
                }
                Divider()
                Button("No Project") {
                    model.fileChat(chat.id, under: nil)
                }
                .disabled(chat.projectID == nil)
            }
        }
        Divider()
        Button("Delete", role: .destructive) {
            model.deleteChat(chat.id)
        }
    }

    private func commitChatRename(_ chat: ChatSummary) {
        model.renameChat(chat.id, to: draftName)
        renaming = nil
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Button { model.newChat() } label: {
                Image(systemName: "square.and.pencil")
            }
            .help("New chat")
            .disabled(model.isStreaming)

            Button {
                newProjectName = ""
                showingNewProject = true
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .help("New project")
            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    /* The same decision the Projects module's create sheet asks, and
       the same create the wire serves: a chat folder that is also a
       real ProjectStore project, through the mint/associate seam —
       never a bare folder named "New Project". */
    private var newProjectSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Project").font(.headline)
            TextField("Project Name", text: $newProjectName)
            ProjectLocationPicker(
                toolchain: $newProjectToolchain,
                guestToolchainQualified: newProjectGuestQualified)
            Text("Chats filed under the project are stored beside its code, in New Old World's application-owned Projects directory.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { showingNewProject = false }
                Button("Create") {
                    let name = newProjectName
                    let toolchain = newProjectToolchain
                    Task { await model.createChatProject(
                        name: name, toolchain: toolchain) }
                    showingNewProject = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newProjectName.trimmingCharacters(
                    in: .whitespacesAndNewlines).isEmpty
                    || (newProjectToolchain == ProjectGround.guestMPWToken
                        && !newProjectGuestQualified))
            }
        }
        .padding(20).frame(width: 460)
        .task {
            newProjectGuestQualified = await model.guestToolchainQualified()
            newProjectToolchain = ProjectLocationPicker.defaultToken(
                guestToolchainQualified: newProjectGuestQualified)
        }
    }
}
