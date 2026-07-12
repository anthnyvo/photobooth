import SwiftUI

/// Attendant PIN storage — not generic-parameterized like PINGate itself so
/// AdminView's Security section can read/write it without a dummy Content
/// type. Every ShutterGlow install shipped with the same fixed "1234",
/// never written anywhere, with no way to change it; AdminView's Security
/// section now writes a real PIN here on first use. "1234" stays the
/// fallback for installs that haven't set one yet.
enum AdminPIN {
    static var current: String {
        UserDefaults.standard.string(forKey: "com.anthonyvo.photobooth.adminPIN") ?? "1234"
    }

    static func set(_ pin: String) {
        UserDefaults.standard.set(pin, forKey: "com.anthonyvo.photobooth.adminPIN")
    }
}

/// Gates a view behind a 4-digit PIN. Not meant as real security — just
/// keeps guests from wandering into settings/admin screens.
struct PINGate<Content: View>: View {

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
                            .fill(.ultraThinMaterial)
                        Circle()
                            .strokeBorder(Chassis.hairline, lineWidth: 1)
                        Image(systemName: "lock")
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

                        GhostButton(title: "Cancel") { dismiss() }
                    }
                    .padding(28)
                    .chassisPanel()
                }
                .padding()
            }
        }
    }

    private func check() {
        if entered == AdminPIN.current {
            unlocked = true
        } else {
            showError = true
            entered = ""
        }
    }
}
