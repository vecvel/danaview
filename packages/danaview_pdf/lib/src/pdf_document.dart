// OWNER: HOM-24
//
// Read-only PDF documents (ARCH v1.2 §8 "PDF viewer", §11 `PdfFailure`, rule 27) over the frozen
// Pigeon surface (pigeons/pdf_api.dart): capabilities, the viewer router's probe, open with an
// optional password, unlock, page sizes, outline, page thumbnails and close. PDFKit on iOS and
// macOS (HOM-24), PdfRenderer on Android (HOM-25). Also the shared error type of every danaview_pdf
// wrapper. Nothing here logs a name, a path, a password or document text (rule 30).

import 'package:flutter/foundation.dart';

import 'pigeon/pdf_api.g.dart';
import 'pigeon/pdf_channels.dart';

/// Error codes of the PDF plugin (pigeons/pdf_api.dart, "Errors"; ARCH §11 `PdfFailure`).
enum PdfErrorCode {
  /// The capability does not exist on this platform, or its native class has not landed yet.
  notSupportedOnDevice,

  /// The file is encrypted and no or a wrong password was given.
  passwordRequired,

  /// A PDF feature the platform can't open.
  unsupported,

  /// Not a readable PDF.
  damaged,

  /// The operation was cancelled.
  cancelled,

  /// The device is out of space.
  noSpace,

  /// No such file, document, view or job.
  notFound,

  /// The request was malformed.
  invalidArgument,

  /// A file system error.
  ioError,

  /// Anything else.
  internal;

  /// The code of a platform error code string; Pigeon's `channel-error` (no native handler) is
  /// [notSupportedOnDevice], an unknown string [internal].
  static PdfErrorCode fromCode(String code) {
    if (code == 'channel-error') return notSupportedOnDevice;
    for (final value in values) {
      if (value.name == code) return value;
    }
    return internal;
  }
}

/// A failure of a danaview_pdf call. [message] is debug text without names, paths or text.
final class PdfException implements Exception {
  /// A failure with [code].
  const PdfException(this.code, this.message);

  /// What went wrong.
  final PdfErrorCode code;

  /// Debug text (never shown to users, never logged with names).
  final String message;

  @override
  String toString() => 'PdfException(${code.name}: $message)';
}

/// A page tool (HOM-28…HOM-31).
enum PdfTool {
  /// Merge PDFs and images.
  merge,

  /// Split by ranges.
  split,

  /// Reorder pages.
  reorder,

  /// Rotate pages.
  rotate,

  /// Delete pages.
  deletePages,

  /// Annotate and highlight.
  annotate,

  /// Visual signatures.
  sign,

  /// Compress.
  compress,
}

/// What this device's PDF implementation offers; the UI hides what is missing.
@immutable
final class PdfCapabilities {
  /// Capabilities as given.
  const PdfCapabilities({
    this.platformView = false,
    this.textureView = false,
    this.search = false,
    this.selection = false,
    this.outline = false,
    this.passwords = false,
    this.textExtraction = false,
    this.tools = const {},
  });

  /// Nothing (no plugin on this platform).
  static const PdfCapabilities none = PdfCapabilities();

  /// The viewer is a native platform view (Apple PDFKit).
  final bool platformView;

  /// The viewer is a texture (Android PdfRenderer).
  final bool textureView;

  /// In-document search.
  final bool search;

  /// Text selection and copy.
  final bool selection;

  /// The document outline.
  final bool outline;

  /// Encrypted files open with a password.
  final bool passwords;

  /// Text extraction for the search index.
  final bool textExtraction;

  /// Page tools that have landed here.
  final Set<PdfTool> tools;

  /// True when a viewer exists.
  bool get canView => platformView || textureView;
}

/// The size of one page.
@immutable
final class PdfPageSize {
  /// A page of [width] × [height] points (unrotated) turned by [rotation] degrees clockwise.
  const PdfPageSize(this.width, this.height, [this.rotation = 0]);

  /// Crop box width in points, unrotated.
  final double width;

  /// Crop box height in points, unrotated.
  final double height;

  /// 0, 90, 180 or 270.
  final int rotation;

  /// Width as displayed (rotation applied).
  double get displayWidth => rotation % 180 == 0 ? width : height;

  /// Height as displayed (rotation applied).
  double get displayHeight => rotation % 180 == 0 ? height : width;

  /// Displayed width over height.
  double get aspectRatio => displayHeight <= 0 ? 1 : displayWidth / displayHeight;

  @override
  bool operator ==(Object other) => other is PdfPageSize && other.width == width && other.height == height && other.rotation == rotation;

  @override
  int get hashCode => Object.hash(width, height, rotation);
}

/// An open, read-only document.
@immutable
final class PdfDocumentInfo {
  /// Info as given.
  const PdfDocumentInfo({
    required this.handle,
    required this.pageCount,
    this.encrypted = false,
    this.locked = false,
    this.allowsCopying = true,
    this.allowsPrinting = true,
    this.pageSizes = const [],
    this.title,
  });

  /// The handle for the other calls; valid until [PdfDocuments.close].
  final int handle;

  /// Pages (0 while [locked]).
  final int pageCount;

  /// The file is encrypted.
  final bool encrypted;

  /// A password is needed ([PdfDocuments.unlock]).
  final bool locked;

  /// The file allows copying text.
  final bool allowsCopying;

  /// The file allows printing.
  final bool allowsPrinting;

  /// One size per page.
  final List<PdfPageSize> pageSizes;

  /// Title from the metadata (shown, never logged).
  final String? title;

