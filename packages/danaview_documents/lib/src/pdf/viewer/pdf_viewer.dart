// OWNER: HOM-24
//
// The PDF viewer screen (HOM plan §8.4, V2-120; ARCH §10.1 "PDF open ≤ 500 ms"): opens the file
// read-only through danaview_pdf (rule 27), asks for the password of an encrypted file in a kit
// sheet, then shows the native view (PDFKit on Apple, the PdfRenderer texture on Android) under the
// documents top bar with search (result list), page thumbnails (wrapping grid), the outline, copy
// of the selected text, "Compress…" (HOM-31, when the app passes [PdfViewer.onCompress]) and
// "Open in another app". Panels dock on the right on wide windows and
// below the pages on narrow ones. A file the platform can't open calls [PdfViewer.onUnavailable]
// so the router falls back (Quick Look, then the file card). Nothing here logs a name, a path, a
// query, a password or document text (rule 30).

import 'dart:async';

import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_pdf/danaview_pdf.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/widgets.dart';
// Icons only (rule 31 bans Material chrome widgets, not the icon font).
import 'package:flutter/material.dart' show Icons;

import '../../card/document_format.dart';
import '../../card/document_out.dart';
import '../../card/viewer_bar.dart';
import '../../router/viewer_file.dart';
import '../../text/viewer_parts.dart';
import 'pdf_password_sheet.dart';
import 'pdf_viewer_panels.dart';

/// Builds the native view of an open document (tests replace the platform view).
typedef PdfViewBuilder = Widget Function(BuildContext context, PdfDocumentInfo document, ValueChanged<PdfViewController> onCreated);

/// Shows the password sheet (tests replace it).
typedef PdfPasswordPrompt = Future<bool> Function(BuildContext context, PdfPasswordAttempt tryPassword);

/// Opens the compress sheet for the open file (HOM-31); [password] is the one it was unlocked
/// with, if any (never logged).
typedef PdfCompressLauncher = Future<void> Function(BuildContext context, ViewerFile file, {String? password});

enum _Panel { none, search, pages, outline }

/// Windows at least this wide dock panels on the right.
const double _dockWidth = 720;

/// The PDF viewer of [file].
class PdfViewer extends StatefulWidget {
  /// A viewer over [documents].
  const PdfViewer({
    super.key,
    required this.file,
    required this.documents,
    this.capabilities,
    this.fileOut,
    this.onClose,
    this.onUnavailable,
    this.viewBuilder,
    this.passwordPrompt,
    this.onCompress,
  });

  /// The file.
  final ViewerFile file;

  /// Read-only documents (PlatformPdfDocuments in the app).
  final PdfDocuments documents;

  /// What the platform offers; null asks [documents].
  final PdfCapabilities? capabilities;

  /// Getting files out ("Open in another app").
  final FileOutPort? fileOut;

  /// Closes the viewer.
  final VoidCallback? onClose;

  /// The file can't be shown here (damaged, unsupported, no viewer): the router falls back.
  final VoidCallback? onUnavailable;

  /// The native view (default [PdfView]).
  final PdfViewBuilder? viewBuilder;

  /// The password prompt (default [showPdfPasswordSheet]).
  final PdfPasswordPrompt? passwordPrompt;

  /// Opens the compress sheet (HOM-31); null hides "Compress…" in the menu.
  final PdfCompressLauncher? onCompress;

  @override
  State<PdfViewer> createState() => _PdfViewerState();
}

class _PdfViewerState extends State<PdfViewer> {
  PdfCapabilities _caps = PdfCapabilities.none;
  PdfDocumentInfo? _doc;
  bool _needsPassword = false;

  /// The password the document was unlocked with, for Compress (HOM-31); never logged.
  String? _password;
  bool _failed = false;
  PdfViewController? _view;
  StreamSubscription<PdfViewState>? _stateSub;
  PdfViewState? _state;
  _Panel _panel = _Panel.none;
  List<PdfOutlineEntry>? _outline;
  final GlobalKey _menuKey = GlobalKey();

  // Search.
  final TextEditingController _query = TextEditingController();
  final FocusNode _queryFocus = FocusNode();
  PdfSearchStatus _searchStatus = PdfSearchStatus.idle;
  List<PdfSearchHit> _hits = const [];
  bool _truncated = false;
  int _currentHit = -1;
  int _searchGeneration = 0;

