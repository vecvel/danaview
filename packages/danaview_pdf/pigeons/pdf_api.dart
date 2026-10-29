// OWNER: HOM-24
//
// FROZEN 2026-10-23 by HOM-24 (ARCH v1.2 V2-25): the whole Pigeon surface of danaview_pdf. Later
// tickets implement the native classes behind it (HOM-25 Android viewer and text; HOM-28/28A page
// tools; HOM-29/29A annotate; HOM-30/30A sign; HOM-31/31A compress); a change to this file is a
// lead-approved [INTEGRATION] amendment. Regenerate from the package root (Mac only; Windows never
// runs Pigeon) with
//
//   dart run pigeon --input pigeons/pdf_api.dart
//
// and commit the generated Dart, Swift and Kotlin files (test/surface/pigeon_regeneration_test.dart
// fails when they drift). Conventions:
//
// - Every host method that reads a file, renders or writes replies asynchronously (`@asyncCallback`,
//   completion-handler / callback style, no Kotlin coroutines). Methods without it are cheap and
//   run on the platform main thread.
// - Host handlers never block the main thread on PDF work: they post to a background queue or
//   executor and reply from it.
// - Errors are `FlutterError(code: <PdfErrorCode>, message: debug text without names, paths or
//   document text (rule 30), details: null)`. Codes: `notSupportedOnDevice` (the capability does
//   not exist here, or its ticket has not landed), `passwordRequired` (the file is encrypted and
//   no or a wrong password was given), `unsupported` (a PDF feature the platform can't open),
//   `damaged` (not a readable PDF), `cancelled`, `noSpace`, `notFound` (no such file, handle, view
//   or job), `invalidArgument`, `ioError`, `internal`. A host API that is not registered answers
//   Pigeon's `channel-error`, which the Dart wrappers map to `notSupportedOnDevice`.
// - Sources are opened read-only and never written back (rule 27). Every tool writes only the new
//   file(s) it is given (`outPath`, `outPaths`), which must not exist yet; the caller does the
//   Replace rename (ARCH §9.3). A cancelled or failed tool leaves no partial file.
// - Pages are 0-based indices. Geometry is in PDF points in page space (origin bottom-left of the
//   crop box, unrotated). Ranges are `[start, end)`. Text and ranges of text are UTF-16 offsets
//   into the page's text (`PDFPage.string` on Apple).
// - Documents are addressed by the integer `handle` `PdfDocumentHostApi.open` returns, views by
//   `viewId`: the Flutter platform view id on Apple (view type `com.vecvel.danaview.pdf/view`,
//   creation params `{handle: int, page: int, displayMode: String}` in the standard codec), the id
//   `createTextureView` returns on Android. A view keeps its document open until both are closed.
// - Events: one multiplexed `PdfEventsApi.pdfEvents` stream (view page / scale / selection changes,
//   tool progress), emitted on the main thread; the Dart side keeps exactly one subscription and
//   fans it out (lib/src/pdf_events.dart).
// - Nothing in this surface opens a socket (rule 21).

import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/pigeon/pdf_api.g.dart',
    dartOptions: DartOptions(),
    dartPackageName: 'danaview_pdf',
    swiftOut: 'darwin/Classes/Glue/PdfApi.g.swift',
    swiftOptions: SwiftOptions(errorClassName: 'PdfPigeonError'),
    kotlinOut: 'android/src/main/kotlin/com/vecvel/danaview/pdf/pigeon/PdfApi.g.kt',
    kotlinOptions: KotlinOptions(package: 'com.vecvel.danaview.pdf.pigeon', errorClassName: 'PdfPigeonError'),
  ),
)
// ---------------------------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------------------------

/// How a viewer lays out pages.
enum PdfDisplayModeMsg {
  /// One column of pages, scrolling continuously (the default).
  continuous,

  /// One page at a time.
  singlePage,

  /// Two pages side by side, scrolling continuously.
  twoUpContinuous,
}

