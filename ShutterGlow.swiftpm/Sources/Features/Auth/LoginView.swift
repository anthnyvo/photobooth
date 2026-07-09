import SwiftUI

/// Same account as the web dashboard signs into — an operator's login
/// pairs the iPad with whatever events they're assigned. "Continue offline"
/// skips this entirely: a booth that's already been paired (or is
/// admin-configured purely on-device via the PIN-gated Event Setup) never
/// needs connectivity to run.
struct LoginView: View {
    @ObservedObject var model: BoothViewModel
    @State private var email = ""
    @State private var password = ""
    @State private var isSubmitting = false

    var body: some View {
        ZStack {
            ChassisBackground()

            VStack(spacing: 22) {
                Spacer()

                ZStack {
                    Circle().fill(.ultraThinMaterial)
                    Circle().strokeBorder(Chassis.hairline, lineWidth: 1)
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(Chassis.textPrimary)
                }
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.4), radius: 12, y: 5)

                VStack(spacing: 6) {
                    Text("Sign in")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(Chassis.textPrimary)
                    Text("Same account as the ShutterGlow dashboard")
                        .font(.caption)
                        .foregroundStyle(Chassis.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }

                VStack(spacing: 12) {
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        #if os(iOS)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        #endif
                        .padding(.vertical, 14)
                        .padding(.horizontal, 18)
                        .background(Capsule().fill(Chassis.control))
                        .overlay(Capsule().strokeBorder(Chassis.hairline, lineWidth: 1))
                        .foregroundStyle(Chassis.textPrimary)

                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .padding(.vertical, 14)
                        .padding(.horizontal, 18)
                        .background(Capsule().fill(Chassis.control))
                        .overlay(Capsule().strokeBorder(Chassis.hairline, lineWidth: 1))
                        .foregroundStyle(Chassis.textPrimary)
                        .onSubmit(submit)
                }
                .frame(maxWidth: 320)

                if let error = model.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }

                PillButton(title: isSubmitting ? "Signing in…" : "Sign in", action: submit)

                GhostButton(title: "Continue offline") {
                    model.continueOffline()
                }

                Spacer()
            }
            .padding()
        }
        .statusBarHidden()
    }

    private func submit() {
        guard !email.isEmpty, !password.isEmpty, !isSubmitting else { return }
        isSubmitting = true
        Task {
            await model.signIn(email: email, password: password)
            isSubmitting = false
        }
    }
}
