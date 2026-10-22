// OWNER: HOM-18
//
// Rows and tiles of the filter tabs and the Folders tab (HOM plan §5.2, §8.1; ARCH v1.2 §1.4):
// a file row (type icon or thumbnail, name, size, date, page count where known) for Danaview
// entries and for linked-folder documents, and the video grid tile of the Videos tab (duration
// pill, resolution and frame-rate labels until HOM-13's badges land). A Danaview entry's menu
// offers Open, Rename, Move and Delete; a linked-folder file offers Open only: actions that change
// a file exist only inside Danaview folders (§8.1). Kit components only, ≥ 44 px targets,
// semantics labels, ellipsised text so nothing overflows at 280 px and text scale 1.35.

import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../files/library_store_providers.dart';
import '../library_format.dart';
import '../library_widgets.dart';
import '../organise/organise_widgets.dart';
import '../thumbs/library_thumbnail.dart';
import '../thumbs/thumb_key.dart';
import 'filter_providers.dart';

/// Opens a Danaview entry in its viewer (the router, HOM-23; wired by the app root).
typedef LibraryEntryOpen = void Function(FileEntry entry);

/// Opens a linked-folder document in its viewer.
typedef LinkedDocumentOpen = void Function(DocumentItem document);

/// The Danaview-entry actions a row's menu can call (null hides the item).
@immutable
class LibraryEntryActions {
  /// Actions; every one optional.
  const LibraryEntryActions({this.onOpen, this.onRename, this.onMove, this.onDelete});

  /// None: the row only shows.
  static const LibraryEntryActions none = LibraryEntryActions();

  /// Open in a viewer.
  final LibraryEntryOpen? onOpen;

  /// Rename (Danaview folders only).
  final ValueChanged<FileEntry>? onRename;

  /// Move to another Danaview folder.
  final ValueChanged<FileEntry>? onMove;

  /// Move to Recently deleted.
  final ValueChanged<FileEntry>? onDelete;
}

const List<String> _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// A short date: `22 Oct 2026`.
String formatLibraryDate(DateTime date) {
  final local = date.toLocal();
  return '${local.day} ${_months[local.month - 1]} ${local.year}';
}

/// A file size: `512 B`, `1.4 KB`, `12 MB`, `2.1 GB`.
String formatFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final text = value >= 10 ? value.round().toString() : value.toStringAsFixed(1);
  return '$text ${units[unit]}';
}

/// The meta line of a file row: size · date · pages.
String libraryFileSubtitle({required int? sizeBytes, required DateTime date, int? pageCount}) => [
      if (sizeBytes != null) formatFileSize(sizeBytes),
      formatLibraryDate(date),
      if (pageCount != null) formatCount(pageCount, 'page'),
    ].join(' · ');

/// The accent of a kind's icon.
Color libraryKindColor(FileKind kind) => switch (kind) {
      FileKind.video => DanaviewColors.primaryLight,
      FileKind.photo => DanaviewColors.cyan,
      FileKind.document => DanaviewColors.purple,
      FileKind.audio => DanaviewColors.primaryLight,
      FileKind.other => DanaviewColors.textSecondary,
    };

/// The icon of a document sub-kind.
IconData documentKindIcon(DocumentKind kind) => switch (kind) {
      DocumentKind.pdf => Icons.picture_as_pdf_outlined,
      DocumentKind.word => Icons.article_outlined,
      DocumentKind.excel => Icons.table_chart_outlined,
      DocumentKind.powerpoint => Icons.slideshow_outlined,
      DocumentKind.text => Icons.notes_rounded,
      DocumentKind.other => Icons.insert_drive_file_outlined,
    };

/// The leading tile of an entry: a thumbnail for photos, videos and PDFs (first page), else the
/// type icon. The thumbnail falls back to the icon until (or unless) one exists.
class LibraryEntryLeading extends ConsumerWidget {
  /// The tile of [entry].
  const LibraryEntryLeading({super.key, required this.entry, this.size = 40});

  /// The entry.
  final FileEntry entry;

  /// Side length.
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final doc = entry.docKind;
    final icon = doc != null ? documentKindIcon(doc) : organiseKindIcon(entry.kind);
    final tile = DanaviewTileIcon(icon, color: libraryKindColor(entry.kind), size: size);
    final store = ref.watch(libraryStoreProvider);
    final thumbable = entry.kind == FileKind.photo || entry.kind == FileKind.video || entry.docKind == DocumentKind.pdf;
    if (store == null || !thumbable) return tile;
    return SizedBox.square(
      dimension: size,
      child: ClipRRect(
        borderRadius: DanaviewRadius.smAll,
        child: LibraryThumbnail(
          itemId: entry.id.value,
          source: store.paths.entryFile(entry.id, entry.displayName),
          modifiedAt: entry.modifiedAt,
          kind: entry.kind == FileKind.document ? ThumbSourceKind.document : ThumbSourceKind.media,
          placeholder: tile,
        ),
      ),
    );
  }
}

/// One Danaview entry: leading tile, name, size, date, page count, and its menu.
class LibraryEntryRow extends ConsumerWidget {
  /// The row of [entry]; [actions] decide the menu.
  const LibraryEntryRow({super.key, required this.entry, this.actions = LibraryEntryActions.none});

  /// The entry.
  final FileEntry entry;