/// A page tool (HOM-28…HOM-31; HOM-28A…HOM-31A).
enum PdfToolKindMsg { merge, split, reorder, rotate, deletePages, annotate, sign, compress }

/// The kind of one [PdfAnnotationMsg] (HOM-29).
enum PdfAnnotationKindMsg {
  /// Text markup over [PdfAnnotationMsg.rects].
  highlight,

  /// Text markup over [PdfAnnotationMsg.rects].
  underline,

  /// Text markup over [PdfAnnotationMsg.rects].
  strikeOut,

  /// Freehand [PdfAnnotationMsg.strokes].
  ink,

  /// [PdfAnnotationMsg.text] drawn in the first rect.
  freeText,

  /// A text note icon at the first rect, holding [PdfAnnotationMsg.text].
  note,
}

/// Compression presets (HOM-31): images re-encoded at falling quality and resolution.
enum PdfCompressPresetMsg { high, medium, small }

/// The kind of one [PdfEventMsg].
enum PdfEventKindMsg {
  /// A view's current page changed; [PdfEventMsg.viewState] is set.
  viewPageChanged,

  /// A view's zoom changed; [PdfEventMsg.viewState] is set.
  viewScaleChanged,

  /// A view's text selection changed; [PdfEventMsg.viewState] is set.
  viewSelectionChanged,

  /// A tool job progressed; [PdfEventMsg.toolProgress] is set.
  toolProgress,
}

// ---------------------------------------------------------------------------------------------
// Documents
// ---------------------------------------------------------------------------------------------

/// What this device's implementation offers; the Dart UI hides what is missing.
class PdfCapabilitiesMsg {
  PdfCapabilitiesMsg({
    required this.platformView,
    required this.textureView,
    required this.search,
    required this.selection,
    required this.outline,
    required this.passwords,
    required this.textExtraction,
    required this.tools,
  });

  /// The viewer is a native platform view (Apple `PDFView`).
  bool platformView;

  /// The viewer is a texture driven by `createTextureView` / `setTextureViewport` (Android).
  bool textureView;

  /// `PdfViewHostApi.search` works.
  bool search;

  /// Text selection and copy work.
  bool selection;

  /// `PdfDocumentHostApi.outline` returns the document outline.
  bool outline;

  /// Encrypted files open with a password.
  bool passwords;

  /// `PdfTextHostApi.extractText` works.
  bool textExtraction;

  /// The page tools that have landed on this platform.
  List<PdfToolKindMsg> tools;
}

/// Opens a file read-only.
class PdfOpenRequestMsg {
  PdfOpenRequestMsg({required this.path, this.password});

  /// Absolute local path.
  String path;

  /// The password of an encrypted file; null tries an empty password only.
  String? password;
}

/// The size of one page.
class PdfPageSizeMsg {
  PdfPageSizeMsg({required this.width, required this.height, required this.rotation});

  /// Crop box width in points, unrotated.
  double width;

  /// Crop box height in points, unrotated.
  double height;

  /// Page rotation in degrees clockwise (0, 90, 180, 270).
  int rotation;
}

/// An open document.
class PdfDocumentInfoMsg {
  PdfDocumentInfoMsg({
    required this.handle,
    required this.pageCount,
    required this.encrypted,
    required this.locked,
    required this.allowsCopying,
    required this.allowsPrinting,
    required this.pageSizes,
    this.title,
  });

  /// The handle for the other calls; valid until `close`.
  int handle;

  /// Number of pages (0 while [locked]).
  int pageCount;

  /// The file is encrypted.
  bool encrypted;

  /// The file needs a password before pages can be read (`unlock`).
  bool locked;

  /// The file's permissions allow copying text.
  bool allowsCopying;

  /// The file's permissions allow printing.
  bool allowsPrinting;

  /// One entry per page (empty while [locked]).
  List<PdfPageSizeMsg> pageSizes;

  /// The document title from its metadata (shown to the user only, never logged).
  String? title;
}

/// What a cheap open says about a file (the viewer router's probe).
class PdfProbeMsg {
  PdfProbeMsg({required this.canOpen, required this.encrypted, required this.pageCount});

