// OWNER: HOM-21 (placeholder created by INT-104 so the DanaviewShare target lists every source)
//
// Streams shared items into `<App Group>/Inbox/<batchId>/` with `manifest.json` written last
// (ARCH v1.2 §5.6). Backup class (ARCH §5.2): the inbox is excluded from backups, so the writer
// must mark `Inbox/` with `URLResourceValues.isExcludedFromBackup = true` when it creates it.
// Empty until HOM-21 apart from the App Group id, which must match DanaviewShare.entitlements and
// ios/Runner/Runner.entitlements.

import Foundation

enum DanaviewAppGroup {
  static let identifier = "group.com.vecvel.danaview"
}
