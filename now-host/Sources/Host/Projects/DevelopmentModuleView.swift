import SwiftUI

struct DevelopmentModuleView: View {
    @ObservedObject var model: DevelopmentModel
    @State private var showingCreate = false
    @State private var projectName = "Untitled Project"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    authority
                    projects
                    workspace
                    environment
                    receipts
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
        }
        .sheet(isPresented: $showingCreate) { createSheet }
        .onAppear { model.refresh() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Development").font(.headline)
                Text("Projects and build environments for classic Macintosh software.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button("New Project…") { showingCreate = true }
                .disabled(!model.isAvailable)
        }
        .padding(14)
    }

    private var authority: some View {
        section("Authority") {
            Text("Project tools can read and write only \(model.projectsRootDescription). Guest builds and publication separately require Full access on the connected Mac.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var projects: some View {
        section("Projects") {
            if model.projects.isEmpty {
                Text("No projects yet.").foregroundStyle(.secondary)
            } else {
                Picker("Project", selection: $model.selectedProjectID) {
                    ForEach(model.projects, id: \.projectID) { project in
                        Text("\(project.name) — \(project.home.rawValue)")
                            .tag(Optional(project.projectID))
                    }
                }
                if let project = model.selectedProject {
                    Grid(alignment: .leadingFirstTextBaseline,
                         horizontalSpacing: 14, verticalSpacing: 5) {
                        fact("Home", project.home.rawValue)
                        fact("Revision", String(project.revision))
                        fact("Commit", String(project.currentCommit.prefix(12)))
                        fact("Content", String(project.contentDigest.prefix(12)))
                        fact("Guest state", project.guestState.rawValue)
                    }
                    .font(.callout)
                }
            }
        }
    }

    private var workspace: some View {
        section("Agent Workspace") {
            if let workspace = model.workspace {
                Text(workspace.workspaceID.rawValue).font(.system(.callout, design: .monospaced))
                Text("Base revision \(workspace.baseRevision) · \(workspace.lifecycle.rawValue) · commit \(workspace.currentCommit.prefix(12))")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Resume") { model.openWorkspace() }
                    Button("Discard") { model.discardWorkspace() }
                }
            } else {
                Text("No workspace is open. A guest-home workspace changes a recoverable host copy, not the active guest project.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Open Workspace") { model.openWorkspace() }
                    .disabled(model.selectedProject == nil)
            }
        }
    }

    private var environment: some View {
        section("Toolchains, Builds & Runs") {
            Text("No qualified guest toolchain has been reported. Toolchain roots are registered on the classic Mac and are never exposed as Files or agent paths.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Build") {}
                Button("Run") {}
                Button("Open in CodeKitten") {}
            }
            .disabled(true)
        }
    }

    @ViewBuilder
    private var receipts: some View {
        if let receipt = model.latestRevision {
            section("Latest Receipt") {
                Text("Revision \(receipt.revision) · \(receipt.commit.prefix(12))")
                    .font(.system(.callout, design: .monospaced))
                Text("Build and run receipts remain separate.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if let problem = model.problem {
            section("Problems") {
                Text(problem).foregroundStyle(.red)
            }
        }
    }

    private var createSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Host Project").font(.headline)
            TextField("Project Name", text: $projectName)
            Text("The working source and its Git history stay inside New Old World's application-owned Projects directory.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { showingCreate = false }
                Button("Create") {
                    model.createHostProject(name: projectName)
                    showingCreate = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(width: 420)
    }

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.14)))
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}
