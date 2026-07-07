# Photobooth — iPad + Canon EOS R open-air booth

Single-iPad photobooth system. No companion computer, no cloud. Camera control over USB
via ImageCaptureCore PTP passthrough (Phase 0 spike proves this before anything else gets built).

## Layout

```
CameraKit/        Swift package — PTP codec, Canon EOS protocol, ImageCaptureCore transport.
                  Pure-parsing unit tests run without hardware (swift test on macOS).
Phase0Spike/      SwiftUI spike app: connect → live view → capture → retrieve, with
                  fps counter, capture round-trip timer, exportable diagnostic log.
docs/PHASE0.md    Test protocol, exit criteria, fallback ladder, findings log.
```

## Building the spike (requires a Mac with Xcode 15+)

This repo was scaffolded off-Mac, so expect minor compiler fixes on first build —
ImageCaptureCore's iOS delegate surface has required methods that vary slightly by SDK;
add empty stubs for whatever the compiler demands.

1. Xcode → New Project → iOS App, name `Phase0Spike`, interface SwiftUI.
   Delete the generated `ContentView.swift` and `<name>App.swift`.
2. Drag the three files from `Phase0Spike/` into the project (copy if needed).
3. File → Add Package Dependencies → Add Local… → select the `CameraKit/` folder.
   Add the `CameraKit` library to the app target.
4. Target → Info: add key **NSCameraUsageDescription** — e.g.
   `"Connects to the Canon EOS R over USB to run the photobooth."`
   (Without it, external-camera access is denied silently on iPadOS.)
5. Signing: personal team is fine for the spike (7-day provisioning).
6. Build & run **on the iPad Air over cable/Wi-Fi debug** (simulator has no USB camera support),
   then plug the EOS R into the iPad and follow `docs/PHASE0.md`.

No Mac available: the same three spike files + package can be assembled in
**Swift Playgrounds 4 on the iPad itself** (App project, add camera capability
purpose string in App Settings). Xcode preferred — better logs.

## Camera settings for the spike

- USB mode: default (PTP). Wi-Fi off. Auto power-off: off (or longest).
- Any exposure mode; live view (EVF output) gets redirected to the iPad when tethered.

## Phase gates

Phase 0 (tethering, live view mandatory) → Phase 1 (single photo MVP + branding config
builder) → Phase 2 (strips/GIF/gallery) → Phase 3 (AI filters/background removal) →
Phase 4 (corporate mode). Phase 0 exit criteria in `docs/PHASE0.md` — no Phase 1 work
until all boxes tick.
