import SwiftUI
import UniformTypeIdentifiers

/// v0.6.0: collapsed the three-step wizard into a single screen per user
/// request. JIT probe step is gone (not actionable - no sideload path
/// grants JIT execute in the current LiveContainer/StikDebug landscape)
/// and the sign-in step was a placeholder (Claude Code prompts for auth
/// itself on first launch inside the VM).
struct SetupWizardView: View {
    @AppStorage("setupComplete") private var setupComplete = false
    @State private var showFolderPicker = false
    @State private var workspaceName: String? = WorkspaceStore.displayName
    @State private var workspaceError: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()
                header
                workspacePicker
                Spacer()
                startButton
            }
            .padding(24)
            .navigationTitle("PocketDev")
            .navigationBarTitleDisplayMode(.inline)
        }
        .fileImporter(
            isPresented: $showFolderPicker,
            allowedContentTypes: [.folder]
        ) { result in
            switch result {
            case .success(let url):
                do {
                    try WorkspaceStore.save(url: url)
                    workspaceName = WorkspaceStore.displayName
                    workspaceError = nil
                } catch {
                    workspaceError = error.localizedDescription
                }
            case .failure(let error):
                workspaceError = error.localizedDescription
            }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Choose a workspace")
                .font(.title2.bold())
            Text("Pick or create a folder in iCloud Drive or On My iPhone. The VM mounts it at /workspace, and Claude Code (or any other AI coding CLI you install later) runs inside it. Changes appear in the Files app live.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
        }
    }

    private var workspacePicker: some View {
        VStack(spacing: 10) {
            Button {
                showFolderPicker = true
            } label: {
                Label(
                    workspaceName.map { "Workspace: \($0)" } ?? "Choose Folder",
                    systemImage: workspaceName == nil ? "folder" : "checkmark.circle.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            if let workspaceError {
                Text(workspaceError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    private var startButton: some View {
        Button {
            logBoot("wizard_finish_tapped")
            setupComplete = true
            logBoot("wizard_finish_done")
        } label: {
            Text("Start VM and launch Claude Code")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .disabled(workspaceName == nil)
    }
}
