import SwiftUI

@main
struct CanonGeotagApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(coordinator: .shared)
        }
    }
}
