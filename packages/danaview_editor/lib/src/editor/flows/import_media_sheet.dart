// OWNER: UX-06
//
// The import flow (ux.md §5.3, ARCH §9.1, D-13), used by the New project sheet, the editor's Media
// tool and external drops (UX-36) and the player's Edit (UX-41):
//
// 1. Free-space preflight: before any managed copy, the bytes of the items that will be copied
//    (decided by the import policy of the real `FileMediaPoolService`) plus 64 MB must be free, or
//    the import is refused with what is needed and what is free. Nothing is copied then.
// 2. Per-item progress: each item shows "Checking…" (probe) or "Copying into Danaview…" (with a
//    percentage when the job reports one), then "Added" or an inline error for its
//    `ImportRejected.reason` (unsupported container with platform copy, permission denied, disk
//    full, …).
// 3. Cancel: stops the job through [ImportCancellation]; the job deletes partial copies (the
//    store copies through `.part` files, and a cancelled new project is deleted as a whole) and
//    reports the remaining items as cancelled. System back while importing cancels too.
// 4. A result summary (all added, some added, nothing added, cancelled) with Done / Open project /
//    Back. The "copied into Danaview" hint shows only for iOS Photos picks (D-13).
//
// What an import does is an [ImportJob]: this file provides [sessionImportJob] (an open session)
// and [createProjectImportJob] (`ProjectRepository.create(fromMedia)`, the player's Edit); the New
// project sheet provides its own (format choice).

import 'dart:async';

import 'package:flutter/material.dart' show Icons, Theme;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/model.dart' show MediaAsset, MediaKind, MediaOrigin, PickedMedia, ProjectId;
import 'package:danaview_editor_core/ops.dart' show EditSession;
import 'package:danaview_editor_core/store.dart';
import 'package:danaview_features/storage.dart' show formatDataSize;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../app/editor_providers.dart';
import '../../app/strings/import_strings.dart';

// =================================================================================================
// Job contract
// =================================================================================================

/// What one picked item is doing.
enum ImportItemPhase {
  /// Waiting for its turn.
  waiting,

  /// Being probed (and fingerprinted) without a copy.
  checking,

  /// Being copied into the editor's storage.
  copying,

  /// Added to the project.
  done,

  /// Not added (see [ImportItemResult.reason]).
  failed,

  /// Not added because the import was cancelled.
  cancelled,
}

/// Cancellation shared by the import sheet and a running [ImportJob].
final class ImportCancellation {
  bool _cancelled = false;
  final Completer<void> _completer = Completer<void>();
  final List<VoidCallback> _listeners = [];

  /// Whether Cancel was pressed.
  bool get isCancelled => _cancelled;

  /// Completes when Cancel is pressed.
  Future<void> get whenCancelled => _completer.future;

  /// Requests cancellation (idempotent).
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _completer.complete();
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }

  /// Calls [listener] when cancelled.
  void addListener(VoidCallback listener) => _listeners.add(listener);

  /// Stops calling [listener].
  void removeListener(VoidCallback listener) => _listeners.remove(listener);
}

/// What happened to one picked item.
@immutable
final class ImportItemResult {
  /// The item was added ([asset] is the pool asset when the job knows it).
  const ImportItemResult.added({this.asset, this.reused = false})
      : phase = ImportItemPhase.done,
        reason = null;

  /// The item was not added; [reason] is a stable `ImportRejected.reason` code.
  const ImportItemResult.failed(String this.reason)
      : phase = ImportItemPhase.failed,
        asset = null,
        reused = false;

  /// The item was not added because the import was cancelled.
  const ImportItemResult.cancelled()
      : phase = ImportItemPhase.cancelled,
        reason = 'cancelled',
        asset = null,
        reused = false;

  /// Maps a media pool outcome.
  factory ImportItemResult.of(ImportOutcome outcome) => switch (outcome) {
        ImportedMedia(:final asset, :final reused) => ImportItemResult.added(asset: asset, reused: reused),
        ImportRejected(reason: 'cancelled') => const ImportItemResult.cancelled(),
        ImportRejected(:final reason) => ImportItemResult.failed(reason),
      };

