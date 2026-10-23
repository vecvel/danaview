// OWNER: HOM-23
//
// The viewer router (HOM plan §8.4, ARCH §3 "PDF viewer", "Office / other files", "Text / CSV";
// V2-120 native first, V2-121 Android Office → file card). `candidates` is the matrix as a pure
// table: for each kind and platform, the viewers to try in order, always ending in a viewer the
// app has (the file card, the in-app text viewer, the photo viewer, the player). `resolve` walks
// that list with capability probes: a native viewer is used only when one is registered and its
// probe says it can open the file (PDFKit present, `PdfRenderer` can't open a password PDF on
// older Android, Quick Look can't preview the type, …), else the next candidate is tried.

import 'package:danaview_library/danaview_library.dart';

import 'viewer_file.dart';

/// A viewer the router can pick.
enum ViewerKind {
  /// The existing photo viewer (HOM-11; registered by the Home).
  photo,

  /// The existing Danaview player, for videos and audio (registered by the Home).
  player,

  /// The native PDF viewer: PDFKit (Apple, HOM-24) or `PdfRenderer` (Android, HOM-25).
  pdf,

  /// Quick Look with editing off (Apple, HOM-26).
  quickLook,

  /// The in-app text viewer (this package).
  text,

  /// The in-app read-only CSV/TSV grid (this package).
  csv,

  /// The file card with "Open in another app" and Share (this package).
  fileCard;

  /// True for the viewers this package always has; the others need a registered builder.
  bool get isBuiltIn => this == text || this == csv || this == fileCard;
}

/// Capability probes the router asks before using a registered native viewer. Implementations
/// must not throw; a throw counts as "can't".
abstract interface class ViewerProbes {
  /// Whether [viewer] can open [file] on this device.
  Future<bool> canOpen(ViewerKind viewer, ViewerFile file);
}

/// Probes that accept every registered viewer.
final class AcceptAllProbes implements ViewerProbes {
  /// Accepts everything.
  const AcceptAllProbes();

  @override
  Future<bool> canOpen(ViewerKind viewer, ViewerFile file) async => true;
}

/// Probes from one function per viewer; viewers without a function are accepted.
final class FunctionProbes implements ViewerProbes {
  /// Probes from [probes].
  const FunctionProbes(this.probes);

  /// The probe of each viewer.
  final Map<ViewerKind, Future<bool> Function(ViewerFile file)> probes;

  @override
  Future<bool> canOpen(ViewerKind viewer, ViewerFile file) => probes[viewer]?.call(file) ?? Future.value(true);
}

/// Picks the viewer of a file by kind and platform (ARCH §3).
final class ViewerRouter {
  /// A router for [platform].
  const ViewerRouter(this.platform);

  /// The platform whose column of ARCH §3 applies.
  final ViewerPlatform platform;

  /// The viewers to try for [file], in order; the last is always built in or the photo viewer or
  /// player.
  List<ViewerKind> candidates(ViewerFile file) {
    final apple = platform.isApple;
    final android = platform == ViewerPlatform.android;
    switch (file.kind) {
      case FileKind.photo:
        return const [ViewerKind.photo, ViewerKind.fileCard];
      case FileKind.video:
      case FileKind.audio:
        return const [ViewerKind.player, ViewerKind.fileCard];
      case FileKind.document:
      case FileKind.other:
        break;
    }
    final inApp = file.isDelimited ? const [ViewerKind.csv, ViewerKind.text] : const [ViewerKind.text];
    return switch (file.effectiveDocKind ?? DocumentKind.other) {
      DocumentKind.pdf => [
          if (apple || android) ViewerKind.pdf,
          if (apple) ViewerKind.quickLook,
          ViewerKind.fileCard,
        ],
      DocumentKind.word || DocumentKind.excel || DocumentKind.powerpoint => [
          if (apple) ViewerKind.quickLook,
          ViewerKind.fileCard,
        ],
      DocumentKind.text => [
          if (apple) ViewerKind.quickLook,
          ...inApp,
          ViewerKind.fileCard,
        ],
      DocumentKind.other => [
          if (apple) ViewerKind.quickLook,
          ViewerKind.fileCard,
        ],
    };
  }

  /// The first of [candidates] that can show [file]: built-in viewers always can; the others need
  /// to be in [registered] and pass [probes]. With [skip], those viewers are passed over (a viewer
  /// that failed after opening).
  Future<ViewerKind> resolve(
    ViewerFile file, {
    Set<ViewerKind> registered = const {},
    ViewerProbes probes = const AcceptAllProbes(),
    Set<ViewerKind> skip = const {},
  }) async {
    for (final viewer in candidates(file)) {
      if (skip.contains(viewer)) continue;
      if (viewer.isBuiltIn) return viewer;
      if (!registered.contains(viewer)) continue;
      bool ok;
      try {
        ok = await probes.canOpen(viewer, file);
      } on Object {
        ok = false;
      }
      if (ok) return viewer;
    }
    return ViewerKind.fileCard;
  }
}
