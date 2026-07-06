import Foundation

/// Real VM engine: dlopens qemu-aarch64-softmmu.framework from the app
/// bundle (extracted at CI time from UTM-SE.ipa - TCTI-interpreter build,
/// matches Pocket Claude's accepted slow-mode fallback per spec sections
/// 2 and 6) and runs it on a background thread. Speaks to the guest over
/// unix-socket chardevs: console (serial console -> SwiftTerm), control
/// (spec section 4.6 events), QMP (lifecycle pause/resume).
///
/// Only one instance can run per process - qemu holds process-global state.
///
/// v0.3.0 guards against `qemu_init`'s documented `exit(2)`-on-argv-error
/// behaviour with:
///   - an atexit hook (in QEMUBootstrap.c) that logs `qemu_exit_hook`
///     before the process tears down, so a crash still leaves a
///     breadcrumb in the boot log
///   - preflight file-existence checks on every path we pass in argv,
///     surfaced as `.error("<reason>")` before qemu_init is called
///   - a 90-second boot-timeout watchdog that transitions to
///     `.error("Boot timeout")` if no bytes arrive on the console
private let bootTimeoutSeconds: TimeInterval = 90

final class QEMUVMEngine: VMEngine {
    private(set) var state: VMState = .stopped {
        didSet {
            let s = state
            DispatchQueue.main.async { [weak self] in self?.onStateChange?(s) }
        }
    }
    var onOutput: (([UInt8]) -> Void)?
    var onStateChange: ((VMState) -> Void)?

    /// Callbacks for events parsed off the control channel.
    var onAuthURL: ((URL) -> Void)?
    var onBootOK: (() -> Void)?

    private let workspacePath: String?
    private let ramMB: Int
    private let vcpus: Int

    private let consoleSock = UnixSocket(label: "console")
    private let controlSock = UnixSocket(label: "control")
    private let qmpSock = UnixSocket(label: "qmp")

    private var runtimeDir: URL?
    private var controlBuffer = ""
    private var firstSerialSeen = false
    private var bootTimeoutTimer: DispatchSourceTimer?
    private var memPressureSource: DispatchSourceMemoryPressure?

    private static var isRunning = false

    init(workspacePath: String?, ramMB: Int? = nil, vcpus: Int = 2) {
        self.workspacePath = workspacePath
        // v0.3.3: default drops from 1024 to 768 to fit under
        // PluginKit-extension jetsam quotas (LiveContainer runs us as
        // one). User can retune via Settings; GuestRAM.current() reads
        // from UserDefaults with fallback to the default.
        self.ramMB = ramMB ?? GuestRAM.current()
        self.vcpus = vcpus
    }