  /// The platform viewer can open it (a password may still be needed).
  bool canOpen;

  /// The file is encrypted and needs a password.
  bool encrypted;

  /// Number of pages, or -1 when unknown (locked or unreadable).
  int pageCount;
}

/// One entry of the outline, flattened depth-first.
class PdfOutlineItemMsg {
  PdfOutlineItemMsg({required this.title, required this.pageIndex, required this.depth});

  /// The entry's label.
  String title;

  /// The page it points to, or -1 when it has no destination.
  int pageIndex;

  /// 0 for top-level entries.
  int depth;
}

/// A rendered page image.
class PdfThumbnailRequestMsg {
  PdfThumbnailRequestMsg({required this.handle, required this.pageIndex, required this.maxWidthPx, required this.maxHeightPx});

  /// The document.
  int handle;

  /// The page.
  int pageIndex;

  /// Bounding box in pixels; the page is fitted inside it keeping its aspect ratio.
  int maxWidthPx;

  /// Bounding box in pixels.
  int maxHeightPx;
}

/// An encoded image.
class PdfImageMsg {
  PdfImageMsg({required this.png, required this.widthPx, required this.heightPx});

  /// PNG bytes.
  Uint8List png;

  /// Width in pixels.
  int widthPx;

  /// Height in pixels.
  int heightPx;
}

/// A rectangle in page space (points, origin bottom-left, unrotated).
class PdfRectMsg {
  PdfRectMsg({required this.x, required this.y, required this.width, required this.height});

  double x;
  double y;
  double width;
  double height;
}

// ---------------------------------------------------------------------------------------------
// Views
// ---------------------------------------------------------------------------------------------

/// A search in a view's document.
class PdfSearchOptionsMsg {
  PdfSearchOptionsMsg({required this.query, required this.caseSensitive, required this.maxHits});

  /// The text to find (never logged).
  String query;

  /// Match case; otherwise case- and diacritic-insensitive.
  bool caseSensitive;

  /// Stop after this many hits ([PdfSearchResultMsg.truncated] is then true).
  int maxHits;
}

/// One search hit.
class PdfSearchHitMsg {
  PdfSearchHitMsg({
    required this.index,
    required this.pageIndex,
    required this.rangeStart,
    required this.rangeLength,
    required this.snippet,
    required this.snippetMatchStart,
    required this.snippetMatchLength,
    required this.bounds,
  });

  /// Position in the result list.
  int index;

  /// The page.
  int pageIndex;

  /// UTF-16 offset of the match in the page text.
  int rangeStart;

  /// UTF-16 length of the match.
  int rangeLength;

  /// The match with some words around it, one line.
  String snippet;

  /// Where the match starts in [snippet].
  int snippetMatchStart;

  /// Length of the match in [snippet].
  int snippetMatchLength;

  /// The match's bounds on its page.
  PdfRectMsg bounds;
}

/// The hits of one search.
class PdfSearchResultMsg {
  PdfSearchResultMsg({required this.hits, required this.truncated});

  /// Hits in reading order.
  List<PdfSearchHitMsg> hits;

  /// More hits exist than `maxHits`.
  bool truncated;
}

/// The state of a view.
class PdfViewStateMsg {
  PdfViewStateMsg({
    required this.viewId,
    required this.pageIndex,
    required this.pageCount,
    required this.scale,
    required this.minScale,
    required this.maxScale,
    required this.hasSelection,
    required this.displayMode,
  });

  int viewId;

  /// The page mostly on screen.
  int pageIndex;

  int pageCount;

  /// 1.0 shows a page at its point size; fit-to-width is usually a different value.
  double scale;

  double minScale;

  double maxScale;

  /// Text is selected.
  bool hasSelection;

  PdfDisplayModeMsg displayMode;
}

/// Creates a texture-backed view (Android, HOM-25).
class PdfTextureViewRequestMsg {
  PdfTextureViewRequestMsg({
    required this.handle,
    required this.widthPx,
    required this.heightPx,
    required this.initialPage,
    required this.displayMode,
  });

