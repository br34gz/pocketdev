import Foundation

/// Locates and, on first launch, materialises the guest disk image and
/// kernel/initramfs shipped in the app bundle. The base image is stored
/// zstd-compressed to keep the IPA small (spec section 3); we decompress
/// to Documents on first launch.
enum GuestAssets {
    /// nil if the app was built without an embedded guest image (fallback
    /// tier from v0.1) — in that case the VM engine is not started.
    struct Paths {
        let disk: URL          // decompressed qcow2 in Documents/
        let kernel: URL        // vmlinuz-virt (readable from bundle)
        let initramfs: URL     // initramfs-virt (readable from bundle)
    }

    static var bundleGuestDir: URL? {
        Bundle.main.url(forResource: "GuestImage", withExtension: nil)
    }

    static var isEmbedded: Bool {
        guard let dir = bundleGuestDir else { return false }
        let compressed = dir.appendingPathComponent("alpine-claude.qcow2.zst")
        return FileManager.default.fileExists(atPath: compressed.path)
    }

    /// Prepare the on-disk paths, decompressing the qcow2 on first launch.
    /// Emits progress via the callback (0.0-1.0 by best guess of ratio).
    /// Throws on I/O or zstd error.
    static func materialize(progress: ((Double) -> Void)? = nil) throws -> Paths {
        guard let dir = bundleGuestDir else {
            throw NSError(domain: "PocketClaude", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No GuestImage/ in app bundle"
            ])
        }
        let bundleZst = dir.appendingPathComponent("alpine-claude.qcow2.zst")
        let bundleKernel = dir.appendingPathComponent("vmlinuz-virt")
        let bundleInitrd = dir.appendingPathComponent("initramfs-virt")

        let docs = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let disk = docs.appendingPathComponent("alpine-claude.qcow2")

        if !FileManager.default.fileExists(atPath: disk.path) {
            progress?(0.05)
            guard let frameworkPath = zstdFrameworkPath() else {
                throw NSError(domain: "PocketClaude", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "zstd.1.framework not found in app"
                ])
            }
            // Decompress into a .tmp then rename so a mid-decode crash
            // doesn't leave a truncated qcow2 that later boots would
            // happily open.
            let tmp = disk.appendingPathExtension("tmp")
            try? FileManager.default.removeItem(at: tmp)
            let rc = frameworkPath.withCString { fw in
                bundleZst.path.withCString { src in
                    tmp.path.withCString { dst in
                        pocket_zstd_decompress_file(fw, src, dst)
                    }
                }
            }
            if rc != 0 {
                throw NSError(domain: "PocketClaude", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "zstd decompress failed rc=\(rc)"
                ])
            }
            try FileManager.default.moveItem(at: tmp, to: disk)
            progress?(1.0)
        }
        return Paths(disk: disk, kernel: bundleKernel, initramfs: bundleInitrd)
    }

    /// Reset: delete the decompressed qcow2 so the next launch re-materialises
    /// (spec section 5, "wipe VM" settings action).
    static func wipe() throws {
        let docs = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        let disk = docs.appendingPathComponent("alpine-claude.qcow2")
        try? FileManager.default.removeItem(at: disk)
    }

    private static func zstdFrameworkPath() -> String? {
        let frameworksURL = Bundle.main.bundleURL.appendingPathComponent("Frameworks")
        let candidate = frameworksURL
            .appendingPathComponent("zstd.1.framework")
            .appendingPathComponent("zstd.1")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate.path : nil
    }

    /// Which QEMU variant we picked, and where it lives.
    struct QemuVariant {
        let name: String   // "jit" or "se"
        let path: String
    }

    /// v0.4.1 ships two qemu variants side by side:
    ///   qemu-aarch64-softmmu-jit.framework  (from UTM.ipa, 29 MB, JIT-only)
    ///   qemu-aarch64-softmmu-se.framework   (from UTM-SE.ipa, 191 MB, interpreter)
    /// Runtime picks JIT if the mmap-MAP_JIT probe succeeded, SE otherwise.
    /// SE always works; JIT only works when the runtime exec grant is in
    /// place (StikDebug + SideStore/AltStore, main app process context).
    static func qemuFrameworkPath() -> String? {
        selectQemuVariant()?.path
    }

    static func selectQemuVariant() -> QemuVariant? {
        let jitAvailable = pocket_probe_jit() == 1
        let preferred = jitAvailable ? "jit" : "se"
        if let variant = variantIfPresent(preferred) { return variant }
        // Fall back to the other one if we somehow shipped an asymmetric
        // build (should never happen but defensive).
        return variantIfPresent(preferred == "jit" ? "se" : "jit")
    }

    private static func variantIfPresent(_ name: String) -> QemuVariant? {
        let frameworkName = "qemu-aarch64-softmmu-\(name)"
        let path = Bundle.main.bundleURL
            .appendingPathComponent("Frameworks")
            .appendingPathComponent("\(frameworkName).framework")
            .appendingPathComponent(frameworkName)
            .path
        return FileManager.default.fileExists(atPath: path)
            ? QemuVariant(name: name, path: path)
            : nil
    }
}