    func start() {
        logPhase("qemu_engine_start")
        logPhase("qemu_engine_ram_mb=\(self.ramMB)")
        armMemoryPressureObserver()
        guard !Self.isRunning else {
            state = .error("VM already running in this process")
            return
        }
        guard let variant = GuestAssets.selectQemuVariant() else {
            state = .error("neither qemu-*-jit nor qemu-*-se framework present in bundle")
            return
        }
        logPhase("qemu_variant_selected=\(variant.name)")
        DispatchQueue.main.async {
            PocketClaudeEnvironment.shared.selectedVariant = variant.name
        }
        let qemuPath = variant.path
        Self.isRunning = true
        state = .starting

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                logPhase("qemu_assets_materialize_start")
                let assets = try GuestAssets.materialize()
                logPhase("qemu_assets_materialized")

                // Preflight: qemu_init calls exit(2) if a -kernel /
                // -initrd / -drive file is missing or unreadable.
                // Check up-front so we can raise a proper Swift error
                // instead of hitting exit() inside qemu.
                if let missing = preflightMissing(paths: [
                    ("kernel",  assets.kernel.path),
                    ("initrd",  assets.initramfs.path),
                    ("disk",    assets.disk.path),
                ]) {
                    logPhase("qemu_engine_preflight_failed")
                    self.finish(with: .error("preflight failed: \(missing) not readable"))
                    return
                }
                if let ws = self.workspacePath,
                   !FileManager.default.fileExists(atPath: ws) {
                    logPhase("qemu_engine_preflight_failed_workspace")
                    self.finish(with: .error("workspace path not readable: \(ws)"))
                    return
                }
                logPhase("qemu_engine_preflight_ok")

                let dir = try self.prepareRuntimeDir()
                self.runtimeDir = dir
                logPhase("qemu_runtime_dir=\(dir.path)")
                logPhase("qemu_runtime_dir_ready")

                // Single-char names to stay under sun_path 103-char limit.
                let consolePath = try self.socketPath(dir: dir, name: "c")
                let controlPath = try self.socketPath(dir: dir, name: "k")
                let qmpPath     = try self.socketPath(dir: dir, name: "q")
                logPhase("socket_paths_ok")

                // -display none suppresses SDL/Cocoa init. -nodefaults +
                // -no-user-config for a stripped baseline; every device
                // is added explicitly.
                // -L <dir> tells qemu where to look for firmware ROMs.
                // v0.3.1's qemu stderr showed "failed to find romfile
                // efi-virtio.rom" - the QEMU framework doesn't include
                // its pc-bios directory. CI now copies UTM's qemu/
                // (minus the huge edk2-*.fd UEFI files we don't need
                // for direct-kernel boot) into
                // Payload/PocketClaude.app/qemu-firmware/.
                let romsDir = Bundle.main.bundleURL
                    .appendingPathComponent("qemu-firmware").path
                logPhase("qemu_roms_dir=\(romsDir)")

                var args: [String] = [
                    "qemu-aarch64-softmmu",
                    "-L", romsDir,
                    "-M", "virt,highmem=off",
                    "-cpu", "cortex-a72",
                    "-smp", "\(self.vcpus)",
                    "-m", "\(self.ramMB)",
                    "-display", "none",
                    "-nodefaults",
                    "-no-user-config",
                    "-rtc", "base=utc,clock=host",
                    "-kernel", assets.kernel.path,
                    "-initrd", assets.initramfs.path,
                    "-append", "console=ttyAMA0 root=/dev/vda rootfstype=ext4 rw quiet",
                    "-drive", "file=\(assets.disk.path),if=virtio,format=qcow2,cache=writeback,discard=unmap",
                    // v0.3.2: switch from virtio-net-pci to virtio-net-device
                    // (MMIO). The MMIO transport on -M virt doesn't need a
                    // PCI expansion ROM, sidestepping efi-virtio.rom
                    // entirely. Belt-and-braces on top of the -L fix.
                    "-netdev", "user,id=net0",
                    "-device", "virtio-net-device,netdev=net0",
                    "-chardev", "socket,id=console0,path=\(consolePath),server=on,wait=off",
                    "-serial", "chardev:console0",
                    // Control channel: use virtio-serial-device (MMIO) too
                    // for consistency; virtio-serial-pci was fine but
                    // -device virtio-serial-device is the equivalent
                    // MMIO transport and doesn't touch any PCI ROM.
                    "-device", "virtio-serial-device,id=vser0",
                    "-chardev", "socket,id=ctrl0,path=\(controlPath),server=on,wait=off",
                    "-device", "virtserialport,chardev=ctrl0,name=pocket.control",
                    "-qmp", "unix:\(qmpPath),server=on,wait=off",
                ]

                if let ws = self.workspacePath {
                    args.append(contentsOf: [
                        "-fsdev", "local,security_model=mapped,id=fsdev0,path=\(ws)",
                        "-device", "virtio-9p-pci,fsdev=fsdev0,mount_tag=workspace",
                    ])
                }

                logPhase("qemu_argv_ready")
                self.logArgv(args)

                // v0.3.1: capture qemu stderr to a file so a crash inside
                // qemu_init leaves the actual error message behind.
                let stderrPath = self.stderrLogPath()
                if let stderrPath {
                    let rc = stderrPath.withCString { pocket_qemu_redirect_stderr($0) }
                    logPhase(rc == 0 ? "stderr_redirected" : "stderr_redirect_failed")
                }

                DispatchQueue.main.async { self.armBootTimeout() }

                // v0.3.1: delay the initial socket-connect attempts so
                // we don't spam "connect_failed" while qemu is still
                // binding. UnixSocket.connect already retries, so a
                // slight lead is enough.
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) {
                    self.connectSockets(consolePath: consolePath,
                                        controlPath: controlPath,
                                        qmpPath: qmpPath)
                }