  /// [ImportItemPhase.done], [ImportItemPhase.failed] or [ImportItemPhase.cancelled].
  final ImportItemPhase phase;

  /// Why it was not added (`unsupported`, `containerUnsupportedIos`, `accessDenied`, `diskFull`,
  /// `cancelled`, …), or null.
  final String? reason;

  /// The pool asset, when known.
  final MediaAsset? asset;

  /// Whether an existing asset was reused.
  final bool reused;

  /// Whether the item was added.
  bool get added => phase == ImportItemPhase.done;
}

/// The result of an [ImportJob]: one entry per picked item, in order.
@immutable
final class ImportJobResult {
  /// Creates the result.
  ImportJobResult(List<ImportItemResult> items, {this.projectId}) : items = List.unmodifiable(items);

  /// Per item, in pick order.
  final List<ImportItemResult> items;

  /// The project the job created (new project, player's Edit), or null.
  final ProjectId? projectId;

  /// Items added.
  int get addedCount => items.where((i) => i.added).length;

  /// Items that failed.
  int get failedCount => items.where((i) => i.phase == ImportItemPhase.failed).length;

  /// Items cancelled.
  int get cancelledCount => items.where((i) => i.phase == ImportItemPhase.cancelled).length;

  /// Whether the import was cancelled.
  bool get cancelled => cancelledCount > 0;

  /// Whether every item was added.
  bool get allAdded => items.isNotEmpty && addedCount == items.length;
}

/// Reports progress of item [index]; [fraction] (0–1) when a copy knows its progress.
typedef ImportItemReporter = void Function(int index, ImportItemPhase phase, double? fraction);

/// Reports the final result of item [index] (its reason or asset) as soon as it is known.
typedef ImportResultReporter = void Function(int index, ImportItemResult result);

/// One run of an [ImportJob].
final class ImportRun {
  /// Creates a run of [picks]; [copies] are the indices the preflight expects to be copied.
  ImportRun({
    required List<PickedMedia> picks,
    Set<int> copies = const {},
    ImportCancellation? cancellation,
    ImportItemReporter? onReport,
    ImportResultReporter? onResult,
  })  : picks = List.unmodifiable(picks),
        copies = Set.unmodifiable(copies),
        cancellation = cancellation ?? ImportCancellation(),
        _onReport = onReport,
        _onResult = onResult;

  /// The picked items, in order.
  final List<PickedMedia> picks;

  /// Indices of the items that will be copied (the rest are moved or referenced).
  final Set<int> copies;

  /// Cancellation.
  final ImportCancellation cancellation;

  final ImportItemReporter? _onReport;
  final ImportResultReporter? _onResult;

  /// Whether Cancel was pressed.
  bool get isCancelled => cancellation.isCancelled;

  /// Reports item [index].
  void report(int index, ImportItemPhase phase, {double? fraction}) => _onReport?.call(index, phase, fraction);

  /// Reports the final [result] of item [index] (its phase, and its error or asset).
  void reportResult(int index, ImportItemResult result) {
    _onResult?.call(index, result);
    _onReport?.call(index, result.phase, null);
  }

  /// The in-progress phase of item [index]: copying when it will be copied, else checking.
  ImportItemPhase workingPhaseOf(int index) => copies.contains(index) ? ImportItemPhase.copying : ImportItemPhase.checking;
}

/// Runs an import for the sheet. A job must stop when [ImportRun.isCancelled] turns true, delete
/// the partial copy of the item in flight, report the remaining items as cancelled, and never
/// throw for a rejected item (only for a failure of the whole job).
typedef ImportJob = Future<ImportJobResult> Function(ImportRun run);

/// A media pool that can stop an item mid-copy: when the cancellation fires it stops the copy in
/// flight, deletes its partial file and reports the item as `cancelled`; it may report the copy's
/// progress. `FileMediaPoolService` (CORE-27) checks cancellation between items only, so an item
/// already copying finishes there (a cancelled new project is then deleted as a whole).
abstract interface class CancellableMediaImport {
  /// Imports [picked] like `MediaPoolService.import`, honouring [cancellation] during copies.
  Future<List<ImportOutcome>> importWithCancel(
    EditSession session,
    List<PickedMedia> picked, {
    required ImportCancellation cancellation,
    void Function(double fraction)? onCopyProgress,
  });
}

