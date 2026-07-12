import SwiftUI

/// Per-frame live-view state, split out of BoothViewModel so a new camera
/// frame (~20/sec) only re-renders the backdrop actually drawing it.
/// Publishing frames through the main view model invalidated entire screens
/// — mode picker, buttons, badges — at live-view rate, which is where most
/// of the UI's CPU went and why everything felt heavier once live view ran.
@MainActor
public final class LiveViewFeed: ObservableObject {
    /// Newest decoded live-view frame, already rasterized off-main
    /// (`preparingForDisplay`) so rendering it costs a blit, not a decode.
    @Published public var image: UIImage?
    /// Transparent props-only frame matching the live view's pixel aspect —
    /// rendered a few times a second by the prop loop and layered over the
    /// feed for an AR-style preview.
    @Published public var propOverlay: UIImage?
}

/// The shared full-screen live-view layer: camera frame, the guest's filter,
/// a darkening wash, and the AR prop overlay. Screens embed this instead of
/// observing frames themselves, so their own bodies stay off the per-frame
/// invalidation path. Renders nothing until the first frame arrives.
struct LiveViewBackdrop: View {
    @ObservedObject var feed: LiveViewFeed
    var filter: PhotoFilter = .none
    var dim: Double = 0

    var body: some View {
        if let frame = feed.image {
            Image(uiImage: frame)
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()
                .liveFilterEffect(filter)
                .overlay(Chassis.base.opacity(dim).ignoresSafeArea())
            // Same pixel aspect as the frame, so the identical scaledToFill
            // transform keeps the two layers aligned. Drawn above the dim
            // so props read clearly.
            if let propOverlay = feed.propOverlay {
                Image(uiImage: propOverlay)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
    }
}