                self.runQemu(dylib: qemuPath, args: args)
                logPhase("qemu_engine_finished")
                self.finish(with: .stopped)
            } catch {
                logPhase("qemu_engine_exception")
                self.finish(with: .error(error.localizedDescription))
            }
        }
    }

    private func finish(with newState: VMState) {
        cancelBootTimeout()
        cancelMemoryPressureObserver()
        pocket_boot_log_rss()
        Self.isRunning = false
        state = newState
    }

    // MARK: - Memory pressure

    private func armMemoryPressureObserver() {
        cancelMemoryPressureObserver()
        let src = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: .global(qos: .utility)
        )
        src.setEventHandler {
            let event = src.data
            if event.contains(.critical) {
                logPhase("mem_pressure_critical")
                pocket_boot_log_rss()
            } else if event.contains(.warning) {
                logPhase("mem_pressure_warning")
                pocket_boot_log_rss()
            }
        }
        src.resume()
        memPressureSource = src
    }

    private func cancelMemoryPressureObserver() {
        memPressureSource?.cancel()
        memPressureSource = nil
    }

    private func runQemu(dylib: String, args: [String]) {
        var cArgs: [UnsafePointer<CChar>?] = args.map { s in
            UnsafePointer(strdup(s))
        }
        defer {
            for p in cArgs {
                if let p { free(UnsafeMutablePointer(mutating: p)) }
            }
        }
        let argc = Int32(args.count)
        cArgs.withUnsafeMutableBufferPointer { buf in
            _ = pocket_qemu_run(dylib, argc, buf.baseAddress)
        }
    }

    private func connectSockets(consolePath: String, controlPath: String, qmpPath: String) {
        // Console: bytes both ways. Log the first arrival so we know
        // qemu is far enough along to have accepted the chardev socket.
        consoleSock.onData = { [weak self] bytes in
            guard let self else { return }
            if !self.firstSerialSeen {
                self.firstSerialSeen = true
                logPhase("first_serial_output")
                DispatchQueue.main.async {
                    self.cancelBootTimeout()
                    PocketClaudeEnvironment.shared.sessionSawSerial = true
                }
            }
            self.onOutput?(bytes)
        }
        if consoleSock.connect(path: consolePath) {
            logPhase("console_socket_connected")
            consoleSock.startReading()
        } else {
            logPhase("console_socket_connect_failed")
        }

        controlSock.onData = { [weak self] bytes in self?.handleControlBytes(bytes) }
        if controlSock.connect(path: controlPath) {
            logPhase("control_socket_connected")
            controlSock.startReading()
        }

        qmpSock.onData = { _ in /* silently absorb replies */ }
        if qmpSock.connect(path: qmpPath) {
            logPhase("qmp_socket_connected")
            qmpSock.startReading()
            let neg = "{\"execute\":\"qmp_capabilities\"}\n"
            qmpSock.write(Array(neg.utf8))
            state = .running(jit: false)
        }
    }

    private func handleControlBytes(_ bytes: [UInt8]) {
        guard let s = String(bytes: bytes, encoding: .utf8) else { return }
        controlBuffer += s
        while let nlIdx = controlBuffer.firstIndex(of: "\n") {
            let line = String(controlBuffer[..<nlIdx])
                .trimmingCharacters(in: .whitespaces)
            controlBuffer.removeSubrange(...nlIdx)
            handleControlLine(line)
        }
    }

    private func handleControlLine(_ line: String) {
        if line == "BOOT_OK" {
            logPhase("BOOT_OK_received")
            DispatchQueue.main.async { [weak self] in self?.onBootOK?() }
            return
        }
        if line.hasPrefix("AUTH_URL ") {
            let raw = String(line.dropFirst("AUTH_URL ".count))
            if let url = URL(string: raw) {
                logPhase("AUTH_URL_received")
                DispatchQueue.main.async { [weak self] in self?.onAuthURL?(url) }
            }
            return
        }
        if line.hasPrefix("CLAUDE_VARIANT ") {
            // Guest reports which claude-install strategy landed.
            // v0.5.x: apk:claude-code=X or npm:@anthropic-ai/...
            // v0.6.x: npm:@anthropic-ai/...
            let raw = String(line.dropFirst("CLAUDE_VARIANT ".count))
            logPhase("claude_variant=\(raw)")
            DispatchQueue.main.async {
                PocketClaudeEnvironment.shared.guestClaudeVariant = raw
            }
            return
        }
        if line.hasPrefix("GUEST_OS ") {
            // v0.6.0+: guest broadcasts its OS name (debian-12, etc).
            let raw = String(line.dropFirst("GUEST_OS ".count))
            logPhase("guest_os=\(raw)")
            DispatchQueue.main.async {
                PocketClaudeEnvironment.shared.guestOS = raw
            }
        }
    }

    func send(bytes: [UInt8]) {
        consoleSock.write(bytes)
    }

    func sendToControl(_ text: String) {
        controlSock.write(Array(text.utf8))
    }

    func stop() {
        sendQMP("{\"execute\":\"quit\"}")
    }

    func pause() {
        sendQMP("{\"execute\":\"stop\"}")
    }

    func resume() {
        sendQMP("{\"execute\":\"cont\"}")
    }

    private func sendQMP(_ json: String) {
        qmpSock.write(Array((json + "\n").utf8))
    }

    private func prepareRuntimeDir() throws -> URL {
        // v0.3.1: Darwin's sockaddr_un.sun_path is capped at 104 chars
        // including nul. v0.3.0 placed sockets under Documents/, which
        // becomes 140+ chars once the app container UUID + LiveContainer's
        // Documents/Data/Application/<guest-uuid>/ nesting is factored
        // in - QEMU's bind() fails and it exit(2)s.
        //
        // NSTemporaryDirectory() is the shortest path we can reach that
        // is app-writable. Combined with single-char socket filenames
        // ("c", "k", "q") this stays under the limit on both plain
        // sideloads and LiveContainer setups.
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        // Don't nest a subdir - every extra path component costs us.
        // The launcher itself owns the sockets by unique name in tmp.
        return base
    }

    /// Return a socket path under runtime dir, guarded against Darwin's
    /// sun_path limit. Throws if the resulting path would not bind.
    private func socketPath(dir: URL, name: String) throws -> String {
        let path = dir.appendingPathComponent(name).path
        // 104 - 1 (nul) = 103 char usable budget.
        if path.utf8.count > 103 {
            logPhase("socket_path_too_long")
            logPhase("path=\(path) len=\(path.utf8.count)")
            throw NSError(domain: "PocketClaude", code: 42, userInfo: [
                NSLocalizedDescriptionKey:
                    "Unix socket path too long for Darwin (\(path.utf8.count) > 103 chars): \(path)"
            ])
        }
        // Also remove any stale socket from a previous crashed run;
        // qemu's bind() fails with EADDRINUSE otherwise.
        try? FileManager.default.removeItem(atPath: path)
        return path
    }

    // MARK: - Boot timeout watchdog

    private func armBootTimeout() {
        cancelBootTimeout()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + bootTimeoutSeconds)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if !self.firstSerialSeen {
                logPhase("boot_timeout")
                self.state = .error("Boot timeout - no console output in \(Int(bootTimeoutSeconds))s. Copy the boot log from the diagnostic banner.")
            }
        }
        timer.resume()
        bootTimeoutTimer = timer
    }

    private func cancelBootTimeout() {
        bootTimeoutTimer?.cancel()
        bootTimeoutTimer = nil
    }

    // MARK: - Boot log helpers

    private func logArgv(_ args: [String]) {
        // v0.3.1: log the full arg without truncation. Some socket paths
        // are 100+ chars and truncating them hid the sun_path overrun
        // in v0.3.0.
        for (i, a) in args.enumerated() {
            logPhase("argv[\(i)]=\(a)")
        }
    }

    /// Path we redirect qemu stderr into. Sits next to the boot log so
    /// the in-app viewer can show it too.
    private func stderrLogPath() -> String? {
        guard let docs = try? FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return docs.appendingPathComponent("pocket-claude-qemu-stderr.log").path
    }
}

/// Free function so both instance methods and background closures can
/// call into the C boot logger without capturing self.
private func logPhase(_ phase: String) {
    phase.withCString { pocket_boot_log($0) }
}

private func preflightMissing(paths: [(name: String, path: String)]) -> String? {
    for (name, path) in paths {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        if !exists {
            return "\(name) at \(path)"
        }
        if isDir.boolValue {
            return "\(name) is a directory, expected file: \(path)"
        }
    }
    return nil
}
