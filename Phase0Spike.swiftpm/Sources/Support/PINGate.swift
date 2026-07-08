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
            ZStack {
                ChassisBackground()
                VStack(spacing: 24) {
                    ZStack {
                        Circle()
                            .fill(Chassis.card.opacity(0.86))
                        Circle()
                            .strokeBorder(Chassis.hairline, lineWidth: 1)
                        Image(systemName: "lock.fill")
                            .font(.system(size: 30, weight: .medium))
                            .foregroundStyle(Chassis.textPrimary)
                    }
                    .frame(width: 88, height: 88)
                    .shadow(color: .black.opacity(0.4), radius: 10, y: 4)

                    ChassisLabel(text: "Attendant PIN", size: 13)

                    VStack(spacing: 18) {
                        SecureField("• • • •", text: $entered)
                            .font(.system(size: 24, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Chassis.textPrimary)
                            .multilineTextAlignment(.center)
                            .padding(.vertical, 14)
                            .frame(width: 180)
                            .background(Capsule().fill(Chassis.control))
                            .overlay(Capsule().strokeBorder(showError ? Color.red.opacity(0.7) : Chassis.hairline, lineWidth: 1))
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                            .onSubmit(check)

                        if showError {
                            Text("Wrong PIN")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }

                        PillButton(title: "Unlock", action: check)

                        Button("Cancel") { dismiss() }
                            .font(.footnote)
                            .foregroundStyle(Chassis.textSecondary)
                    }
                    .padding(28)
                    .chassisPanel()
                }
                .padding()
            }
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
