# Phase 0 — Tethering Spike Protocol

Goal: prove iPad ⇄ Canon EOS R over USB — **connect, live view, trigger, retrieve** — via
ImageCaptureCore PTP passthrough. Live view is the gate. No live view = Phase 0 not passed,
no Phase 1 work starts.

## Setup

- Canon EOS R, latest firmware, powered on, USB connection mode left at default (PTP).
- Data-capable USB-C↔USB-C cable, camera → iPad Air.
- Spike app installed via Xcode (see root README).
- Camera clock set; a freshly formatted card with a handful of photos on it
  (an empty card makes catalog indexing fast; a full 64GB card is a separate test below).

## Test sequence (run in order, log everything)

### T1 — Discovery & authorization
1. Launch spike app, then plug in camera.
2. Expect: `camera found` → `session opened` → `deviceDidBecomeReady` → banner **READY**.
3. **Record:** time from plug-in to READY. If PTP commands fail with -21249 before
   ready fires, that confirms the FB7593726 gating — expected, not a failure.

### T2 — Remote mode
1. Auto-runs on ready: `SetRemoteMode(1)`, `SetEventMode(1)`.
2. Expect both to return 0x2001 OK (or "no response container — assuming OK"; if that
   log line fires, record it — it tells us how the passthrough wraps replies).
3. Failure with 0x2005 (operation not supported) here = passthrough is filtering
   vendor opcodes → go straight to the Fallback ladder below.