  /// Bumped when the file or documents change and on dispose, so a stale open closes its handle.
  int _openGeneration = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  @override
  void didUpdateWidget(PdfViewer old) {
    super.didUpdateWidget(old);
    if (old.file != widget.file || old.documents != widget.documents) {
      final doc = _doc;
      if (doc != null) pdfIgnore(old.documents.close(doc.handle));
      unawaited(_stateSub?.cancel());
      _stateSub = null;
      _searchGeneration++;
      _openGeneration++;
      setState(() {
        _doc = null;
        _view = null;
        _state = null;
        _outline = null;
        _failed = false;
        _needsPassword = false;
        _password = null;
        _panel = _Panel.none;
        _hits = const [];
        _currentHit = -1;
        _searchStatus = PdfSearchStatus.idle;
      });
      unawaited(_open());
    }
  }

  @override
  void dispose() {
    unawaited(_stateSub?.cancel());
    _query.dispose();
    _queryFocus.dispose();
    _openGeneration++;
    final doc = _doc;
    if (doc != null) pdfIgnore(widget.documents.close(doc.handle));
    super.dispose();
  }

  Future<void> _open() async {
    final generation = _openGeneration;
    final documents = widget.documents;
    bool stale() => !mounted || generation != _openGeneration;
    try {
      final caps = widget.capabilities ?? await documents.capabilities();
      if (stale()) return;
      _caps = caps;
      if (!_caps.canView) return _unavailable();
      final doc = await documents.open(widget.file.path);
      if (stale()) {
        pdfIgnore(documents.close(doc.handle));
        return;
      }
      if (doc.locked && !_caps.passwords) {
        pdfIgnore(documents.close(doc.handle));
        return _unavailable();
      }
      setState(() {
        _doc = doc;
        _needsPassword = doc.locked;
      });
      if (doc.locked) {
        await _askPassword();
      } else {
        unawaited(_loadOutline());
      }
    } on PdfException catch (e) {
      if (stale()) return;
      if (e.code == PdfErrorCode.notFound || e.code == PdfErrorCode.ioError) {
        setState(() => _failed = true);
      } else {
        _unavailable();
      }
    }
  }

  void _unavailable() {
    if (!mounted) return;
    setState(() => _failed = true);
    widget.onUnavailable?.call();
  }

  Future<bool> _tryPassword(String password) async {
    final doc = _doc;
    if (doc == null) return false;
    final unlocked = await widget.documents.unlock(doc.handle, password);
    if (unlocked == null || unlocked.locked) return false;
    _password = password;
    if (mounted) {
      setState(() {
        _doc = unlocked;
        _needsPassword = false;
      });
      unawaited(_loadOutline());
    }
    return true;
  }

  Future<void> _askPassword() async {
    if (!mounted) return;
    final prompt = widget.passwordPrompt ?? (context, attempt) => showPdfPasswordSheet(context, tryPassword: attempt);
    await prompt(context, _tryPassword);
  }

  Future<void> _loadOutline() async {
    final doc = _doc;
    if (doc == null || !_caps.outline) return;
    try {
      final outline = await widget.documents.outline(doc.handle);
      if (mounted) setState(() => _outline = outline);
    } on PdfException {
      if (mounted) setState(() => _outline = const []);
    }
  }

  void _onCreated(PdfViewController controller) {
    _view = controller;
    unawaited(_stateSub?.cancel());
    _stateSub = controller.states.listen((s) {
      if (mounted) setState(() => _state = s);
    });
    controller.state().then((s) {
      if (mounted) setState(() => _state = s);
    }, onError: (Object _) {});
  }

  // ---------------------------------------------------------------------------------------------
  // Search

