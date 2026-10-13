import CoreLocation
import Observation
import CanonProtocol

nonisolated enum LocationMode: String, CaseIterable, Identifiable, Sendable {
    /// Significant changes, plus a short GPS fix when the camera connects or asks.
    case hybrid
    /// Significant changes only: lowest battery, roughly 500 m accuracy.
    case significantOnly
    /// Full GPS while the camera is connected.
    case continuous

    var id: Self { self }

    var title: String {
        switch self {
        case .hybrid: "Balanced"
        case .significantOnly: "Battery saver"
        case .continuous: "Precise"
        }
    }

    var summary: String {
        switch self {
        case .hybrid: "Low-power tracking, with a short GPS fix when the camera connects or you've moved."
        case .significantOnly: "Low-power tracking only. Accuracy is about 500 m."
        case .continuous: "GPS stays on while the camera is connected. Uses the most battery."
        }
    }
}

/// Supplies `GeoFix`es from significant-location-change monitoring (always
/// on; it also relaunches the app in the background) and from on-demand GPS
/// via `CLLocationUpdate.liveUpdates`.
@Observable
final class LocationProvider: NSObject {
    private(set) var authorization: CLAuthorizationStatus
    private(set) var isPrecise = true
    private(set) var latest: GeoFix?
    private(set) var isUsingGPS = false

    /// Every fix from every source, in order. Single consumer.
    @ObservationIgnored let fixes: AsyncStream<GeoFix>
    @ObservationIgnored private let fixContinuation: AsyncStream<GeoFix>.Continuation
    @ObservationIgnored private let manager = CLLocationManager()
    /// Held for the app's lifetime: declares that we need Always authorization
    /// and keeps background `liveUpdates` working (iOS 18+).
    @ObservationIgnored private var serviceSession: CLServiceSession?

    override init() {
        (fixes, fixContinuation) = AsyncStream.makeStream(of: GeoFix.self, bufferingPolicy: .bufferingNewest(16))
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        isPrecise = manager.accuracyAuthorization == .fullAccuracy
    }

    var isAuthorizedAlways: Bool { authorization == .authorizedAlways }

    /// Restarts significant-change monitoring. Call on every launch, including
    /// background relaunches for a queued location event.
    func start() {
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        if authorization != .notDetermined { requestAuthorization() }
        if let location = manager.location { publish(location) }
        startSignificantChanges()
    }

    /// Declares the Always requirement. Core Location shows When In Use first
    /// and the Always upgrade afterwards; call from a user action.
    func requestAuthorization() {
        if serviceSession == nil {
            serviceSession = CLServiceSession(authorization: .always)
        }
    }

    /// Runs GPS until a fix within `accuracy` metres arrives or `limit` passes.
    func preciseFix(accuracy: CLLocationAccuracy = 30, limit: Duration = .seconds(20)) async {
        isUsingGPS = true
        defer { isUsingGPS = false }
        let updates = Task {
            do {
                for try await update in CLLocationUpdate.liveUpdates(.otherNavigation) {
                    guard let location = update.location else { continue }
                    publish(location)
                    if location.horizontalAccuracy <= accuracy { return }
                }
            } catch {}
        }
        let deadline = Task {
            try? await Task.sleep(for: limit)
            updates.cancel()
        }
        await withTaskCancellationHandler {
            await updates.value
        } onCancel: {
            updates.cancel()
        }
        deadline.cancel()
    }

    /// Streams GPS fixes until the calling task is cancelled.
    func continuousUpdates() async {
        isUsingGPS = true
        defer { isUsingGPS = false }
        do {
            for try await update in CLLocationUpdate.liveUpdates(.otherNavigation) {
                if let location = update.location { publish(location) }
            }
        } catch {}
    }

    private func startSignificantChanges() {
        guard CLLocationManager.significantLocationChangeMonitoringAvailable() else { return }
        switch authorization {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startMonitoringSignificantLocationChanges()
        default:
            break
        }
    }

    private func authorizationChanged(_ status: CLAuthorizationStatus, precise: Bool) {
        authorization = status
        isPrecise = precise
        startSignificantChanges()
    }

    private func publish(_ location: CLLocation) {
        guard location.horizontalAccuracy >= 0 else { return }
        let fix = GeoFix(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: location.verticalAccuracy >= 0 ? location.altitude : nil,
            horizontalAccuracy: location.horizontalAccuracy,
            timestamp: location.timestamp
        )
        if let latest, latest.timestamp > fix.timestamp { return }
        latest = fix
        fixContinuation.yield(fix)
    }
}

// CLLocationManagerDelegate is nonisolated, so its witnesses must be too.
// Values are extracted synchronously, then handed to the main actor.
extension LocationProvider: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        let precise = manager.accuracyAuthorization == .fullAccuracy
        Task { @MainActor in self.authorizationChanged(status, precise: precise) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in locations.forEach(self.publish) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {}
}

extension GeoFix {
    func distance(to other: GeoFix) -> CLLocationDistance {
        CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: other.latitude, longitude: other.longitude))
    }
}
