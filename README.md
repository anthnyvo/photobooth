# Photobooth — iPad + Canon EOS R open-air booth

Single-iPad photobooth system. No companion computer, no cloud, no Mac in the toolchain.
Camera control over USB via ImageCaptureCore PTP passthrough (Phase 0 spike proves this
before anything else gets built).

## Layout

```
ShutterGlow.swiftpm/   Swift Playgrounds app project — builds and runs ON THE iPAD, no Mac.
  Package.swift        App manifest (camera purpose string declared here)
  Sources/App/         Spike UI: connect → live view → capture, fps counter, log export
  Sources/CameraKit/   PTP codec, Canon EOS protocol actor, ImageCaptureCore transport —
                       its own library target so tests can @testable import it
  Tests/AppModuleTests/ Parsing unit tests against CameraKit, run in CI via xcodebuild
docs/PHASE0.md         Test protocol T1–T7, exit criteria, fallback ladder, findings log
```

## Hardware plan

- **Now (dev + Phase 0 rig):** iPhone 17 (USB-C) — same ImageCaptureCore PTP surface as
  iPadOS, so the tethering spike is fully valid on it. UI adapts to the small screen.
- **Events:** iPad Air (to be acquired). Booth UI is designed for it; nothing built on
  the iPhone gets thrown away.

## No-Mac build workflow

### Current loop: Windows PC → GitHub Actions → AltServer → iPhone 17

1. **One-time PC setup:** install Apple's own **iTunes** and **iCloud** installers
   (from apple.com, NOT the Microsoft Store versions), then **AltServer for Windows**
   (altstore.io). AltServer sits in the system tray.
2. Code edited on the PC → push → repo **Actions** tab → run **Build unsigned IPA**
   (or `gh workflow run build-ipa.yml`) → download the `ShutterGlow-unsigned-ipa` artifact, unzip.
3. iPhone plugged into the PC via USB → AltServer tray icon → **Sideload .ipa** →
   pick the file, sign in with the free Apple ID when asked.
4. On the iPhone: Settings → General → VPN & Device Management → trust the developer
   profile (first install only).
5. Free-ID signing expires every **7 days** — resideload or let AltStore auto-refresh
   over shared Wi-Fi with the PC.

Budget note: macOS CI minutes are 10x on private repos (~200 effective/month ≈ 20 builds).
If iteration gets minute-starved, making the repo public buys unlimited free minutes.

### Later loop: iPad Air + Swift Playgrounds (no PC in the loop)

The `.swiftpm` folder is also a **Swift Playgrounds app project**. On the iPad:
install Swift Playgrounds + Working Copy (both free), clone this repo in Working Copy,
tap `ShutterGlow.swiftpm` in Files → opens in Playgrounds → Run. Iteration = push from
PC, pull in Working Copy, rerun. Caveat: whether Playgrounds' entitlement set allows
ImageCaptureCore external-camera access is unverified; if blocked (no `camera found`
log ever), use the AltServer loop above for the iPad too.

### Testing on the phone

Plug the EOS R into the iPhone's USB-C port, then follow `docs/PHASE0.md` T1–T7.
Diagnostics: the app's log panel (Export button) is the primary record.

## Camera settings for the spike

- USB mode: default (PTP). Camera Wi-Fi off. Auto power-off: off or longest.
- Any exposure mode; the camera's screen goes dark when live view is redirected to the iPad — expected.

## Power note (T7)

Camera has its own battery — not the issue. The issue: the camera cable occupies the
iPad's **only** port, so the iPad can't charge while tethered. T7 tests whether a USB-C
PD hub keeps PTP alive while feeding the iPad power. Until then: start events at 100%.

## Phase gates

Phase 0 (tethering, live view mandatory) → Phase 1 (single photo MVP + branding config
builder) → Phase 2 (strips/GIF/gallery) → Phase 3 (AI filters/background removal) →
Phase 4 (corporate mode). Phase 0 exit criteria in `docs/PHASE0.md` — no Phase 1 work
until all boxes tick.