  Future<void> _search(String raw) async {
    final query = raw.trim();
    final generation = ++_searchGeneration;
    final view = _view;
    if (query.isEmpty || view == null) {
      if (view != null) pdfIgnore(view.clearSearch());
      setState(() {
        _searchStatus = PdfSearchStatus.idle;
        _hits = const [];
        _currentHit = -1;
      });
      return;
    }
    setState(() => _searchStatus = PdfSearchStatus.searching);
    try {
      final result = await view.search(query);
      if (!mounted || generation != _searchGeneration) return;
      setState(() {
        _searchStatus = PdfSearchStatus.done;
        _hits = result.hits;
        _truncated = result.truncated;
        _currentHit = -1;
      });
      if (result.hits.isNotEmpty) _selectHit(0);
    } on PdfException catch (e) {
      if (!mounted || generation != _searchGeneration || e.code == PdfErrorCode.cancelled) return;
      setState(() {
        _searchStatus = PdfSearchStatus.failed;
        _hits = const [];
      });
    }
  }

  void _selectHit(int index) {
    if (index < 0 || index >= _hits.length) return;
    setState(() => _currentHit = index);
    final view = _view;
    if (view != null) pdfIgnore(view.showSearchHit(_hits[index]));
  }

  void _togglePanel(_Panel panel) {
    final next = _panel == panel ? _Panel.none : panel;
    if (_panel == _Panel.search && next != _Panel.search) {
      _searchGeneration++;
      final view = _view;
      if (view != null) {
        pdfIgnore(view.cancelSearch());
        pdfIgnore(view.clearSearch());
      }
    }
    setState(() => _panel = next);
    if (next == _Panel.search) _queryFocus.requestFocus();
  }

  void _goTo(int page) {
    final view = _view;
    if (view != null) pdfIgnore(view.goToPage(page));
  }

  Future<void> _copy() async {
    final view = _view;
    if (view == null) return;
    final ok = await view.copySelection().catchError((Object _) => false);
    if (!mounted) return;
    DanaviewToast.show(context, ok ? 'Copied' : 'Nothing to copy');
  }

  // ---------------------------------------------------------------------------------------------
  // Build

  String _subtitle() {
    final doc = _doc;
    if (doc == null || doc.locked) return documentTypeLabel(widget.file);
    final count = doc.pageCount == 1 ? '1 page' : '${formatCount(doc.pageCount)} pages';
    final state = _state;
    if (state == null) return 'PDF · $count';
    return 'Page ${state.pageIndex + 1} of ${formatCount(doc.pageCount)}';
  }

  List<DanaviewMenuEntry> _menu() {
    final doc = _doc;
    final port = widget.fileOut;
    final open = doc != null && !doc.locked && _view != null;
    final mode = _state?.displayMode ?? PdfDisplayMode.continuous;
    return [
      if (_caps.selection && doc != null && doc.allowsCopying)
        DanaviewMenuItem(
          label: 'Copy selected text',
          icon: Icons.copy_rounded,
          enabled: open && (_state?.hasSelection ?? false),
          onTap: () => unawaited(_copy()),
        ),
      DanaviewMenuItem(label: 'Fit width', icon: Icons.fit_screen_rounded, enabled: open, onTap: () => pdfIgnore(_view!.zoomToFit())),
      if (_caps.platformView) ...[
        const DanaviewMenuHeader('Layout'),
        for (final (m, label) in const [
          (PdfDisplayMode.continuous, 'Scroll'),
          (PdfDisplayMode.singlePage, 'Single page'),
          (PdfDisplayMode.twoUpContinuous, 'Two pages'),
        ])
          DanaviewMenuItem(label: label, selected: mode == m, enabled: open, onTap: () => pdfIgnore(_view!.setDisplayMode(m))),
      ],
      if (widget.onCompress case final compress? when _caps.tools.contains(PdfTool.compress)) ...[
        const DanaviewMenuDivider(),
        DanaviewMenuItem(
          label: 'Compress…',
          icon: Icons.compress_rounded,
          enabled: doc != null && !doc.locked,
          onTap: () => unawaited(compress(_menuKey.currentContext ?? context, widget.file, password: _password)),
        ),
      ],
      if (port != null && port.capabilities.canOpenIn) ...[
        const DanaviewMenuDivider(),
        DanaviewMenuItem(
          label: 'Open in another app',
          icon: Icons.open_in_new_rounded,
          onTap: () => unawaited(openInAnotherApp(_menuKey.currentContext ?? context, port, widget.file)),
        ),
      ],
    ];
  }

  Widget _barButton(_Panel panel, IconData icon, String label, {bool enabled = true}) => DanaviewIconButton(
        icon: icon,
        size: 44,
        selected: _panel == panel,
        semanticLabel: label,
        tooltip: label,
        onPressed: enabled ? () => _togglePanel(panel) : null,
      );

