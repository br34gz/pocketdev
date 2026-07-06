import SwiftUI
import SwiftTerm
import UIKit

/// Bridges SwiftTerm's UIKit TerminalView into SwiftUI and wires it to a
/// VMEngine: engine output feeds the terminal, terminal input goes to the
/// engine. With the real QEMU engine this becomes the virtio-serial console.
struct TerminalHostView: UIViewRepresentable {
    let engine: VMEngine

    func makeCoordinator() -> Coordinator {
        Coordinator(engine: engine)
    }

    func makeUIView(context: Context) -> TerminalView {
        let terminal = TerminalView(frame: .zero)
        terminal.terminalDelegate = context.coordinator
        terminal.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminal.nativeBackgroundColor = .black
        terminal.nativeForegroundColor = UIColor(white: 0.92, alpha: 1)
        terminal.backgroundColor = .black
        context.coordinator.terminal = terminal

        engine.onOutput = { [weak terminal] bytes in
            // v0.7.2: also let the environment observe console output so
            // its bootStage scanner can advance the overlay through
            // launching -> booting -> logging in -> starting claude ->
            // ready. Runs on the engine's callback queue; observers
            // hop to main themselves.
            PocketDevEnvironment.shared.observeConsoleOutput(bytes)
            DispatchQueue.main.async {
                terminal?.feed(byteArray: bytes[...])
            }
        }
        DispatchQueue.main.async {
            _ = terminal.becomeFirstResponder()
        }
        return terminal
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {}

    final class Coordinator: NSObject, TerminalViewDelegate {
        let engine: VMEngine
        weak var terminal: TerminalView?

        init(engine: VMEngine) {
            self.engine = engine
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            engine.send(bytes: Array(data))
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            // TODO(M0): propagate to the guest via QMP / control channel
            // so the guest tty gets a matching winsize.
        }

        func setTerminalTitle(source: TerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func scrolled(source: TerminalView, position: Double) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link), url.scheme == "https" || url.scheme == "http" {
                UIApplication.shared.open(url)
            }
        }

        func bell(source: TerminalView) {}

        func clipboardCopy(source: TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) {
                UIPasteboard.general.string = text
            }
        }

        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
