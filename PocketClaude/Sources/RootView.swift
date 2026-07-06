import SwiftUI

struct RootView: View {
    @AppStorage("setupComplete") private var setupComplete = false
    @AppStorage(DebugMode.storageKey) private var debugMode = false
    @State private var showBootLog = false

    var body: some View {
        VStack(spacing: 0) {
            if debugMode {
                DiagnosticBanner(showBootLog: $showBootLog)
            }
            if setupComplete {
                MainView()
            } else {
                SetupWizardView()
            }
        }
        .sheet(isPresented: $showBootLog) { BootLogView() }
    }
}

enum DebugMode {
    static let storageKey = "debugMode"
}

/// v0.6.0: diagnostic banner gated on the "Debug mode" toggle in Settings.
/// Tap opens the combined boot log + qemu stderr viewer.
private struct DiagnosticBanner: View {
    @Binding var showBootLog: Bool
    var body: some View {
        Button {
            showBootLog = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "stethoscope")
                Text("Debug. Tap for boot log + QEMU stderr.")
                    .font(.caption2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.yellow.opacity(0.85))
            .foregroundStyle(.black)
        }
        .buttonStyle(.plain)
    }
}

private struct BootLogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var boot: String = "(reading...)"
    @State private var stderr: String = "(reading...)"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section(title: "pocket-claude-boot.log", body: boot)
                    section(title: "pocket-claude-qemu-stderr.log", body: stderr)
                }
                .padding()
            }
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Copy") {
                        UIPasteboard.general.string =
                            "=== boot log ===\n\(boot)\n\n=== qemu stderr ===\n\(stderr)"
                    }
                }
            }
            .onAppear(perform: reload)
        }
    }

    private func section(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                .foregroundStyle(.secondary)
            Text(body)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func reload() {
        boot = readDoc("pocket-claude-boot.log")
        stderr = readDoc("pocket-claude-qemu-stderr.log")
    }

    private func readDoc(_ name: String) -> String {
        guard let docs = try? FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
              ) else {
            return "(no Documents directory)"
        }
        let path = docs.appendingPathComponent(name).path
        guard let data = try? String(contentsOfFile: path, encoding: .utf8) else {
            return "(not present yet)"
        }
        return data.isEmpty ? "(empty)" : data
    }
}
