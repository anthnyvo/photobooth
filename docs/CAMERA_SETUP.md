# Camera Setup — Canon EOS R, per event

Steps to configure the camera before each event/test session. Skipping any of
these reproduces bugs that took a full day to root-cause once — see
`docs/PHASE0.md` for the investigation history.

> **USB is the connection method for camera control.** Plug a data-capable
> USB-C cable from camera to iPad and that is the whole setup — no AP, no
> pairing, no IP address, no pre-flight, and nothing to tap. It is also faster
> than Wi-Fi on both counts (30-36 fps live view vs 14, 1.94s capture vs
> 2.79s), and has since passed 20 consecutive captures at booth pace
> (2026-08-05).
>
> **The camera does not need to be on any network.** Guest QR sharing needs
> the *iPad* and the guests' phones on one network — see §3. This is a change
> from how it used to work, and the most common wasted setup step now is
> putting the camera on the venue Wi-Fi for a reason that no longer exists.
>
> This is on the `spike/usb-liveview-blob-diagnostic` branch and is not
> merged, so the shipping build still uses Wi-Fi for control. Steps below
> cover both; the Wi-Fi ones are marked.

## 1. Card

Insert a formatted SD card with free space. Captures are written to the card
and then pulled off it over the cable — see §4.

## 2. Lens

Mount properly (twist to lock). If using anything other than a native,
fully-electronic Canon lens (manual glass, third-party adapter, etc.):

- Menu → Custom Functions → **"Release shutter without lens"** → enabled.
  Without this, the body refuses to fire at all when it can't detect a
  communicating lens, independent of anything the app does.

## 3. Network — for guest sharing only, not for the camera

**Over USB there is nothing to do here for camera control.** Skip to §4 unless
the event uses QR sharing.

**If QR sharing is on:** the *iPad* must be joined to a network the guests'
phones can also reach — normally the venue Wi-Fi. The iPad hosts a small local
server that guests reach by scanning a code, so what matters is that the iPad
has a real LAN address. **The camera is not part of this and does not need to
be on any network.** An earlier version of this section said QR sharing needed
camera + phone + guests on one network; that was true only while the camera
was also the control link.

If there is no usable venue Wi-Fi, turn the QR toggle off in Event Setup for
that event and use AirDrop or print instead.

### Wi-Fi control mode (fallback path only)

Only needed if you are running the Wi-Fi build, or the cable has failed and
the app has revealed the IP field.

- **Venue Wi-Fi available:** join the venue's existing network
  (infrastructure/client mode), same network the iPad is on. Keeps QR sharing
  working.
- **No venue Wi-Fi:** camera creates its own private network (auto-AP), iPad
  joins that directly. PTP/IP control works, but the iPad is then off the
  venue network, so QR sharing is gone.

Either way: **Wi-Fi Function → Remote control (EOS Utility)**, not "Connect to
smartphone" — that's Camera Connect's own app-specific pairing scheme and
rejects this app's connection with Init Fail.

## 4. Do not manually set CaptureDestination

Leave it at the camera's default (card). The app sets it explicitly to card
on connect and restores it on disconnect.

`CaptureDestination=Host` is the setting to avoid, for two reasons, both
confirmed on hardware 2026-08-03:

- **The shutter will not fire.** Host destination needs an object-transfer
  handshake this app does not implement, so the body answers `DeviceBusy` to
  every release path — bare release, full press, half+full, with live view
  torn down, in AF and in MF.
- **It persists after unplugging, and photos go nowhere.** A body left on
  Host writes nothing to the card, including from the physical shutter, with
  no warning on the camera. That is a silent way to lose an entire event.

> An earlier version of this section said Host destination "disables
> autofocus camera-wide, including the physical shutter button". That was a
> misdiagnosis. The real cause of everything attributed to it was the USB
> transport discarding every PTP data phase, which starved the event queue
> and wedged the body — see `docs/PHASE0.md`. **Treat any "we tried X and it
> made no difference" note written before 2026-08-03 as untested**, because
> every one of them measured a camera that could not have worked.

## 5. Connect

**Over USB (preferred).** Launch the app first, then plug the camera in — the
device browser picks it up on connection, and a camera already attached at
launch may not enumerate.

**There is nothing to tap.** Picking an event goes straight to a searching
screen and the camera connects on its own; live view appears a couple of
seconds later. Nothing to configure on the camera beyond §1 and §2.

If the cable search comes back empty the app reveals the IP field and a
**Search for camera again** button. Plug the cable in (or wake the camera) and
use that button rather than backing out — it re-probes USB, it does not just
retry the address in the box.

Backing out to the event list keeps the wired session open on purpose, so
picking another event reconnects instantly. See `docs/PHASE0.md` for why
tearing it down was worse.

**Over Wi-Fi.** Enter the camera's IP (auto-AP mode: usually `192.168.1.2`;
venue Wi-Fi mode: check the camera's Wi-Fi info screen), tap Connect.

## Troubleshooting

**Capture fails with `DeviceBusy (0x2019)`, repeatedly, right after
connecting:** `CaptureDestination` is on Host — see §4. Power-cycle the
camera to clear it. Current builds set card on connect and restore it on
disconnect, but a body left on Host by an older build stays that way until
restarted.

**Photos are not appearing on the card at all, even from the physical
shutter:** same cause, and the more expensive version of it. Power-cycle
before shooting anything you care about.

**No camera found over USB:** launch the app before plugging in, and replug
while the connect screen is open. Also check nothing else holds the session —
Cascable, Photos' import prompt, or another camera app. Only one app gets the
device.

**Live view runs but the shutter never fires, on a manual or adapted lens:**
check §2's "Release shutter without lens". Note this was *not* the cause of
the 2026-08-03 investigation, which turned out to be §4 — but it is a real
setting and a real cause on adapted glass.

**QR code button shows "not connected to Wi-Fi" or guests can't reach the
scan link:** check the **iPad's** network, not the camera's (§3). The iPad
needs a real LAN address on the same network the guests are on. Joining the
camera's own AP is the usual cause — it isn't bridged to anything, so nobody
else can reach the iPad. Over USB the camera's network state is irrelevant
here.

**Mid-event Wi-Fi drop — app recovers to the connect screen but won't
reconnect no matter how many times you tap Connect:** expected, not a bug.
Wi-Fi path only; the cable does not have this failure mode.
When the camera's own Wi-Fi session drops, its firmware fully exits Remote
control (EOS Utility) mode rather than just losing the link — it needs to be
manually re-armed **on the camera itself** (Wi-Fi menu → Remote control (EOS
Utility) again) before any client, this app included, can reconnect.
Attendant needs to walk back to the camera, not just retry in the app.
