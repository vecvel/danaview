// OWNER: HOM-02
//
// The empty iOS app that hosts the PhotoLibrary XCTests on the simulator (run_xctests.sh ios):
// a hosted test bundle runs inside this process, so the photo access granted to its bundle id
// (`xcrun simctl privacy … grant photos com.vecvel.danaview.librarytests`) applies to PhotoKit.

import UIKit

@main
final class HostAppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?

  func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    let window = UIWindow(frame: UIScreen.main.bounds)
    window.rootViewController = UIViewController()
    window.makeKeyAndVisible()
    self.window = window
    return true
  }
}
