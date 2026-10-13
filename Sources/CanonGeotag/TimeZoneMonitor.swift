import Foundation
import Observation
import UserNotifications

/// Tracks whether the camera's time zone setting still matches the phone.
///
/// Location packets carry absolute UTC time, so geotags are always correct.
/// The camera's own clock and time zone (EXIF `DateTimeOriginal`/`OffsetTime`)
/// can't be set over Bluetooth, though, so after travelling or a daylight
/// saving change the user has to update *Date/Time/Zone* on the camera. This
/// detects that and reminds them. Significant location changes wake the app
/// after arriving somewhere new, which is when `check()` runs.
@Observable
final class TimeZoneMonitor {
    nonisolated struct Zone: Equatable, Sendable {
        let identifier: String
        let secondsFromGMT: Int

        static var current: Zone {
            let zone = TimeZone.current
            return Zone(identifier: zone.identifier, secondsFromGMT: zone.secondsFromGMT())
        }

        var offsetText: String {
            let hours = secondsFromGMT / 3600
            let minutes = abs(secondsFromGMT % 3600) / 60
            let sign = secondsFromGMT < 0 ? "−" : "+"
            return minutes == 0 ? "UTC\(sign)\(abs(hours))" : "UTC\(sign)\(abs(hours)):\(String(format: "%02d", minutes))"
        }

        var cityName: String {
            identifier.split(separator: "/").last.map { String($0).replacing("_", with: " ") } ?? identifier
        }
    }

    /// The zone the camera is assumed to be set to.
    private(set) var cameraZone: Zone
    private(set) var phoneZone: Zone = .current

    /// Only the offset matters to the camera's clock.
    var needsCameraUpdate: Bool { cameraZone.secondsFromGMT != phoneZone.secondsFromGMT }

    @ObservationIgnored private let defaults = UserDefaults.standard

    private enum Keys {
        static let cameraZoneID = "cameraTimeZoneID"
        static let cameraOffset = "cameraTimeZoneOffset"
        static let notifiedOffset = "notifiedTimeZoneOffset"
    }

    init() {
        if let identifier = defaults.string(forKey: Keys.cameraZoneID) {
            cameraZone = Zone(identifier: identifier, secondsFromGMT: defaults.integer(forKey: Keys.cameraOffset))
        } else {
            cameraZone = .current
        }
    }

    /// Call when a camera is paired: assume it is set to the current zone.
    func resetToPhone() {
        phoneZone = .current
        setCameraZone(phoneZone)
    }

    /// The user updated the camera's time zone.
    func confirmCameraUpdated() {
        setCameraZone(phoneZone)
    }

    /// Re-reads the phone's zone and notifies once per new offset.
    func check() async {
        phoneZone = .current
        guard needsCameraUpdate,
              defaults.object(forKey: Keys.notifiedOffset) as? Int != phoneZone.secondsFromGMT else { return }
        defaults.set(phoneZone.secondsFromGMT, forKey: Keys.notifiedOffset)

        let content = UNMutableNotificationContent()
        content.title = "Update your camera's time zone"
        content.body = "Your phone is now on \(phoneZone.cityName) time (\(phoneZone.offsetText)). "
            + "On the camera, open Date/Time/Zone so photo times stay correct. Locations are unaffected."
        let request = UNNotificationRequest(identifier: "timezone", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Re-checks whenever the system time zone changes while the app runs.
    func monitor() async {
        await check()
        for await _ in NotificationCenter.default.notifications(named: .NSSystemTimeZoneDidChange) {
            await check()
        }
    }

    func requestNotificationPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    private func setCameraZone(_ zone: Zone) {
        cameraZone = zone
        defaults.set(zone.identifier, forKey: Keys.cameraZoneID)
        defaults.set(zone.secondsFromGMT, forKey: Keys.cameraOffset)
        defaults.removeObject(forKey: Keys.notifiedOffset)
    }
}
