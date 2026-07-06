import SwiftUI
import SafariServices

struct MainView: View {
    /// v0.2.3: switched from @EnvironmentObject to @ObservedObject on the
    /// shared singleton. `@EnvironmentObject` `fatalError`s if the object
    /// isn't found in the environment during a view transition; that was
    /// the suspected cause of the v0.2.2 crash-on-Finish.
    @ObservedObject var env = PocketClaudeEnvironment.shared
    @AppStorage("setupComplete") private var setupComplete = false
    @State private var showAuthSheet = false
    @State private var authSheetURL: URL?
    @State private var codeToPaste: String = ""
    @State private var showSettings = false

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
            .navigationTitle(WorkspaceStore.displayName ?? "Pocket Claude")
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
            // If the session started emitting to the console and then
            // stopped without an explicit error, we most likely got
            // jetsam-killed by iOS's memory manager. Give the user the
            // specific hint per spec plus a Retry.
            if env.sessionSawSerial {
                let msg: String = {
                    let base = "The Alpine kernel started printing, then the session ended. Most likely iOS killed the process for memory pressure. Try lowering guest RAM in Settings (currently \(GuestRAM.current()) MB)."
                    if env.selectedVariant == "se" {
                        return base + "\n\nYou're in interpreter mode (SE fallback). If you want JIT: install directly via SideStore/AltStore instead of LiveContainer, then re-launch under StikDebug. LiveContainer's PluginKit runtime interferes with StikDebug's register injection so JIT can't land."
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
            Text("Note: QEMU holds process-global state, so Retry only works cleanly once. If it fails again, close and reopen the app (via the launcher that gave it JIT, if applicable).")
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
            HStack(spacing: 6) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 10, height: 10)
                Text(env.vmState.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                variantPill
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
                    Text("Paste the code shown in the browser, then send it back to the VM:")
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
                            bytes.append(0x0d) // CR
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

    private var bootingCopy: String {
        switch env.selectedVariant {
        case "jit":
            return "JIT active -- boot to Alpine login expected in ~15-30 seconds."
        case "se":
            return "Interpreter mode (no runtime exec grant). Boot to Alpine login can take 5-20 minutes. Be patient; the terminal will start streaming kernel messages as they arrive."
        default:
            return "Booting Alpine..."
        }
    }

    /// Small pill next to the VM state indicator in the toolbar showing
    /// which QEMU variant the engine picked. `nil` before start.
    private var variantPill: some View {
        Group {
            if let v = env.selectedVariant {
                Text(v.uppercased())
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(v == "jit" ? Color.green.opacity(0.7) : Color.orange.opacity(0.7))
                    .foregroundStyle(.black)
                    .clipShape(Capsule())
            } else {
                EmptyView()
            }
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

/// SFSafariViewController wrapped for SwiftUI (M3 sign-in handoff).
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}
