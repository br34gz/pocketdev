import SwiftUI

struct RootView: View {
    @AppStorage("setupComplete") private var setupComplete = false

    var body: some View {
        if setupComplete {
            MainView()
        } else {
            SetupWizardView()
        }
    }
}
