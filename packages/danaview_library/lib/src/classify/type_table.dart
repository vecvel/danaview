// OWNER: HOM-16
//
// The type table (ARCH v1.2 §5.1, HOM plan §8.1, V2-114): the single table the classifier reads.
// One row per Home kind and Documents sub-filter. The document rows carry exactly the UTTypes,
// MIME types and extensions of HOM plan §8.1, plus the UTType and MIME spellings of the same
// formats so Apple (UTType) and Android (MIME) inputs land on the row their extension would.
// The media rows (video, photo, audio) feed the Videos and Photos filters. Anything no row matches
// is a document under `Other` (HOM plan §8.1: "anything else"). To add a kind (1.3.0 `savedCode`),
// append a FileKind value and a row here.
//
// Every value is lower case; extensions have no dot. A value appears in at most one row (tested).

import 'package:meta/meta.dart';

import '../model/document_item.dart';
import '../model/file_kind.dart';

/// One row of the type table: the UTTypes, MIME types and extensions that mean [kind] (and, for
/// documents, [docKind]).
@immutable
final class TypeRow {
  /// A row. [mimePrefixes] are wildcard families such as `text/` (written `text/*` in the plan).
  const TypeRow({
    required this.id,
    required this.kind,
    this.docKind,
    this.utis = const {},
    this.mimes = const {},
    this.mimePrefixes = const {},
    this.extensions = const {},
  });

  /// A stable name for the row (tests and diagnostics).
  final String id;

  /// The Home kind of matching files.
  final FileKind kind;

  /// The Documents sub-filter of matching files; null unless [kind] is [FileKind.document].
  final DocumentKind? docKind;

  /// Exact UTType identifiers (Apple).
  final Set<String> utis;

  /// Exact MIME types (Android, desktop).
  final Set<String> mimes;

  /// MIME families matched by prefix (`text/` for `text/*`); an exact [mimes] match in any row wins
  /// over a prefix.
  final Set<String> mimePrefixes;

  /// File extensions without the dot.
  final Set<String> extensions;

  @override
  String toString() => 'TypeRow($id)';
}

/// UTTypes that say nothing about the content; the classifier defers to the next input (ARCH §5.1).
/// Dynamic UTTypes (`dyn.…`) are generic too.
const Set<String> genericUtis = {
  'public.data',
  'public.item',
  'public.content',
  'public.composite-content',
  'public.file-url',
};

/// MIME types that say nothing about the content; the classifier defers to the extension.
const Set<String> genericMimes = {
  'application/octet-stream',
  'binary/octet-stream',
  'application/binary',
  'application/unknown',
  'application/x-unknown',
  'application/x-download',
  'application/force-download',
  'unknown/unknown',
  '*/*',
};

