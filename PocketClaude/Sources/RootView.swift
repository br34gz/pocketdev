import SwiftUI

struct RootView: View {
    @AppStorage("setupComplete") private var setupComplete = false

    var body: some View {
        VStack(spacing: 0) {
            DiagnosticBanner()
            if setupComplete {
                MainView()
            } else {
                SetupWizardView()
            }
        }
    }
}

/// v0.2.2 diagnostic-build banner. Removed once the sideload launch is
/// no longer under bisection.
private struct DiagnosticBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "stethoscope")
            Text("v0.2.2 diagnostic build — QEMU frameworks NOT embedded. Boot log at Files → On My iPhone → PocketClaude → pocket-claude-boot.log")
                .font(.caption2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.85))
        .foregroundStyle(.black)
    }
}
