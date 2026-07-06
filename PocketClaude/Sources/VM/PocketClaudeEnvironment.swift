import Foundation
import SwiftUI

/// Shared, observable state that both the wizard and main view read/write:
/// which VM engine to hand the terminal, workspace URL, auth handoff URL.
///
/// Exposed via a process-wide singleton (`PocketClaudeEnvironment.shared`)
/// rather than SwiftUI's environment plumbing. v0.2.2 confirmed the app
/// itself launches; v0.2.2 also crashed when the wizard's "Finish" button
/// flipped `setupComplete` and the RootView swapped from SetupWizardView
/// to MainView. Most likely culprit: MainView used `@EnvironmentObject`
/// for this class, and `@EnvironmentObject` `fatalError`s if the object
/// isn't found in the environment during the transition. Sidestepping
/// that entirely by not touching SwiftUI's environment for state.
///
/// Not @MainActor because @StateObject property-initializer runs during
/// view init and Swift-6 strict concurrency will crash at launch if the
/// environment is annotated. All publishes happen through DispatchQueue
/// .main hops instead.
final class PocketClaudeEnvironment: ObservableObject {
    static let shared = PocketClaudeEnvironment()

    @Published private(set) var engine: (any VMEngine)?
    @Published var pendingAuthURL: URL?
    @Published var vmState: VMState = .stopped
    /// True once the current session has seen at least one byte on the
    /// serial console. Used by MainView to distinguish "died before boot"
    /// (probably argv / firmware / socket issue) from "died after boot
    /// progressed" (probably jetsam / iOS memory kill).
    @Published var sessionSawSerial: Bool = false
    /// Which QEMU variant the engine picked at start: "jit" or "se"
    /// (or nil if never started). Drives the "expected boot time" copy
    /// on the status overlay.
    @Published var selectedVariant: String?

    /// URL the guest just published; wizard step 3 offers Safari handoff.
    var latestAuthURL: URL? { pendingAuthURL }

    /// Detected auth URLs from console output (fallback path when the
    /// guest's control-channel emitter isn't running yet).
    private var seenURLs = Set<String>()

    func startEngine() {
        "env_start_engine".withCString { pocket_boot_log($0) }
        sessionSawSerial = false
        stopEngine()
        let workspacePath = resolvedWorkspacePath()
        let real: any VMEngine
        if GuestAssets.isEmbedded && GuestAssets.qemuFrameworkPath() != nil {
            "env_pick_qemu_engine".withCString { pocket_boot_log($0) }
            let e = QEMUVMEngine(workspacePath: workspacePath)
            e.onAuthURL = { [weak self] url in
                DispatchQueue.main.async { self?.pendingAuthURL = url }
            }
            real = e
        } else {
            "env_pick_stub_engine".withCString { pocket_boot_log($0) }
            real = StubVMEngine()
        }
        real.onStateChange = { [weak self] s in
            DispatchQueue.main.async { self?.vmState = s }
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
