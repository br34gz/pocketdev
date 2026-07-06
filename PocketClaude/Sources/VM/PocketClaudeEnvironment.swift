import Foundation
import SwiftUI

/// Shared, observable state that both the wizard and main view read/write:
/// which VM engine to hand the terminal, workspace URL, auth handoff URL.
/// Not @MainActor because SwiftUI's @StateObject property-initializer
/// runs during view init and Swift-6 strict concurrency will crash at
/// launch if the environment is annotated. All publishes happen through
/// DispatchQueue.main hops instead.
final class PocketClaudeEnvironment: ObservableObject {
    @Published private(set) var engine: (any VMEngine)?
    @Published var pendingAuthURL: URL?
    @Published var vmState: VMState = .stopped

    /// URL the guest just published; wizard step 3 offers Safari handoff.
    var latestAuthURL: URL? { pendingAuthURL }

    /// Detected auth URLs from console output (fallback path when the
    /// guest's control-channel emitter isn't running yet).
    private var seenURLs = Set<String>()

    func startEngine() {
        stopEngine()
        let workspacePath = resolvedWorkspacePath()
        _ = workspacePath  // unused in diagnostic build; keeps the resolver warm
        let real: any VMEngine
        // v0.2.2 diagnostic build: force the stub engine unconditionally.
        // The UTM framework path is deliberately unreachable so we can
        // prove whether the sideload-launch crash lives in our own Swift
        // or in the framework payload. Original guard, kept commented
        // for the re-enable path:
        //   if GuestAssets.isEmbedded && GuestAssets.qemuFrameworkPath() != nil {
        //     let e = QEMUVMEngine(workspacePath: workspacePath); ...
        //   }
        real = StubVMEngine()
        real.onStateChange = { [weak self] s in
            DispatchQueue.main.async { self?.vmState = s }
        }
        // Wrap output to also scan for auth URLs — belt and braces
        // for M3 when the guest's control-channel emitter hasn't caught
        // the URL (e.g. it flew past before we hooked up).
        let originalOnOutput = real.onOutput
        real.onOutput = { [weak self, weak real] bytes in
            originalOnOutput?(bytes)
            real?.onOutput = originalOnOutput
            self?.scanForAuthURL(bytes)
        }
        engine = real
        real.start()
    }

    func stopEngine() {
        engine?.stop()
        engine = nil
        vmState = .stopped
    }

    private func resolvedWorkspacePath() -> String? {
        guard let url = WorkspaceStore.resolve() else { return nil }
        let ok = url.startAccessingSecurityScopedResource()
        if ok {
            // NOTE: the app relinquishes access on next launch. For a v0.2
            // baseline we hold the scope for the app's lifetime — matches
            // spec section 5 "resolve bookmark, startAccessing, hand path
            // to QEMU's 9p export." Future revision should force-download
            // undownloaded iCloud items here (NSFileManager
            // startDownloadingUbiquitousItem + NSFileCoordinator).
        }
        return url.path
    }

    private func scanForAuthURL(_ bytes: [UInt8]) {
        guard let s = String(bytes: bytes, encoding: .utf8) else { return }
        // Broad match: any https URL the guest emits during setup-token.
        // We debounce by URL string so a single URL doesn't spam.
        let pattern = #"https://[a-zA-Z0-9./?&=_%\-#]+"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return }
        let ns = s as NSString
        re.enumerateMatches(in: s, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m else { return }
            let match = ns.substring(with: m.range)
            guard match.contains("claude.ai") || match.contains("anthropic") else { return }
            if self.seenURLs.insert(match).inserted, let url = URL(string: match) {
                DispatchQueue.main.async { self.pendingAuthURL = url }
            }
        }
    }
}
