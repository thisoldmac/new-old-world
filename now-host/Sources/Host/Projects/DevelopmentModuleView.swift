import SwiftUI

struct DevelopmentModuleView: View {
    @ObservedObject var model: DevelopmentModel
    @State private var showingCreate = false
    @State private var showingImport = false
    @State private var projectName = "Untitled Project"
    @State private var projectToolchain = ProjectGround.hostRetro68Token
    @State private var guestProjectID = ""

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
        .sheet(isPresented: $showingImport) { importSheet }
        .onAppear {
            model.refresh()
            model.refreshDevelopment()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Projects").font(.headline)
                Text("Projects and build environments for classic Macintosh software.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button("New Project…") { showingCreate = true }
                .disabled(!model.isAvailable)
            Button("Import Guest…") { showingImport = true }
                .disabled(model.developmentBusy)
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
            if model.environmentRows.isEmpty {
                Text("No qualified guest toolchain has been reported. Toolchain roots are registered on \(MachineNaming.simpleReference) and are never exposed as Files or agent paths.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leadingFirstTextBaseline,
                     horizontalSpacing: 14, verticalSpacing: 5) {
                    ForEach(Array(model.environmentRows.enumerated()), id: \.offset) {
                        _, row in fact(row.label, row.value)
                    }
                }.font(.callout)
            }
            if !model.buildRows.isEmpty {
                Divider()
                Grid(alignment: .leadingFirstTextBaseline,
                     horizontalSpacing: 14, verticalSpacing: 5) {
                    ForEach(Array(model.buildRows.enumerated()), id: \.offset) {
                        _, row in fact(row.label, row.value)
                    }
                }.font(.callout)
            }
            HStack {
                Button("Stage") { model.stage() }
                    .disabled(!model.canStage)
                Button("Build") { model.build() }
                    .disabled(!model.canBuildActiveGuestProject
                              && model.candidateReference == nil)
                Button("Cancel") { model.cancelBuild() }
                    .disabled(model.developmentBusy)
                Button("Run") { model.run() }
                    .disabled(!model.canRun)
                Button("Promote") { model.promote() }
                    .disabled(!model.canPromote)
                Button("Open in CodeKitten") { model.openInCodeKitten() }
                    .disabled(model.selectedProject?.home != .guest
                              || model.developmentBusy)
                Spacer()
                Button("Refresh") { model.refreshDevelopment() }
                    .disabled(model.developmentBusy)
            }
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
            Text("New Project").font(.headline)
            TextField("Project Name", text: $projectName)
            ProjectLocationPicker(
                toolchain: $projectToolchain,
                guestToolchainQualified: model.guestToolchainQualified)
            Text("The working source and its Git history stay inside New Old World's application-owned Projects directory.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { showingCreate = false }
                Button("Create") {
                    model.createHostProject(name: projectName,
                                            toolchain: projectToolchain)
                    showingCreate = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || (projectToolchain == ProjectGround.guestMPWToken
                              && !model.guestToolchainQualified))
            }
        }
        .padding(20).frame(width: 460)
        .onAppear {
            projectToolchain = ProjectLocationPicker.defaultToken(
                guestToolchainQualified: model.guestToolchainQualified)
        }
    }

    private var importSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import Guest Project").font(.headline)
            TextField("32-character project ID", text: $guestProjectID)
                .font(.system(.body, design: .monospaced))
            Text("NOW reads a coherent snapshot beneath the Projects folder selected on \(MachineNaming.simpleReference), verifies it, and stores a private Git history mirror. The active guest source is not changed.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { showingImport = false }
                Button("Import") {
                    model.importGuestProject(projectID: guestProjectID)
                    showingImport = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(guestProjectID.count != 32)
            }
        }
        .padding(20).frame(width: 460)
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
