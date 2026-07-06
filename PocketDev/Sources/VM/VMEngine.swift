import Foundation

/// State of the guest VM.
enum VMState: Equatable {
    case stopped
    case starting
    case running(jit: Bool)
    case error(String)

    var label: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Starting"
        case .running(let jit): return jit ? "Running" : "Running (slow mode)"
        case .error: return "Error"
        }
    }
}

/// Abstraction over the VM backend. The terminal UI talks only to this
/// protocol, so the stub can be swapped for the real QEMU engine without
/// touching the UI layer.
///
/// TODO(M0) — QEMUVMEngine, the real implementation:
///   - Link utmapp/QEMUKit (SPM, source-only — provides QEMUVirtualMachine,
///     QMP monitor, launcher/interface protocols; requires linking glib-2.0).
///   - QEMU binaries are NOT shipped by QEMUKit. Two viable sources, both
///     prebuilt by the UTM project:
///       a) UTM CI "Sysroot-ios-arm64" artifacts (~268 MB) — full iOS
///          sysroot with qemu-aarch64-softmmu + deps as frameworks.
///       b) Frameworks/ extracted from UTM-SE.ipa release assets — the
///          no-JIT (TCTI interpreter) build, matching our slow-mode
///          fallback; stable unauthenticated download URLs.
///   - Implement QEMUKit's launcher to dlopen the qemu framework and run it
///     in-process (see UTM's UTMQemuSystem for the reference wiring).
///   - Arguments per spec section 2: -M virt, TCG, virtio-blk (qcow2),
///     virtio-net (SLIRP), virtio-9p (workspace), virtio-serial (console +
///     control channel), direct kernel boot with console=ttyAMA0 quiet.
///   - Do not chase JIT provisioning in v0.x; interpreter fallback is the
///     accepted path (spec sections 2 and 6).
protocol VMEngine: AnyObject {
    var state: VMState { get }
    /// Bytes emitted by the guest console; delivered on an arbitrary queue.
    var onOutput: (([UInt8]) -> Void)? { get set }
    var onStateChange: ((VMState) -> Void)? { get set }
    func start()
    func stop()
    /// Bytes typed by the user, destined for the guest console.
    func send(bytes: [UInt8])
}
