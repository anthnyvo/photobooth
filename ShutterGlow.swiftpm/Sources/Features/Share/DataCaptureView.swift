import SwiftUI
import UIKit

/// Optional lead/survey form shown before a guest gets their photos, when the
/// event enables data capture. Collected contacts are stored LOCALLY per
/// event (never auto-uploaded) and exported by the attendant — the consent
/// checkbox, when configured, is recorded alongside each lead.
///
/// Styled as one floating glass card over the chassis gradient, same as the
/// other guest screens. `onDone` is called with a lead to record, or nil if
/// the guest skips — either way the caller marks this guest handled.
struct DataCaptureView: View {
    let options: EventConfig.DataCaptureOptions
    let onDone: (EventStorage.GuestLead?) -> Void

    @State private var name = ""
    @State private var email = ""
    @State private var phone = ""
    @State private var consented = false

    var body: some View {
        ZStack {
            ChassisBackground()
            VStack(spacing: 22) {
                VStack(spacing: 6) {
                    Text("Get your photos")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(Chassis.textPrimary)
                    Text("Pop in your details and we'll take it from here.")
                        .font(.callout)
                        .foregroundStyle(Chassis.textSecondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 14) {
                    if options.collectName {
                        GlassEntryField(label: "Name", text: $name, keyboard: .default, capitalize: true)
                    }
                    if options.collectEmail {
                        GlassEntryField(label: "Email", text: $email, keyboard: .emailAddress, capitalize: false)
                    }
                    if options.collectPhone {
                        GlassEntryField(label: "Phone", text: $phone, keyboard: .phonePad, capitalize: false)
                    }
                    if !options.consentText.isEmpty {
                        Button {
                            consented.toggle()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: consented ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(consented ? Chassis.accent : Chassis.textSecondary)
                                Text(options.consentText)
                                    .font(.footnote)
                                    .foregroundStyle(Chassis.textSecondary)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 420)

                VStack(spacing: 10) {
                    Button {
                        onDone(EventStorage.GuestLead(
                            name: name.trimmingCharacters(in: .whitespaces),
                            email: email.trimmingCharacters(in: .whitespaces),
                            phone: phone.trimmingCharacters(in: .whitespaces),
                            consented: options.consentText.isEmpty ? true : consented
                        ))
                    } label: {
                        Text("Continue")
                            .font(.headline)
                            .frame(maxWidth: 420)
                            .padding(.vertical, 14)
                            .background(Capsule().fill(Chassis.accent))
                            .foregroundStyle(Color.black)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canContinue)
                    .opacity(canContinue ? 1 : 0.4)

                    Button("Skip") { onDone(nil) }
                        .font(.subheadline)
                        .foregroundStyle(Chassis.textSecondary)
                }
            }
            .padding(32)
        }
    }

    /// Require at least one contact method the event asked for, so a submitted
    /// lead is actually reachable — otherwise the guest should Skip.
    private var canContinue: Bool {
        var ok = false
        if options.collectEmail, !email.trimmingCharacters(in: .whitespaces).isEmpty { ok = true }
        if options.collectPhone, !phone.trimmingCharacters(in: .whitespaces).isEmpty { ok = true }
        // If the event only collects a name, a name is enough.
        if !options.collectEmail && !options.collectPhone && options.collectName {
            ok = !name.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return ok
    }
}

private struct GlassEntryField: View {
    let label: String
    @Binding var text: String
    let keyboard: UIKeyboardType
    let capitalize: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Chassis.textSecondary)
            TextField("", text: $text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(capitalize ? .words : .never)
                .autocorrectionDisabled(!capitalize)
                .foregroundStyle(Chassis.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.white.opacity(0.15), lineWidth: 1)
                        )
                )
        }
    }
}
