import SwiftUI
import CameraKit

/// Root router for the guest-facing booth. ShutterGlow's diagnostic screen
/// (SpikeView) stays reachable via a long-press in the corner for ongoing
/// hardware debugging, but this is the real product surface.
struct BoothRootView: View {
    @StateObject private var model = BoothViewModel()
    @State private var showDiagnostics = false

    var body: some View {
        ZStack {
            let theme = Theme(model.config)

            // Soft crossfade + slight scale between steps — hard cuts read
            // as old; screens should flow into each other. Grouped so one
            // transition covers every step view.
            Group {
                switch model.step {
                case .login:
                    LoginView(model: model)
                case .home:
                    HomeView(model: model)
                case .eventPicker:
                    EventPickerView(model: model)
                case .connecting:
                    ConnectView(model: model, theme: theme)
                case .attract:
                    AttractView(model: model, theme: theme)
                case .readyToShoot:
                    ReadyToShootView(model: model, theme: theme)
                case .countdown, .capturing, .recording:
                    CaptureView(model: model, theme: theme)
                case .review(let url):
                    ReviewView(model: model, theme: theme, photoURL: url)
                case .sharing(let url):
                    ShareView(model: model, theme: theme, photoURL: url)
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.985)))
            .animation(.snappy(duration: 0.3), value: model.step)

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
            // Was reachable by any guest with a 2-second long-press and no
            // PIN — SpikeView's independent camera controls could collide
            // with the live booth session, and (before the dismiss button
            // added alongside this) there was no way back out at all.
            PINGate {
                SpikeView()
            }
        }
        // Bounds Dynamic Type for the semantic text styles already used in
        // a handful of places (.callout, .headline, etc.) to the standard
        // range, excluding the OS's five largest accessibility sizes
        // (AX1-AX5) that would break this kiosk's fixed layouts outright.
        // Most of the app's text uses hardcoded `.font(.system(size: N))`
        // rather than a semantic style, which this modifier does NOT make
        // scale — that would need per-screen work (ScaledMetric or
        // switching to semantic styles) across every guest-facing view,
        // which isn't something to do as a blind, unverified sweep on a
        // kiosk layout with no simulator/Mac to check the result against.
        // Real, bounded win for what's already scalable; not a full pass.
        .dynamicTypeSize(.xSmall ... .xxxLarge)
    }
}

/// Attendant setup step: connect to the camera over Wi-Fi before the guest
/// flow can start. Camera must already be in Remote control (EOS Utility)
/// mode with the iPad/iPhone joined to its network. While a connect attempt
/// is running, radar rings pulse outward from the camera mark.
private struct ConnectView: View {
    @ObservedObject var model: BoothViewModel
    let theme: Theme
    @State private var showAdmin = false
    @State private var entered = false

    private var isConnecting: Bool {
        model.connectionMessage.contains("…")
    }

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
                    if isConnecting {
                        // radar pulse — expanding, fading rings
                        ForEach(0..<3, id: \.self) { ring in
                            PulseRing(delay: Double(ring) * 0.55)
                        }
                    }
                    Circle()
                        .fill(.ultraThinMaterial)
                    Circle()
                        .strokeBorder(Chassis.hairline, lineWidth: 1)
                    Image(systemName: "camera")
                        .font(.system(size: 40, weight: .medium))
                        .foregroundStyle(Chassis.textPrimary)
                        .symbolEffect(.pulse, options: .repeating, isActive: isConnecting)
                }
                .frame(width: 116, height: 116)
                .shadow(color: .black.opacity(0.4), radius: 12, y: 5)
                .entrance(entered)

                Text(model.connectionMessage)
                    .font(.callout)
                    .foregroundStyle(Chassis.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.3), value: model.connectionMessage)
                    .entrance(entered, delay: 0.06)

                // Camera brand picker. Only three brands ship, all short
                // labels, so they sit centered in one row rather than a
                // left-aligned scroller.
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        ForEach(CameraBrand.allCases) { brand in
                            Button {
                                model.selectedBrand = brand
                            } label: {
                                Text(brand.displayName)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(model.selectedBrand == brand ? Color.black : Chassis.textPrimary)
                                    .padding(.vertical, 9)
                                    .padding(.horizontal, 16)
                                    .background(
                                        Capsule().fill(model.selectedBrand == brand
                                            ? AnyShapeStyle(Color.white)
                                            : AnyShapeStyle(.ultraThinMaterial))
                                    )
                                    .overlay(Capsule().strokeBorder(Chassis.hairline, lineWidth: 1))
                            }
                            .buttonStyle(PressableStyle())
                        }
                    }
                    .padding(.horizontal, 24)
                    Text(model.selectedBrand.connectionHint)
                        .font(.caption)
                        .foregroundStyle(Chassis.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                        .contentTransition(.opacity)
                        .animation(.easeOut(duration: 0.25), value: model.selectedBrand)
                }
                .entrance(entered, delay: 0.1)

                VStack(spacing: 14) {
                    // Wired UVC webcam mode has no IP to enter — it's a
                    // cable, not a network connection.
                    if model.selectedBrand != .usbWebcam {
                        ChassisLabel(text: "Camera IP", size: 10)
                    }
                    HStack(spacing: 12) {
                        if model.selectedBrand != .usbWebcam {
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
                        }
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
                    .entrance(entered, delay: 0.18)
            }
        }
        .onAppear { entered = true }
        .sheet(isPresented: $showAdmin) {
            PINGate {
                AdminView(model: model)
            }
        }
    }
}

/// One expanding radar ring — scales out from the mark and fades, on a
/// staggered repeating loop.
private struct PulseRing: View {
    let delay: Double
    @State private var animating = false

    var body: some View {
        Circle()
            .strokeBorder(Chassis.accent.opacity(0.5), lineWidth: 1.5)
            .scaleEffect(animating ? 2.4 : 1)
            .opacity(animating ? 0 : 0.8)
            .animation(
                .easeOut(duration: 1.8).repeatForever(autoreverses: false).delay(delay),
                value: animating
            )
            .onAppear { animating = true }
    }
}
