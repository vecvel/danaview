// OWNER: HOM-22
//
// Getting files out, as the pure library sees it (ARCH v1.2 §8 "Getting files out", rule 26,
// V2-117; HOM plan §8.3): the files handed out, the destinations, what each platform offers and
// the port the app implements over danaview_library_native (features: NativeFileOut) or the
// desktop save dialog. This package never writes outside the store: the platform makes the
// temporary read-only copies for share and open-in, and save-out is create-new only.

import 'package:meta/meta.dart';

/// One file handed to the system.
@immutable
final class OutFile {
  /// The readable file at the absolute [path], shown to the receiver as [displayName].
  const OutFile({required this.path, required this.displayName, this.mime, this.uti});

  /// Absolute local path (a library file, a linked-folder file).
  final String path;

  /// The name the receiver sees.
  final String displayName;

  /// MIME type, when known.
  final String? mime;

  /// Apple UTType, when known.
  final String? uti;

  @override
  bool operator ==(Object other) =>
      other is OutFile && other.path == path && other.displayName == displayName && other.mime == mime && other.uti == uti;

  @override
  int get hashCode => Object.hash(path, displayName, mime, uti);

  // Never prints names or paths (rule 30).
  @override
  String toString() => 'OutFile(${mime ?? uti ?? '?'})';
}

/// Where a "save a copy" goes.
enum SaveOutTarget {
  /// The system file picker / save panel / save dialog ("Save to Files", "Save…").
  files,

  /// Android `Download/Danaview` ("Save to Downloads").
  downloads,

  /// The system photo library, add-only ("Save to Photos"); photos and videos only.
  photos,
}

/// The platforms of the Home (pure Dart: no Flutter `TargetPlatform`).
enum FileOutPlatform {
  /// iPhone and iPad.
  iOS,

  /// Android phones and tablets.
  android,

  /// macOS.
  macOS,

  /// Windows.
  windows,

  /// Linux.
  linux,
}

/// What getting files out offers on one platform (HOM plan §8.3 table).
@immutable
final class FileOutCapabilities {
  /// Capabilities; see [FileOutCapabilities.of] for the platform defaults.
  const FileOutCapabilities({required this.saveTargets, required this.canShare, required this.canOpenIn, required this.saveLabel});

  /// The defaults of [platform]: iOS Save to Files, share, Open in, Photos; Android Save to
  /// Downloads, share, open with, Photos (MediaStore); macOS save panel, share, default app,
  /// Photos; Windows and Linux the save dialog and the default app, no share sheet, no Photos.
  factory FileOutCapabilities.of(FileOutPlatform platform) => switch (platform) {
        FileOutPlatform.iOS => const FileOutCapabilities(
            saveTargets: {SaveOutTarget.files, SaveOutTarget.photos},
            canShare: true,
            canOpenIn: true,
            saveLabel: 'Save to Files',
          ),
        FileOutPlatform.android => const FileOutCapabilities(
            saveTargets: {SaveOutTarget.downloads, SaveOutTarget.files, SaveOutTarget.photos},
            canShare: true,
            canOpenIn: true,
            saveLabel: 'Save to Downloads',
          ),
        FileOutPlatform.macOS => const FileOutCapabilities(
            saveTargets: {SaveOutTarget.files, SaveOutTarget.photos},
            canShare: true,
            canOpenIn: true,
            saveLabel: 'Save…',
          ),
        FileOutPlatform.windows || FileOutPlatform.linux => const FileOutCapabilities(
            saveTargets: {SaveOutTarget.files},
            canShare: false,
            canOpenIn: true,
            saveLabel: 'Save…',
          ),
      };

  /// Nothing can leave (no port).
  static const FileOutCapabilities none = FileOutCapabilities(saveTargets: {}, canShare: false, canOpenIn: false, saveLabel: 'Save…');

  /// The destinations offered.
  final Set<SaveOutTarget> saveTargets;

  /// Whether the system share sheet exists.
  final bool canShare;

  /// Whether "Open in another app" exists.
  final bool canOpenIn;

  /// The label of the main "save a copy" action.
  final String saveLabel;

  /// The main "save a copy" destination: Downloads on Android, else Files; null when none.
  SaveOutTarget? get primarySaveTarget => saveTargets.contains(SaveOutTarget.downloads)
      ? SaveOutTarget.downloads
      : (saveTargets.contains(SaveOutTarget.files) ? SaveOutTarget.files : null);

  /// Whether Save to Photos is offered.
  bool get canSaveToPhotos => saveTargets.contains(SaveOutTarget.photos);
}

/// A popover anchor in logical pixels (iPad, macOS).
@immutable
final class OutAnchor {
  /// A rectangle.
  const OutAnchor(this.left, this.top, this.width, this.height);

  /// Left edge.
  final double left;

  /// Top edge.
  final double top;

  /// Width.
  final double width;

  /// Height.
  final double height;
}

/// What a save-out did.
@immutable
final class SaveOutOutcome {
  /// An outcome.
  const SaveOutOutcome({required this.cancelled, required this.saved, required this.failed});

  /// The user cancelled.
  static const SaveOutOutcome userCancelled = SaveOutOutcome(cancelled: true, saved: 0, failed: 0);

  /// True when the user cancelled.
  final bool cancelled;

  /// Files created.
  final int saved;

  /// Items that could not be saved.
  final int failed;
}

/// What a share did.
@immutable
final class ShareOutcome {
  /// An outcome.
  const ShareOutcome({required this.completed});

  /// True when something was shared.
  final bool completed;
}

/// Why a file-out call failed.
enum FileOutError {
  /// The platform has no such destination or sheet.
  unsupported,

  /// The user (or a policy) denied access (Photos add-only permission).
  denied,

  /// The file is gone.
  missing,

  /// Another sheet or picker is open.
  busy,

  /// Anything else.
  failed,
}

/// A failed file-out call; never holds a name or path (rule 30).
final class FileOutException implements Exception {
  /// A failure.
  const FileOutException(this.error);

  /// Why.
  final FileOutError error;

  @override
  String toString() => 'FileOutException(${error.name})';
}

/// The platform side of getting files out. Implementations throw [FileOutException].
abstract interface class FileOutPort {
  /// What this port offers.
  FileOutCapabilities get capabilities;

  /// Saves create-new copies of [files] to [target].
  Future<SaveOutOutcome> saveOut(List<OutFile> files, SaveOutTarget target, {OutAnchor? anchor});

  /// Shows the share sheet with temporary read-only copies of [files].
  Future<ShareOutcome> share(List<OutFile> files, {String? subject, OutAnchor? anchor});

  /// Offers a temporary read-only copy of [file] to another app; false when no app takes it.
  Future<bool> openIn(OutFile file, {OutAnchor? anchor});
}
