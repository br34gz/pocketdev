import Darwin
import Foundation

/// Probes whether the process can map writable+executable memory, which is
/// what QEMU's TCG JIT needs (spec section 5, wizard step 2). On a plain
/// sideloaded install this fails; it succeeds when JIT has been enabled via
/// StikDebug / SideJITServer / a debugger attach. Without JIT the VM falls
/// back to the TCTI interpreter ("slow mode", spec section 6).
enum JITProbe {
    static func canAllocateRWX() -> Bool {
        let size = 16384
        let ptr = mmap(
            nil,
            size,
            PROT_READ | PROT_WRITE | PROT_EXEC,
            MAP_PRIVATE | MAP_ANON,
            -1,
            0
        )
        guard let ptr, ptr != MAP_FAILED else { return false }
        munmap(ptr, size)
        return true
    }
}
