import CoreLocation
import SwiftUI
import CanonProtocol

struct ContentView: View {
    @Bindable var coordinator: GeotagCoordinator
    @State private var isPairing = false

    var body: some View {
        NavigationStack {
            Form {
                if coordinator.timeZone.needsCameraUpdate, coordinator.cameraName != nil {
                    timeZoneSection
                }
                cameraSection
                locationSection
                modeSection
                Section {
                    NavigationLink("Activity") { ActivityLogView(coordinator: coordinator) }
                } footer: {
                    Text("Keep CanonGeotag in the app switcher. If you force-quit it, iOS won't relaunch it when the camera turns on.")
                }
            }
            .navigationTitle("CanonGeotag")
            .sheet(isPresented: $isPairing) {
                PairingView(coordinator: coordinator)
            }
        }
    }

    private var cameraSection: some View {
        Section("Camera") {
            LabeledContent {
                Text(coordinator.state.title)
                    .multilineTextAlignment(.trailing)
            } label: {
                Label(coordinator.cameraName ?? "Camera", systemImage: statusSymbol)
                    .symbolEffect(.pulse, isActive: coordinator.state == .connecting)
            }
            if coordinator.ble.power == .poweredOff {
                Label("Turn on Bluetooth to connect", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if coordinator.cameraName == nil {
                Button("Pair Camera", systemImage: "plus") { isPairing = true }
                    .buttonStyle(.glassProminent)
            } else {
                Button("Forget Camera", systemImage: "trash", role: .destructive) {
                    coordinator.forgetCamera()
                }
            }
        }
    }

    private var timeZoneSection: some View {
        let zone = coordinator.timeZone.phoneZone
        return Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Update the camera's time zone", systemImage: "clock.badge.exclamationmark")
                    .font(.headline)
                Text("Your phone is on \(zone.cityName) time (\(zone.offsetText)), but the camera was last set to \(coordinator.timeZone.cameraZone.offsetText). On the camera, open **Menu → Set-up → Date/Time/Zone** and choose the new zone (or toggle daylight saving). Geotags are correct either way, but photo times use the camera's clock.")
                    .font(.callout)
                Button("I've Updated the Camera") { coordinator.timeZone.confirmCameraUpdated() }
                    .buttonStyle(.glassProminent)
            }
        }
    }

    private var locationSection: some View {
        Section {
            if !coordinator.location.isAuthorizedAlways {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Allow location access “Always” so photos are geotagged while CanonGeotag runs in the background.")
                        .font(.callout)
                    if coordinator.location.authorization == .denied {
                        Button("Open Settings") { openSettings() }
                    } else {
                        Button("Allow Location") { coordinator.location.requestAuthorization() }
                            .buttonStyle(.glassProminent)
                    }
                }
            }
            if !coordinator.location.isPrecise {
                Label("Precise Location is off, so positions will be several kilometres off. Turn it on in Settings.",
                      systemImage: "location.slash")
                    .foregroundStyle(.orange)
            }
            if let fix = coordinator.location.latest {
                LabeledContent("Current", value: fix.coordinateText)
                LabeledContent("Accuracy", value: "±\(Int(fix.horizontalAccuracy)) m")
                LabeledContent("Updated") { Text(fix.timestamp, style: .relative) }
            }
            if let sent = coordinator.lastSentDate {
                LabeledContent("Last sent to camera") { Text(sent, style: .relative) }
            }
        } header: {
            HStack {
                Text("Location")
                Spacer()
                if coordinator.location.isUsingGPS {
                    Label("GPS on", systemImage: "location.fill").labelStyle(.titleAndIcon)
                }
            }
        }
    }

    private var modeSection: some View {
        Section {
            Picker("Mode", selection: $coordinator.mode) {
                ForEach(LocationMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Accuracy and Battery")
        } footer: {
            Text(coordinator.mode.summary)
        }
    }

    private var statusSymbol: String {
        switch coordinator.state {
        case .noCamera: "camera"
        case .waiting: "camera.badge.clock"
        case .connecting, .confirmOnCamera: "antenna.radiowaves.left.and.right"
        case .connected(true): "location.circle.fill"
        case .connected(false): "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

struct PairingView: View {
    let coordinator: GeotagCoordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("On the camera") {
                    Text("1. Open **Menu → Wireless features → Bluetooth settings** and turn Bluetooth on.")
                    Text("2. Choose **Connect to smartphone → Add a device to connect**.")
                    Text("3. When the camera shows its name, select it below.")
                    Text("4. Confirm the pairing on the camera when asked.")
                    Text("5. In **Wireless features → GPS device settings**, set **Select GPS device** to **Smartphone**.")
                }
                Section("Nearby cameras") {
                    if coordinator.ble.discovered.isEmpty {
                        HStack {
                            ProgressView()
                            Text("Searching…").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(coordinator.ble.discovered) { camera in
                        Button {
                            coordinator.pair(with: camera)
                            dismiss()
                        } label: {
                            LabeledContent(camera.name, value: "\(camera.rssi) dBm")
                        }
                    }
                }
            }
            .navigationTitle("Pair Camera")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
            }
            .onAppear { coordinator.beginPairing() }
            .onDisappear { coordinator.ble.stopScan() }
        }
    }
}

struct ActivityLogView: View {
    let coordinator: GeotagCoordinator

    var body: some View {
        List(coordinator.log.reversed()) { entry in
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.message)
                Text(entry.date, format: .dateTime.day().month().hour().minute().second())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .overlay {
            if coordinator.log.isEmpty {
                ContentUnavailableView("No Activity", systemImage: "list.bullet")
            }
        }
        .navigationTitle("Activity")
        .toolbar {
            Button("Clear", systemImage: "trash") { coordinator.clearLog() }
        }
    }
}

private extension GeoFix {
    var coordinateText: String {
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(5))
        return "\(latitude.formatted(format)), \(longitude.formatted(format))"
    }
}
