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
            Chassis.base.ignoresSafeArea()
            VStack(spacing: 24) {
                ChassisLabel(text: "Select Event", size: 16)
                    .padding(.top, 60)

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

                Button {
                    showingNewEvent = true
                } label: {
                    ChassisLabel(text: "+ New Event", size: 13)
                        .padding(.vertical, 14)
                        .padding(.horizontal, 28)
                        .chassisPanel(cornerRadius: 24)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 40)
            }
        }
        .statusBarHidden()
        .onAppear(perform: reload)
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
