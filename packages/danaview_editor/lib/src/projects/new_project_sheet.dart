// OWNER: UX-06
//
// The New project sheet (ux.md §5.3): pick media from Photos/Gallery or Files (the engine's system
// pickers, several at once; picked items are listed with a remove button), choose the format
// (Auto = match the first video, 16:9, 9:16, 1:1, 4:5, 4:3, 21:9; preselected from the
// `editor.newProjectAspect` preference), name it (optional, 1–80 characters), then Create, which
// runs the import flow (ImportMediaSheet: free-space preflight, per-item progress, Cancel, inline
// errors, summary) in the same sheet, or Start empty. The sheet resolves to the new project's id;
// the Projects screen opens it.
//
// [newProjectImportJob] creates the project: an empty project with the chosen canvas, the media
// imported item by item into it through `MediaPoolService.import` (progress per item, cancellation
// between and during items), settings derived from the first video as `create(fromMedia)` does
// (aspect unless one was chosen, base short side, frame rate), visual media on the main lane and
// audio on a music lane, then saved and closed. When it is cancelled or nothing could be added the
// project is deleted, so nothing is kept.

import 'dart:async';

import 'package:flutter/material.dart' show Icons, Theme;
import 'package:flutter/services.dart' show LengthLimitingTextInputFormatter, TextInputAction;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/model.dart' as core show AspectRatio;
import 'package:danaview_editor_core/model.dart'
    show CanvasSpec, MediaAsset, MediaId, MediaKind, MediaOrigin, MediaProbe, PickedMedia, ProjectId;
import 'package:danaview_editor_core/ops.dart' show EditSession, InsertMedia, SetCanvas, SetFrameRate;
import 'package:danaview_editor_core/store.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' show MediaPickKind, MediaPickRequest, MediaPickSource;
import 'package:danaview_features/storage.dart' show formatDataSize;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../app/editor_prefs.dart';
import '../app/editor_providers.dart';
import '../app/strings/import_strings.dart';
import '../editor/flows/import_media_sheet.dart';

/// The format of a new project (ux.md §5.3).
enum NewProjectFormat {
  /// Match the first video (16:9 without media).
  auto(null),

  /// 16:9.
  landscape16x9(core.AspectRatio.landscape16x9),

  /// 9:16.
  portrait9x16(core.AspectRatio.portrait9x16),

  /// 1:1.
  square(core.AspectRatio.square),

  /// 4:5.
  portrait4x5(core.AspectRatio.portrait4x5),

  /// 4:3.
  classic4x3(core.AspectRatio.classic4x3),

  /// 21:9.
  cinema21x9(core.AspectRatio.cinema21x9);

  const NewProjectFormat(this.aspect);

  /// The fixed aspect, or null for Auto.
  final core.AspectRatio? aspect;

  /// Label (`Auto`, `16:9`).
  String get label {
    final a = aspect;
    return a == null ? NewProjectStrings.formatAuto : '${a.w}:${a.h}';
  }

  /// The format preselected by the `editor.newProjectAspect` preference.
  static NewProjectFormat fromPreference(NewProjectAspect preference) => switch (preference) {
        NewProjectAspect.matchFirstClip => NewProjectFormat.auto,
        NewProjectAspect.landscape16x9 => NewProjectFormat.landscape16x9,
        NewProjectAspect.portrait9x16 => NewProjectFormat.portrait9x16,
        NewProjectAspect.square => NewProjectFormat.square,
        NewProjectAspect.portrait4x5 => NewProjectFormat.portrait4x5,
      };
}

/// What a new project may hold (pickers are asked for these kinds).
const Set<MediaPickKind> newProjectPickKinds = {MediaPickKind.video, MediaPickKind.image, MediaPickKind.audio};

