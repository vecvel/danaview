// OWNER: HOM-24
// EXTENDED: HOM-28 (with a PdfToolsScope above it, the top bar gets "Organise pages" and the menu
// "Merge with…"; a Replace from the organiser reopens the file.)
// EXTENDED: HOM-29 (with an annotate engine in the scope and the tool reported, the top bar gets
// "Annotate": an annotate mode over the same native view, with the Cinema B toolbar under the
// pages, undo / redo and Save in the top bar, "<name> (annotated).pdf" saved as a new file
// (Replace for Danaview folder files), and a prompt before unsaved annotations are left.)
// EXTENDED: HOM-30 (with a signature store in the scope too and the sign tool reported, the top bar
// gets "Sign": a sign mode over the same native view (the annotate mode's place input) with the
// signature strip under the pages; tap a page to place the chosen signature, drag it, resize it
// from its round handle, delete it, place it on several pages; Undo / Redo and Save, which burns
// the signatures into "<name> (signed).pdf" as a new file (Replace for Danaview folder files); a
// prompt before unplaced signatures are left. A scope's `startWith: sign` opens it at once.)
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
import '../annotate/pdf_annotate_model.dart';
import '../annotate/pdf_annotate_save.dart';
import '../annotate/pdf_annotate_session.dart';
import '../annotate/pdf_annotate_toolbar.dart';
import '../organiser/pdf_tool_launcher.dart';
import '../organiser/pdf_tool_save.dart' show PdfSaveMode;
import '../sign/pdf_sign_model.dart';
import '../sign/pdf_sign_save.dart';
import '../sign/pdf_sign_session.dart';
import '../sign/pdf_sign_toolbar.dart';
import '../../signatures/signature_create_sheet.dart';
import '../../signatures/signature_list.dart';
import '../../signatures/signature_store.dart';
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

/// Narrower windows show "Sign…" in the viewer's menu instead of the top bar (HOM-30), so the bar's
/// buttons keep their 44 pt.
const double _signInBarWidth = 360;

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
    this.annotateTextPrompt,
    this.chooseSaveMode,
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

  /// Asks for a text box's text while annotating (default a kit prompt; tests replace it).
  final Future<String?> Function(BuildContext context, String? initial)? annotateTextPrompt;

  /// Asks new file or Replace when saving annotations (default the organiser's sheet).
  final Future<PdfSaveMode?> Function(BuildContext context, String newName)? chooseSaveMode;

  @override
  State<PdfViewer> createState() => _PdfViewerState();
}

class _PdfViewerState extends State<PdfViewer> {
  PdfCapabilities _caps = PdfCapabilities.none;
  PdfDocumentInfo? _doc;
  bool _needsPassword = false;

  /// The password the document was unlocked with, for the tools (HOM-28, HOM-31); never logged.
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

  // Annotate (HOM-29).
  PdfAnnotateModel? _annotateModel;
  PdfAnnotateSession? _annotateSession;
  bool _annotateBusy = false;

  // Sign (HOM-30).
  PdfSignModel? _signModel;
  PdfSignSession? _signSession;
  bool _signBusy = false;
  bool _startToolDone = false;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  @override
  void didUpdateWidget(PdfViewer old) {
    super.didUpdateWidget(old);
    if (old.file != widget.file || old.documents != widget.documents) {
      _password = null; // a new file asks for its own password
      _reopen(old.documents);
    }
  }

