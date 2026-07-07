# Photobooth — iPad + Canon EOS R open-air booth

Single-iPad photobooth system. No companion computer, no cloud, no Mac in the toolchain.
Camera control over USB via ImageCaptureCore PTP passthrough (Phase 0 spike proves this
before anything else gets built).

## Layout

```
Phase0Spike.swiftpm/   Swift Playgrounds app project — builds and runs ON THE iPAD, no Mac.
  Package.swift        App manifest (camera purpose string declared here)
  Sources/App/         Spike UI: connect → live view → capture, fps counter, log export
  Sources/CameraKit/   PTP codec, Canon EOS protocol actor, ImageCaptureCore transport
  MacOnlyTests/        Parsing unit tests — parked outside Sources/, not built by
                       Playgrounds; runnable later on Mac/CI
docs/PHASE0.md         Test protocol T1–T7, exit criteria, fallback ladder, findings log
```

## No-Mac build workflow (Windows PC + iPad)

The `.swiftpm` folder is a **Swift Playgrounds app project**. Swift Playgrounds 4+
(free, App Store) compiles and runs it directly on the iPad.

### Get the project onto the iPad — pick one

- **A. Git loop (recommended for ongoing dev):** push this repo to GitHub (private is fine).
  On the iPad install **Working Copy** (free tier clones/pulls), clone the repo, then in
  Files → Working Copy → repo → tap `Phase0Spike.swiftpm` → opens in Playgrounds.
  Iteration loop: code edited on the PC → push → pull in Working Copy → rerun in
  Playgrounds. No re-transfer, no cable.
- **B. iCloud Drive:** install iCloud for Windows, copy the whole `Phase0Spike.swiftpm`
  folder into iCloud Drive; on the iPad open it from Files.
- **C. Any file transfer:** zip the folder, move it however (Drive/AirDrop-alternative),
  unzip in the Files app on iPad, tap the `.swiftpm`.

### Run

1. Open `Phase0Spike.swiftpm` in Swift Playgrounds → tap **Run**.
2. First build may surface small compiler complaints (this code was written off-device;
   ImageCaptureCore's required delegate methods vary slightly by SDK — add empty stubs
   for whatever it names).
3. Plug the EOS R into the iPad's USB-C port, then follow `docs/PHASE0.md` T1–T7.
4. Diagnostics: the app's own log panel (with Export button) is the primary record;
   Playgrounds' console shows the same lines via `print`.

### Known risk of the Playgrounds path

Playgrounds-built apps run with a limited entitlement set. ImageCaptureCore external-camera
access from a Playgrounds app is **unverified** — it is itself a Phase 0 finding. Symptom
if blocked: camera never appears (no `camera found` log) or no permission prompt.

**Fallback (still $0, no Mac):** GitHub Actions macOS runner builds the app
(`xcodebuild` opens `.swiftpm` projects directly) into an unsigned `.ipa`;
**AltServer for Windows** signs it with a free Apple ID and sideloads to the iPad over
USB (7-day resign cycle). Workflow file gets written if and when the Playgrounds path fails.

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
