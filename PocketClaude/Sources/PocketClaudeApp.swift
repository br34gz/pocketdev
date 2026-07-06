import SwiftUI
import UIKit

/// v0.2.3: diagnostic-plus-fix build. Still no UTM/QEMU frameworks.
///
/// v0.2.2 confirmed the app launches (all four expected phases hit the
/// boot log). It also revealed a separate Swift-side crash: tapping
/// "Finish" on the wizard's sign-in step crashed. Suspected cause:
/// `@EnvironmentObject var env: PocketClaudeEnvironment` in MainView
/// `fatalError`s if the environment object isn't found during the
/// RootView -> MainView view swap.
///
/// Fix: PocketClaudeEnvironment is now a plain shared singleton, no
/// SwiftUI environment plumbing involved. Every view that needs it just
/// calls `PocketClaudeEnvironment.shared`.
///
/// Boot log (Documents/pocket-claude-boot.log) extended with:
///   dylib_ctor            — C constructor ran
///   app_init              — Swift App.init ran
///   delegate_launch       — UIApplicationDelegate fired
///   root_appear           — first WindowGroup scene rendered
///   wizard_finish_tapped  — top of the Finish button handler
///   wizard_finish_done    — after setupComplete = true
///   mainview_body         — MainView.body computed
///   mainview_appear       — MainView.onAppear ran
///   env_start_engine      — env.startEngine() called
///   stub_engine_start     — StubVMEngine.start entry

@inline(__always)
func logBoot(_ phase: String) {
    phase.withCString { pocket_boot_log($0) }
}

@main
struct PocketClaudeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Layer marker: which UTM framework subset is embedded in this
        // build. Read by us in the boot log to cross-reference which
        // build the user is running without having to check the version
        // string. See release-notes body for each build's framework list.
        logBoot("framework_layer_glib")
        logBoot("framework_layer_pixman_crypto")
        logBoot("framework_layer_io_display")
        logBoot("app_init")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .onAppear { logBoot("root_appear") }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                (PocketClaudeEnvironment.shared.engine as? QEMUVMEngine)?.pause()
            case .active:
                (PocketClaudeEnvironment.shared.engine as? QEMUVMEngine)?.resume()
            default: break
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        logBoot("delegate_launch")
        return true
    }
}
