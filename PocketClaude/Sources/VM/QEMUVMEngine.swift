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

    private static var isRunning = false

    init(workspacePath: String?, ramMB: Int = 1024, vcpus: Int = 2) {
        self.workspacePath = workspacePath
        self.ramMB = ramMB
        self.vcpus = vcpus
    }

    func start() {
        logPhase("qemu_engine_start")
        guard !Self.isRunning else {
            state = .error("VM already running in this process")
            return
        }
        guard let qemuPath = GuestAssets.qemuFrameworkPath() else {
            state = .error("qemu-aarch64-softmmu.framework missing from app bundle")
            return
        }
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
                logPhase("qemu_runtime_dir_ready")

                let consolePath = dir.appendingPathComponent("console.sock").path
                let controlPath = dir.appendingPathComponent("control.sock").path
                let qmpPath = dir.appendingPathComponent("qmp.sock").path

                // -display none suppresses SDL/Cocoa init. -nodefaults +
                // -no-user-config for a stripped baseline; every device
                // is added explicitly.
                var args: [String] = [
                    "qemu-aarch64-softmmu",
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
                    "-nic", "user,model=virtio-net-pci",
                    "-chardev", "socket,id=console0,path=\(consolePath),server=on,wait=off",
                    "-serial", "chardev:console0",
                    "-device", "virtio-serial-pci,id=vser0",
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
                // Also log the argv itself so we can see exactly what
                // qemu got if it dies inside qemu_init.
                self.logArgv(args)

                // Arm the boot-timeout watchdog on the main queue so a
                // hung boot surfaces to the user as an error state,
                // even if qemu itself is happily spinning.
                DispatchQueue.main.async { self.armBootTimeout() }

                DispatchQueue.global(qos: .userInitiated).async {
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
        Self.isRunning = false
        state = newState
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
                DispatchQueue.main.async { self.cancelBootTimeout() }
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
        // Caches/qemu-rt. Unix socket paths are capped at 104 chars on
        // Darwin, so keep this short.
        let base = try FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("qemu-rt")
        try? FileManager.default.removeItem(at: base)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
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
        // Each arg logged on its own line, prefixed so we can grep them
        // out later. Boot log is append-only text; keep entries short.
        for (i, a) in args.enumerated() {
            let trimmed = a.count > 120 ? String(a.prefix(117)) + "..." : a
            logPhase("argv[\(i)]=\(trimmed)")
        }
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
