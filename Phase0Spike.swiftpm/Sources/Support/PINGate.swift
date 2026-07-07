import SwiftUI

/// Gates a view behind a 4-digit PIN. Not meant as real security — just
/// keeps guests from wandering into settings/admin screens.
struct PINGate<Content: View>: View {
    private static var storedPIN: String {
        UserDefaults.standard.string(forKey: "com.anthonyvo.photobooth.adminPIN") ?? "1234"
    }

    @State private var entered = ""
    @State private var unlocked = false
    @State private var showError = false
    @Environment(\.dismiss) private var dismiss
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        if unlocked {
            content()
        } else {
            VStack(spacing: 20) {
                Text("Attendant PIN").font(.title2.bold())
                SecureField("PIN", text: $entered)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .multilineTextAlignment(.center)
                    .onSubmit(check)
                if showError {
                    Text("Wrong PIN").foregroundStyle(.red).font(.caption)
                }
                HStack {
                    Button("Cancel") { dismiss() }
                    Button("Unlock", action: check).buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
    }

    private func check() {
        if entered == Self.storedPIN {
            unlocked = true
        } else {
            showError = true
            entered = ""
        }
    }
}
