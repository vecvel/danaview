// OWNER: HOM-23
//
// The viewer host (HOM plan §8.4): resolves the viewer of a file with the router and its probes,
// records the open in Recents (HOM plan §8.1: "the last 50 files opened in any viewer"; Danaview
// folder entries only, through `LibraryOrganiser.markOpened`), then shows the viewer. Native and
// Home viewers (PDF: HOM-24/HOM-25, Quick Look: HOM-26, photo viewer, player) are registered as
// builders by whoever opens the host, so this package never imports them; a registered viewer
// that fails after opening calls `ViewerContext.unavailable` and the host falls back to the next
// candidate, ending at the file card.

import 'dart:async';

import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../card/file_card.dart';
import '../text/csv_viewer.dart';
import '../text/text_viewer.dart';
import '../text/viewer_parts.dart';
import 'viewer_file.dart';
import 'viewer_router.dart';

/// What a registered viewer gets from the host.
@immutable
final class ViewerContext {
  /// A context for [file].
  const ViewerContext({required this.file, required this.unavailable, this.fileOut, this.onClose});

  /// The file to show.
  final ViewerFile file;

  /// Getting files out, for the viewer's own "Open in another app" and Share.
  final FileOutPort? fileOut;

  /// Closes the viewer.
  final VoidCallback? onClose;

  /// Tells the host this viewer can't show the file after all (password PDF on older Android,
  /// Quick Look preview failed); the host moves on to the next candidate.
  final VoidCallback unavailable;
}

/// Builds a registered viewer.
typedef ViewerBuilder = Widget Function(BuildContext context, ViewerContext viewer);

/// Records that a Danaview folder entry was opened (`LibraryOrganiser.markOpened`).
typedef MarkOpened = Future<void> Function(EntryId id);

/// Opens [file] in the viewer the router picks for [platform].
class DocumentViewer extends StatefulWidget {
  /// A host for [file]. [platform] defaults to the ambient [TargetPlatform].
  const DocumentViewer({
    super.key,
    required this.file,
    this.platform,
    this.viewers = const {},
    this.probes = const AcceptAllProbes(),
    this.fileOut,
    this.onOpened,
    this.onClose,
    this.textLoader,
    this.onResolved,
  });

  /// The file.
  final ViewerFile file;

  /// The ARCH §3 column; null uses [defaultTargetPlatform].
  final ViewerPlatform? platform;

  /// Builders of the viewers this package doesn't have (photo, player, pdf, quickLook). Entries
  /// for built-in kinds are ignored.
  final Map<ViewerKind, ViewerBuilder> viewers;

  /// Capability probes for the registered viewers.
  final ViewerProbes probes;

  /// Getting files out (file card, "Open in another app").
  final FileOutPort? fileOut;

  /// Recents: called once per host with the entry id of a Danaview folder file.
  final MarkOpened? onOpened;

  /// Closes the viewer.
  final VoidCallback? onClose;

  /// Loads text for the in-app viewers (tests).
  final TextDocumentLoader? textLoader;

  /// Called with each viewer the host shows (tests, analytics-free diagnostics).
  final ValueChanged<ViewerKind>? onResolved;

  @override
  State<DocumentViewer> createState() => _DocumentViewerState();
}

class _DocumentViewerState extends State<DocumentViewer> {
  ViewerKind? _viewer;
  final Set<ViewerKind> _skip = {};
  int _generation = 0;
  bool _recorded = false;

  ViewerRouter get _router => ViewerRouter(widget.platform ?? ViewerPlatform.of(defaultTargetPlatform));

  @override
  void initState() {
    super.initState();
    unawaited(_resolve());
    _record();
  }

  @override
  void didUpdateWidget(DocumentViewer old) {
    super.didUpdateWidget(old);
    if (old.file != widget.file || old.platform != widget.platform) {
      _skip.clear();
      _viewer = null;
      _recorded = false;
      unawaited(_resolve());
      _record();
    }
  }

  void _record() {
    final id = widget.file.entryId;
    final mark = widget.onOpened;
    if (_recorded || id == null || mark == null) return;
    _recorded = true;
    // Recents never block or break viewing (a trashed or missing entry is simply not recorded).
    unawaited(mark(id).catchError((Object _) {}));
  }

  Future<void> _resolve() async {
    final generation = ++_generation;
    final viewer = await _router.resolve(
      widget.file,
      registered: {
        for (final k in widget.viewers.keys)
          if (!k.isBuiltIn) k,
      },
      probes: widget.probes,
      skip: _skip,
    );
    if (!mounted || generation != _generation) return;
    setState(() => _viewer = viewer);
    widget.onResolved?.call(viewer);
  }

  void _unavailable(ViewerKind viewer) {
    if (!mounted || _viewer != viewer || viewer == ViewerKind.fileCard) return;
    _skip.add(viewer);
    setState(() => _viewer = null);
    unawaited(_resolve());
  }

  @override
  Widget build(BuildContext context) {
    final viewer = _viewer;
    final file = widget.file;
    if (viewer == null) return const ColoredBox(color: DanaviewColors.background, child: DocumentLoading());
    switch (viewer) {
      case ViewerKind.text:
        return TextViewer(
          key: const ValueKey(ViewerKind.text),
          file: file,
          loader: widget.textLoader,
          fileOut: widget.fileOut,
          onClose: widget.onClose,
          onUnavailable: () => _unavailable(ViewerKind.text),
        );
      case ViewerKind.csv:
        return CsvViewer(
          key: const ValueKey(ViewerKind.csv),
          file: file,
          loader: widget.textLoader,
          fileOut: widget.fileOut,
          onClose: widget.onClose,
          onUnavailable: () => _unavailable(ViewerKind.csv),
        );
      case ViewerKind.fileCard:
        return FileCard(
          key: const ValueKey(ViewerKind.fileCard),
          file: file,
          fileOut: widget.fileOut,
          onClose: widget.onClose,
          message: _skip.isEmpty ? null : 'This file can\'t be shown here.',
        );
      case ViewerKind.photo:
      case ViewerKind.player:
      case ViewerKind.pdf:
      case ViewerKind.quickLook:
        final build = widget.viewers[viewer]!;
        return KeyedSubtree(
          key: ValueKey(viewer),
          child: build(
            context,
            ViewerContext(file: file, fileOut: widget.fileOut, onClose: widget.onClose, unavailable: () => _unavailable(viewer)),
          ),
        );
    }
  }
}