/// Creates a project named [name] with [format] from the picked media (see the file header).
ImportJob newProjectImportJob({
  required ProjectRepository repository,
  required MediaPoolService pool,
  required String name,
  required NewProjectFormat format,
  bool allow2160 = false,
}) =>
    (run) async {
      final fixed = format.aspect;
      final id = await repository.create(EmptyProjectSpec(name: name, canvas: fixed == null ? null : CanvasSpec(aspect: fixed)));
      try {
        final loaded = await repository.open(id);
        final session = EditSession(loaded.project);
        final results = <ImportItemResult>[];
        final added = <MediaAsset>[];
        for (var i = 0; i < run.picks.length; i++) {
          if (run.isCancelled) {
            results.add(const ImportItemResult.cancelled());
            run.report(i, ImportItemPhase.cancelled);
            continue;
          }
          run.report(i, run.workingPhaseOf(i));
          final outcome = await importOne(pool, session, run, i);
          final result = ImportItemResult.of(outcome);
          results.add(result);
          if (outcome is ImportedMedia) added.add(outcome.asset);
          run.reportResult(i, result);
        }
        final placeable = [
          for (final a in added)
            if (a.kind != MediaKind.lut) a
        ];
        if (run.isCancelled || placeable.isEmpty) {
          // Nothing is kept: the project goes, and with it every copy only it referenced.
          await discardCreatedProject(repository, id);
          final cancelled = run.isCancelled;
          final kept = [for (final r in results) cancelled && r.added ? const ImportItemResult.cancelled() : r];
          for (final (i, r) in kept.indexed) {
            run.reportResult(i, r);
          }
          return ImportJobResult(kept);
        }
        arrangeNewProject(session, placeable, format: format, allow2160: allow2160);
        await repository.save(session, reason: SaveReason.manual);
        await repository.close(id);
        return ImportJobResult(results, projectId: id);
      } on Object {
        await discardCreatedProject(repository, id);
        rethrow;
      }
    };

/// Applies the settings derived from the first video (or image) and places [assets]: visual media
/// back to back on the main lane, audio from 0 on a music lane (ARCH §8.4).
void arrangeNewProject(EditSession session, List<MediaAsset> assets, {required NewProjectFormat format, bool allow2160 = false}) {
  MediaProbe? firstVideo;
  MediaProbe? firstImage;
  for (final a in assets) {
    if (a.kind == MediaKind.video && firstVideo == null) firstVideo = a.probe;
    if ((a.kind == MediaKind.image || a.kind == MediaKind.still) && firstImage == null) firstImage = a.probe;
  }
  final source = firstVideo ?? firstImage;
  if (source != null) {
    final derived = deriveProjectSettings(source, allow2160: allow2160);
    session.apply(SetCanvas(aspect: format.aspect ?? derived.canvas.aspect, baseShortSide: derived.canvas.baseShortSide));
    if (firstVideo != null) session.apply(SetFrameRate(derived.frameRate));
  }
  final visual = <MediaId>[];
  final audio = <MediaId>[];
  for (final a in assets) {
    final list = switch (a.kind) {
      MediaKind.video || MediaKind.image || MediaKind.still => visual,
      MediaKind.audio || MediaKind.recording => audio,
      MediaKind.lut => null,
    };
    if (list != null && !list.contains(a.id)) list.add(a.id);
  }
  if (visual.isNotEmpty) session.apply(InsertMedia(visual, 0));
  if (audio.isNotEmpty) session.apply(InsertMedia(audio, 0));
}

/// Shows the New project sheet; resolves to the created project's id, or null when closed.
Future<ProjectId?> showNewProjectSheet(BuildContext context) => showDanaviewSheet<ProjectId>(
      context,
      title: NewProjectStrings.title,
      builder: (context) => const NewProjectSheet(),
    );

/// Picks media, a format and a name for a new project (ux.md §5.3).
class NewProjectSheet extends ConsumerStatefulWidget {
  /// Creates the sheet content. [onCreated] receives the new project's id (default: the sheet's
  /// route is popped with it).
  const NewProjectSheet({super.key, this.onCreated});

  /// Called with the created project.
  final ValueChanged<ProjectId>? onCreated;

  @override
  ConsumerState<NewProjectSheet> createState() => _NewProjectSheetState();
}

class _NewProjectSheetState extends ConsumerState<NewProjectSheet> {
  final List<PickedMedia> _picks = [];
  final Map<String, String> _errors = {};
  late NewProjectFormat _format = NewProjectFormat.fromPreference(ref.read(editorPrefsProvider).newProjectAspect);
  final TextEditingController _name = TextEditingController();
  String? _nameError;
  String? _notice;
  bool _picking = false;
  bool _creatingEmpty = false;
  List<PickedMedia>? _importing;
  ImportJob? _job;
  int _attempt = 0;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _busy => _picking || _creatingEmpty;

  /// The trimmed name (`Untitled project` when empty), or null after showing why it is invalid.
  String? _validName() {
    final name = _name.text.trim();
    if (name.runes.length > 80) {
      setState(() => _nameError = NewProjectStrings.nameTooLong);
      return null;
    }
    return name.isEmpty ? NewProjectStrings.untitled : name;
  }

