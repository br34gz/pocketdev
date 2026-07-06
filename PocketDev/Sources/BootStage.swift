import Foundation

/// Coarse stages of the VM boot sequence, shown as an animated overlay
/// while the guest is booting. Advances one-way; `.ready` dismisses.
enum BootStage: Int, Comparable, Sendable {
    case idle           = 0
    case launching      = 1  // "Starting virtual machine..."
    case booting        = 2  // "Booting Debian..."       (first console byte)
    case loggingIn      = 3  // "Logging in..."           (login: prompt seen)
    case startingClaude = 4  // "Starting Claude Code..." (version probe printed)
    case ready          = 5  // dismiss overlay           (claude TUI up)

    static func < (a: BootStage, b: BootStage) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .idle:           return ""
        case .launching:      return "Starting virtual machine..."
        case .booting:        return "Booting Debian..."
        case .loggingIn:      return "Logging in..."
        case .startingClaude: return "Starting Claude Code..."
        case .ready:          return "Ready"
        }
    }

    /// Order relative to the 4 progress steps (launching..startingClaude).
    var progress: Double {
        switch self {
        case .idle, .launching: return 0.15
        case .booting:          return 0.40
        case .loggingIn:        return 0.65
        case .startingClaude:   return 0.90
        case .ready:            return 1.0
        }
    }
}