  /// The document.
  int handle;

  /// Texture size in physical pixels.
  int widthPx;

  /// Texture size in physical pixels.
  int heightPx;

  /// The page to show first.
  int initialPage;

  PdfDisplayModeMsg displayMode;
}

/// A created texture view.
class PdfTextureViewMsg {
  PdfTextureViewMsg({required this.viewId, required this.textureId, required this.state});

  /// The view id for [PdfViewHostApi].
  int viewId;

  /// The Flutter texture id to show with `Texture`.
  int textureId;

  /// The initial state.
  PdfViewStateMsg state;
}

/// The part of a texture view's document that is visible; Dart owns scrolling and zooming and
/// the native side renders the matching tiles into the texture.
class PdfViewportMsg {
  PdfViewportMsg({
    required this.widthPx,
    required this.heightPx,
    required this.offsetX,
    required this.offsetY,
    required this.scale,
  });

  /// Texture size in physical pixels (a change resizes the texture).
  int widthPx;

  /// Texture size in physical pixels.
  int heightPx;

  /// Left edge of the viewport in document points at scale 1 (pages laid out per display mode).
  double offsetX;

  /// Top edge of the viewport in document points at scale 1.
  double offsetY;

  /// Physical pixels per document point.
  double scale;
}

// ---------------------------------------------------------------------------------------------
// Text
// ---------------------------------------------------------------------------------------------

/// Text of a page range of a file, for the search index (AIS-50's DocumentTextPort).
class PdfTextRequestMsg {
  PdfTextRequestMsg({required this.path, this.password, required this.firstPage, required this.pageCount, required this.maxChars});

  /// Absolute local path; opened read-only.
  String path;

  /// The password of an encrypted file.
  String? password;

  /// First page.
  int firstPage;

  /// Number of pages; -1 to the end.
  int pageCount;

  /// Stop after this many UTF-16 units in total ([PdfTextResultMsg.truncated]); -1 for no limit.
  int maxChars;
}

/// The text of one page.
class PdfPageTextMsg {
  PdfPageTextMsg({required this.pageIndex, required this.text});

  int pageIndex;

  /// The page text (never logged); empty for a page without a text layer.
  String text;
}

/// Extracted text.
class PdfTextResultMsg {
  PdfTextResultMsg({required this.documentPageCount, required this.pages, required this.truncated});

  /// Pages in the document.
  int documentPageCount;

  /// The requested pages that were read, in order.
  List<PdfPageTextMsg> pages;

  /// `maxChars` was reached.
  bool truncated;
}

// ---------------------------------------------------------------------------------------------
// Tools (HOM-28…HOM-31, HOM-28A…HOM-31A)
// ---------------------------------------------------------------------------------------------

/// One input file of a tool (opened read-only).
class PdfToolInputMsg {
  PdfToolInputMsg({required this.path, this.password, required this.isImage});

  String path;

  String? password;

  /// The input is an image (JPEG, PNG, HEIC) that becomes one page (merge).
  bool isImage;
}

/// Pages `[start, end)`.
class PdfPageRangeMsg {
  PdfPageRangeMsg({required this.start, required this.end});

  int start;
  int end;
}

/// Merges [inputs] in order into [outPath].
class PdfMergeRequestMsg {
  PdfMergeRequestMsg({required this.jobId, required this.inputs, required this.outPath});

  /// Caller-chosen id for progress events and `cancel`.
  String jobId;
  List<PdfToolInputMsg> inputs;
  String outPath;
}

/// Writes one file per range: `ranges[i]` → `outPaths[i]`.
class PdfSplitRequestMsg {
  PdfSplitRequestMsg({required this.jobId, required this.input, required this.ranges, required this.outPaths});

  String jobId;
  PdfToolInputMsg input;
  List<PdfPageRangeMsg> ranges;
  List<String> outPaths;
}

