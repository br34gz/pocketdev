import Darwin
import Foundation

/// Minimal blocking unix domain socket helper for connecting to the
/// listen sockets QEMU creates via `-chardev socket,path=...,server=on`.
/// Fires callbacks on background queues; caller is responsible for
/// hopping to main for UI.
final class UnixSocket {
    private var fd: Int32 = -1
    private var reading = false
    private let readQueue: DispatchQueue

    var onData: (([UInt8]) -> Void)?
    var onClose: ((Int32) -> Void)?

    init(label: String) {
        self.readQueue = DispatchQueue(label: "com.br34gz.pocketclaude.sock.\(label)")
    }

    /// Connect to a unix socket at `path`, retrying briefly while qemu
    /// spins up its listeners (qemu_init returns before all chardev
    /// sockets are ready to accept in practice).
    func connect(path: String, retries: Int = 40, retryDelay: TimeInterval = 0.1) -> Bool {
        for attempt in 0..<retries {
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            if fd < 0 { return false }
            // (Darwin.close disambiguated everywhere below to avoid
            //  clashing with self.close() the instance method.)
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = Array(path.utf8)
            guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
                Darwin.close(fd); fd = -1; return false
            }
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                let dst = raw.bindMemory(to: CChar.self).baseAddress!
                for (i, b) in pathBytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[pathBytes.count] = 0
            }
            let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if rc == 0 { return true }
            Darwin.close(fd); fd = -1
            if attempt < retries - 1 { Thread.sleep(forTimeInterval: retryDelay) }
        }
        return false
    }

    func startReading() {
        guard fd >= 0, !reading else { return }
        reading = true
        let readFd = fd
        readQueue.async { [weak self] in
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = buf.withUnsafeMutableBufferPointer { bp -> Int in
                    Darwin.read(readFd, bp.baseAddress, bp.count)
                }
                if n > 0 {
                    self?.onData?(Array(buf.prefix(n)))
                } else {
                    self?.onClose?(Int32(n))
                    return
                }
            }
        }
    }

    func write(_ bytes: [UInt8]) {
        guard fd >= 0 else { return }
        var remaining = bytes
        while !remaining.isEmpty {
            let n = remaining.withUnsafeBufferPointer { bp -> Int in
                Darwin.write(fd, bp.baseAddress, bp.count)
            }
            if n <= 0 { return }
            remaining.removeFirst(n)
        }
    }

    func close() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        reading = false
    }

    deinit { close() }
}
