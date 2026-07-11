import SwiftUI

/// Splash screen shown once at launch, before the event picker — a branded
/// landing moment with continuous motion: polaroids drifting behind glass,
/// a slowly turning shutter ring, staggered entrance for the type. All
/// generative SwiftUI animation, no bundled video, so the IPA stays lean
/// and it loops forever without a player.
struct HomeView: View {
    @ObservedObject var model: BoothViewModel
    @State private var entered = false

    var body: some View {
        ZStack {
            ChassisBackground()
            FloatingPolaroids()

            VStack(spacing: 28) {
                Spacer()

                ShutterRingMark()
                    .frame(width: 150, height: 150)
                    .scaleEffect(entered ? 1 : 0.86)
                    .opacity(entered ? 1 : 0)

                VStack(spacing: 10) {
                    Text("ShutterGlow")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundStyle(Chassis.textPrimary)
                    Text("Pro camera photobooth. Runs even with zero signal.")
                        .font(.callout)
                        .foregroundStyle(Chassis.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                .opacity(entered ? 1 : 0)
                .offset(y: entered ? 0 : 18)

                Spacer()

                PillButton(title: "Get Started") {
                    model.enterEventPicker()
                }
                .padding(.bottom, 56)
                .opacity(entered ? 1 : 0)
                .offset(y: entered ? 0 : 14)
            }
        }
        .statusBarHidden()
        .onAppear {
            // Staggered feel comes from the single longer curve — ring
            // resolves first (scale), type and button trail it (offset).
            withAnimation(.easeOut(duration: 0.9)) {
                entered = true
            }
        }
    }
}

/// The app-icon mark, alive: hairline outer ring rotating a dash pattern
/// slowly (a lens focusing), soft breathing on the accent core.
private struct ShutterRingMark: View {
    @State private var spinning = false
    @State private var breathing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
            Circle()
                .strokeBorder(Chassis.hairline, lineWidth: 1)

            // rotating dash ring — the "motion" read even at a glance
            Circle()
                .stroke(
                    Color.white.opacity(0.55),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [1, 14])
                )
                .padding(12)
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(.linear(duration: 24).repeatForever(autoreverses: false), value: spinning)

            Circle()
                .strokeBorder(.white.opacity(0.8), lineWidth: 4)
                .padding(24)

            Circle()
                .fill(Chassis.accent)
                .padding(38)
                .scaleEffect(breathing ? 1.06 : 0.96)
                .shadow(color: Chassis.accent.opacity(breathing ? 0.55 : 0.2), radius: breathing ? 26 : 12)
                .animation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true), value: breathing)
        }
        .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
        .onAppear {
            spinning = true
            breathing = true
        }
    }
}

/// Ambient layer: tilted polaroid prints drifting slowly behind the content
/// — photobooth output as the room's wallpaper. Uses the current event's
/// real photos when any exist (downscaled off-main), falling back to the
/// gradient placeholder cards on a fresh install. Deterministic parameters
/// (no randomness) so it looks composed, not scattered.
private struct FloatingPolaroids: View {
    @State private var drift = false
    @State private var thumbnails: [UIImage] = []

    private struct Card {
        let x: CGFloat, y: CGFloat
        let angle: Double
        let scale: CGFloat
        let duration: Double
    }

    // Positions are unit-space (-1...1 of half-extent from center).
    private let cards: [Card] = [
        Card(x: -0.78, y: -0.62, angle: -11, scale: 1.0, duration: 7.5),
        Card(x: 0.82, y: -0.38, angle: 8, scale: 0.8, duration: 9.0),
        Card(x: -0.7, y: 0.52, angle: 6, scale: 0.9, duration: 8.2),
        Card(x: 0.74, y: 0.66, angle: -7, scale: 1.1, duration: 10.0),
    ]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(Array(cards.enumerated()), id: \.offset) { index, card in
                    PolaroidCard(photo: index < thumbnails.count ? thumbnails[index] : nil)
                        .scaleEffect(card.scale)
                        .rotationEffect(.degrees(card.angle + (drift ? 3 : -3)))
                        .position(
                            x: geo.size.width / 2 + card.x * geo.size.width / 2,
                            y: geo.size.height / 2 + card.y * geo.size.height / 2
                                + (drift ? -14 : 14)
                        )
                        .animation(
                            .easeInOut(duration: card.duration)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.7),
                            value: drift
                        )
                }
            }
            .opacity(0.5)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear { drift = true }
        .task {
            // Real prints from the active event when it has any (decoded and
            // downscaled off-main so four 6000px JPEGs don't stall launch);
            // fresh installs fall back to the bundled sample booth shots so
            // the splash never shows empty gradient placeholders.
            var urls: [URL] = []
            if let eventId = EventStorage.shared.currentEventId() {
                urls = Array(EventStorage.shared.listPhotos(eventId: eventId)
                    .filter { $0.pathExtension.lowercased() != "gif" }
                    .prefix(4))
            }
            if urls.isEmpty {
                urls = (1...4).compactMap {
                    Bundle.main.url(forResource: "sample-\($0)", withExtension: "jpg")
                }
            }
            guard !urls.isEmpty else { return }
            let loaded = await Task.detached(priority: .utility) {
                urls.compactMap { url in
                    autoreleasepool {
                        // Center-crop to the card's 4:3 up front — letting
                        // the view fill-crop a tall strip print would show
                        // a meaningless zoomed sliver of one frame.
                        UIImage(contentsOfFile: url.path)?
                            .downscaled(maxWidth: 360)
                            .croppedToAspectFill(CGSize(width: 360, height: 270))
                    }
                }
            }.value
            withAnimation(.easeIn(duration: 0.8)) {
                thumbnails = loaded
            }
        }
    }
}

/// One background polaroid — white stock; a real event photo when one is
/// available, the dusty gradient placeholder otherwise.
private struct PolaroidCard: View {
    var photo: UIImage? = nil

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let photo {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFill()
                } else {
                    LinearGradient(
                        colors: [
                            Color(red: 0.45, green: 0.40, blue: 0.52),
                            Color(red: 0.30, green: 0.26, blue: 0.36)
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                }
            }
            // Fixed pixel box + clip: scaledToFill happily overflows a
            // fitted aspectRatio container (the tall strip samples spilled
            // right off the print), so the photo area gets hard dimensions
            // — card 110pt wide minus 7pt padding each side, 4:3.
            .frame(width: 96, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
            Spacer(minLength: 0)
        }
        .padding(7)
        .frame(width: 110, height: 118)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.85)))
        .shadow(color: .black.opacity(0.45), radius: 10, y: 5)
    }
}
