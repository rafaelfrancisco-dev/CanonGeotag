import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Runs for every launch, including background relaunches when the camera
    /// connects or a significant location change arrives. The central manager
    /// (with its restore identifier) and the location manager are recreated
    /// here unconditionally, which is what lets iOS deliver those events.
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let reason = application.applicationState == .background ? "background" : "foreground"
        GeotagCoordinator.shared.start(launchReason: reason)
        return true
    }
}
