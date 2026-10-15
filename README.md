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
- **Handshake:** identify the phone with its name and a persistent 16-byte ID, then wait up to 3 s for the pairing result. The app currently assumes the camera is already paired (for example through Canon Camera Connect), so only a rejection stops it, and no result counts as accepted. Next, subscribe to location indications. furble also switches the camera to shooting mode, but that turns on a camera whose power switch is off, and geotagging doesn't need it.
- **Location packet:** 20 bytes, packed and little-endian, sent with write-with-response to `00040002` once the camera indicates `0x02` on `00040003`.
  - `0x04` header
  - `N`/`S` and `|lat|` as Float32
  - `E`/`W` and `|lon|` as Float32
  - `+`/`-` and `|alt|` as Float32
  - Unix time (UTC) as UInt32, taken when the packet is sent (see *Time handling*)

### Background auto-start

Sony's app keeps a pending `connect()` that completes when the camera turns on. That doesn't work for Canon. With Bluetooth enabled, the R7 keeps advertising while its power switch is off, and **any connection turns it on**. The app watches the advertisement instead:

1. **Status byte.** The manufacturer data ends in a status byte: `05` while switched off (one packet every 30–70 s) and `02` while on (about 4 a second), e.g. `a9 01 01 f7 32 35 26 02`. The app connects only when the status isn't `05`. See `CameraStatus` in `CanonProtocol`.
2. **Background scan.** The app scans for the Canon primary service, which the camera advertises in both states, so iOS keeps the scan running in the background and wakes the app on a match. In the background iOS reports a peripheral only once per scan, so the app restarts the scan after each "off" packet. It wakes briefly about once a minute while the camera is off and in range.
3. **State restoration.** The central has a restore identifier, so the scan survives iOS terminating the app. iOS relaunches the app in the background, and it rebuilds the central in `didFinishLaunching` and resumes.

A camera that Canon Camera Connect already has connected doesn't advertise. The app checks for it among connected peripherals and connects directly.

Significant-location-change monitoring also wakes or relaunches the app after the phone moves about 500 m.

### Time handling

- **The location timestamp is absolute UTC.** A Unix time has no time zone, so crossing zones never affects the packet. The R7 shows it as *UTC* in its shooting info and stores it as the EXIF GPS date/time.
- **It is the time of sending, not the fix's capture time.** Canon Camera Connect and [camera-gps](https://github.com/mcfitz2/camera-gps) do the same. A significant-change fix can be hours old while still being the best known position, and its capture time would put the wrong GPS time in photos.
- **The camera's own clock can't be set over Bluetooth.** Photo times (EXIF `DateTimeOriginal`/`OffsetTime`) come from the camera's *Date/Time/Zone* setting. No public implementation documents a BLE command to set it, and Canon's own app only offers a manual update.
- **The app reminds you after a zone change instead.** When the phone's UTC offset changes (travel or daylight saving), CanonGeotag shows a banner and posts one notification asking you to update *Menu → Set-up → Date/Time/Zone* on the camera. Arriving somewhere new wakes the app through significant location changes, so the reminder also arrives in the background. `TimeZoneMonitor.swift` assumes the camera matches the phone at pairing time.

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
  TimeZoneMonitor.swift       Reminds you to update the camera's time zone after travel or DST
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
4. On the camera, go to **Wireless features → GPS device settings** and set **Select GPS device** to **Smartphone**. Without this, the camera ignores phone location.
5. From then on, turning on the camera connects it automatically, and the app sends location while the camera is on.

## Testing background auto-start

**Do not swipe the app away in the app switcher.** On iOS that is a force-quit, and iOS will not relaunch the app until you open it again yourself. Sony's app has the same limitation. To test:

1. Leave the app in the background, or restart the iPhone.
2. Turn the camera off, then on.
3. Open **Activity** in the app. You should see *Camera is off, waiting for it to turn on*, then *Camera turned on*, *Camera connected*, *Camera accepted location* and *Sent …* entries.

## Status and caveats

- **Not yet tested on hardware.** R7 compatibility is inferred from furble's tested list, which includes the R6 Mark II from the same generation.
- **Single phone pairing.** The R7 pairs with one phone app at a time, so pairing CanonGeotag likely replaces the Canon Camera Connect pairing.
- **Clock reminder is manual.** After the time-zone reminder, the camera's clock still has to be updated by hand. A BLE command for this is unknown.
- **Battery saver accuracy.** In this mode, positions can be about 500 m off.
- **Free Apple ID signing.** With xtool and a free Apple ID, the install expires after 7 days.
