import SwiftUI

/// Event list, shown before camera connect — the attendant picks which
/// client/event config is active, or creates a new one. Cards cascade in
/// with a staggered spring; fixed chassis styling only (no event accent)
/// since no event is chosen yet.
struct EventPickerView: View {
    @ObservedObject var model: BoothViewModel
    @State private var events: [EventConfig] = []
    @State private var showingNewEvent = false
    @State private var entered = false

    var body: some View {
        ZStack {
            ChassisBackground()
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Events")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(Chassis.textPrimary)
                    Spacer()
                    if model.isSyncing {
                        ProgressView().tint(Chassis.textSecondary)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 60)
                .entrance(entered)

                if let email = model.signedInEmail {
                    HStack(spacing: 14) {
                        Text(email)
                            .font(.caption)
                            .foregroundStyle(Chassis.textSecondary)
                            .lineLimit(1)
                        if !model.isSyncing {
                            Button("Sync") {
                                Task {
                                    await model.syncRemoteEvents()
                                    reload()
                                }
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Chassis.textPrimary)
                        }
                        Spacer()
                        Button("Sign out") { model.signOut() }
                            .font(.caption)
                            .foregroundStyle(Chassis.textSecondary)
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 6)
                    .entrance(entered, delay: 0.05)
                    if let syncError = model.syncError {
                        Text(syncError)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 28)
                    }
                }

                if events.isEmpty {
                    Spacer()
                    VStack(spacing: 14) {
                        Image(systemName: "sparkles.rectangle.stack")
                            .font(.system(size: 44, weight: .light))
                            .foregroundStyle(Chassis.textSecondary)
                            .symbolEffect(.pulse, options: .repeating)
                        Text("No events yet")
                            .font(.callout)
                            .foregroundStyle(Chassis.textSecondary)
                        Text("Create one here, or add it on the dashboard and sync.")
                            .font(.caption)
                            .foregroundStyle(Chassis.textSecondary.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity)
                    .entrance(entered, delay: 0.1)
                    Spacer()
                } else {
                    ScrollView {
                        VStack(spacing: 14) {
                            ForEach(Array(events.enumerated()), id: \.element.eventId) { index, event in
                                Button {
                                    model.selectEvent(event.eventId)
                                } label: {
                                    EventCard(event: event)
                                }
                                .buttonStyle(PressableStyle())
                                .entrance(entered, delay: 0.08 + Double(index) * 0.06)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 22)
                        .padding(.bottom, 12)
                    }
                }

                HStack {
                    Spacer()
                    PillButton(title: "+ New Event") {
                        showingNewEvent = true
                    }
                    Spacer()
                }
                .padding(.bottom, 40)
                .entrance(entered, delay: 0.15)
            }
        }
        .statusBarHidden()
        .onAppear {
            reload()
            entered = true
            if model.signedInEmail != nil {
                Task {
                    await model.syncRemoteEvents()
                    reload()
                }
            }
        }
        .sheet(isPresented: $showingNewEvent, onDismiss: reload) {
            PINGate {
                AdminView(model: model, mode: .create)
            }
        }
    }

    private func reload() {
        events = EventStorage.shared.listEventIds()
            .compactMap { try? EventStorage.shared.load($0) }
            .sorted { $0.createdAt > $1.createdAt }
    }
}

/// One event row: monogram disc in the event's own accent, name + id,
/// synced badge for dashboard events, chevron.
private struct EventCard: View {
    let event: EventConfig

    private var accent: Color {
        Color(hex: event.colors.primaryHex) ?? Chassis.accent
    }

    private var monogram: String {
        let words = event.displayName.split(separator: " ").prefix(2)
        return words.map { String($0.prefix(1)) }.joined().uppercased()
    }

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(accent.opacity(0.2))
                Circle().strokeBorder(accent.opacity(0.5), lineWidth: 1)
                Text(monogram)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 3) {
                Text(event.displayName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Chassis.textPrimary)
                HStack(spacing: 8) {
                    Text(event.eventId)
                        .font(.caption)
                        .foregroundStyle(Chassis.textSecondary)
                    if event.isRemote {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 8, weight: .bold))
                            Text("SYNCED")
                                .font(.system(size: 8, weight: .bold))
                                .tracking(1)
                        }
                        .foregroundStyle(Chassis.accent)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 7)
                        .background(Capsule().fill(Chassis.accent.opacity(0.12)))
                    }
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Chassis.textSecondary)
                .accessibilityHidden(true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .chassisPanel(cornerRadius: 24)
        // Without this, VoiceOver read the monogram initials, the name,
        // the id, and "SYNCED" as separate stops on one tappable row —
        // combining reads it as one coherent element instead.
        .accessibilityElement(children: .combine)
    }
}
