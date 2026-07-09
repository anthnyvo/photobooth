import SwiftUI

@main
struct ShutterGlowApp: App {
    var body: some Scene {
        WindowGroup {
            BoothRootView()
                .preferredColorScheme(.dark)
        }
    }
}
