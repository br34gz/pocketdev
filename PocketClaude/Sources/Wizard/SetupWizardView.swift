import SwiftUI
import UniformTypeIdentifiers

/// First-run wizard, three steps per spec section 5:
/// 1. Workspace folder (security-scoped bookmark)
/// 2. Performance check (JIT probe)
/// 3. Sign in — placeholder until the VM engine lands (M0/M3); the real
///    flow boots headless, watches the control channel for AUTH_URL and
///    hands off to SFSafariViewController.
struct SetupWizardView: View {
    @AppStorage("setupComplete") private var setupComplete = false
    @State private var step = 0
    @State private var showFolderPicker = false
    @State private var workspaceName: String? = WorkspaceStore.displayName
    @State private var workspaceError: String?
    @State private var jitAvailable: Bool?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                switch step {
                case 0: workspaceStep
                case 1: performanceStep
                default: signInStep
                }
                Spacer()
                footer
            }
            .padding()
            .navigationTitle("Pocket Claude")
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

    private var workspaceStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Choose a workspace")
                .font(.title2.bold())
            Text("Pick or create a folder in iCloud Drive or On My iPhone. The VM mounts it at /workspace, and Claude Code runs inside it. Changes show up in the Files app live.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button {
                showFolderPicker = true
            } label: {
                Label(
                    workspaceName.map { "Workspace: \($0)" } ?? "Choose Folder",
                    systemImage: workspaceName == nil ? "folder" : "checkmark.circle.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            if let workspaceError {
                Text(workspaceError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    private var performanceStep: some View {
        VStack(spacing: 16) {
            Image(systemName: jitAvailable == true ? "hare.fill" : "tortoise.fill")
                .font(.system(size: 56))
                .foregroundStyle(jitAvailable == true ? .green : .orange)
            Text("Performance check")
                .font(.title2.bold())
            if let jitAvailable {
                if jitAvailable {
                    Text("JIT is available. The VM will run at full speed.")
                        .multilineTextAlignment(.center)
                } else {
                    Text("JIT is not available — the VM will use interpreter mode, which is noticeably slower. To enable JIT, use StikDebug (iOS 17.4+) or SideJITServer, then re-run this check.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Link(
                        "StikDebug setup instructions",
                        destination: URL(string: "https://github.com/StephenDev0/StikDebug")!
                    )
                }
            } else {
                Text("Checks whether QEMU can use just-in-time compilation on this device.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            Button {
                jitAvailable = JITProbe.canAllocateRWX()
            } label: {
                Text(jitAvailable == nil ? "Run Check" : "Re-run Check")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var signInStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.badge.key")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Sign in to Claude")
                .font(.title2.bold())
            Text("Sign-in happens inside the VM on first boot. The guided flow (browser handoff and code paste-back) arrives with the VM engine — for now this build ships a terminal shell with the VM integration stubbed.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            if step > 0 {
                Button("Back") { step -= 1 }
            }
            Spacer()
            if step < 2 {
                Button("Next") { step += 1 }
                    .buttonStyle(.borderedProminent)
                    .disabled(step == 0 && workspaceName == nil)
            } else {
                Button("Finish") { setupComplete = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