/// Imports item [index] of [run] through [pool], passing the cancellation (and, where the pool
/// supports it, copy progress) along.
Future<ImportOutcome> importOne(MediaPoolService pool, EditSession session, ImportRun run, int index) async {
  final picked = run.picks[index];
  final pick = [picked];
  final List<ImportOutcome> outcomes;
  if (pool case final CancellableMediaImport cancellable) {
    outcomes = await cancellable.importWithCancel(
      session,
      pick,
      cancellation: run.cancellation,
      onCopyProgress: (fraction) => run.report(index, ImportItemPhase.copying, fraction: fraction),
    );
  } else if (pool is FileMediaPoolService) {
    outcomes = await pool.import(session, pick, isCancelled: () => run.isCancelled);
  } else {
    outcomes = await pool.import(session, pick);
  }
  return outcomes.isEmpty ? ImportRejected(picked, 'io') : outcomes.first;
}

/// Imports into an open [session] (the editor's Media tool, external drops): items added before a
/// cancel stay in the bin (they are complete), the remaining ones are cancelled. [place] puts the
/// imported media on the timeline (UX-36 applies it through its controller), or null for bin only.
ImportJob sessionImportJob({
  required MediaPoolService pool,
  required EditSession session,
  void Function(List<ImportOutcome> outcomes)? place,
}) =>
    (run) async {
      final results = <ImportItemResult>[];
      final outcomes = <ImportOutcome>[];
      for (var i = 0; i < run.picks.length; i++) {
        if (run.isCancelled) {
          results.add(const ImportItemResult.cancelled());
          run.report(i, ImportItemPhase.cancelled);
          continue;
        }
        run.report(i, run.workingPhaseOf(i));
        final outcome = await importOne(pool, session, run, i);
        outcomes.add(outcome);
        final result = ImportItemResult.of(outcome);
        results.add(result);
        run.reportResult(i, result);
      }
      if (place != null && outcomes.any((o) => o is ImportedMedia)) place(outcomes);
      return ImportJobResult(results);
    };

/// Creates a project with `ProjectRepository.create(fromMedia)` (the player's Edit, UX-41). The
/// repository imports every item in one call, so items show their working phase until it returns.
/// A cancel deletes the created project (and with it every copy only it referenced).
ImportJob createProjectImportJob({required ProjectRepository repository, required FromMediaProjectSpec spec}) => (run) async {
      for (var i = 0; i < run.picks.length; i++) {
        run.report(i, run.workingPhaseOf(i));
      }
      try {
        final id = await repository.create(spec);
        if (run.isCancelled) {
          await discardCreatedProject(repository, id);
          for (var i = 0; i < run.picks.length; i++) {
            run.report(i, ImportItemPhase.cancelled);
          }
          return ImportJobResult([for (final _ in run.picks) const ImportItemResult.cancelled()]);
        }
        for (var i = 0; i < run.picks.length; i++) {
          run.report(i, ImportItemPhase.done);
        }
        return ImportJobResult([for (final _ in run.picks) const ImportItemResult.added()], projectId: id);
      } on ProjectCreateFailure catch (failure) {
        final results = [for (final o in failure.outcomes) ImportItemResult.of(o)];
        for (final (i, r) in results.indexed) {
          run.reportResult(i, r);
        }
        return ImportJobResult(results);
      }
    };

/// Closes and deletes a project an import created but must not keep (cancelled, nothing added).
/// Best effort: a failure is logged without paths.
Future<void> discardCreatedProject(ProjectRepository repository, ProjectId id) async {
  try {
    await repository.close(id);
  } on Object catch (e) {
    debugPrint('[Import] Close before discard failed: ${e.runtimeType}');
  }
  try {
    await repository.delete(id);
  } on Object catch (e) {
    debugPrint('[Import] Discarding the new project failed: ${e.runtimeType}');
  }
}

// =================================================================================================
// Free-space preflight
// =================================================================================================

