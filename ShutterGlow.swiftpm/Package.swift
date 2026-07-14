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
        ),
        // Pure-logic tests only (byte parsing/encoding, no UIKit/camera
        // hardware) — runs via `swift test` on the CI macOS runner, since
        // there's no local Mac to run it on otherwise. `@testable import
        // AppModule` works against this executable target because its entry
        // point is `@main`-attributed (ShutterGlowApp.swift), not a plain
        // main.swift. NOTE: if this project is ever opened and saved from
        // within the Swift Playgrounds app itself (not just edited as files),
        // check this target survived — Playgrounds has been observed
        // dropping unrecognized manifest content on save (FB9824864).
        .testTarget(
            name: "AppModuleTests",
            dependencies: ["AppModule"],
            path: "Tests/AppModuleTests"
        )
    ]
)
