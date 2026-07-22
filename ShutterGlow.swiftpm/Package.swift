// swift-tools-version: 5.9

// Swift Playgrounds app project — buildable and runnable directly on the iPad,
// no Mac required. Open this .swiftpm folder in Swift Playgrounds 4+.
import PackageDescription
import AppleProductTypes

let package = Package(
    name: "ShutterGlow",
    platforms: [
        .iOS("17.0")
    ],
    products: [
        .iOSApplication(
            name: "ShutterGlow",
            targets: ["AppModule"],
            bundleIdentifier: "com.anthonyvo.shutterglow",
            teamIdentifier: "",
            displayVersion: "1.0",
            bundleVersion: "1",
            appIcon: .asset("AppIcon"),
            accentColor: .presetColor(.blue),
            supportedDeviceFamilies: [
                .pad,
                .phone
            ],
            // All four orientations, including portraitUpsideDown, are
            // required for an iPad app that supports multitasking, which App
            // Store validation enforces. A Swift Playgrounds .iOSApplication
            // product can't set UIRequiresFullScreen to opt out of
            // multitasking, so the only way past the check is to declare all
            // four. In practice the booth lives on a landscape stand; this is
            // about satisfying validation, not inviting an upside-down kiosk.
            supportedInterfaceOrientations: [
                .landscapeRight,
                .landscapeLeft,
                .portrait,
                .portraitUpsideDown
            ],
            capabilities: [
                .camera(purposeString: "Connects to your camera over USB, and uses the iPad camera for USB webcam mode, to run the photo booth."),
                .localNetwork(
                    purposeString: "Connects to your camera over Wi-Fi to run the photo booth.",
                    bonjourServiceTypes: []
                )
            ]
        )
    ],
    targets: [
        // Camera protocol/tethering layer, split out from AppModule solely
        // so it's a plain library target — `@testable import AppModule`
        // fails ("no such module") because AppModule is wrapped in
        // AppleProductTypes' .iOSApplication product, which doesn't produce
        // an importable module the normal way. A library target has no such
        // restriction, so the tests below `@testable import CameraKit`
        // instead. Every symbol the app or tests cross this boundary with
        // was already `public` before this split (verified by grep across
        // Sources/App, Sources/Domain, Sources/Features) except
        // SonyLiveviewParser, fixed alongside this change.
        .target(
            name: "CameraKit",
            path: "Sources/CameraKit"
        ),
        .executableTarget(
            name: "AppModule",
            dependencies: ["CameraKit"],
            path: "Sources",
            exclude: ["CameraKit"],
            resources: [
                .process("Assets.xcassets")
            ]
        ),
        // Pure parsing tests — no hardware, no simulator I/O, just the
        // byte-level PTP/PTP-IP/Sony-liveview framing logic. See
        // Tests/AppModuleTests for the actual cases.
        .testTarget(
            name: "AppModuleTests",
            dependencies: ["CameraKit"],
            path: "Tests/AppModuleTests"
        )
    ]
)