  /// The menu's actions.
  final LibraryEntryActions actions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final meta = entry.kind == FileKind.document ? ref.watch(libraryEntryMetaProvider(entry.id)) : null;
    final subtitle = libraryFileSubtitle(sizeBytes: entry.sizeBytes, date: entry.addedAt, pageCount: meta?.pageCount);
    final menu = <DanaviewMenuEntry>[
      if (actions.onOpen case final open?) DanaviewMenuItem(label: 'Open', icon: Icons.open_in_new_rounded, onTap: () => open(entry)),
      if (actions.onRename case final rename?) DanaviewMenuItem(label: 'Rename…', icon: Icons.edit_rounded, onTap: () => rename(entry)),
      if (actions.onMove case final move?)
        DanaviewMenuItem(label: 'Move to…', glyph: DanaviewGlyphKind.folderOpen, onTap: () => move(entry)),
      if (actions.onDelete case final delete?) ...[
        const DanaviewMenuDivider(),
        DanaviewMenuItem(label: 'Delete', icon: Icons.delete_outline_rounded, destructive: true, onTap: () => delete(entry)),
      ],
    ];
    return KeyedSubtree(
      key: ValueKey('library-entry-${entry.id.value}'),
      child: DanaviewLibraryRow(
        leading: LibraryEntryLeading(entry: entry),
        title: entry.displayName,
        subtitle: subtitle,
        semanticLabel: '${organiseKindLabel(entry.kind)} ${entry.displayName}, $subtitle',
        onTap: actions.onOpen == null ? null : () => actions.onOpen!(entry),
        trailing: menu.isEmpty ? null : DanaviewMenuIconTrigger(icon: Icons.more_horiz_rounded, tooltip: 'More', entries: menu),
      ),
    );
  }
}

/// One document in a linked folder: read-only (Open only, HOM plan §8.1).
class LinkedDocumentRow extends StatelessWidget {
  /// The row of [document].
  const LinkedDocumentRow({super.key, required this.document, this.onOpen});

  /// The document.
  final DocumentItem document;

  /// Opens it.
  final LinkedDocumentOpen? onOpen;

  @override
  Widget build(BuildContext context) {
    final subtitle = libraryFileSubtitle(sizeBytes: document.sizeBytes, date: document.modifiedAt, pageCount: document.pageCount);
    return KeyedSubtree(
      key: ValueKey('linked-document-${document.id.value}'),
      child: DanaviewLibraryRow(
        leading: DanaviewTileIcon(documentKindIcon(document.docKind), color: DanaviewColors.purple, size: 40),
        title: document.name,
        subtitle: subtitle,
        semanticLabel: 'Document ${document.name} in a linked folder, $subtitle',
        onTap: onOpen == null ? null : () => onOpen!(document),
        trailing: onOpen == null
            ? null
            : DanaviewMenuIconTrigger(
                icon: Icons.more_horiz_rounded,
                tooltip: 'More',
                entries: [DanaviewMenuItem(label: 'Open', icon: Icons.open_in_new_rounded, onTap: () => onOpen!(document))],
              ),
      ),
    );
  }
}

/// The resolution label of a video: `4K`, `1080p`, `720p` or null.
String? videoResolutionLabel(int? width, int? height) {
  if (width == null || height == null) return null;
  final short = width < height ? width : height;
  final long = width < height ? height : width;
  if (long >= 3840 || short >= 2160) return '4K';
  if (short >= 1080) return '1080p';
  if (short >= 720) return '720p';
  return null;
}

/// One video of the Videos tab's grid: thumbnail, duration pill, resolution and frame-rate labels.
class LibraryVideoTile extends ConsumerWidget {
  /// The tile of [entry].
  const LibraryVideoTile({super.key, required this.entry, this.onOpen});

  /// The video entry.
  final FileEntry entry;

  /// Opens it.
  final LibraryEntryOpen? onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final meta = ref.watch(libraryEntryMetaProvider(entry.id));
    final duration = meta?.duration;
    final resolution = videoResolutionLabel(meta?.width, meta?.height);
    final fps = meta?.fps;
    final labels = [
      if (resolution != null) resolution,
      if (fps != null && fps >= 50) '${fps.round()} fps',
      if (meta != null && meta.flags & EntryMeta.flagHdr != 0) 'HDR',
    ];
    final spoken = [
      'Video ${entry.displayName}',
      if (duration != null) formatClock(duration),
      ...labels,
    ].join(', ');
    return KeyedSubtree(
      key: ValueKey('library-video-${entry.id.value}'),
      child: DanaviewPressable(
        onTap: onOpen == null ? null : () => onOpen!(entry),
        borderRadius: DanaviewRadius.mdAll,
        semanticLabel: spoken,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: DanaviewRadius.mdAll,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    LibraryEntryLeading(entry: entry, size: 200),
                    if (labels.isNotEmpty)
                      PositionedDirectional(
                        top: 6,
                        start: 6,
                        end: 6,
                        child: Wrap(
                          spacing: 4,
                          runSpacing: 4,
                          children: [for (final l in labels) _Pill(l)],
                        ),
                      ),
                    if (duration != null)
                      PositionedDirectional(bottom: 6, end: 6, child: _Pill(formatClock(duration))),
                  ],
                ),
              ),
            ),
            const SizedBox(height: DanaviewSpacing.xs),
            Text(
              entry.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: DanaviewTextStyles.caption.copyWith(color: DanaviewColors.textPrimary),
            ),
          ],
        ),
      ),
    );
  }
}

/// A label on a dark scrim (light text on near-black: contrast well above 4.5:1 over any frame).
class _Pill extends StatelessWidget {
  const _Pill(this.label);

  final String label;

  static const Color _scrim = Color(0xD9000000);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: _scrim, borderRadius: DanaviewRadius.smAll),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: DanaviewTextStyles.micro.copyWith(color: DanaviewColors.foregroundOn(_scrim), fontWeight: FontWeight.w600),
      ),
    );
  }
}