/// The type table, in documentation order: the media rows, then the six Documents sub-filters of
/// HOM plan §8.1 (`Other` holds the archive and e-book types; unknown types fall back to it too).
const List<TypeRow> typeTable = [
  TypeRow(
    id: 'video',
    kind: FileKind.video,
    utis: {
      'public.movie',
      'public.video',
      'public.mpeg-4',
      'com.apple.quicktime-movie',
      'com.apple.m4v-video',
      'public.avi',
      'public.mpeg',
      'public.mpeg-2-video',
      'public.mpeg-2-transport-stream',
      'public.3gpp',
      'public.3gpp2',
      'org.matroska.mkv',
      'org.webmproject.webm',
      'com.microsoft.windows-media-wmv',
    },
    mimes: {'application/x-matroska', 'application/vnd.rn-realmedia'},
    mimePrefixes: {'video/'},
    extensions: {
      'mp4', 'm4v', 'mov', 'mkv', 'webm', 'avi', 'ts', 'm2ts', 'mts', 'flv', 'wmv', 'ogv', '3gp', '3g2', 'mpg', //
      'mpeg', 'rm', 'rmvb',
    },
  ),
  TypeRow(
    id: 'photo',
    kind: FileKind.photo,
    utis: {
      'public.image',
      'public.jpeg',
      'public.png',
      'public.heic',
      'public.heics',
      'public.heif',
      'public.avif',
      'com.compuserve.gif',
      'public.tiff',
      'org.webmproject.webp',
      'com.microsoft.bmp',
      'public.camera-raw-image',
      'com.adobe.raw-image',
      'com.canon.cr2-raw-image',
      'com.canon.cr3-raw-image',
      'com.nikon.raw-image',
      'com.sony.arw-raw-image',
      'com.fuji.raw-image',
      'com.olympus.raw-image',
      'com.panasonic.rw2-raw-image',
    },
    mimes: {'application/x-dng'},
    mimePrefixes: {'image/'},
    extensions: {
      'jpg', 'jpeg', 'png', 'heic', 'heif', 'avif', 'gif', 'tif', 'tiff', 'webp', 'bmp', 'dng', 'cr2', 'cr3', //
      'nef', 'arw', 'raf', 'orf', 'rw2',
    },
  ),
  TypeRow(
    id: 'audio',
    kind: FileKind.audio,
    utis: {
      'public.audio',
      'public.mp3',
      'public.mpeg-4-audio',
      'com.apple.m4a-audio',
      'public.aiff-audio',
      'public.aifc-audio',
      'com.microsoft.waveform-audio',
      'org.xiph.flac',
      'org.xiph.ogg-audio',
      'com.microsoft.windows-media-wma',
    },
    mimes: {'application/ogg'},
    mimePrefixes: {'audio/'},
    extensions: {'mp3', 'm4a', 'aac', 'wav', 'aif', 'aiff', 'flac', 'ogg', 'oga', 'opus', 'wma'},
  ),
  TypeRow(
    id: 'pdf',
    kind: FileKind.document,
    docKind: DocumentKind.pdf,
    utis: {'com.adobe.pdf'},
    mimes: {'application/pdf', 'application/x-pdf'},
    extensions: {'pdf'},
  ),
  TypeRow(
    id: 'word',
    kind: FileKind.document,
    docKind: DocumentKind.word,
    utis: {
      'com.microsoft.word.doc',
      'org.openxmlformats.wordprocessingml.document',
      'org.oasis-open.opendocument.text',
      'public.rtf',
      'com.apple.iwork.pages.pages',
      'com.apple.iwork.pages.sffpages',
    },
    mimes: {
      'application/msword',
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'application/vnd.oasis.opendocument.text',
      'application/rtf',
      'text/rtf',
      'application/vnd.apple.pages',
      'application/x-iwork-pages-sffpages',
    },
    extensions: {'doc', 'docx', 'odt', 'rtf', 'pages'},
  ),
  TypeRow(
    id: 'excel',
    kind: FileKind.document,
    docKind: DocumentKind.excel,
    utis: {
      'com.microsoft.excel.xls',
      'org.openxmlformats.spreadsheetml.sheet',
      'org.oasis-open.opendocument.spreadsheet',
      'com.apple.iwork.numbers.numbers',
      'com.apple.iwork.numbers.sffnumbers',
    },
    mimes: {
      'application/vnd.ms-excel',
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'application/vnd.oasis.opendocument.spreadsheet',
      'application/vnd.apple.numbers',
      'application/x-iwork-numbers-sffnumbers',
    },
    extensions: {'xls', 'xlsx', 'ods', 'numbers'},
  ),
  TypeRow(
    id: 'powerpoint',
    kind: FileKind.document,
    docKind: DocumentKind.powerpoint,
    utis: {
      'com.microsoft.powerpoint.ppt',
      'org.openxmlformats.presentationml.presentation',
      'org.oasis-open.opendocument.presentation',
      'com.apple.iwork.keynote.key',
      'com.apple.iwork.keynote.sffkey',
    },
    mimes: {
      'application/vnd.ms-powerpoint',
      'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      'application/vnd.oasis.opendocument.presentation',
      'application/vnd.apple.keynote',
      'application/x-iwork-keynote-sffkey',
    },
    extensions: {'ppt', 'pptx', 'odp', 'key'},
  ),
  TypeRow(
    id: 'text',
    kind: FileKind.document,
    docKind: DocumentKind.text,
    utis: {
      'public.plain-text',
      'public.utf8-plain-text',
      'public.utf16-plain-text',
      'public.utf16-external-plain-text',
      'public.comma-separated-values-text',
      'public.tab-separated-values-text',
      'public.json',
      'net.daringfireball.markdown',
      'public.log',
    },
    mimes: {'application/json', 'application/csv'},
    mimePrefixes: {'text/'},
    extensions: {'txt', 'md', 'markdown', 'csv', 'tsv', 'json', 'log'},
  ),
  TypeRow(
    id: 'other',
    kind: FileKind.document,
    docKind: DocumentKind.other,
    utis: {
      'public.archive',
      'public.zip-archive',
      'org.gnu.gnu-zip-archive',
      'public.tar-archive',
      'org.7-zip.7-zip-archive',
      'com.rarlab.rar-archive',
      'org.idpf.epub-container',
      'com.amazon.mobi-ebook',
      'public.svg-image',
    },
    mimes: {
      'application/zip',
      'application/gzip',
      'application/x-gzip',
      'application/x-tar',
      'application/x-7z-compressed',
      'application/vnd.rar',
      'application/x-rar-compressed',
      'application/epub+zip',
      'application/x-mobipocket-ebook',
      'application/vnd.amazon.ebook',
      'image/svg+xml',
    },
    extensions: {'zip', 'gz', 'tgz', 'tar', '7z', 'rar', 'epub', 'mobi', 'azw', 'azw3', 'svg'},
  ),
];

/// The row anything unmatched falls back to (Documents › `Other`).
final TypeRow fallbackRow = typeTable.singleWhere((r) => r.id == 'other');
