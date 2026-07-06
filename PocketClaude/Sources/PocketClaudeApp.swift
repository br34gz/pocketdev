import SwiftUI
import UIKit

/// v0.3.0: the real thing. All 22 UTM frameworks embedded, guest image
/// embedded (vmlinuz-virt, initramfs-virt, alpine-claude.qcow2.zst),
/// QEMUVMEngine wired for actual boot.
///
/// Bisection outcome (v0.2.4-v0.2.7): every framework layer launched
/// cleanly on device. The v0.2.0/v0.2.1 crash was NOT the framework
/// payload -- it was almost certainly qemu_init calling exit(2) on
/// arg errors, dragging the whole process down before we saw any
/// Swift-side error. v0.3.0 guards that:
///   - QEMUBootstrap.c installs an atexit hook that logs
///     qemu_exit_hook before termination
///   - QEMUVMEngine preflight-checks every argv file path; missing
///     paths become VMState.error before qemu_init is called
///   - a 90-second boot-timeout watchdog raises .error if no
///     console output arrives
///   - MainView shows a status overlay: "Launching QEMU..." during
///     starting, error + Retry on failure
///
/// Boot log entries in order of expected occurrence:
///   dylib_ctor, framework_layer_glib..qemu, app_init,
///   delegate_launch, root_appear,
///   wizard_finish_tapped, wizard_finish_done,
///   mainview_body, mainview_appear, env_start_engine,
///   env_pick_qemu_engine, qemu_engine_start,
///   qemu_assets_materialize_start, zstd_decompress_start,
///   zstd_decompress_ok, qemu_assets_materialized,
///   qemu_engine_preflight_ok, qemu_runtime_dir_ready,
///   qemu_argv_ready, argv[0..N]=..., qemu_atexit_armed,
///   qemu_bootstrap_dlopen_start/ok, qemu_bootstrap_dlsym_ok,
///   qemu_init_call, [qemu_exit_hook if it dies],
///   qemu_init_return, qemu_main_loop_entered,
///   console_socket_connected, first_serial_output,
///   BOOT_OK_received, AUTH_URL_received

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
        logBoot("framework_layer_qemu")
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
