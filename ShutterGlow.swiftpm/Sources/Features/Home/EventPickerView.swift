import SwiftUI

/// Home screen, shown before camera connect — lets the attendant pick which
/// client/event config is active, or create a new one. Deliberately styled
/// with fixed chassis colors only (no accent) since no event is chosen yet.
struct EventPickerView: View {
    @ObservedObject var model: BoothViewModel
    @State private var events: [EventConfig] = []
    @State private var showingNewEvent = false

    var body: some View {
        ZStack {
            ChassisBackground()
            VStack(spacing: 24) {
                ChassisLabel(text: "Select Event", size: 16)
                    .padding(.top, 60)

                if let email = model.signedInEmail {
                    HStack(spacing: 12) {
                        Text(email)
                            .font(.caption)
                            .foregroundStyle(Chassis.textSecondary)
                            .lineLimit(1)
                        if model.isSyncing {
                            ProgressView().scaleEffect(0.7)
                        } else {
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
                    .padding(.horizontal, 24)
                    if let syncError = model.syncError {
                        Text(syncError)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }

                if events.isEmpty {
                    Spacer()
                    Text("No events yet")
                        .font(.callout)
                        .foregroundStyle(Chassis.textSecondary)
                    Spacer()
                } else {
                    ScrollView {
                        VStack(spacing: 14) {
                            ForEach(events, id: \.eventId) { event in
                                Button {
                                    model.selectEvent(event.eventId)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(event.displayName)
                                            .font(.headline)
                                            .foregroundStyle(Chassis.textPrimary)
                                        Text(event.eventId)
                                            .font(.caption)
                                            .foregroundStyle(Chassis.textSecondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(16)
                                    .chassisPanel()
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                }

                PillButton(title: "+ New Event") {
                    showingNewEvent = true
                }
                .padding(.bottom, 40)
            }
        }
        .statusBarHidden()
        .onAppear {
            reload()
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