  @override
  Widget build(BuildContext context) {
    final doc = _doc;
    final ready = doc != null && !doc.locked;
    return ColoredBox(
      color: DanaviewColors.background,
      child: Column(
        children: [
          DocumentTopBar(
            title: widget.file.displayName,
            subtitle: _subtitle(),
            onClose: widget.onClose,
            actions: [
              if (_caps.search) _barButton(_Panel.search, Icons.search_rounded, 'Search in PDF', enabled: ready),
              _barButton(_Panel.pages, Icons.grid_view_rounded, 'Pages', enabled: ready),
              if (_caps.outline && (_outline?.isNotEmpty ?? false)) _barButton(_Panel.outline, Icons.toc_rounded, 'Contents', enabled: ready),
              ViewerOptionsButton(key: _menuKey, entries: _menu()),
            ],
          ),
          Expanded(child: ClipRect(child: _body(context, doc))),
        ],
      ),
    );
  }

  Widget _body(BuildContext context, PdfDocumentInfo? doc) {
    if (_failed) {
      final port = widget.fileOut;
      return DanaviewEmptyState(
        icon: Icons.error_outline_rounded,
        iconColor: DanaviewColors.textSecondary,
        title: 'Can\'t show this PDF',
        message: 'Danaview couldn\'t open it.',
        actions: [
          if (port != null && port.capabilities.canOpenIn)
            Builder(
              builder: (context) => DanaviewButton.tonal(
                label: 'Open in another app',
                icon: Icons.open_in_new_rounded,
                semanticLabel: 'Open in another app',
                onPressed: () => openInAnotherApp(context, port, widget.file),
              ),
            ),
        ],
      );
    }
    if (doc == null) return const DocumentLoading();
    if (_needsPassword) {
      return DanaviewEmptyState(
        icon: Icons.lock_outline_rounded,
        iconColor: DanaviewColors.textSecondary,
        title: 'This PDF is protected',
        message: 'Enter its password to open it.',
        actions: [
          DanaviewButton.primary(label: 'Enter password', semanticLabel: 'Enter password', onPressed: () => unawaited(_askPassword())),
        ],
      );
    }
    final build = widget.viewBuilder ?? (context, d, onCreated) => PdfView(document: d, onCreated: onCreated);
    final view = KeyedSubtree(key: ValueKey('pdf-view-${doc.handle}'), child: build(context, doc, _onCreated));
    if (_panel == _Panel.none) return view;
    return LayoutBuilder(
      builder: (context, c) {
        final panel = DecoratedBox(
          decoration: BoxDecoration(
            color: DanaviewColors.surface,
            border: c.maxWidth >= _dockWidth ? const Border(left: DanaviewBorders.hairline) : const Border(top: DanaviewBorders.hairline),
          ),
          child: _panelBody(doc),
        );
        if (c.maxWidth >= _dockWidth) {
          final width = (c.maxWidth * 0.36).clamp(300.0, 400.0);
          return Row(children: [Expanded(child: view), SizedBox(width: width, child: panel)]);
        }
        final height = (c.maxHeight * 0.48).clamp(160.0, 420.0);
        return Column(children: [Expanded(child: view), SizedBox(height: height, child: panel)]);
      },
    );
  }

  Widget _panelBody(PdfDocumentInfo doc) {
    switch (_panel) {
      case _Panel.search:
        return PdfSearchPanel(
          controller: _query,
          focusNode: _queryFocus,
          status: _searchStatus,
          hits: _hits,
          truncated: _truncated,
          current: _currentHit,
          onQuery: (q) => unawaited(_search(q)),
          onSelect: _selectHit,
        );
      case _Panel.pages:
        return PdfPagesPanel(
          pageCount: doc.pageCount,
          pageSizes: doc.pageSizes,
          currentPage: _state?.pageIndex ?? 0,
          load: (page, w, h) => widget.documents.thumbnail(doc.handle, page, maxWidth: w, maxHeight: h),
          onSelect: _goTo,
        );
      case _Panel.outline:
        return PdfOutlinePanel(entries: _outline ?? const [], onSelect: _goTo);
      case _Panel.none:
        return const SizedBox.shrink();
    }
  }
}
