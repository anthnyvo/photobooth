import SwiftUI
import CameraKit

/// Root router for the guest-facing booth. ShutterGlow's diagnostic screen
/// (SpikeView) stays reachable via a long-press in the corner for ongoing
/// hardware debugging, but this is the real product surface.
struct BoothRootView: View {
    @StateObject private var model = BoothViewModel()
    @State private var showDiagnostics = false
    @State private var showExitPIN = false

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

            // Attendant exit from the guest flow, PIN-gated. Shown only on
            // the attract screen: that's where the booth idles between
            // guests, so the attendant can always get out, while a guest
            // mid-countdown or mid-capture can't derail their own session
            // by hitting it. .readyToShoot deliberately keeps its own
            // unGated back button, which just cancels that guest's session
            // rather than leaving the booth.
            //
            // The PIN is what makes this safe to show openly. Without it,
            // a visible exit on a kiosk screen is an invitation for a guest
            // to wander into the event picker mid-event.
            if model.step == .attract {
                VStack {
                    HStack {
                        BackButton { showExitPIN = true }
                            .padding(.leading, 20)
                            .padding(.top, 20)
                        Spacer()
                    }
                    Spacer()
                }
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
        .sheet(isPresented: $showExitPIN) {
            PINPromptSheet(prompt: "Attendant PIN to exit") {
                DiagnosticLog.shared.log(.app, "attendant exited booth to event picker")
                model.backToEventPicker()
            }
        }
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

/// Attendant setup step, between picking an event and the guest flow.
///
/// Normally passed through without a tap: `.task` probes the cable on
/// appearance and a wired camera connects on its own. The brand picker, IP
/// field and retry button only appear once that probe has completed and
/// failed — see `wifiFallbackVisible`, which gates all of them. Wi-Fi is the
/// fallback, and only there does the camera need to be in Remote control
/// (EOS Utility) mode with the iPad joined to its network.
///
/// While a connect attempt is running, radar rings pulse outward from the
/// camera mark.
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

                // Shown only once the cable has been checked and come back
                // empty. Gating on wifiFallbackVisible rather than
                // !isProbingUSB is deliberate: isProbingUSB starts false, so
                // the screen painted the picker and IP box for one frame
                // before the probe flipped it, which is what "it still goes to
                // the IP page first" was. This flag only ever becomes true
                // after a completed, failed probe, so there is no such window.
                if model.wifiFallbackVisible {
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
                    // Only shown for a transport that actually needs an
                    // address — see BoothViewModel.showsIPField. Canon now
                    // tries USB first and only reveals this if no camera is
                    // found on the cable.
                    if model.showsIPField {
                        ChassisLabel(text: "Camera IP", size: 10)
                    }
                    HStack(spacing: 12) {
                        if model.showsIPField {
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
                }

                // Explicit retry. The Connect button below re-probes USB too,
                // but it reads as "connect using the address in this box",
                // so an attendant who has just plugged the cable in after the
                // search failed has no obvious way to ask again.
                if model.wifiFallbackVisible {
                    Button(action: model.retryCameraSearch) {
                        Label("Search for camera again", systemImage: "arrow.clockwise")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Chassis.textPrimary)
                            .padding(.vertical, 13)
                            .padding(.horizontal, 22)
                            .background(Capsule().fill(.ultraThinMaterial))
                            .overlay(Capsule().strokeBorder(Chassis.hairline, lineWidth: 1))
                    }
                    .buttonStyle(PressableStyle())
                    .padding(.top, 4)
                }

                if let note = model.cameraCapabilityNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(Chassis.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }

                if let error = model.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }

                // Still reachable here, but no longer the only route: editing
                // now lives on the event list, next to the events themselves,
                // rather than behind a camera-connect step.
                GhostButton(title: "Event Setup") { showAdmin = true }
                    .padding(.top, 20)
                    .entrance(entered, delay: 0.18)
            }
        }
        .onAppear { entered = true }
        // Reach for the cable before the operator reaches for the screen. If
        // no camera is attached this falls through to the Wi-Fi path and
        // reveals the IP field, same as tapping Connect would.
        .task { model.autoConnectIfPossible() }
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
