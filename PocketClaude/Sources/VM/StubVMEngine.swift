import Foundation

/// Placeholder VM backend used until the QEMU engine lands (see the TODO in
/// VMEngine.swift). Plays a labelled fake boot transcript into the terminal
/// and then provides a minimal local line-echo prompt so the terminal
/// plumbing (SwiftTerm rendering, key row, input path) is exercised
/// end-to-end. It never pretends to be a real shell.
final class StubVMEngine: VMEngine {
    private(set) var state: VMState = .stopped {
        didSet { onStateChange?(state) }
    }
    var onOutput: (([UInt8]) -> Void)?
    var onStateChange: ((VMState) -> Void)?

    private var lineBuffer: [UInt8] = []
    private let queue = DispatchQueue(label: "com.br34gz.pocketclaude.stubvm")
    private var generation = 0

    private static let prompt = "pocket-claude:stub$ "

    func start() {
        guard state == .stopped || isError else { return }
        state = .starting
        generation += 1
        let gen = generation
        let jit = JITProbe.canAllocateRWX()
        let bootLines = [
            "Pocket Claude v0.1.0 — VM engine stub",
            "",
            "[stub] qemu-system-aarch64 ........ not integrated (M0 pending)",
            "[stub] alpine-claude.qcow2 ........ built in CI, not booted here",
            "[stub] JIT probe .................. \(jit ? "available" : "unavailable (interpreter mode when QEMU lands)")",
            "[stub] workspace .................. \(WorkspaceStore.displayName ?? "not configured")",
            "",
            "This build ships the app shell only. The QEMU integration path is",
            "documented in the repo README. Type 'status' or 'help'.",
            "",
        ]
        var delay = 0.15
        for line in bootLines {
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.generation == gen else { return }
                self.emit(line + "\r\n")
            }
            delay += 0.06
        }
        queue.asyncAfter(deadline: .now() + delay + 0.1) { [weak self] in
            guard let self, self.generation == gen else { return }
            self.state = .running(jit: jit)
            self.emit(Self.prompt)
        }
    }

    func stop() {
        generation += 1
        lineBuffer.removeAll()
        state = .stopped
        emit("\r\n[stub] VM stopped.\r\n")
    }

    func send(bytes: [UInt8]) {
        guard case .running = state else { return }
        for byte in bytes {
            switch byte {
            case 0x0d, 0x0a: // Enter
                emit("\r\n")
                handleLine(String(decoding: lineBuffer, as: UTF8.self))
                lineBuffer.removeAll()
            case 0x7f, 0x08: // Backspace
                if !lineBuffer.isEmpty {
                    lineBuffer.removeLast()
                    emit("\u{08} \u{08}")
                }
            case 0x03: // Ctrl-C
                lineBuffer.removeAll()
                emit("^C\r\n" + Self.prompt)
            case 0x20...0x7e:
                lineBuffer.append(byte)
                emit(String(UnicodeScalar(byte)))
            default:
                break // swallow escape sequences etc. in the stub
            }
        }
    }

    private var isError: Bool {
        if case .error = state { return true }
        return false
    }

    private func handleLine(_ line: String) {
        let cmd = line.trimmingCharacters(in: .whitespaces)
        switch cmd {
        case "":
            break
        case "help":
            emit("""
            Stub commands:\r
              status  show stub engine status\r
              help    this text\r
            Everything else needs the real VM (QEMU integration, milestone M0).\r

            """)
        case "status":
            let jit = JITProbe.canAllocateRWX()
            emit("""
            engine    : stub (no VM)\r
            jit       : \(jit ? "available" : "unavailable")\r
            workspace : \(WorkspaceStore.displayName ?? "not configured")\r

            """)
        default:
            emit("\(cmd): VM not running — QEMU integration lands in M0 (see README)\r\n")
        }
        emit(Self.prompt)
    }

    private func emit(_ text: String) {
        onOutput?(Array(text.utf8))
    }
}