  /// Closes the open document of [documents] and opens the file again from the start.
  void _reopen(PdfDocuments documents) {
    _endAnnotate();
    _endSign();
    final doc = _doc;
    if (doc != null) pdfIgnore(documents.close(doc.handle));
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
      _panel = _Panel.none;
      _hits = const [];
      _currentHit = -1;
      _searchStatus = PdfSearchStatus.idle;
    });
    unawaited(_open());
  }

  @override
  void dispose() {
    _endAnnotate(notify: false);
    _endSign(notify: false);
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
      final doc = await documents.open(widget.file.path, password: _password);
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
    if (_view != null && _view!.viewId != controller.viewId) {
      _endAnnotate();
      _endSign();
    }
    _view = controller;
    _maybeStartTool();
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

  Future<void> _organise(PdfToolsEnvironment tools) async {
    final saved = await openPdfOrganiser(context, tools, widget.file, password: _password);
    if (mounted && saved != null && saved.replaced) _reopen(widget.documents);
  }

  Future<void> _mergeWith(PdfToolsEnvironment tools) => openPdfMerge(context, tools, [PdfMergeItem.ofFile(widget.file, password: _password)], pickFirst: true);

  // ---------------------------------------------------------------------------------------------
  // Annotate (HOM-29)

  bool get _annotating => _annotateModel != null;

  /// "Annotate" shows where the scope has an engine and the platform reports the tool (its viewer
  /// mode and save both work there).
  bool _canAnnotate(PdfToolsEnvironment? tools) => tools?.annotate != null && _caps.tools.contains(PdfTool.annotate);

  void _toast(String message, {bool error = false}) {
    if (!mounted) return;
    DanaviewToast.show(
      context,
      message,
      kind: error ? DanaviewToastKind.error : DanaviewToastKind.success,
      icon: error ? Icons.error_outline_rounded : null,
    );
  }

  Future<String?> _askText(String? initial) {
    final prompt = widget.annotateTextPrompt;
    if (prompt != null) return prompt(context, initial);
    return showDanaviewPrompt(
      context,
      title: initial == null ? 'Add text' : 'Edit text',
      hint: 'Type your note',
      initialValue: initial,
      confirmLabel: initial == null ? 'Add' : 'Save',
    );
  }

  Future<void> _startAnnotate(PdfToolsEnvironment tools) async {
    final engine = tools.annotate;
    final view = _view;
    final doc = _doc;
    if (engine == null || view == null || doc == null || _annotating || _signing) return;
    if (_panel != _Panel.none) _togglePanel(_panel);
    final model = PdfAnnotateModel();
    final session = PdfAnnotateSession(
      engine: engine,
      viewId: view.viewId,
      model: model,
      pageSizes: doc.pageSizes,
      askText: _askText,
      onError: (_) => _toast('Annotations couldn’t be shown. Try again.', error: true),
    );
    model.addListener(_onAnnotateChanged);
    setState(() {
      _annotateModel = model;
      _annotateSession = session;
    });
    try {
      await session.start();
    } on PdfException {
      _endAnnotate();
      _toast('Annotate isn’t available for this PDF.', error: true);
    }
  }

  void _onAnnotateChanged() {
    if (mounted) setState(() {});
  }

  /// Leaves annotate mode without asking (the preview goes, the session is dropped).
  void _endAnnotate({bool notify = true}) {
    final model = _annotateModel;
    final session = _annotateSession;
    if (model == null) return;
    _annotateModel = null;
    _annotateSession = null;
    _annotateBusy = false;
    model.removeListener(_onAnnotateChanged);
    unawaited(session?.stop().whenComplete(model.dispose) ?? Future<void>.sync(model.dispose));
    if (notify && mounted) setState(() {});
  }

  /// True when nothing unsaved would be lost, or the user chose to discard it.
  Future<bool> _confirmDiscardAnnotations() async {
    final model = _annotateModel;
    if (model == null || !model.isDirty) return true;
    return showDanaviewConfirm(
      context,
      title: 'Discard annotations?',
      message: 'Your annotations haven’t been saved.',
      confirmLabel: 'Discard',
      destructive: true,
    );
  }

  Future<void> _leaveAnnotate() async {
    if (_annotateBusy) return;
    if (!await _confirmDiscardAnnotations() || !mounted) return;
    _endAnnotate();
  }

  /// The viewer's back button and the system back: unsaved annotations ask first.
  Future<void> _close() async {
    if (_annotating) {
      if (_annotateBusy || !await _confirmDiscardAnnotations() || !mounted) return;
      _endAnnotate();
    }
    if (_signing) {
      if (_signBusy || !await _confirmDiscardSignatures() || !mounted) return;
      _endSign();
    }
    final close = widget.onClose;
    if (close != null) {
      close();
    } else if (mounted) {
      await Navigator.of(context).maybePop();
    }
  }

  Future<void> _markup(PdfAnnotationKind kind) async {
    final session = _annotateSession;
    final view = _view;
    if (session == null) return;
    try {
      final marked = await session.markup(kind);
      if (marked == 0) {
        _toast('Select some text first.');
      } else if (view != null) {
        pdfIgnore(view.clearSelection());
      }
    } on PdfException {
      _toast('That didn’t work. Try again.', error: true);
    }
  }

  void _deleteSelected() {
    final model = _annotateModel;
    final id = model?.selectedId;
    if (model != null && id != null) model.remove(id);
  }

  void _editSelected() {
    final id = _annotateModel?.selectedId;
    final session = _annotateSession;
    if (id != null && session != null) unawaited(session.editText(id));
  }

  Future<void> _saveAnnotations(PdfToolsEnvironment tools) async {
    final model = _annotateModel;
    final engine = tools.annotate;
    if (model == null || engine == null || !model.isDirty || _annotateBusy) return;
    setState(() => _annotateBusy = true);
    try {
      final saved = await savePdfAnnotations(
        context,
        environment: tools,
        engine: engine,
        file: widget.file,
        password: _password,
        annotations: [
          for (final i in model.items)
            if (i.annotation case final a?) a,
        ],
        chooseSaveMode: widget.chooseSaveMode,
      );
      if (saved == null || !mounted) return;
      _endAnnotate();
      _toast(saved.replaced ? 'Replaced ${saved.displayName}' : 'Saved as ${saved.displayName}');
      if (saved.replaced) _reopen(widget.documents);
    } on PdfException catch (e) {
      _toast(pdfAnnotateErrorMessage(e), error: true);
    } on Object {
      _toast('The annotations couldn’t be saved. Try again.', error: true);
    } finally {
      if (mounted && _annotateBusy) setState(() => _annotateBusy = false);
    }
  }

  Widget _annotateTopBar(PdfToolsEnvironment tools, PdfAnnotateModel model) {
    final idle = !_annotateBusy;
    return DocumentTopBar(
      title: 'Annotate',
      subtitle: widget.file.displayName,
      onClose: () => unawaited(_leaveAnnotate()),
      actions: [
        DanaviewIconButton(
          key: const ValueKey('pdf-annotate-undo'),
          icon: Icons.undo_rounded,
          size: 44,
          semanticLabel: 'Undo',
          tooltip: 'Undo',
          onPressed: idle && model.canUndo ? model.undo : null,
        ),
        DanaviewIconButton(
          key: const ValueKey('pdf-annotate-redo'),
          icon: Icons.redo_rounded,
          size: 44,
          semanticLabel: 'Redo',
          tooltip: 'Redo',
          onPressed: idle && model.canRedo ? model.redo : null,
        ),
        const SizedBox(width: DanaviewSpacing.xs),
        DanaviewButton.primary(
          key: const ValueKey('pdf-annotate-save'),
          label: 'Save',
          size: DanaviewButtonSize.sm,
          semanticLabel: 'Save annotations',
          onPressed: idle && model.isDirty ? () => unawaited(_saveAnnotations(tools)) : null,
        ),
        const SizedBox(width: DanaviewSpacing.sm),
      ],
    );
  }

  // ---------------------------------------------------------------------------------------------
  // Sign (HOM-30)

  bool get _signing => _signModel != null;

  /// "Sign" shows where the scope has an annotate engine and a signature store and the platform
  /// reports the sign tool (the place input and the burn-in save both work there).
  bool _canSign(PdfToolsEnvironment? tools) => tools?.annotate != null && tools?.signatures != null && _caps.tools.contains(PdfTool.sign);

  /// Opens the tool the scope asks for (the file menu's "Sign…"), once, when the pages show.
  void _maybeStartTool() {
    if (_startToolDone) return;
    final start = PdfToolsScope.startToolOf(context);
    if (start == null) return;
    _startToolDone = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final tools = PdfToolsScope.maybeOf(context);
      switch (start) {
        case PdfViewerStartTool.sign:
          if (tools != null && _canSign(tools)) unawaited(_startSign(tools));
      }
    });
  }

  Future<void> _startSign(PdfToolsEnvironment tools) async {
    final engine = tools.annotate;
    final store = tools.signatures;
    final view = _view;
    final doc = _doc;
    if (engine == null || store == null || view == null || doc == null || doc.locked || _signing || _annotating) return;
    if (_panel != _Panel.none) _togglePanel(_panel);
    final model = PdfSignModel();
    final session = PdfSignSession(
      engine: engine,
      viewId: view.viewId,
      model: model,
      pageSizes: doc.pageSizes,
      onNeedSignature: () => unawaited(_newSignature(tools)),
      onError: (_) => _toast('Signatures couldn’t be shown. Try again.', error: true),
    );
    model.addListener(_onSignChanged);
    setState(() {
      _signModel = model;
      _signSession = session;
    });
    try {
      await session.start();
    } on PdfException {
      _endSign();
      _toast('Signing isn’t available for this PDF.', error: true);
      return;
    }
    // The newest saved signature is ready to place; without one, "New signature" opens.
    final saved = await store.list().catchError((Object _) => <SavedSignature>[]);
    if (!mounted || _signModel != model) return;
    if (saved.isNotEmpty) {
      model.signature = saved.first;
    } else {
      await _newSignature(tools);
    }
  }

  void _onSignChanged() {
    if (mounted) setState(() {});
  }

  /// Leaves sign mode without asking (the preview goes, the session is dropped).
  void _endSign({bool notify = true}) {
    final model = _signModel;
    final session = _signSession;
    if (model == null) return;
    _signModel = null;
    _signSession = null;
    _signBusy = false;
    model.removeListener(_onSignChanged);
    unawaited(session?.stop().whenComplete(model.dispose) ?? Future<void>.sync(model.dispose));
    if (notify && mounted) setState(() {});
  }

  /// True when no placed signature would be lost, or the user chose to discard them.
  Future<bool> _confirmDiscardSignatures() async {
    final model = _signModel;
    if (model == null || !model.isDirty) return true;
    return showDanaviewConfirm(
      context,
      title: 'Discard signatures?',
      message: 'The signatures you placed haven’t been saved.',
      confirmLabel: 'Discard',
      destructive: true,
    );
  }

  Future<void> _leaveSign() async {
    if (_signBusy) return;
    if (!await _confirmDiscardSignatures() || !mounted) return;
    _endSign();
  }

  bool _choosingSignature = false;

  Future<void> _newSignature(PdfToolsEnvironment tools) async {
    final store = tools.signatures;
    if (store == null || _choosingSignature || !mounted) return;
    _choosingSignature = true;
    try {
      final saved = await showSignatureCreateSheet(context, store: store, fonts: tools.signatureFonts, pickPhoto: tools.pickSignaturePhoto);
      final model = _signModel;
      if (saved != null && model != null && mounted) model.signature = saved;
    } finally {
      _choosingSignature = false;
    }
  }

  Future<void> _manageSignatures(PdfToolsEnvironment tools) async {
    final store = tools.signatures;
    final model = _signModel;
    if (store == null || model == null) return;
    final chosen = await showSavedSignaturesSheet(context, store: store, inUse: model.pathsInUse);
    if (!mounted || _signModel != model) return;
    if (chosen != null) {
      model.signature = chosen;
    } else if (model.signature != null && !(await store.list()).any((s) => s.id == model.signature!.id)) {
      // The chosen signature was deleted.
      if (mounted && _signModel == model) model.signature = null;
    }
  }

  void _deleteSelectedSignature() {
    final model = _signModel;
    final id = model?.selectedId;
    if (model != null && id != null) model.remove(id);
  }

  Future<void> _saveSignatures(PdfToolsEnvironment tools) async {
    final model = _signModel;
    final engine = tools.annotate;
    if (model == null || engine == null || !model.isDirty || _signBusy) return;
    setState(() => _signBusy = true);
    try {
      final saved = await savePdfSignatures(
        context,
        environment: tools,
        engine: engine,
        file: widget.file,
        password: _password,
        stamps: model.stamps,
        chooseSaveMode: widget.chooseSaveMode,
      );
      if (saved == null || !mounted) return;
      _endSign();
      _toast(saved.replaced ? 'Signed and replaced ${saved.displayName}' : 'Saved as ${saved.displayName}');
      if (saved.replaced) _reopen(widget.documents);
    } on PdfException catch (e) {
      _toast(pdfSignErrorMessage(e), error: true);
    } on Object {
      _toast('The signed copy couldn’t be saved. Try again.', error: true);
    } finally {
      if (mounted && _signBusy) setState(() => _signBusy = false);
    }
  }

  Widget _signTopBar(PdfToolsEnvironment tools, PdfSignModel model) {
    final idle = !_signBusy;
    return DocumentTopBar(
      title: 'Sign',
      subtitle: widget.file.displayName,
      onClose: () => unawaited(_leaveSign()),
      actions: [
        DanaviewIconButton(
          key: const ValueKey('pdf-sign-undo'),
          icon: Icons.undo_rounded,
          size: 44,
          semanticLabel: 'Undo',
          tooltip: 'Undo',
          onPressed: idle && model.canUndo ? model.undo : null,
        ),
        DanaviewIconButton(
          key: const ValueKey('pdf-sign-redo'),
          icon: Icons.redo_rounded,
          size: 44,
          semanticLabel: 'Redo',
          tooltip: 'Redo',
          onPressed: idle && model.canRedo ? model.redo : null,
        ),
        const SizedBox(width: DanaviewSpacing.xs),
        DanaviewButton.primary(
          key: const ValueKey('pdf-sign-save'),
          label: 'Save',
          size: DanaviewButtonSize.sm,
          semanticLabel: 'Save signed copy',
          onPressed: idle && model.isDirty ? () => unawaited(_saveSignatures(tools)) : null,
        ),
        const SizedBox(width: DanaviewSpacing.sm),
      ],
    );
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

  bool _signInMenu(BuildContext context) => MediaQuery.sizeOf(context).width < _signInBarWidth;

  List<DanaviewMenuEntry> _menu(PdfToolsEnvironment? tools) {
    final doc = _doc;
    final port = widget.fileOut;
    final open = doc != null && !doc.locked && _view != null;
    final mode = _state?.displayMode ?? PdfDisplayMode.continuous;
    final canMerge = tools != null && tools.pickMergeInputs != null && _caps.tools.contains(PdfTool.merge);
    return [
      if (_canSign(tools) && _signInMenu(context)) ...[
        DanaviewMenuItem(
          label: 'Sign…',
          icon: Icons.history_edu_rounded,
          enabled: open,
          onTap: () => unawaited(_startSign(tools!)),
        ),
        const DanaviewMenuDivider(),
      ],
      if (canMerge) ...[
        DanaviewMenuItem(
          label: 'Merge with…',
          icon: Icons.merge_rounded,
          enabled: doc != null && !doc.locked,
          onTap: () => unawaited(_mergeWith(tools)),
        ),
        const DanaviewMenuDivider(),
      ],
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
    final tools = PdfToolsScope.maybeOf(context);
    final organise = tools != null && canOrganise(_caps.tools);
    final annotate = _annotateModel;
    final sign = _signModel;
    final Widget topBar;
    if (annotate != null && tools != null) {
      topBar = _annotateTopBar(tools, annotate);
    } else if (sign != null && tools != null) {
      topBar = _signTopBar(tools, sign);
    } else {
      topBar = _viewerTopBar(tools, ready: ready, organise: organise);
    }
    return PopScope(
      canPop: !(annotate?.isDirty ?? false) && !_annotateBusy && !(sign?.isDirty ?? false) && !_signBusy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_close());
      },
      child: ColoredBox(
        color: DanaviewColors.background,
        child: Column(
          children: [
            topBar,
            Expanded(child: ClipRect(child: _body(context, doc))),
          ],
        ),
      ),
    );
  }

  Widget _viewerTopBar(PdfToolsEnvironment? tools, {required bool ready, required bool organise}) => DocumentTopBar(
        title: widget.file.displayName,
        subtitle: _subtitle(),
        onClose: widget.onClose == null ? null : () => unawaited(_close()),
        actions: [
          if (_caps.search) _barButton(_Panel.search, Icons.search_rounded, 'Search in PDF', enabled: ready),
          _barButton(_Panel.pages, Icons.grid_view_rounded, 'Pages', enabled: ready),
          if (_caps.outline && (_outline?.isNotEmpty ?? false)) _barButton(_Panel.outline, Icons.toc_rounded, 'Contents', enabled: ready),
          if (organise)
            DanaviewIconButton(
              key: const ValueKey('pdf-viewer-organise'),
              icon: Icons.dashboard_customize_outlined,
              size: 44,
              semanticLabel: 'Organise pages',
              tooltip: 'Organise pages',
              onPressed: ready ? () => unawaited(_organise(tools!)) : null,
            ),
          if (_canAnnotate(tools))
            DanaviewIconButton(
              key: const ValueKey('pdf-viewer-annotate'),
              icon: Icons.edit_note_rounded,
              size: 44,
              semanticLabel: 'Annotate',
              tooltip: 'Annotate',
              onPressed: ready && _view != null ? () => unawaited(_startAnnotate(tools!)) : null,
            ),
          if (_canSign(tools) && !_signInMenu(context))
            DanaviewIconButton(
              key: const ValueKey('pdf-viewer-sign'),
              icon: Icons.history_edu_rounded,
              size: 44,
              semanticLabel: 'Sign',
              tooltip: 'Sign',
              onPressed: ready && _view != null ? () => unawaited(_startSign(tools!)) : null,
            ),
          ViewerOptionsButton(key: _menuKey, entries: _menu(tools)),
        ],
      );

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
    final annotate = _annotateModel;
    final tools = PdfToolsScope.maybeOf(context);
    // The view keeps its place in the tree when annotate mode adds the toolbar under it, so the
    // native view (and its annotate session) survives.
    if (_panel == _Panel.none) {
      return Column(
        children: [
          Expanded(child: view),
          if (annotate != null)
            PdfAnnotateToolbar(
              key: const ValueKey('pdf-annotate-toolbar'),
              model: annotate,
              hasTextSelection: _state?.hasSelection ?? false,
              enabled: !_annotateBusy,
              onMarkup: (kind) => unawaited(_markup(kind)),
              onDeleteSelected: _deleteSelected,
              onEditSelected: _editSelected,
            ),
          if (_signModel case final sign? when tools != null && tools.signatures != null)
            PdfSignToolbar(
              key: const ValueKey('pdf-sign-toolbar'),
              model: sign,
              store: tools.signatures!,
              enabled: !_signBusy,
              onNew: () => unawaited(_newSignature(tools)),
              onManage: () => unawaited(_manageSignatures(tools)),
              onDeleteSelected: _deleteSelectedSignature,
            ),
        ],
      );
    }
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