/// Writes the pages in a new order: `order[i]` is the source page shown at position i (a
/// permutation of all pages).
class PdfReorderRequestMsg {
  PdfReorderRequestMsg({required this.jobId, required this.input, required this.order, required this.outPath});

  String jobId;
  PdfToolInputMsg input;
  List<int> order;
  String outPath;
}

/// Rotates [pages] by [degrees] (a multiple of 90, clockwise).
class PdfRotateRequestMsg {
  PdfRotateRequestMsg({required this.jobId, required this.input, required this.pages, required this.degrees, required this.outPath});

  String jobId;
  PdfToolInputMsg input;
  List<int> pages;
  int degrees;
  String outPath;
}

/// Writes the file without [pages] (at least one page must remain).
class PdfDeletePagesRequestMsg {
  PdfDeletePagesRequestMsg({required this.jobId, required this.input, required this.pages, required this.outPath});

  String jobId;
  PdfToolInputMsg input;
  List<int> pages;
  String outPath;
}

/// One ink stroke: page-space points as `[x0, y0, x1, y1, …]`.
class PdfInkStrokeMsg {
  PdfInkStrokeMsg({required this.points});

  List<double> points;
}

/// One annotation to add.
class PdfAnnotationMsg {
  PdfAnnotationMsg({
    required this.kind,
    required this.pageIndex,
    required this.rects,
    required this.strokes,
    required this.colorArgb,
    required this.lineWidth,
    this.text,
  });

  PdfAnnotationKindMsg kind;
  int pageIndex;

  /// Markup: one rect per line of selected text; freeText / note: the box or icon position.
  List<PdfRectMsg> rects;

  /// Ink strokes.
  List<PdfInkStrokeMsg> strokes;

  /// Colour as 0xAARRGGBB.
  int colorArgb;

  /// Ink and border width in points.
  double lineWidth;

  /// freeText and note content.
  String? text;
}

/// Adds [annotations] and writes [outPath].
class PdfAnnotateRequestMsg {
  PdfAnnotateRequestMsg({required this.jobId, required this.input, required this.annotations, required this.outPath});

  String jobId;
  PdfToolInputMsg input;
  List<PdfAnnotationMsg> annotations;
  String outPath;
}

/// One visual signature placed on a page.
class PdfSignatureStampMsg {
  PdfSignatureStampMsg({required this.pageIndex, required this.rect, required this.imagePath, required this.rotationDegrees});

  int pageIndex;

  /// Where the signature goes.
  PdfRectMsg rect;

  /// The signature image (PNG with transparency) in the signatures store.
  String imagePath;

  /// Rotation around the rect's centre, degrees clockwise.
  double rotationDegrees;
}

/// Burns [stamps] into the page content and writes [outPath] (a visual signature, not a
/// certificate).
class PdfSignRequestMsg {
  PdfSignRequestMsg({required this.jobId, required this.input, required this.stamps, required this.outPath});

  String jobId;
  PdfToolInputMsg input;
  List<PdfSignatureStampMsg> stamps;
  String outPath;
}

/// Writes a smaller copy with [preset].
class PdfCompressRequestMsg {
  PdfCompressRequestMsg({required this.jobId, required this.input, required this.preset, required this.outPath});

  String jobId;
  PdfToolInputMsg input;
  PdfCompressPresetMsg preset;
  String outPath;
}

/// What a tool wrote.
class PdfToolResultMsg {
  PdfToolResultMsg({required this.outPaths, required this.pageCounts, required this.sizesBytes});

  /// The files written, in request order.
  List<String> outPaths;

  /// Pages of each file.
  List<int> pageCounts;

  /// Size of each file in bytes.
  List<int> sizesBytes;
}

/// Progress of a tool job.
class PdfToolProgressMsg {
  PdfToolProgressMsg({required this.jobId, required this.tool, required this.fraction, required this.pagesDone, required this.pagesTotal});

  String jobId;
  PdfToolKindMsg tool;

  /// 0…1.
  double fraction;
  int pagesDone;
  int pagesTotal;
}

/// One event of the multiplexed stream.
class PdfEventMsg {
  PdfEventMsg({required this.kind, this.viewState, this.toolProgress});