/// The outcome of [ImportSpaceCheck.check].
@immutable
final class ImportSpaceVerdict {
  /// Creates the verdict.
  ImportSpaceVerdict({required Set<int> copies, required this.neededBytes, required this.freeBytes}) : copies = Set.unmodifiable(copies);

  /// Indices of the items that will be copied.
  final Set<int> copies;

  /// Bytes the copies need (known sizes only).
  final int neededBytes;

  /// Free bytes, or null when unknown (no refusal then).
  final int? freeBytes;

  /// Whether the copies fit with the 64 MB margin (ARCH §9.1).
  bool get fits {
    final free = freeBytes;
    return neededBytes == 0 || free == null || free >= neededBytes + ImportSpaceCheck.marginBytes;
  }
}

/// The free-space preflight of ARCH §9.1: size + 64 MB before any managed copy.
@immutable
final class ImportSpaceCheck {
  /// Creates a check from a free-space probe and a "will this item be copied" test.
  const ImportSpaceCheck({required this.freeBytes, required this.needsCopy});

  /// Free bytes on the volume of the editor's storage, or null when unknown.
  final Future<int?> Function() freeBytes;

  /// Whether [picked] will be copied (rather than moved or referenced).
  final Future<bool> Function(PickedMedia picked) needsCopy;

  /// Space kept free on top of the copies.
  static const int marginBytes = ImportPolicy.freeSpaceMarginBytes;

  /// The usual guess when the import policy is not available: drops that are not app-owned
  /// temporary copies are copied; everything else is moved (temporary copies) or referenced.
  static bool likelyCopied(PickedMedia picked) => !picked.isTemporaryCopy && picked.origin == MediaOrigin.drop;

  /// Whether the real [pool] copies [picked]: a managed copy of a file that is not an app-owned
  /// temporary copy, a project-owned file that is not temporary, or a URI grant once the grant
  /// budget is exhausted (D-13).
  static Future<bool> copiedBy(FileMediaPoolService pool, PickedMedia picked) async {
    final decision = pool.policy.decide(picked);
    return switch (decision.route) {
      ImportRoute.managedCopy || ImportRoute.projectLut || ImportRoute.projectRecording || ImportRoute.projectStill => !decision.temporary,
      ImportRoute.persistedGrant => ImportPolicy.grantBudgetExhausted(await pool.access.remainingGrantBudget()),
      ImportRoute.bookmark || ImportRoute.documentsReference || ImportRoute.fileReference => false,
    };
  }

  /// Decides which items are copied and whether they fit.
  Future<ImportSpaceVerdict> check(List<PickedMedia> picks) async {
    final copies = <int>{};
    var needed = 0;
    for (final (i, picked) in picks.indexed) {
      bool copied;
      try {
        copied = await needsCopy(picked);
      } on Object catch (e) {
        debugPrint('[Import] Copy decision failed: ${e.runtimeType}');
        copied = false;
      }
      if (!copied) continue;
      copies.add(i);
      needed += picked.sizeBytes ?? 0;
    }
    int? free;
    if (needed > 0) {
      try {
        free = await freeBytes();
      } on Object catch (e) {
        debugPrint('[Import] Free-space probe failed: ${e.runtimeType}');
      }
    }
    return ImportSpaceVerdict(copies: copies, neededBytes: needed, freeBytes: free);
  }
}

/// The preflight used by the import sheet: the engine's free-space probe on the editor's storage
/// and the import policy of the real media pool service (a guess for other services).
final importSpaceCheckProvider = Provider<ImportSpaceCheck>((ref) {
  final engine = ref.watch(editorEngineProvider);
  final pool = ref.watch(mediaPoolServiceProvider);
  if (pool is FileMediaPoolService) {
    return ImportSpaceCheck(
      freeBytes: () => engine.freeBytes(pool.roots.editorSupport),
      needsCopy: (picked) => ImportSpaceCheck.copiedBy(pool, picked),
    );
  }
  return ImportSpaceCheck(freeBytes: () => engine.freeBytes(''), needsCopy: (picked) async => ImportSpaceCheck.likelyCopied(picked));
}, name: 'importSpaceCheckProvider');

// =================================================================================================
// Sheet
// =================================================================================================