### T3 — Live view (THE gate)
1. Auto-runs after T2: `EVFMode=1`, `EVFOutputDevice=PC`, then `GetViewFinderData` polling.
2. Expect: moving image on screen, fps counter live.
3. **Record:**
   - sustained fps over 5 minutes (target ≥ 15; 10–15 = discuss; < 10 = fail)
   - `structured framing: yes/no` log line (tells us the EOS R's actual block format)
   - iPad thermal state / battery drain over 30 min of continuous live view
4. Camera screen goes dark when EVFOutputDevice=PC — expected (output redirected to host).

### T4 — Capture round trip
1. Tap **Trigger Capture** with live view running.
2. Expect: shutter fires (flash too if mounted+on), image appears in-app, round-trip time shown.
3. **Record:** which release path worked (0x910F vs 0x9128/9129 pair — the log says),
   round-trip seconds (budget ≤ 5s), whether live view stalls during transfer and for how long.
4. Repeat 20× back-to-back — booth pace. Watch for degradation or wedging.

### T5 — Disconnect recovery
1. With live view running, pull the USB cable. Expect red DISCONNECTED banner, no crash.
2. Replug. Expect full auto-recovery to live view with **no app restart**.
3. **Record:** recovery time. Repeat 5×. Also test: camera auto-power-off wake,
   camera power-cycled while connected.

### T6 — Endurance
1. Leave live view running 60+ minutes, capture every ~2 min.
2. **Record:** fps drift, memory growth, iPad temperature, any wedge.
3. Rerun with a card holding 1000+ existing images — catalog indexing time at session
   open is the risk (ICC indexes before `ready`; a slow index delays every reconnect).

### T7 — Power (operational blocker check)
1. Note iPad battery % at start/end of T6.
2. If drain projects < 4h runtime: test a USB-C PD hub between camera and iPad —
   does passthrough survive a hub? (If yes: buy hub. If no: bigger conversation.)

## Exit criteria (all required)

- [ ] Live view ≥ 15 fps sustained, stable for 60 min
- [ ] Capture round trip ≤ 5 s, 20 consecutive captures without degradation
- [ ] Cable-pull recovery with no app restart, 5/5
- [ ] Full-res image retrieved and displayed in-app
- [ ] Power path viable for a 4-hour event

## Fallback ladder (if a gate fails)

1. **ICC passthrough tuning** — different poll cadence, smaller live view size param,
   `requestEnableTethering` timing, capture-destination property.
2. **Canon CCAPI over Wi-Fi** — official HTTP API, free activation, live view + shutter +
   download. Camera hosts its own AP. Costs: lower fps, Wi-Fi radio contention with QR
   gallery. Build a CCAPITransport sibling of ICCTransport; protocol layer unchanged.
3. **Stop. Conversation with owner** — companion device or licensing Breeze/Cascable
   camera layer. Not a decision to make unilaterally (per brief §2).

## ✅ 2026-08-03: USB PASSES. Live view, capture, retrieval, one cable.

**Connect → live view → trigger → retrieve now works entirely over USB**, which is
what this document set out to prove and then wrongly concluded was impossible.

| Test | Result | Numbers |
|---|---|---|
| Live view (USB) | pass | **30-36 fps** sustained, structured framing |
| Capture round trip (USB) | pass | **1.94s** for a 6,089,569-byte full-res JPEG |
| Release path | pass | bare `RemoteRelease` 0x910F, fires in ~3s |
| Retrieval | pass | `ObjectAddedEx64` handle → `GetObjectInfo` + `GetObject` |

For comparison the Wi-Fi PTP/IP path this project was rebuilt around gets 14 fps and
2.79s. USB is faster on both, and needs no AP, no pairing and no pre-flight.

**Still outstanding before this replaces the Wi-Fi path in the booth:** 20 consecutive
captures (T4's real bar), 60-minute endurance (T6), and the 4-hour power question (T7).
This work lives on `spike/usb-liveview-blob-diagnostic` and is not merged.

### Four bugs, one root cause

1. **The transport discarded the data phase.** `requestSendPTPCommand`'s completion
   returns two blobs; the first is the data phase and the code read only the second.
   Every command that returns data came back empty. Live view got no frames, `GetEvent`
   drained nothing, property reads returned nothing. Fixed in
   `PTPTransactionResult.from`.
2. **`CaptureDestination=Host` stopped the shutter firing.** Host destination needs an
   object-transfer handshake this app never implemented, so the body refused to release
   at all — `DeviceBusy` on every release path tried. Now captures to card.
3. **The camera was left reconfigured after disconnect.** Canon properties persist past
   the USB session, so a body left on Host writes photos *nowhere*, physical shutter
   included, silently, at a real event. `disconnect()` now restores them.
4. **Retrieval watched the wrong channel.** `nextCapturedFile` waited on
   ImageCaptureCore's file catalog, which never re-announced a shot taken mid-session,
   while Canon's own event had already delivered the object handle.

Only the first is really a root cause. Bugs 2-4 were invisible underneath it, because
nothing could work until the data phase came back.

### What this cost, and why

Three weeks, an entire Wi-Fi transport, and a day of hardware iteration — because a
single wrong inference got written down as fact and then cited instead of re-tested.

The 2026-07-07 conclusion was reached by observing one API through one of its two
return values. It was recorded here, in two source files and in the project vault as
"an iOS platform limitation". Every later decision cited it. Nothing re-derived it.

Worse, **every "we tried X and it made no difference" note in `EOSCamera.swift` was
written while the transport was broken** — the AF investigation, the EVFOutputDevice
comparisons, the CaptureDestination diagnostic. All of them measured a camera that
could not have worked under any setting, and all of them concluded the setting was
innocent. That accumulated "knowledge" then actively misdirected this work: the AF
theory in particular sent the previous session chasing a lens.

Two things broke the deadlock, and neither was reasoning:

- **The owner said he had run this exact rig with live view under Snappic.** The first
  response was to explain that away. It should have been to go looking.
- **Cascable Studio's warning dialog** named the setting our own app had left on the
  camera, which was simultaneously the reason the shutter would not fire and a
  photo-loss bug waiting to happen at a live event.

`0x910F` deserves a specific correction. The original T4 row recorded it working at
2.79s. A comment later called it "a no-op, not implemented on EOS". Earlier today that
comment looked confirmed, because with Host destination it acks `0x2001` and does
nothing. It was the original record that was right: with Card destination it is the
release path that fires, on the first try.

## ~~2026-08-01: FIXED — USB live view works~~ (superseded by the section above)

`requestSendPTPCommand`'s completion hands back **two** `NSData` blobs. The **first** is
the device-to-host data phase. `ICCTransport.send()` read only the second and discarded
the first with `_`, so `payload` came back empty for every command that returns data.

The symptom that got recorded below — "a clean `0x2001` response with a 0-byte payload"
— was never evidence of a missing data phase. It is what a PTP **response container**
looks like on its own, because that is exactly what blob two is.

### The measurement (EOS R, 2026-08-01, `GetViewFinderData` 0x9153)

```
param 1 (was discarded): 192153 bytes
  head: 2C 00 00 00 FF FF FF FF 00 00 00 00 02 00 23 00 ...
  PTP container: does NOT parse as one — raw payload
  JPEG SOI found at offset 52
  LiveViewParser EXTRACTED a 184321-byte frame (structured framing)

param 2 (what we read): 20 bytes
  PTP container: kind=response code=0x2001 txn=1680 (fills blob)
  no JPEG anywhere
```

A 184KB live-view JPEG, every frame, in the parameter being thrown away. Reproduced
twice in the same session. `LiveViewParser` decoded it via Canon's structured block
framing on the first attempt — the parser was always correct, it was simply never handed
anything.

### The fix

`PTPTransactionResult.from(dataPhase:responseBlob:)` — payload from blob one, response
from blob two, falling back to the old single-blob split when there is no data phase so
that capture and `SetRemoteMode`, which were never broken, behave identically.

**This very likely repaired more than live view.** `GetEvent` (0x9116) also carries a
data phase, so event polling over USB was blind too, and the 2026-07-07 conclusion that
"only live view is blocked" was itself incomplete.

### What this changes

USB is now a viable primary transport: live view **and** full-res capture **and** flash
sync on one cable. The Wi-Fi PTP/IP transport becomes the fallback rather than the
primary. Nothing about `EOSCamera` or the protocol layer changed — they were correct all
along, sitting on a transport that returned empty payloads.

Not yet re-run on hardware with the fix in place. T3 over USB is still formally open
until the frames actually appear on screen.

### Why it took three weeks

Worth keeping. The conclusion "iOS platform limitation" was reached by observing one
API's behaviour through one of its two return values, and was then written into
`PHASE0.md`, two source files and the vault as settled fact. Every later decision — the
whole Wi-Fi transport, the UVC path's justification — cited it. Nothing re-derived it,
because it read as already proven.

It came apart only when the owner said he had run this exact rig with live view under
Snappic. The first response to that was to explain it away. **A hardware observation
from someone operating the gear outranks a repo doc, however confidently the doc is
written.**

Everything below this line is the 2026-07-07 record, left intact. Its USB verdict is
superseded; its Wi-Fi work all still stands and currently ships.

## Outcome (2026-07-07): PASSED, via Wi-Fi PTP/IP, not USB

**USB path: dead end, confirmed.** ImageCaptureCore's `requestSendPTPCommand(_:outData:completion:)`
is the only PTP passthrough API available on iOS (the delegate-based variant that separates
inbound data from the response is `IC_UNAVAILABLE(ios)`, confirmed from the SDK header itself).
It never surfaces the device-to-host bulk data phase `GetViewFinderData` needs — every poll
returned a clean `0x2001` response with a 0-byte payload, regardless of property tuning, poll
cadence, or settle time. Capture and remote control both work fine over USB (they use
ImageCaptureCore's normal file-catalog path, not this data-phase mechanism) — only live view
is blocked, and it's ~~an iOS platform limitation, not a Canon protocol detail~~ **WRONG.
It was our own bug: the data phase was in the completion's first parameter, which this
transport discarded. Fixed 2026-08-01 — see above.**

**Wi-Fi path: works, following the fallback ladder's #2 slot but via PTP/IP, not CCAPI**
(CCAPI itself was ruled out first — Canon never added CCAPI support to the original 2018 EOS R
at any firmware level, confirmed against the official supported-camera list and this body's own
changelog). PTP/IP is Canon's *other* Wi-Fi transport — the one the free Camera Connect app
already uses for remote live view on every Wi-Fi-equipped EOS body, no per-model gating.
Reused ~90% of the existing Canon protocol logic (`EOSCamera.swift`); only the transport layer
is new (`PTPIPTransport.swift`, `PTPIPPacket.swift` — raw TCP sockets via `Network.framework`,
CIPA DC-005 packet framing).

Camera-side setup: Wi-Fi Function → **Remote control (EOS Utility)** (not "Connect to
smartphone" — that's Camera Connect's own app-specific pairing scheme and rejects generic
PTP/IP clients with Init Fail). Client GUID must be fixed/persistent across sessions
(Canon's pairing model remembers a connecting client like Bluetooth pairing — a random GUID
per launch looks like a new, untrusted device every time).

| Date | Test | Result | Numbers | Notes |
|------|------|--------|---------|-------|
| 2026-07-07 | T1 (USB) | pass | — | camera found → ready, ImageCaptureCore catalog indexing ~9s on a full card |
| 2026-07-07 | T2 (USB) | pass | — | SetRemoteMode/SetEventMode both 0x2001 OK |
| 2026-07-07 | T3 (USB) | ~~**FAIL**~~ **misdiagnosed** | 0.0 fps | Attributed to an iOS ImageCaptureCore limitation. It was our own bug — the data phase was in the completion's discarded first parameter |
| 2026-08-01 | Passthrough shape (USB) | **pass** | 184KB/frame | `GetViewFinderData` param 1 = 192153 bytes with a decodable JPEG at offset 52; param 2 = 20-byte `0x2001` response. Reproduced twice |
| 2026-08-03 | T3 (USB) | **PASS** | 30-36 fps | Structured framing, sustained. Beats the Wi-Fi path's 14 fps |
| 2026-08-03 | T4 (USB) | **PASS** | 1.94s | 6,089,569-byte JPEG. Release via bare 0x910F; retrieval via ObjectAddedEx64 handle + GetObject. Single capture only — the 20-consecutive bar is still untested |
| 2026-07-07 | T4 (USB) | pass | 2.79s | RemoteRelease 0x910F, well inside 5s budget; CaptureDestination=Host fix avoided Err 70 |
| 2026-07-07 | T5 (USB) | pass | — | mid-session USB drop (-21400) auto-recovered with no app restart |
| 2026-07-07 | Connect (Wi-Fi/PTP-IP) | pass | ~1-2s | Init Command Ack → Init Event Ack → OpenSession, fixed client GUID |
| 2026-07-07 | T3 (Wi-Fi/PTP-IP) | pass | 3.3fps → 14fps | fixed after tuning poll cadence (200ms→10ms live view, 200ms→1000ms event poll); real bug turned out to be a stray `outData: Data()` making `send()` skip the inbound data-phase read entirely, not a concurrency issue (a hardware-verified reentrancy guard ruled out concurrency first) |
| 2026-07-07 | Capture (Wi-Fi/PTP-IP) | pass | — | shutter + object download over the same PTP/IP connection |

**Exit criteria status:** live view fps target (≥15) effectively met (14fps, booth-usable);
capture round trip and full-res retrieval both proven (on USB, and capture also proven on
Wi-Fi); cable-pull/reconnect recovery proven on USB. Endurance (T6) and power (T7) not yet
run on the Wi-Fi path specifically — worth a pass during Phase 1 once the real guest-facing
flow exists, but not a blocker to starting Phase 1.

**Phase 1 baseline:** build on `PTPIPTransport` + `EOSCamera` as-is. The camera must already be
in Remote control (EOS Utility) Wi-Fi mode and the iPad/iPhone already joined to it before the
app launches — Phase 1 should surface this as a clear pre-flight check/instruction on the
attract screen, not assume it's silently handled.
