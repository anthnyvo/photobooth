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
            case .connecting:
                ConnectView(model: model, theme: theme)
            case .attract:
                AttractView(model: model, theme: theme)
            case .countdown, .capturing:
                CaptureView(model: model, theme: theme)
            case .review(let url):
                ReviewView(model: model, theme: theme, photoURL: url)
            case .sharing(let url):
                ShareView(model: model, theme: theme, photoURL: url)
            }

            // Hidden attendant escape hatch — top-left corner, long press.
            VStack {
                HStack {
                    Color.clear
                        .frame(width: 60, height: 60)
                        .contentShape(Rectangle())
                        .onLongPressGesture(minimumDuration: 2) { showDiagnostics = true }
                    Spacer()
                }
                Spacer()
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
            theme.background.ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(theme.primary)
                Text(model.connectionMessage)
                    .font(.title3)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                HStack {
                    TextField("Camera IP", text: $model.cameraIPText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                        #if os(iOS)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        #endif
                    Button("Connect", action: model.connectCamera)
                        .buttonStyle(.borderedProminent)
                }

                if let error = model.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }

                Button("Event Setup") { showAdmin = true }
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.6))
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