/// How the import sheet ended.
enum ImportSheetExit {
  /// The import ran; see [ImportSheetResult.job].
  finished,

  /// The user went back to the selection (New project sheet).
  back,

  /// The user closed it after a refusal or a failed job.
  closed,
}

/// The result of [ImportMediaSheet].
@immutable
final class ImportSheetResult {
  /// Creates the result.
  const ImportSheetResult(this.exit, {this.job});

  /// How it ended.
  final ImportSheetExit exit;

  /// The job's result when it ran.
  final ImportJobResult? job;

  /// The project the job created, if any.
  ProjectId? get projectId => job?.projectId;
}

/// Shows the import of [picks] by [job] in a modal sheet. Resolves when the sheet closes.
Future<ImportSheetResult?> showImportMediaSheet(
  BuildContext context, {
  required List<PickedMedia> picks,
  required ImportJob job,
  String title = ImportStrings.title,
  String finishLabel = ImportStrings.done,
  bool closeWhenAllAdded = true,
}) =>
    showDanaviewSheet<ImportSheetResult>(
      context,
      title: title,
      builder: (context) => ImportMediaSheet(
        picks: picks,
        job: job,
        finishLabel: finishLabel,
        closeWhenAllAdded: closeWhenAllAdded,
        onFinished: (result) => Navigator.of(context).pop(result),
      ),
    );

enum _Stage { preflight, refused, running, finished, failed }

/// Preflight, per-item progress, cancel and the result summary of an import (ux.md §5.3). The
/// import starts as soon as the widget is shown.
class ImportMediaSheet extends ConsumerStatefulWidget {
  /// Creates the sheet content.
  const ImportMediaSheet({
    super.key,
    required this.picks,
    required this.job,
    required this.onFinished,
    this.onBack,
    this.finishLabel = ImportStrings.done,
    this.closeWhenAllAdded = true,
  });

  /// The picked items, in order.
  final List<PickedMedia> picks;

  /// What the import does.
  final ImportJob job;

  /// Called once the user is done (or at once when everything was added and [closeWhenAllAdded]).
  final ValueChanged<ImportSheetResult> onFinished;

  /// Back to the selection (shown after a refusal, a failure or a cancel); null shows Close.
  final ValueChanged<ImportSheetResult>? onBack;

  /// The primary button after a successful import (`Done`, `Open project`).
  final String finishLabel;

  /// Whether a fully successful import finishes without showing the summary.
  final bool closeWhenAllAdded;

  @override
  ConsumerState<ImportMediaSheet> createState() => _ImportMediaSheetState();
}

class _ItemState {
  ImportItemPhase phase = ImportItemPhase.waiting;
  double? fraction;
  String? reason;
  MediaAsset? asset;
}

