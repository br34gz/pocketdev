import SwiftUI
import UIKit

/// v0.2.2 is the diagnostic build: no UTM/QEMU frameworks embedded, no
/// guest image. Boot log lands at Documents/pocket-claude-boot.log,
/// visible in the Files app under On My iPhone → PocketClaude.
///
///  - dylib_ctor    → dyld loaded our binary (C constructor ran)
///  - app_init      → PocketClaudeApp.init() ran (Swift+SwiftUI up)
///  - delegate_launch → UIApplicationDelegate hook fired
///  - root_appear   → first SwiftUI view mounted
///
/// If the log file doesn't even exist after the user reinstalls, the
/// crash is pre-main (dyld / amfid). If it stops after `dylib_ctor`,
/// Swift itself is dying at init. Etc.

private func logBoot(_ phase: String) {
    phase.withCString { pocket_boot_log($0) }
}

@main
struct PocketClaudeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var env: PocketClaudeEnvironment
    @Environment(\.scenePhase) private var scenePhase

    init() {
        logBoot("app_init")
        _env = StateObject(wrappedValue: PocketClaudeEnvironment())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(env)
                .onAppear { logBoot("root_appear") }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                (env.engine as? QEMUVMEngine)?.pause()
            case .active:
                (env.engine as? QEMUVMEngine)?.resume()
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