  PdfEventKindMsg kind;
  PdfViewStateMsg? viewState;
  PdfToolProgressMsg? toolProgress;
}

// ---------------------------------------------------------------------------------------------
// APIs
// ---------------------------------------------------------------------------------------------

/// Documents: open read-only, unlock, outline, close (HOM-24 Apple, HOM-25 Android).
@HostApi()
abstract class PdfDocumentHostApi {
  /// What this device offers.
  PdfCapabilitiesMsg capabilities();

  /// A cheap open-and-close of [path] (the viewer router's probe); never throws for a damaged
  /// file (`canOpen` false), only for a missing one (`notFound`).
  @asyncCallback
  PdfProbeMsg probe(String path);

  /// Opens [request] read-only. An encrypted file with no or a wrong password opens `locked`.
  @asyncCallback
  PdfDocumentInfoMsg open(PdfOpenRequestMsg request);

  /// Unlocks a locked document; null when [password] is wrong.
  @asyncCallback
  PdfDocumentInfoMsg? unlock(int handle, String password);

  /// The outline, flattened depth-first (empty when there is none).
  @asyncCallback
  List<PdfOutlineItemMsg> outline(int handle);

  /// Releases [handle] (views showing it keep their own reference).
  void close(int handle);
}

/// Views: navigation, zoom, search, selection, page thumbnails (HOM-24 Apple, HOM-25 Android).
@HostApi()
abstract class PdfViewHostApi {
  PdfViewStateMsg state(int viewId);

  void goToPage(int viewId, int pageIndex);

  /// Sets the zoom, clamped to the view's range.
  void setScale(int viewId, double scale);

  /// Fits the page width to the view and turns automatic scaling back on.
  void zoomToFit(int viewId);

  void setDisplayMode(int viewId, PdfDisplayModeMsg mode);

  /// Finds [options] in the view's document off the main thread; a newer search or
  /// `cancelSearch` cancels this one (`cancelled`).
  @asyncCallback
  PdfSearchResultMsg search(int viewId, PdfSearchOptionsMsg options);

  void cancelSearch(int viewId);

  /// Scrolls to [hit] and highlights it.
  void showSearchHit(int viewId, PdfSearchHitMsg hit);

  /// Removes search highlights.
  void clearSearch(int viewId);

  /// The selected text (never logged), or null.
  String? selectedText(int viewId);

  /// Copies the selection to the clipboard; false when nothing is selected or the file forbids it.
  bool copySelection(int viewId);

  void clearSelection(int viewId);

  /// A page image fitted into the request's box (thumbnail strip and grid).
  @asyncCallback
  PdfImageMsg pageThumbnail(PdfThumbnailRequestMsg request);

  /// Android: creates a texture-backed view of an open document (Apple: `notSupportedOnDevice`).
  @asyncCallback
  PdfTextureViewMsg createTextureView(PdfTextureViewRequestMsg request);

  /// Android: moves or resizes a texture view's viewport.
  void setTextureViewport(int viewId, PdfViewportMsg viewport);

  /// Android: releases a texture view and its texture.
  void disposeTextureView(int viewId);
}

/// Text extraction for the search index (HOM-24 Apple, HOM-25 Android where available).
@HostApi()
abstract class PdfTextHostApi {
  @asyncCallback
  PdfTextResultMsg extractText(PdfTextRequestMsg request);
}

/// Page tools that write new files with progress and cancel (stubs until their tickets land).
@HostApi()
abstract class PdfToolsHostApi {
  @asyncCallback
  PdfToolResultMsg merge(PdfMergeRequestMsg request);

  @asyncCallback
  PdfToolResultMsg split(PdfSplitRequestMsg request);

  @asyncCallback
  PdfToolResultMsg reorder(PdfReorderRequestMsg request);

  @asyncCallback
  PdfToolResultMsg rotate(PdfRotateRequestMsg request);

  @asyncCallback
  PdfToolResultMsg deletePages(PdfDeletePagesRequestMsg request);

