import SwiftUI

/// Extra key row above the keyboard (spec section 5, main screen). Claude
/// Code's TUI leans on Esc and slash commands, neither of which is on the
/// default iOS keyboard.
struct KeyRowView: View {
    let send: ([UInt8]) -> Void

    private struct Key: Identifiable {
        let id = UUID()
        let label: String
        let symbol: String?
        let bytes: [UInt8]
    }

    private var keys: [Key] {
        [
            Key(label: "esc", symbol: nil, bytes: [0x1b]),
            Key(label: "tab", symbol: nil, bytes: [0x09]),
            Key(label: "^C", symbol: nil, bytes: [0x03]),
            Key(label: "/", symbol: nil, bytes: [0x2f]),
            Key(label: "up", symbol: "arrow.up", bytes: [0x1b, 0x5b, 0x41]),
            Key(label: "down", symbol: "arrow.down", bytes: [0x1b, 0x5b, 0x42]),
            Key(label: "left", symbol: "arrow.left", bytes: [0x1b, 0x5b, 0x44]),
            Key(label: "right", symbol: "arrow.right", bytes: [0x1b, 0x5b, 0x43]),
        ]
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(keys) { key in
                    Button {
                        send(key.bytes)
                    } label: {
                        Group {
                            if let symbol = key.symbol {
                                Image(systemName: symbol)
                            } else {
                                Text(key.label)
                                    .font(.system(.footnote, design: .monospaced))
                            }
                        }
                        .frame(minWidth: 36, minHeight: 30)
                    }
                    .buttonStyle(.bordered)
                    .tint(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .background(.black)
    }
}