class _ImportMediaSheetState extends ConsumerState<ImportMediaSheet> {
  _Stage _stage = _Stage.preflight;
  ImportSpaceVerdict? _verdict;
  ImportCancellation? _cancellation;
  ImportJobResult? _result;
  late List<_ItemState> _items = [for (final _ in widget.picks) _ItemState()];
  bool _finishedOnce = false;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    // Leaving the sheet while it runs (route removed) stops the import.
    if (_stage == _Stage.running || _stage == _Stage.preflight) _cancellation?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    if (_stage != _Stage.preflight) {
      setState(() {
        _stage = _Stage.preflight;
        _items = [for (final _ in widget.picks) _ItemState()];
      });
    }
    final check = ref.read(importSpaceCheckProvider);
    final verdict = await check.check(widget.picks);
    if (!mounted) return;
    _verdict = verdict;
    if (!verdict.fits) {
      setState(() => _stage = _Stage.refused);
      return;
    }
    final cancellation = _cancellation = ImportCancellation();
    setState(() => _stage = _Stage.running);
    final run = ImportRun(
      picks: widget.picks,
      copies: verdict.copies,
      cancellation: cancellation,
      onReport: _onReport,
      onResult: _onResult,
    );
    try {
      final result = await widget.job(run);
      if (!mounted) return;
      for (final (i, item) in result.items.indexed) {
        if (i >= _items.length) break;
        _items[i]
          ..phase = item.phase
          ..reason = item.reason
          ..asset = item.asset
          ..fraction = null;
      }
      setState(() {
        _result = result;
        _stage = _Stage.finished;
      });
      if (widget.closeWhenAllAdded && result.allAdded && !cancellation.isCancelled) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _finish(ImportSheetExit.finished));
      }
    } on Object catch (e) {
      if (e is Error) debugPrint('[Import] Job error: ${e.runtimeType}');
      if (!mounted) return;
      setState(() => _stage = _Stage.failed);
    }
  }

  void _onReport(int index, ImportItemPhase phase, double? fraction) {
    if (!mounted || index < 0 || index >= _items.length) return;
    setState(() {
      _items[index]
        ..phase = phase
        ..fraction = fraction;
    });
  }

  void _onResult(int index, ImportItemResult result) {
    if (!mounted || index < 0 || index >= _items.length) return;
    _items[index]
      ..reason = result.reason
      ..asset = result.asset;
  }

  void _cancel() {
    final cancellation = _cancellation;
    if (cancellation == null || cancellation.isCancelled) return;
    setState(cancellation.cancel);
  }

  void _finish(ImportSheetExit exit) {
    if (_finishedOnce || !mounted) return;
    _finishedOnce = true;
    widget.onFinished(ImportSheetResult(exit, job: _result));
  }

  void _back() {
    if (_finishedOnce) return;
    final back = widget.onBack;
    if (back == null) {
      _finish(_result == null ? ImportSheetExit.closed : ImportSheetExit.finished);
      return;
    }
    _finishedOnce = true;
    back(ImportSheetResult(ImportSheetExit.back, job: _result));
  }

  bool get _busy => _stage == _Stage.preflight || _stage == _Stage.running;

  bool _showsPhotosHint(BuildContext context) =>
      Theme.of(context).platform == TargetPlatform.iOS && widget.picks.any((p) => p.origin == MediaOrigin.photos);

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_busy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _stage == _Stage.running) _cancel();
      },
      child: Column(
        key: const ValueKey('import-media-sheet'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(),
          if (_showsPhotosHint(context)) ...[
            const SizedBox(height: DanaviewSpacing.sm),
            const ImportPhotosHint(),
          ],
          if (_stage != _Stage.refused) ...[
            const SizedBox(height: DanaviewSpacing.md),
            DanaviewSurface(
              color: DanaviewColors.surface,
              padding: const EdgeInsets.symmetric(horizontal: DanaviewSpacing.md, vertical: DanaviewSpacing.xs),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (i, picked) in widget.picks.indexed)
                    ImportItemTile(
                      key: ValueKey('import-item-$i'),
                      picked: picked,
                      kind: _items[i].asset?.kind,
                      status: _statusOf(_items[i]),
                      statusColor: _colorOf(_items[i]),
                      progress: _progressOf(_items[i]),
                      trailing: _trailingOf(_items[i]),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: DanaviewSpacing.lg),
          _buttons(),
        ],
      ),
    );
  }

  Widget _header() {
    final (IconData icon, Color color, String title, String? message) = switch (_stage) {
      _Stage.preflight => (
          Icons.storage_rounded,
          DanaviewColors.primaryLight,
          ImportStrings.adding(widget.picks.length),
          ImportStrings.checkingSpace
        ),
      _Stage.running => (
          Icons.downloading_rounded,
          DanaviewColors.primaryLight,
          ImportStrings.adding(widget.picks.length),
          _cancellation?.isCancelled ?? false ? ImportStrings.cancelling : null,
        ),
      _Stage.refused => (
          Icons.sd_card_alert_rounded,
          DanaviewColors.warning,
          ImportStrings.spaceTitle,
          ImportStrings.spaceMessage(formatDataSize(_verdict?.neededBytes ?? 0), formatDataSize(_verdict?.freeBytes ?? 0)),
        ),
      _Stage.failed => (Icons.error_outline_rounded, DanaviewColors.errorLight, ImportStrings.failedTitle, ImportStrings.failedMessage),
      _Stage.finished => _summary(),
    };
    return Semantics(
      liveRegion: true,
      container: true,
      child: Row(
        key: const ValueKey('import-header'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DanaviewIconTile(icon, color: color, size: 40),
          const SizedBox(width: DanaviewSpacing.md),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: DanaviewTextStyles.headline.copyWith(fontWeight: FontWeight.w600)),
                if (message != null) ...[
                  const SizedBox(height: 2),
                  Text(message, style: DanaviewTextStyles.caption.copyWith(color: DanaviewColors.textSecondary, height: 1.35)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  (IconData, Color, String, String?) _summary() {
    final result = _result!;
    final total = result.items.length;
    if (result.cancelled) {
      return (
        Icons.cancel_outlined,
        DanaviewColors.textSecondary,
        ImportStrings.cancelledTitle,
        result.addedCount == 0 ? ImportStrings.cancelledNothingKept : ImportStrings.cancelledKept(result.addedCount),
      );
    }
    if (result.addedCount == 0) {
      return (Icons.error_outline_rounded, DanaviewColors.errorLight, ImportStrings.noneAdded, ImportStrings.noneAddedMessage);
    }
    if (result.allAdded) return (Icons.check_circle_rounded, DanaviewColors.success, ImportStrings.allAdded(total), null);
    return (
      Icons.check_circle_outline_rounded,
      DanaviewColors.warning,
      ImportStrings.someAdded(result.addedCount, total),
      ImportStrings.failedCount(result.failedCount),
    );
  }

  String _statusOf(_ItemState item) => switch (item.phase) {
        ImportItemPhase.waiting => ImportStrings.waiting,
        ImportItemPhase.checking => ImportStrings.checking,
        ImportItemPhase.copying =>
          item.fraction == null ? ImportStrings.copying : ImportStrings.copyingPercent((item.fraction!.clamp(0.0, 1.0) * 100).round()),
        ImportItemPhase.done => ImportStrings.added,
        ImportItemPhase.failed => ImportStrings.itemError(item.reason ?? 'io'),
        ImportItemPhase.cancelled => ImportStrings.cancelled,
      };

  Color _colorOf(_ItemState item) => switch (item.phase) {
        ImportItemPhase.failed => DanaviewColors.errorLight,
        ImportItemPhase.done => DanaviewColors.success,
        _ => DanaviewColors.textSecondary,
      };

  /// Progress bar value: null hides it; NaN means indeterminate.
  double? _progressOf(_ItemState item) => switch (item.phase) {
        ImportItemPhase.checking => double.nan,
        ImportItemPhase.copying => item.fraction ?? double.nan,
        _ => null,
      };

  Widget? _trailingOf(_ItemState item) => switch (item.phase) {
        ImportItemPhase.done => const Icon(Icons.check_circle_rounded, size: 20, color: DanaviewColors.success),
        ImportItemPhase.failed => const Icon(Icons.error_outline_rounded, size: 20, color: DanaviewColors.errorLight),
        ImportItemPhase.cancelled => const Icon(Icons.cancel_outlined, size: 20, color: DanaviewColors.textMuted),
        _ => null,
      };

  Widget _buttons() {
    final backLabel = widget.onBack != null ? ImportStrings.back : ImportStrings.close;
    switch (_stage) {
      case _Stage.preflight:
        return const SizedBox.shrink();
      case _Stage.running:
        final cancelling = _cancellation?.isCancelled ?? false;
        return DanaviewButtonBar(
          children: [
            DanaviewButton.secondary(
              key: const ValueKey('import-cancel'),
              label: cancelling ? ImportStrings.cancelling : ImportStrings.cancel,
              icon: Icons.close_rounded,
              onPressed: cancelling ? null : _cancel,
            ),
          ],
        );
      case _Stage.refused || _Stage.failed:
        return DanaviewButtonBar(
          children: [
            DanaviewButton.secondary(key: const ValueKey('import-back'), label: backLabel, onPressed: _back),
            DanaviewButton.primary(
                key: const ValueKey('import-retry'), label: ImportStrings.tryAgain, icon: Icons.refresh_rounded, onPressed: _start),
          ],
        );
      case _Stage.finished:
        final usable = _result!.addedCount > 0;
        return DanaviewButtonBar(
          children: [
            if (usable)
              DanaviewButton.primary(
                key: const ValueKey('import-finish'),
                label: widget.finishLabel,
                onPressed: () => _finish(ImportSheetExit.finished),
              )
            else
              DanaviewButton.secondary(key: const ValueKey('import-back'), label: backLabel, onPressed: _back),
          ],
        );
    }
  }
}

// =================================================================================================
// Shared pieces (also used by the New project sheet)
// =================================================================================================

/// The D-13 hint shown for iOS Photos picks: they are copied into Danaview.
class ImportPhotosHint extends StatelessWidget {
  /// Creates the hint.
  const ImportPhotosHint({super.key});

  @override
  Widget build(BuildContext context) => Row(
        key: const ValueKey('import-photos-hint'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(Icons.info_outline_rounded, size: 16, color: DanaviewColors.textSecondary),
          ),
          const SizedBox(width: DanaviewSpacing.sm),
          Expanded(
            child:
                Text(ImportStrings.photosCopyHint, style: DanaviewTextStyles.caption.copyWith(color: DanaviewColors.textSecondary, height: 1.35)),
          ),
        ],
      );
}

/// The icon of a picked item: from the imported asset's kind, else from the file name.
IconData importItemIcon(PickedMedia picked, [MediaKind? kind]) {
  final k = kind ?? guessMediaKind(picked.displayName);
  return switch (k) {
    MediaKind.video => Icons.movie_rounded,
    MediaKind.image || MediaKind.still => Icons.image_rounded,
    MediaKind.audio || MediaKind.recording => Icons.music_note_rounded,
    MediaKind.lut => Icons.palette_rounded,
    null => Icons.insert_drive_file_rounded,
  };
}

/// A guess of the kind of a file from its name (before it is probed), or null.
MediaKind? guessMediaKind(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return null;
  return switch (name.substring(dot + 1).toLowerCase()) {
    'mp4' || 'mov' || 'm4v' || 'mkv' || 'webm' || 'avi' || '3gp' || 'ts' || 'mts' => MediaKind.video,
    'jpg' || 'jpeg' || 'png' || 'heic' || 'heif' || 'webp' || 'gif' || 'bmp' => MediaKind.image,
    'mp3' || 'm4a' || 'aac' || 'wav' || 'flac' || 'ogg' || 'opus' || 'aif' || 'aiff' => MediaKind.audio,
    'cube' => MediaKind.lut,
    _ => null,
  };
}

/// One picked item: icon, name, a status line and an optional progress bar and trailing control.
class ImportItemTile extends StatelessWidget {
  /// Creates the tile. [progress]: null hides the bar, NaN shows it indeterminate.
  const ImportItemTile({
    super.key,
    required this.picked,
    required this.status,
    this.kind,
    this.statusColor = DanaviewColors.textSecondary,
    this.progress,
    this.trailing,
  });

  /// The item.
  final PickedMedia picked;

  /// Its kind when known (after import).
  final MediaKind? kind;

  /// Status or size line.
  final String status;

  /// Status colour.
  final Color statusColor;

  /// Progress (null: no bar; NaN: indeterminate; else 0–1).
  final double? progress;

  /// Trailing control (status icon, remove button).
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final p = progress;
    return Semantics(
      container: true,
      label: '${picked.displayName}. $status',
      excludeSemantics: trailing == null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: DanaviewSpacing.sm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ExcludeSemantics(child: DanaviewIconTile(importItemIcon(picked, kind), size: 36)),
            const SizedBox(width: DanaviewSpacing.md),
            Expanded(
              child: ExcludeSemantics(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(picked.displayName, maxLines: 1, overflow: TextOverflow.ellipsis, style: DanaviewTextStyles.body),
                    const SizedBox(height: 2),
                    Text(status, style: DanaviewTextStyles.caption.copyWith(color: statusColor, height: 1.3)),
                    if (p != null) ...[
                      const SizedBox(height: DanaviewSpacing.xs + 2),
                      DanaviewProgressBar(value: p.isNaN ? null : p.clamp(0.0, 1.0), height: 4),
                    ],
                  ],
                ),
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: DanaviewSpacing.sm),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }
}
