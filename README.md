# CanonGeotag

An iOS app that sends the iPhone's location to a **Canon EOS R7** over Bluetooth LE, so the camera geotags photos as you take them.

## Original intent

The goal was an iOS app built with [xtool](https://xtool.sh) that:

- **Provides GPS geotagging for a Canon R7.** The app reuses existing open-source protocol work where possible.
- **Uses very little battery.** It relies on the iOS **significant location change** API, the same way Sony's iOS camera app does.
- **Starts on its own in the background when the camera turns on.** It uses the iOS mechanism that relaunches an app when its BLE accessory connects, also like Sony's app.
- **Follows modern Swift.** The code is fully Swift 6.2 compliant: async/await, structured concurrency and strict data-race checking. The minimum target is iOS 26.

## What was built

### Camera protocol

No existing iOS implementation was found. The Canon "smart device" BLE protocol is ported from [gkoh/furble](https://github.com/gkoh/furble) (`lib/furble/CanonEOSSmart.cpp`), ESP32 firmware that already geotags Canon EOS bodies. [mcfitz2/camera-gps](https://github.com/mcfitz2/camera-gps), an Android app, uses the same protocol.

- **Services:** UUIDs follow the pattern `XXXXXXXX-0000-1000-0000-D8492FFFA821`.
  - Primary `00010000`
  - Mode `00030000`
  - Location `00040000`
- **Handshake:** identify the phone with its name and a persistent 16-byte ID, then wait for the user to confirm on the camera. Next, subscribe to location indications and switch the camera to shooting mode.
- **Location packet:** 20 bytes, packed and little-endian, sent with write-with-response to `00040002` once the camera indicates `0x02` on `00040003`.
  - `0x04` header
  - `N`/`S` and `|lat|` as Float32
  - `E`/`W` and `|lon|` as Float32
  - `+`/`-` and `|alt|` as Float32
  - Unix time (UTC) as UInt32

### Background auto-start

Two CoreBluetooth mechanisms work together:

1. **Pending connection.** `CBCentralManager.connect()` never times out. When the R7 powers on, iOS connects and wakes the suspended app.
2. **State restoration.** The central has a restore identifier, so the pending connection survives iOS terminating the app. iOS relaunches the app in the background, and it rebuilds the central in `didFinishLaunching` and resumes.

Significant-location-change monitoring also wakes or relaunches the app after the phone moves about 500 m.

### Location modes (selectable in the app)

| Mode | Behaviour |
|---|---|
| **Balanced** (default) | Significant changes, plus a GPS fix of up to 20 s when the camera connects or you've moved |
| **Battery saver** | Significant changes only (about 500 m accuracy) |
| **Precise** | GPS stays on while the camera is connected |

### Concurrency design

- Swift 6 language mode, `MainActor` default isolation, and the `NonisolatedNonsendingByDefault` and `InferIsolatedConformances` upcoming features.
- CoreBluetooth calls are wrapped as `async throws` operations built on checked continuations, and indications arrive as `AsyncStream`s. The delegates use main-actor isolated conformances, which is valid because the central uses `queue: nil`.
- Each camera connection runs as one cancellable session. It consists of the handshake followed by a serial event loop over camera indications and location fixes.
- On-demand GPS uses `CLLocationUpdate.liveUpdates`. Authorization is declared through a held `CLServiceSession(.always)`.
- The activity log is an `actor`.
- There are no GCD calls, `@unchecked Sendable` or `nonisolated(unsafe)`.

## Project layout

```
Package.swift                 App package (xtool)
xtool.yml / Info.plist        Bundle ID, background modes, usage strings
Packages/CanonProtocol/       Pure-Swift protocol: UUIDs, packet encoding, handshake (+ Swift Testing tests)
Sources/CanonGeotag/
  AppDelegate.swift           Recreates managers on every (background) launch
  CameraBLEManager.swift      CBCentralManager, state restoration, pending connects, pairing scan
  PeripheralLink.swift        async/await wrapper around a connected CBPeripheral
  LocationProvider.swift      Significant changes + on-demand GPS
  GeotagCoordinator.swift     Connection session, handshake, location → camera
  EventLog.swift              Persistent activity log (for checking background behaviour)
  ContentView.swift           SwiftUI UI: status, pairing, mode picker, activity log
```

## Build and run

```sh
xtool dev run                                      # build, sign and install on a connected iPhone
(cd Packages/CanonProtocol && swift test)          # protocol unit tests (macOS)
```

## Using it

1. Open the app and tap **Allow Location**. Accept *When In Use*, then *Always*.
2. On the R7, go to **Menu → Wireless features → Bluetooth settings** and turn Bluetooth on. Then choose **Connect to smartphone → Add a device**.
3. In the app, tap **Pair Camera**, select the camera, and confirm on the camera.
4. From then on, turning on the camera connects it automatically, and the app sends location while the camera is on.

## Testing background auto-start

**Do not swipe the app away in the app switcher.** On iOS that is a force-quit, and iOS will not relaunch the app until you open it again yourself. Sony's app has the same limitation. To test:

1. Leave the app in the background, or restart the iPhone.
2. Turn the camera off, then on.
3. Open **Activity** in the app. You should see a background launch, *Camera connected*, *Camera accepted location* and *Sent …* entries.

## Status and caveats

- **Not yet tested on hardware.** R7 compatibility is inferred from furble's tested list, which includes the R6 Mark II from the same generation.
- **Single phone pairing.** The R7 pairs with one phone app at a time, so pairing CanonGeotag likely replaces the Canon Camera Connect pairing.
- **Timestamps are sent as UTC.** This follows furble. Check how the R7's time-zone setting interacts with them.
- **Battery saver accuracy.** In this mode, positions can be about 500 m off.
- **Free Apple ID signing.** With xtool and a free Apple ID, the install expires after 7 days.
