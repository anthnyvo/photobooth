# Sony a7 IV (and other UVC bodies) — USB Webcam path

Status: **untested on hardware**. Blocked on getting a USB-C iPad. See
checklist below for what's left before this is verified.

## Why this path exists

The a7 IV dropped the legacy Camera Remote API (`SonyCamera.swift`'s
JSON-RPC-over-Wi-Fi protocol) in favor of Creators' App — "Connect to
Smartphone" on the camera now points there, and Creators' App uses a
closed Sony protocol this app doesn't implement.

Two official Sony integration paths were considered and ruled out:

- **Legacy Camera Remote API** — doesn't support the a7 IV's generation of
  bodies at all.
- **Sony Camera Remote SDK** (native C++) — does support the a7 IV, but
  officially supports Windows/macOS/Linux only. No iOS/iPadOS target
  exists.

PTP-based live view is also a confirmed dead end on iOS regardless of
camera brand — see `docs/PHASE0.md`. ImageCaptureCore's PTP passthrough
API never surfaces the bulk data phase `GetViewFinderData` needs; this was
proven on the Canon EOS R over USB, and would hit the identical iOS
platform ceiling on a Sony body.

**The one path left:** the a7 IV (firmware 5.0+) has a UVC/UAC "USB
Streaming" webcam mode. iPadOS 17+ added native external-camera support
to AVFoundation (`AVCaptureDevice.DeviceType.external`) — no vendor SDK,
no PTP, just treats the camera like a plug-in webcam. Implemented in
`Sources/CameraKit/UVCWebcamCamera.swift`, wired in as the **"USB Webcam
(beta)"** camera brand.

## Hard platform requirement

`.external` AVCaptureDevice support is **iPadOS-only** — confirmed against
Apple's WWDC23 session and dev forums. Does not work on iPhone at all,
even USB-C iPhones. No workaround; the unofficial approaches that exist
for iPhone use private APIs and would get the app rejected from the App
Store.

**iPad requirement:** USB-C port + iPadOS 17+. Qualifying models: base
iPad 10th gen (2022) or newer, iPad Air 4th gen (2020) or newer, iPad mini
6th gen (2021) or newer, any iPad Pro from 2018 on. Anything with a
Lightning port is a dead end regardless of adapter.

## Trade-offs (real, not hidden)

- **No shutter fire.** "Capture" freezes the newest video frame from the
  live stream — it does not fire the camera's actual mechanical shutter.
  No hot-shoe flash sync as a result.
- **Resolution capped at stream resolution**, not the sensor's full still
  output — up to ~8MP at the a7 IV's 4K UVC setting, not the full 33MP
  sensor.
- Whether PTP and USB Streaming mode can coexist on one cable is
  unconfirmed and irrelevant here — this path avoids PTP entirely, for
  both live view and capture.

## Setup

1. Camera: **Menu → Setup → USB → USB Connection Mode → USB Streaming**
   (needs firmware 5.0+).
2. Connect camera to iPad with a data-capable USB-C SuperSpeed cable
   (charge-only cables won't expose the UVC device class).
3. Confirm the camera's own screen shows a **USB Streaming** active
   indicator once plugged in.
4. In the app: brand picker → **USB Webcam (beta)** → Connect. No IP
   field — it's a wired connection, not network.
5. iOS will prompt for camera permission on first connect. If missed:
   Settings → ShutterGlow → Camera.

## Checklist

- [ ] Get a USB-C iPad (10th gen 2022+, or Air/mini 6+/Pro 2018+),
      iPadOS 17+
- [ ] Sideload latest build via AltServer (see root README for the
      AltStore flow)
- [ ] Camera in USB Streaming mode, connected via data-capable USB-C cable
- [ ] App: USB Webcam (beta) → Connect
- [ ] Grant camera permission when prompted
- [ ] Confirm live view renders on the attract/capture screen
- [ ] Confirm capture works and the image lands correctly
- [ ] Check resulting photo resolution/quality is print-usable
- [ ] Confirm no hot-shoe flash fires on capture (expected — flag if this
      matters for a real event)
- [ ] Confirm GIF/Boomerang + timelapse still work (they sample the live
      feed, should work unchanged, worth confirming)
- [ ] If all pass: merge `feature/multi-camera` → `main`, redeploy

**Optional fallback, testable on iPhone today, no iPad needed:** camera's
PC Remote Wi-Fi mode (Menu → Network → PC Remote Function) — if it uses
standard PTP/IP (unconfirmed), the existing "Other PTP (beta)" brand might
work through it. Capture-only, no live view either way.

## Files touched

- `Sources/CameraKit/UVCWebcamCamera.swift` — the UVC camera implementation
- `Sources/CameraKit/TetheredCamera.swift` — `.usbWebcam` brand case
- `Sources/Features/Capture/BoothViewModel.swift` — connect-flow wiring
- `Sources/App/BoothRootView.swift` — hides the IP field for this brand
