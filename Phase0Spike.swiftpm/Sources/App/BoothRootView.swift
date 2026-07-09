import SwiftUI

/// Root router for the guest-facing booth. Phase0Spike's diagnostic screen
/// (SpikeView) stays reachable via a long-press in the corner for ongoing
/// hardware debugging, but this is the real product surface.
struct BoothRootView: View {
    @StateObject private var model = BoothViewModel()
    @State private var showDiagnostics = false

    var body: some View {
        ZStack {
            let theme = Theme(model.config)

            switch model.step {
            case .eventPicker:
                EventPickerView(model: model)
            case .connecting:
                ConnectView(model: model, theme: theme)
            case .attract:
                AttractView(model: model, theme: theme)
            case .readyToShoot:
                ReadyToShootView(model: model, theme: theme)
            case .countdown, .capturing:
                CaptureView(model: model, theme: theme)
            case .review(let url):
                ReviewView(model: model, theme: theme, photoURL: url)
            case .sharing(let url):
                ShareView(model: model, theme: theme, photoURL: url)
            }

            // Hidden attendant escape hatch — bottom-right corner, long
            // press. Was top-left, same corner every screen's back button
            // now lives in — an invisible hit-testable view still consumes
            // taps even though it's Color.clear, so it was silently eating
            // back-button taps meant for the view underneath it.
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Color.clear
                        .frame(width: 60, height: 60)
                        .contentShape(Rectangle())
                        .onLongPressGesture(minimumDuration: 2) { showDiagnostics = true }
                }
            }
        }
        .statusBarHidden()
        .fullScreenCover(isPresented: $showDiagnostics) {
            SpikeView()
        }
    }
}

/// Attendant setup step: connect to the camera over Wi-Fi before the guest
/// flow can start. Camera must already be in Remote control (EOS Utility)
/// mode with the iPad/iPhone joined to its network.
private struct ConnectView: View {
    @ObservedObject var model: BoothViewModel
    let theme: Theme
    @State private var showAdmin = false

    var body: some View {
        ZStack {
            ChassisBackground()

            VStack {
                HStack {
                    BackButton { model.backToEventPicker() }
                    Spacer()
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                    Circle()
                        .strokeBorder(Chassis.hairline, lineWidth: 1)
                    Image(systemName: "camera")
                        .font(.system(size: 40, weight: .medium))
                        .foregroundStyle(Chassis.textPrimary)
                }
                .frame(width: 116, height: 116)
                .shadow(color: .black.opacity(0.4), radius: 12, y: 5)

                Text(model.connectionMessage)
                    .font(.callout)
                    .foregroundStyle(Chassis.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                VStack(spacing: 14) {
                    ChassisLabel(text: "Camera IP", size: 10)
                    HStack(spacing: 12) {
                        TextField("192.168.1.2", text: $model.cameraIPText)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(Chassis.textPrimary)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 16)
                            .background(Capsule().fill(Chassis.control))
                            .overlay(Capsule().strokeBorder(Chassis.hairline, lineWidth: 1))
                            .frame(width: 190)
                            #if os(iOS)
                            .keyboardType(.numbersAndPunctuation)
                            .textInputAutocapitalization(.never)
                            #endif
                        Button(action: model.connectCamera) {
                            Text("Connect")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.black)
                                .padding(.vertical, 13)
                                .padding(.horizontal, 22)
                                .background(Capsule().fill(Color.white))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
                .chassisPanel()

                if let error = model.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }

                GhostButton(title: "Event Setup") { showAdmin = true }
                    .padding(.top, 20)
            }
        }
        .sheet(isPresented: $showAdmin) {
            PINGate {
                AdminView(model: model)
            }
        }
    }
}