  @asyncCallback
  PdfToolResultMsg annotate(PdfAnnotateRequestMsg request);

  @asyncCallback
  PdfToolResultMsg sign(PdfSignRequestMsg request);

  @asyncCallback
  PdfToolResultMsg compress(PdfCompressRequestMsg request);

  /// Cancels a running job; it then fails with `cancelled` and leaves no partial file.
  void cancel(String jobId);
}

/// The multiplexed PDF event stream.
@EventChannelApi()
abstract class PdfEventsApi {
  PdfEventMsg pdfEvents();
}

// =============================================================================================
// HOM-28 amendment [INTEGRATION] (2026-10-30, lead-approved): page organiser in one pass.
//
// The organiser (reorder + rotate + delete + extract selected pages) saves in one native write
// instead of chaining three tools through temporary files. Its own host API, so the other S4
// amendments (HOM-31 compress) merge without touching this block. Implemented by
// Tools/PdfPageTools on Apple (HOM-28) and PdfBox-Android (HOM-28A). Progress events of an
// organise job carry `tool: reorder`; the Dart side filters by job id only. Advertised through
// `PdfCapabilitiesMsg.tools` containing reorder, rotate and deletePages (all three).
// =============================================================================================

/// One page of an organised document: source page [sourcePage] turned by [rotation] more degrees.
class PdfPagePlanMsg {
  PdfPagePlanMsg({required this.sourcePage, required this.rotation});

  /// The 0-based page of the input; each page appears at most once.
  int sourcePage;

  /// Degrees clockwise added to the page's own rotation (a multiple of 90; may be negative).
  int rotation;
}

/// Writes the input's pages in [pages] order (pages not listed are left out) into [outPath].
class PdfOrganiseRequestMsg {
  PdfOrganiseRequestMsg({required this.jobId, required this.input, required this.pages, required this.outPath});

  /// Caller-chosen id for progress events and `PdfToolsHostApi.cancel`.
  String jobId;
  PdfToolInputMsg input;

  /// At least one page; no source page twice.
  List<PdfPagePlanMsg> pages;
  String outPath;
}

/// The page organiser (HOM-28 Apple, HOM-28A Android). Jobs share `PdfToolsHostApi.cancel`.
@HostApi()
abstract class PdfOrganiseHostApi {
  @asyncCallback
  PdfToolResultMsg organise(PdfOrganiseRequestMsg request);
}
// ---- end of the HOM-28 amendment ------------------------------------------------------------

// ---------------------------------------------------------------------------------------------
// Compress estimates (HOM-31; [INTEGRATION] amendment, an additive block of its own)
//
// The compress job itself is `PdfToolsHostApi.compress` above. This API only tells the sheet
// what each preset would give before the user runs one. Android (HOM-31A) may leave it
// unregistered: the Dart wrapper maps the `channel-error` to "no estimate" and the sheet shows
// sizes once a preset has run.
// ---------------------------------------------------------------------------------------------

/// The sizes each compression preset would give for one file.
class PdfCompressEstimateMsg {
  PdfCompressEstimateMsg({
    required this.sourceBytes,
    required this.highBytes,
    required this.mediumBytes,
    required this.smallBytes,
    required this.sampled,
  });

  /// Size of the file now.
  int sourceBytes;

  /// Expected size with [PdfCompressPresetMsg.high].
  int highBytes;

  /// Expected size with [PdfCompressPresetMsg.medium].
  int mediumBytes;

  /// Expected size with [PdfCompressPresetMsg.small].
  int smallBytes;

  /// True when the sizes are extrapolated from a sample of pages (long files); false when every
  /// page was compressed in memory (the sizes are then what a run writes).
  bool sampled;
}

/// Estimates for the compress sheet (HOM-31 Apple, HOM-31A Android).
@HostApi()
abstract class PdfCompressHostApi {
  /// What each preset would give for [input], off the main thread; nothing is written.
  @asyncCallback
  PdfCompressEstimateMsg estimate(PdfToolInputMsg input);
}
