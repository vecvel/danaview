// OWNER: HOM-17
//
// Backup classes of the library (ARCH v1.2 §5.2, V2-115): the database and `files/` are included in
// device and iCloud backups; only `imports/` (part files of running imports) is excluded. On Apple
// platforms the flag is `NSURLIsExcludedFromBackupKey`, set through the port the native plugin
// provides (HOM-02's `BackupFlagApi`); until the app root adapts it, [NoBackupFlagPort] keeps
// everything included, which is the safe default. Android's rules are in the app's backup XML
// (INT-104), not here.

/// Sets the backup-exclusion flag on a directory or file.
abstract interface class BackupFlagPort {
  /// Marks [path] excluded from (or included in) backups. Never throws for an unsupported platform.
  Future<void> setExcludedFromBackup(String path, {required bool excluded});
}

/// A port that does nothing (non-Apple platforms, and until HOM-02's adapter is wired).
final class NoBackupFlagPort implements BackupFlagPort {
  /// The no-op port.
  const NoBackupFlagPort();

  @override
  Future<void> setExcludedFromBackup(String path, {required bool excluded}) async {}
}

/// The backup class of each library location (ARCH §5.2).
enum LibraryBackupClass {
  /// `library.db` (and its WAL) and `files/`: included.
  included,

  /// `imports/`: excluded (partial copies are rebuilt by resuming the import).
  excluded,
}
