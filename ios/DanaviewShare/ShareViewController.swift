// OWNER: HOM-21 (placeholder created by INT-104 so the DanaviewShare target builds)
//
// Principal class of the Share Extension (Info.plist NSExtensionPrincipalClass). HOM-21 replaces it
// with the folder picker and the streamed copy into the App Group inbox (ARCH v1.2 §5.6). Until
// then it imports nothing: it closes the request at once, as if the user cancelled.

import UIKit

@objc(ShareViewController)
final class ShareViewController: UIViewController {
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    let cancelled = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
    extensionContext?.cancelRequest(withError: cancelled)
  }
}
