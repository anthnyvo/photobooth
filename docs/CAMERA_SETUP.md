# Camera Setup — Canon EOS R, per event

Steps to configure the camera before each event/test session. Skipping any of
these reproduces bugs that took a full day to root-cause once — see
`docs/PHASE0.md` for the investigation history.

## 1. Card

Insert a formatted SD card with free space. The app deliberately leaves
`CaptureDestination` at the camera's own default (card), not host/RAM — see
§4 for why.

## 2. Lens

Mount properly (twist to lock). If using anything other than a native,
fully-electronic Canon lens (manual glass, third-party adapter, etc.):

- Menu → Custom Functions → **"Release shutter without lens"** → enabled.
  Without this, the body refuses to fire at all when it can't detect a
  communicating lens, independent of anything the app does.

## 3. Wi-Fi mode

Camera Wi-Fi menu has two connection modes — pick based on venue:

- **Venue Wi-Fi available (preferred):** join the venue's existing network
  (infrastructure/client mode), same network the phone joins. This is what
  makes QR sharing work — the phone hosts a small local server guests reach
  by scanning a code, which only works if camera + phone + guests share one
  network.
- **No venue Wi-Fi:** camera creates its own private network (auto-AP), phone
  joins that directly. PTP/IP control still works fine this way — you just
  lose QR sharing (guest phones can't reach the booth phone's server), so
  disable the QR toggle in Event Setup for that event.

Either way: **Wi-Fi Function → Remote control (EOS Utility)**, not "Connect to
smartphone" — that's Camera Connect's own app-specific pairing scheme and
rejects this app's connection with Init Fail.

## 4. Do not manually set CaptureDestination

The app never sets `CaptureDestination=Host` — this is intentional, not an
oversight. On this body, forcing captures to host/RAM disables autofocus
*camera-wide* for the whole remote session — not just for the app's own
capture commands, but for the physical shutter button too, until
disconnecting. Confirmed on hardware; cost most of a day to trace. Leave the
camera at its own default (card) and the app's capture path handles the rest.

## 5. Connect

Launch the app, enter the camera's IP (auto-AP mode: usually `192.168.1.2`;
venue Wi-Fi mode: check the camera's Wi-Fi info screen for its assigned
address), tap Connect. Expect live view within a couple seconds.

## Troubleshooting

**Capture fails with `DeviceBusy (0x2019)`, repeatedly, right after
connecting:** almost certainly `CaptureDestination` got left at Host from a
previous debug session — see §4. Power-cycle the camera to clear it if it's
stuck (the app no longer sets this value on its own, but if it was set by an
old build or manually, it needs to be cleared camera-side).

**Physical shutter button also stops focusing while the app is connected:**
same root cause as above. Disconnect, power-cycle the camera, reconnect.

**QR code button shows "not connected to Wi-Fi" or guests can't reach the
scan link:** confirm the camera is in venue Wi-Fi mode (§3), not its own
private AP — the two networks aren't bridged, so a phone joined to the
camera's own AP can't be reached by anyone else.
