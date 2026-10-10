# Store GC, availability, relink and backup rules (CORE-28)

Tests in this folder:

| File | Covers |
|---|---|
| `availability_test.dart` | every availability state (`available`, `missing`, `accessLost`, `changed`, `derivedMissing`) with a fake port; the monitor (open, resume, after relink) |
| `relink_test.dart` | every `checkRelink` outcome; `relink` as ONE undoable "Relink media" entry (clamps for shorter files); `autoMatch` ("Relink several": 10 missing Photos assets from one 10-item pick, ambiguous picks unassigned); `findInSameFolder` (readable folders only) |
| `gc_test.dart` | mark (refs.json, open sessions, in-flight imports/jobs, journals), sweep after 24 h, trash, grant/bookmark release, export gate, unreadable projects, scheduler (30 s after start, after delete, on demand) and a fuzz run proving referenced and external files are never deleted |
| `backup_rules_test.dart` | the Android backup rule files and the two manifest attributes |

## V-A7: Android Auto Backup excludes the editor and speech trees (`bmgr` procedure)

Run on an emulator or device with API 31+ (cloud rules) and once on API 29/30 (`fullBackupContent`).
Executed by QA-10; the static part is asserted by `backup_rules_test.dart`.

1. Install a debug build and create content:
   * play a file from the library (player data, must be backed up);
   * open the editor, create a project, record a voice-over (writes
     `files/vwish/editor/projects/<id>/assets/recordings/*.wav`) and import a clip (managed copy
     under `files/vwish/editor/media/`);
   * if available, download a speech model (`files/vwish/speech/models/`).
2. Enable and point the backup transport at local storage:
   ```sh
   adb shell bmgr enabled            # must print "enabled"
   adb shell bmgr transport com.android.localtransport/.LocalTransport
   adb shell setprop log.tag.GmsBackupTransport VERBOSE   # optional, for logs
   ```
3. Run a full backup of the app and list what was written:
   ```sh
   adb shell bmgr backupnow com.vecvel.vwish
   adb shell ls -R /data/data/com.android.localtransport/files/ | grep -i vwish
   ```
   Expected: entries for the player's files and shared preferences; **no** path under
   `files/vwish/editor/` or `files/vwish/speech/`. The command must report `Success` (a quota
   failure, `Agent failure` or `Transport rejected package` is a failure of this check).
4. Device-transfer rules (API 31+): check the `<device-transfer>` section with a real
   "Copy apps & data" transfer between two devices (cable or Wi-Fi setup flow), or with the D2D
   transport where Google Play services provides one (`adb shell bmgr list transports`, then
   `adb shell bmgr transport <d2d transport>` and `bmgr backupnow`). The receiving device has the
   player library and **no** editor projects or speech models.
5. Restore check: `adb shell pm clear com.vecvel.vwish`, then
   `adb shell bmgr restore com.vecvel.vwish`. Launch: the player library and settings are back,
   the Projects list is empty (no editor tree), the app does not crash.
6. Record the Android version, device, `bmgr` output and the listing in the QA-10 report.

## V-D4: `NSURLIsExcludedFromBackupKey` on a directory excludes its contents

The core side is `ManagedStore.ensureLayout()` (CORE-27), which calls
`MediaAccessPort.excludeFromBackup` for `media/` and `derived/`; the speech tree is excluded by
AI-09. The iOS implementation and the device check (`xattr -l` / iCloud backup size before and
after importing a large clip) belong to IOS-15; QA-10 records the result.

## Not covered here

* Real device runs of the `bmgr` procedure: deferred to QA-10 (needs an emulator run outside this
  pure-Dart package).
