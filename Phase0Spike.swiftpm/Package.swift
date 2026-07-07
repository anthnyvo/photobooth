// swift-tools-version: 5.9

// Swift Playgrounds app project — buildable and runnable directly on the iPad,
// no Mac required. Open this .swiftpm folder in Swift Playgrounds 4+.
import PackageDescription
import AppleProductTypes

let package = Package(
    name: "Phase0Spike",
    platforms: [
        .iOS("16.0")
    ],
    products: [
        .iOSApplication(
            name: "Phase0Spike",
            targets: ["AppModule"],
            bundleIdentifier: "com.anthonyvo.phase0spike",
            teamIdentifier: "",
            displayVersion: "1.0",
            bundleVersion: "1",
            appIcon: .placeholder(icon: .camera),
            accentColor: .presetColor(.blue),
            supportedDeviceFamilies: [
                .pad
            ],
            supportedInterfaceOrientations: [
                .landscapeRight,
                .landscapeLeft
            ],
            capabilities: [
                .camera(purposeString: "Connects to the Canon EOS R over USB to run the photobooth.")
            ]
        )
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            path: "Sources"
        )
    ]
)
