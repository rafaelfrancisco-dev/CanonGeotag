import Foundation
import Observation
import UIKit
import UserNotifications

/// Tracks whether the paired camera's time zone setting still matches the phone.
///
/// Location packets carry absolute UTC time, so geotags are always correct.
/// The camera's own clock and time zone (EXIF `DateTimeOriginal`/`OffsetTime`)
/// can't be set over Bluetooth, though, so after travelling or a daylight
/// saving change the user has to update *Date/Time/Zone* on the camera. This
/// detects that and reminds them.
@Observable
final class TimeZoneMonitor {
    /// UTC offset the camera is assumed to be set to; `nil` when no camera is paired.
    private(set) var cameraOffset: Int?
    private(set) var phoneZone = TimeZone.current

    var needsCameraUpdate: Bool {
        cameraOffset.map { $0 != phoneZone.secondsFromGMT() } ?? false
    }

    @ObservationIgnored private let defaults = UserDefaults.standard

    private enum Keys {
        static let cameraOffset = "cameraTimeZoneOffset"
        static let notifiedOffset = "notifiedTimeZoneOffset"
    }

    init() {
        cameraOffset = defaults.object(forKey: Keys.cameraOffset) as? Int
    }

    /// The camera is set to the phone's zone: at pairing, or after the user updates it.
    func markCameraMatchesPhone() {
        refreshPhoneZone()
        setCameraOffset(phoneZone.secondsFromGMT())
    }

    func forgetCamera() {
        setCameraOffset(nil)
    }

    /// Checks at launch (including background relaunches) and whenever the
    /// time zone changes. `significantTimeChangeNotification` is also delivered
    /// on resume if the change happened while the app was suspended, e.g. when
    /// a significant location change wakes it after a flight.
    func monitor() async {
        await check()
        async let zoneChanges: Void = checkOnEach(.NSSystemTimeZoneDidChange)
        async let timeChanges: Void = checkOnEach(UIApplication.significantTimeChangeNotification)
        _ = await (zoneChanges, timeChanges)
    }

    private func checkOnEach(_ name: Notification.Name) async {
        for await _ in NotificationCenter.default.notifications(named: name) {
            await check()
        }
    }

    func requestNotificationPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    /// Notifies once per new offset.
    private func check() async {
        refreshPhoneZone()
        let offset = phoneZone.secondsFromGMT()
        guard needsCameraUpdate, defaults.object(forKey: Keys.notifiedOffset) as? Int != offset else { return }
        defaults.set(offset, forKey: Keys.notifiedOffset)

        let content = UNMutableNotificationContent()
        content.title = "Update your camera's time zone"
        content.body = "Your phone is now on \(Self.city(phoneZone)) time (\(Self.offsetText(offset))). "
            + "On the camera, open Date/Time/Zone so photo times stay correct. Locations are unaffected."
        let request = UNNotificationRequest(identifier: "timezone", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    private func refreshPhoneZone() {
        let current = TimeZone.current
        if current != phoneZone { phoneZone = current }
    }

    private func setCameraOffset(_ offset: Int?) {
        cameraOffset = offset
        defaults.set(offset, forKey: Keys.cameraOffset)
        defaults.removeObject(forKey: Keys.notifiedOffset)
    }

    // MARK: Formatting

    /// "UTC+5:30", matching the camera's Date/Time/Zone menu (Foundation would say "GMT").
    static func offsetText(_ seconds: Int) -> String {
        let minutes = abs(seconds) / 60
        let text = "UTC\(seconds < 0 ? "−" : "+")\(minutes / 60)"
        return minutes % 60 == 0 ? text : text + String(format: ":%02d", minutes % 60)
    }

    /// Localized city for a zone, e.g. "Lisbon".
    static func city(_ zone: TimeZone) -> String {
        Date.now.formatted(Date.FormatStyle(timeZone: zone).timeZone(.exemplarLocation))
    }
}
