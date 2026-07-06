import SwiftUI
import SafariServices

struct MainView: View {
    @ObservedObject var env = PocketDevEnvironment.shared
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
            .sheet(isPresented: $showJITSheet) {
                StatusSheet(
                    vmState: env.vmState,
                    jitActive: env.selectedVariant == "jit",
                    guestOS: env.guestOS,
                    claudeVariant: env.guestClaudeVariant
                )
            }
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
        case .starting, .running:
            if env.bootStage != .ready && env.bootStage != .idle {
                bootStageCard
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .animation(.easeInOut(duration: 0.35), value: env.bootStage)
            }
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
        }
    }

    /// v0.7.2 boot-stages overlay. Advances through 4 named stages
    /// (Starting / Booting / Logging in / Starting Claude Code), then
    /// dismisses itself when claude's TUI drops into view.
    private var bootStageCard: some View {
        VStack(spacing: 20) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
                .scaleEffect(1.4)
                .id("spinner")
            VStack(spacing: 8) {
                Text(env.bootStage.title)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.white)
                    .id("title-\(env.bootStage.rawValue)")
                    .transition(.opacity)
                Text(subtitleCopy)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Progress bar underlays the whole thing to convey advancement.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.15))
                    Capsule().fill(Color.white.opacity(0.75))
                        .frame(width: geo.size.width * env.bootStage.progress)
                        .animation(.easeInOut(duration: 0.6), value: env.bootStage)
                }
            }
            .frame(height: 3)
            .frame(maxWidth: 220)
            // Step-checklist under the bar (visible-only in landscape / iPad).
            HStack(spacing: 6) {
                ForEach([BootStage.launching, .booting, .loggingIn, .startingClaude], id: \.rawValue) { stage in
                    Circle()
                        .fill(stage <= env.bootStage ? Color.white.opacity(0.9) : Color.white.opacity(0.2))
                        .frame(width: 6, height: 6)
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .frame(maxWidth: 320)
        .background(.black.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var subtitleCopy: String {
        switch env.bootStage {
        case .launching, .idle:
            return env.selectedVariant == "jit"
                ? "JIT active — usually 15-30 seconds."
                : "Interpreter mode — usually 30-60 seconds. The terminal will start streaming below."
        case .booting:
            return "Kernel started. Systemd services coming up..."
        case .loggingIn:
            return "Login prompt hit. Auto-login as 'dev' about to fire."
        case .startingClaude:
            return "Guest is warm. Claude Code is opening a session."
        case .ready:
            return ""
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
            // v0.7.2: the JIT dot was an 8-pt Circle with .plain button
            // style - tap area is effectively zero on iOS 17 and the
            // sheet never opened. Move the tap target to the whole
            // state cluster (state dot + label + JIT dot) with an
            // explicit content shape so any part of the cluster works.
            Button {
                showJITSheet = true
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(stateColor)
                        .frame(width: 10, height: 10)
                    Text(env.vmState.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Circle()
                        .fill(jitDotColor)
                        .frame(width: 8, height: 8)
                }
                .contentShape(Rectangle())
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Status: \(env.vmState.label). JIT \(env.selectedVariant == "jit" ? "active" : "inactive"). Tap for details.")
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

/// Combined VM + JIT + guest info sheet. Reached by tapping the status
/// cluster in the top-left of MainView's toolbar.
private struct StatusSheet: View {
    let vmState: VMState
    let jitActive: Bool
    let guestOS: String?
    let claudeVariant: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    row(
                        color: vmStateColor,
                        title: "VM \(vmStateLabel)",
                        subtitle: vmStateCopy
                    )
                    row(
                        color: jitActive ? .green : Color.gray.opacity(0.4),
                        title: jitActive ? "JIT active" : "Interpreter mode",
                        subtitle: jitCopy
                    )
                    if let os = guestOS {
                        row(
                            color: .blue,
                            title: "Guest: \(os)",
                            subtitle: claudeVariant ?? "Claude Code install strategy unknown until BOOT_OK arrives from the control channel."
                        )
                    }
                    Text("Full JIT support is coming — it depends on sideload infrastructure evolving so a JIT execute grant can land inside a plugin-hosted iOS process. For now interpreter mode is a working baseline; the 30-60s boot is a one-time cost per launch and everything after is just claude-code doing its thing.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
                .padding(24)
            }
            .navigationTitle("Status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.bold()
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(color: Color, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(color).frame(width: 14, height: 14).padding(.top, 4)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(subtitle).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var vmStateColor: Color {
        switch vmState {
        case .stopped:  return .gray
        case .starting: return .yellow
        case .running:  return .green
        case .error:    return .red
        }
    }

    private var vmStateLabel: String { vmState.label.lowercased() }

    private var vmStateCopy: String {
        switch vmState {
        case .stopped:  return "The virtual machine isn't running. Restart from the ... menu to try again."
        case .starting: return "QEMU is spinning up the Debian guest. Progress overlay on the terminal shows the current stage."
        case .running:  return "The VM is running and the terminal is live."
        case .error(let msg): return msg
        }
    }

    private var jitCopy: String {
        jitActive
            ? "QEMU's TCG is emitting native ARM64 code for the guest CPU. Boot is fast, guest responsiveness is close to native."
            : "QEMU walks each guest instruction one-by-one (interpreter). Slower but works everywhere. Full JIT needs a sideload-runtime exec grant we can't get from a plugin-hosted process today."
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
