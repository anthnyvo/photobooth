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
            supportedInterfaceOrientations: [
                .landscapeRight,
                .landscapeLeft,
                .portrait
            ],
            capabilities: [
                .camera(purposeString: "Connects to the Canon EOS R over USB to run the photobooth."),
                .localNetwork(
                    purposeString: "Connects to the Canon EOS R over Wi-Fi to run the photobooth.",
                    bonjourServiceTypes: []
                )
            ]
        )
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            path: "Sources",
            resources: [
                .process("Assets.xcassets")
            ]
        )
        // A testTarget depending on AppModule was tried here and reverted:
        // `@testable import AppModule` fails with "no such module" when
        // AppModule is wrapped in AppleProductTypes' .iOSApplication product
        // (this Swift Playgrounds packaging), unlike a plain SPM executable
        // — confirmed on CI, not a local guess. Real fix needs CameraKit
        // extracted into its own library target first (dependencies: []
        // list would gain "CameraKit", tests would `@testable import
        // CameraKit` instead) — see Tests/AppModuleTests for the actual
        // test cases, written and ready, just not wired to a target yet.
    ]
)
