import UIKit

/// IOS-01 spike host. Hosts the XCTest bundle (DVSpikeTests) and the manual/UI-test driven
/// background-export experiment (V-N20, V-N11).
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let window = UIWindow(frame: UIScreen.main.bounds)
    window.rootViewController = SpikeViewController()
    window.makeKeyAndVisible()
    self.window = window
    return true
  }
}
