import SwiftUI

/// v0.3.3 settings sheet. Only knob today: guest RAM.
/// LiveContainer runs sideloaded apps as PluginKit extensions which
/// historically have stricter jetsam quotas than main apps. A lower
/// RAM value gives the process more headroom vs the iOS memory manager.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(GuestRAM.storageKey) private var guestRAM_MB: Int = GuestRAM.defaultMB
    @State private var draftValue: Double = Double(GuestRAM.defaultMB)

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Guest RAM")
                        Spacer()
                        Text("\(Int(draftValue)) MB")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: $draftValue,
                        in: Double(GuestRAM.minMB)...Double(GuestRAM.maxMB),
                        step: Double(GuestRAM.stepMB)
                    )
                } footer: {
                    Text("How much RAM QEMU allocates for the Alpine guest. Lower = less likely to be killed by iOS memory pressure. Higher = more headroom for Claude Code. Change only takes effect on the next VM start.")
                }

                Section {
                    Button {
                        draftValue = Double(GuestRAM.defaultMB)
                    } label: {
                        Text("Reset to default (\(GuestRAM.defaultMB) MB)")
                    }
                } footer: {
                    Text("If the app is running under LiveContainer, the effective process memory quota may be as low as ~500 MB. If v0.3.x sessions get killed mid-boot, try 384-512 MB here or sideload via SideStore/AltStore as a main app.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        guestRAM_MB = Int(draftValue)
                        dismiss()
                    }
                    .bold()
                }
            }
            .onAppear {
                draftValue = Double(guestRAM_MB)
            }
        }
    }
}

/// Central place for guest-RAM bounds. Referenced by both SettingsView
/// and QEMUVMEngine so they can't drift.
enum GuestRAM {
    static let storageKey = "guestRAM_MB"
    static let minMB = 384
    static let maxMB = 2048
    static let stepMB = 64
    static let defaultMB = 768

    /// Read the persisted value or fall back to the default.
    static func current() -> Int {
        let v = UserDefaults.standard.integer(forKey: storageKey)
        guard v > 0 else { return defaultMB }
        return max(minMB, min(maxMB, v))
    }
}
