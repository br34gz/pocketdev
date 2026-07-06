import SwiftUI

struct MainView: View {
    @AppStorage("setupComplete") private var setupComplete = false
    @State private var engine: VMEngine = StubVMEngine()
    @State private var vmState: VMState = .stopped

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TerminalHostView(engine: engine)
                KeyRowView { bytes in
                    engine.send(bytes: bytes)
                }
            }
            .background(.black)
            .navigationTitle(WorkspaceStore.displayName ?? "Pocket Claude")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(stateColor)
                            .frame(width: 10, height: 10)
                        Text(vmState.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            engine.stop()
                            engine.start()
                        } label: {
                            Label("Restart VM", systemImage: "arrow.clockwise")
                        }
                        Button {
                            openWorkspaceInFiles()
                        } label: {
                            Label("Open Workspace in Files", systemImage: "folder")
                        }
                        Divider()
                        Button(role: .destructive) {
                            setupComplete = false
                        } label: {
                            Label("Re-run Setup", systemImage: "gearshape")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .onAppear {
                engine.onStateChange = { newState in
                    DispatchQueue.main.async {
                        vmState = newState
                    }
                }
                if vmState == .stopped {
                    engine.start()
                }
            }
        }
    }

    private var stateColor: Color {
        switch vmState {
        case .stopped: return .gray
        case .starting: return .yellow
        case .running(let jit): return jit ? .green : .orange
        case .error: return .red
        }
    }

    private func openWorkspaceInFiles() {
        guard let url = WorkspaceStore.resolve() else { return }
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "shareddocuments"
        if let filesURL = components?.url {
            UIApplication.shared.open(filesURL)
        }
    }
}