  @override
  String toString() => 'PdfDocumentInfo(#$handle, $pageCount pages${locked ? ', locked' : ''})';
}

/// What a cheap open says about a file.
@immutable
final class PdfProbe {
  /// A probe result.
  const PdfProbe({required this.canOpen, this.encrypted = false, this.pageCount = -1});

  /// The platform viewer can open it (a password may still be needed).
  final bool canOpen;

  /// A password is needed.
  final bool encrypted;

  /// Pages, or -1 when unknown.
  final int pageCount;
}

/// One outline entry, flattened depth-first.
@immutable
final class PdfOutlineEntry {
  /// An entry.
  const PdfOutlineEntry({required this.title, required this.pageIndex, this.depth = 0});

  /// Its label.
  final String title;

  /// Target page, or -1 without a destination.
  final int pageIndex;

  /// 0 for top-level entries.
  final int depth;

  @override
  bool operator ==(Object other) => other is PdfOutlineEntry && other.title == title && other.pageIndex == pageIndex && other.depth == depth;

  @override
  int get hashCode => Object.hash(title, pageIndex, depth);
}

/// A rendered page image.
@immutable
final class PdfPageImage {
  /// An image.
  const PdfPageImage({required this.png, required this.width, required this.height});

  /// PNG bytes.
  final Uint8List png;

  /// Pixels.
  final int width;

  /// Pixels.
  final int height;
}

/// Read-only documents. Implementations: [PlatformPdfDocuments]; tests fake it.
abstract interface class PdfDocuments {
  /// What this device offers ([PdfCapabilities.none] where there is no plugin).
  Future<PdfCapabilities> capabilities();

  /// The viewer router's probe: never throws for a damaged file (`canOpen` false).
  Future<PdfProbe> probe(String path);

  /// Opens [path] read-only; an encrypted file with no or a wrong [password] opens locked.
  Future<PdfDocumentInfo> open(String path, {String? password});

  /// Unlocks a locked document; null when [password] is wrong.
  Future<PdfDocumentInfo?> unlock(int handle, String password);

  /// The outline (empty when there is none).
  Future<List<PdfOutlineEntry>> outline(int handle);

  /// Page [pageIndex] fitted into [maxWidth] × [maxHeight] pixels.
  Future<PdfPageImage> thumbnail(int handle, int pageIndex, {required int maxWidth, required int maxHeight});

  /// Releases [handle]; views showing it keep their own reference.
  Future<void> close(int handle);
}

/// [PdfDocuments] over the plugin.
final class PlatformPdfDocuments implements PdfDocuments {
  /// Documents over the default engine, or [documentApi] / [viewApi] (tests).
  PlatformPdfDocuments({PdfDocumentHostApi? documentApi, PdfViewHostApi? viewApi})
      : _api = documentApi ?? PdfDocumentHostApi(),
        _views = viewApi ?? PdfViewHostApi();

  final PdfDocumentHostApi _api;
  final PdfViewHostApi _views;

  @override
  Future<PdfCapabilities> capabilities() async {
    try {
      final c = await guardPdf(_api.capabilities);
      return PdfCapabilities(
        platformView: c.platformView,
        textureView: c.textureView,
        search: c.search,
        selection: c.selection,
        outline: c.outline,
        passwords: c.passwords,
        textExtraction: c.textExtraction,
        tools: {for (final t in c.tools) PdfTool.values.byName(t.name)},
      );
    } on PdfException catch (e) {
      if (e.code == PdfErrorCode.notSupportedOnDevice) return PdfCapabilities.none;
      rethrow;
    }
  }

  @override
  Future<PdfProbe> probe(String path) async {
    final p = await guardPdf(() => _api.probe(path));
    return PdfProbe(canOpen: p.canOpen, encrypted: p.encrypted, pageCount: p.pageCount);
  }

  @override
  Future<PdfDocumentInfo> open(String path, {String? password}) async =>
      infoOf(await guardPdf(() => _api.open(PdfOpenRequestMsg(path: path, password: password))));

  @override
  Future<PdfDocumentInfo?> unlock(int handle, String password) async {
    final info = await guardPdf(() => _api.unlock(handle, password));
    return info == null ? null : infoOf(info);
  }

  @override
  Future<List<PdfOutlineEntry>> outline(int handle) async => [
        for (final o in await guardPdf(() => _api.outline(handle))) PdfOutlineEntry(title: o.title, pageIndex: o.pageIndex, depth: o.depth),
      ];

  @override
  Future<PdfPageImage> thumbnail(int handle, int pageIndex, {required int maxWidth, required int maxHeight}) async {
    final image = await guardPdf(
      () => _views.pageThumbnail(PdfThumbnailRequestMsg(handle: handle, pageIndex: pageIndex, maxWidthPx: maxWidth, maxHeightPx: maxHeight)),
    );
    return PdfPageImage(png: image.png, width: image.widthPx, height: image.heightPx);
  }

  @override
  Future<void> close(int handle) => guardPdf(() => _api.close(handle));

  /// The Dart info of a Pigeon message.
  static PdfDocumentInfo infoOf(PdfDocumentInfoMsg m) => PdfDocumentInfo(
        handle: m.handle,
        pageCount: m.pageCount,
        encrypted: m.encrypted,
        locked: m.locked,
        allowsCopying: m.allowsCopying,
        allowsPrinting: m.allowsPrinting,
        pageSizes: [for (final s in m.pageSizes) PdfPageSize(s.width, s.height, s.rotation)],
        title: m.title,
      );
}
