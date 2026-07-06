import SwiftUI
import SafariServices

struct MainView: View {
    @ObservedObject var env = PocketClaudeEnvironment.shared
    @AppStorage("setupComplete") private var setupComplete = false
    @State private var showAuthSheet = false
    @State private var authSheetURL: URL?
    @State private var codeToPaste: String = ""
    @State private var showSettings = false
    @State private var showJITSheet = false

    var body: some View {
        logBoot("mainview_body")
        return NavigationStack {
            VStack(spacing: 0) {
                terminal
                KeyRowView { bytes in
                    env.engine?.send(bytes: bytes)
                }
            }
            .background(.black)
            .navigationTitle(WorkspaceStore.displayName ?? "PocketDev")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .onAppear {
                logBoot("mainview_appear")
                if env.engine == nil {
                    env.startEngine()
                }
            }
            .onChange(of: env.pendingAuthURL) { _, url in
                if let url {
                    authSheetURL = url
                    showAuthSheet = true
                }
            }
            .sheet(isPresented: $showAuthSheet) { authSheet }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showJITSheet) { JITStatusSheet(active: env.selectedVariant == "jit") }
        }
    }

    @ViewBuilder
    private var terminal: some View {
        ZStack {
            if let engine = env.engine {
                TerminalHostView(engine: engine)
            } else {
                Color.black
            }
            statusOverlay
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch env.vmState {
        case .starting:
            VStack(spacing: 12) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                Text("Launching QEMU...")
                    .font(.callout)
                    .foregroundStyle(.white)
                Text(bootingCopy)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .padding(24)
            .background(.black.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        case .error(let msg):
            errorCard(title: "VM error", message: msg)
        case .stopped:
            if env.sessionSawSerial {
                let msg: String = {
                    let base = "The kernel started printing, then the session ended. Most likely iOS killed the process for memory pressure. Try lowering guest RAM in Settings (currently \(GuestRAM.current()) MB)."
                    if env.selectedVariant == "se" {
                        return base + "\n\nYou're in interpreter mode. If you want JIT: install via SideStore/AltStore instead of LiveContainer, then launch under StikDebug. LiveContainer's PluginKit runtime interferes with StikDebug's register injection."
                    }
                    return base
                }()
                errorCard(title: "VM session ended", message: msg)
            } else {
                EmptyView()
            }
        case .running:
            EmptyView()
        }
    }

    private func errorCard(title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.orange)
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            HStack(spacing: 12) {
                Button {
                    env.startEngine()
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                Button {
                    showSettings = true
                } label: {
                    Label("Settings", systemImage: "slider.horizontal.3")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
            Text("Note: QEMU holds process-global state. If Retry fails, close and reopen the app.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .padding(24)
        .background(.black.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            HStack(spacing: 8) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 10, height: 10)
                Text(env.vmState.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // v0.6.0: subtle single dot instead of the JIT/SE pill.
                // Tap opens a small info sheet.
                Button {
                    showJITSheet = true
                } label: {
                    Circle()
                        .fill(jitDotColor)
                        .frame(width: 8, height: 8)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("JIT status")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    env.startEngine()
                } label: {
                    Label("Restart VM", systemImage: "arrow.clockwise")
                }
                Button {
                    openWorkspaceInFiles()
                } label: {
                    Label("Open Workspace in Files", systemImage: "folder")
                }
                Button {
                    showSettings = true
                } label: {
                    Label("Settings", systemImage: "slider.horizontal.3")
                }
                if let url = env.pendingAuthURL {
                    Button {
                        authSheetURL = url
                        showAuthSheet = true
                    } label: {
                        Label("Open Claude Sign-in", systemImage: "person.badge.key")
                    }
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

    @ViewBuilder
    private var authSheet: some View {
        if let url = authSheetURL {
            VStack(spacing: 0) {
                SafariView(url: url)
                    .frame(maxHeight: .infinity)
                VStack(spacing: 8) {
                    Text("Paste the code from the browser and send it to the VM:")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    HStack {
                        TextField("Auth code", text: $codeToPaste)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled(true)
                            .textInputAutocapitalization(.never)
                        Button("Send") {
                            let trimmed = codeToPaste.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            var bytes = Array(trimmed.utf8)
                            bytes.append(0x0d)
                            env.engine?.send(bytes: bytes)
                            codeToPaste = ""
                            showAuthSheet = false
                            env.pendingAuthURL = nil
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding()
                .background(.thinMaterial)
            }
        }
    }

    private var stateColor: Color {
        switch env.vmState {
        case .stopped: return .gray
        case .starting: return .yellow
        case .running: return .green
        case .error: return .red
        }
    }

    private var jitDotColor: Color {
        env.selectedVariant == "jit" ? .green : Color.white.opacity(0.35)
    }

    private var bootingCopy: String {
        switch env.selectedVariant {
        case "jit":
            return "JIT active - boot expected in ~15-30 seconds."
        case "se":
            return "Interpreter mode - boot to login takes ~30-60 seconds on modern devices. The terminal will start streaming kernel messages shortly."
        default:
            return "Booting..."
        }
    }

    private func openWorkspaceInFiles() {
        guard let url = WorkspaceStore.resolve() else { return }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "shareddocuments"
        if let filesURL = components?.url {
            UIApplication.shared.open(filesURL)
        }
    }
}

/// Small explanation sheet the JIT dot opens.
private struct JITStatusSheet: View {
    let active: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(active ? Color.green : Color.gray.opacity(0.4))
                        .frame(width: 14, height: 14)
                    Text(active ? "JIT active" : "Interpreter mode")
                        .font(.headline)
                }
                Text(active
                    ? "The VM is running with JIT-compiled guest code. Boot is fast (~15-30 seconds) and Claude Code should feel responsive."
                    : "The VM runs in interpreter mode. Boot takes 30-60 seconds. Full JIT support (up to 10x faster) is on the roadmap - it depends on sideload infrastructure evolving so a JIT permission can actually land in a plugin-hosted iOS process."
                )
                .font(.callout)
                Text(active
                    ? "Under the hood: QEMU's TCG emits native ARM64 instructions instead of walking each guest instruction one-by-one."
                    : "Under the hood: interpreter is fine for Claude Code sessions. The 30-60 second boot is a one-time cost per launch.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                Spacer()
                Button("OK") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            }
            .padding(24)
            .navigationTitle("JIT status")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }
}

/// SFSafariViewController wrapped for SwiftUI (M3 sign-in handoff).
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}