  Future<void> _pick(MediaPickSource source) async {
    if (_busy) return;
    setState(() {
      _picking = true;
      _notice = null;
    });
    try {
      final picker = ref.read(editorEngineProvider).picker;
      final picked = await picker.pick(MediaPickRequest(source: source, kinds: newProjectPickKinds));
      if (!mounted) return;
      setState(() {
        for (final p in picked) {
          if (!_picks.any((q) => q.uri == p.uri)) _picks.add(p);
        }
      });
    } on Object catch (e) {
      debugPrint('[NewProject] Picker failed: ${e.runtimeType}');
      if (mounted) setState(() => _notice = NewProjectStrings.pickerFailed);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  void _remove(PickedMedia picked) => setState(() {
        _picks.removeWhere((p) => p.uri == picked.uri);
        _errors.remove(picked.uri);
      });

  void _create() {
    if (_busy || _picks.isEmpty) return;
    final name = _validName();
    if (name == null) return;
    FocusScope.of(context).unfocus();
    final job = newProjectImportJob(
      repository: ref.read(projectRepositoryProvider),
      pool: ref.read(mediaPoolServiceProvider),
      name: name,
      format: _format,
      allow2160: _allow2160,
    );
    setState(() {
      _errors.clear();
      _notice = null;
      _attempt++;
      _job = job;
      _importing = List.of(_picks);
    });
  }

  Future<void> _startEmpty() async {
    if (_busy) return;
    final name = _validName();
    if (name == null) return;
    setState(() {
      _creatingEmpty = true;
      _notice = null;
    });
    try {
      final aspect = _format.aspect ?? core.AspectRatio.landscape16x9;
      final id = await ref.read(projectRepositoryProvider).create(EmptyProjectSpec(name: name, canvas: CanvasSpec(aspect: aspect)));
      if (mounted) _done(id);
    } on Object catch (e) {
      debugPrint('[NewProject] Create failed: ${e.runtimeType}');
      if (mounted) setState(() => _notice = NewProjectStrings.createFailed);
    } finally {
      if (mounted) setState(() => _creatingEmpty = false);
    }
  }

  void _done(ProjectId id) {
    final onCreated = widget.onCreated;
    if (onCreated != null) {
      onCreated(id);
    } else {
      Navigator.of(context).pop(id);
    }
  }

  /// Back from the import view: failed items keep their error inline.
  void _backFromImport(ImportSheetResult result) {
    final picks = _importing ?? const <PickedMedia>[];
    setState(() {
      _importing = null;
      _job = null;
      final job = result.job;
      if (job == null) return;
      for (final (i, item) in job.items.indexed) {
        if (i < picks.length && item.phase == ImportItemPhase.failed) _errors[picks[i].uri] = item.reason ?? 'io';
      }
    });
  }

  bool get _allow2160 {
    final caps = ref.read(editorCapabilitiesProvider).valueOrNull;
    return caps != null && caps.maxExportSize.shortestSide >= 2160;
  }

  @override
  Widget build(BuildContext context) {
    final importing = _importing;
    final job = _job;
    if (importing != null && job != null) {
      return ImportMediaSheet(
        key: ValueKey('new-project-import-$_attempt'),
        picks: importing,
        job: job,
        finishLabel: ImportStrings.openProject,
        onFinished: (result) {
          final id = result.projectId;
          if (id != null) {
            _done(id);
          } else {
            _backFromImport(result);
          }
        },
        onBack: _backFromImport,
      );
    }
    return _compose(context);
  }

  Widget _compose(BuildContext context) {
    final platform = Theme.of(context).platform;
    final photosHint = platform == TargetPlatform.iOS && _picks.any((p) => p.origin == MediaOrigin.photos);
    return Column(
      key: const ValueKey('new-project-sheet'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionLabel(NewProjectStrings.mediaSection),
        DanaviewButtonBar(
          children: [
            DanaviewButton.secondary(
              key: const ValueKey('new-project-photos'),
              label: NewProjectStrings.photosButton(platform),
              icon: Icons.photo_library_rounded,
              onPressed: _busy ? null : () => _pick(MediaPickSource.photos),
            ),
            DanaviewButton.secondary(
              key: const ValueKey('new-project-files'),
              label: NewProjectStrings.filesButton,
              icon: Icons.folder_open_rounded,
              onPressed: _busy ? null : () => _pick(MediaPickSource.files),
            ),
          ],
        ),
        if (_notice case final notice?) ...[
          const SizedBox(height: DanaviewSpacing.sm),
          _Notice(notice),
        ],
        const SizedBox(height: DanaviewSpacing.sm),
        if (_picks.isEmpty)
          Text(NewProjectStrings.mediaHint, style: DanaviewTextStyles.caption.copyWith(color: DanaviewColors.textSecondary, height: 1.35))
        else
          DanaviewSurface(
            key: const ValueKey('new-project-picks'),
            color: DanaviewColors.surface,
            padding: const EdgeInsets.only(left: DanaviewSpacing.md, right: DanaviewSpacing.xs),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final p in _picks)
                  ImportItemTile(
                    key: ValueKey('new-project-pick-${p.uri}'),
                    picked: p,
                    status: _errors.containsKey(p.uri) ? ImportStrings.itemError(_errors[p.uri]!) : _describe(p),
                    statusColor: _errors.containsKey(p.uri) ? DanaviewColors.errorLight : DanaviewColors.textSecondary,
                    trailing: DanaviewIconButton(
                      icon: Icons.close_rounded,
                      size: 32,
                      iconSize: 18,
                      color: DanaviewColors.textSecondary,
                      tooltip: NewProjectStrings.removeItem(p.displayName),
                      semanticLabel: NewProjectStrings.removeItem(p.displayName),
                      onPressed: () => _remove(p),
                    ),
                  ),
              ],
            ),
          ),
        if (photosHint) ...[
          const SizedBox(height: DanaviewSpacing.sm),
          const ImportPhotosHint(),
        ],
        const _SectionLabel(NewProjectStrings.formatSection),
        DanaviewSegmentedControl<NewProjectFormat>(
          key: const ValueKey('new-project-format'),
          value: _format,
          options: [for (final f in NewProjectFormat.values) DanaviewOption(value: f, label: f.label)],
          onChanged: (f) => setState(() => _format = f),
        ),
        if (_format == NewProjectFormat.auto) ...[
          const SizedBox(height: DanaviewSpacing.xs + 2),
          Text(NewProjectStrings.formatAutoHint, style: DanaviewTextStyles.caption.copyWith(color: DanaviewColors.textSecondary, height: 1.35)),
        ],
        const _SectionLabel(NewProjectStrings.nameSection),
        DanaviewTextField(
          key: const ValueKey('new-project-name'),
          controller: _name,
          hint: NewProjectStrings.untitled,
          errorText: _nameError,
          semanticLabel: NewProjectStrings.nameSection,
          textInputAction: TextInputAction.done,
          inputFormatters: [LengthLimitingTextInputFormatter(120)],
          onChanged: (_) {
            if (_nameError != null) setState(() => _nameError = null);
          },
        ),
        const SizedBox(height: DanaviewSpacing.lg),
        DanaviewButtonBar(
          children: [
            DanaviewButton.secondary(
              key: const ValueKey('new-project-start-empty'),
              label: NewProjectStrings.startEmpty,
              onPressed: _busy ? null : _startEmpty,
            ),
            DanaviewButton.primary(
              key: const ValueKey('new-project-create'),
              label: NewProjectStrings.create,
              icon: Icons.check_rounded,
              onPressed: _busy || _picks.isEmpty ? null : _create,
            ),
          ],
        ),
      ],
    );
  }

  static String _describe(PickedMedia p) {
    final kind = switch (guessMediaKind(p.displayName)) {
      MediaKind.video => 'Video',
      MediaKind.image || MediaKind.still => 'Photo',
      MediaKind.audio || MediaKind.recording => 'Audio',
      MediaKind.lut => 'LUT',
      null => 'File',
    };
    final size = p.sizeBytes;
    return size == null || size <= 0 ? kind : '$kind · ${formatDataSize(size)}';
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: DanaviewSpacing.lg, bottom: DanaviewSpacing.sm),
        child: Semantics(
          header: true,
          child: Text(text, style: DanaviewTextStyles.label.copyWith(color: DanaviewColors.textSecondary)),
        ),
      );
}

class _Notice extends StatelessWidget {
  const _Notice(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Semantics(
        liveRegion: true,
        child: Row(
          key: const ValueKey('new-project-notice'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 1),
              child: Icon(Icons.error_outline_rounded, size: 16, color: DanaviewColors.errorLight),
            ),
            const SizedBox(width: DanaviewSpacing.sm),
            Expanded(child: Text(text, style: DanaviewTextStyles.caption.copyWith(color: DanaviewColors.errorLight, height: 1.35))),
          ],
        ),
      );
}
