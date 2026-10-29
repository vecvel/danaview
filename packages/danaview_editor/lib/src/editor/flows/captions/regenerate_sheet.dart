// OWNER: UX-38
//
// "Regenerate captions" (ai.md §10.3, ux.md §12.3), opened from the subtitle track menu of a
// generated lane (`regenerateCaptions`, offered when the lane has `CaptionProvenance`):
//
// * **Re-split** (instant): the words already recognised are laid out again with a new layout
//   (`TranscriptionService.resegment` over the cached transcripts named by the provenance), then
//   applied as ONE history entry (`ReplaceGeneratedCaptions`). When a cached transcript is gone
//   (evicted, media changed) the flow falls back to "Transcribe again": the Auto captions sheet
//   starts at once with the new layout, and the units still cached are free.
// * **Transcribe again**: the Auto captions sheet, prefilled from the provenance (language, tier,
//   layout, "This clip" scope), replacing this lane.
// * **Edited cues**: when any cue of the target was edited after generation (or added by hand) the
//   user confirms first: "Replace" or "Add as new track" (`AddGeneratedCaptionTrack`). Undo restores
//   everything in one step either way.
// * **Target**: the whole lane, or — when the provenance was scoped to clips or a range — only the
//   cues overlapping those clips' current range (`ReplaceGeneratedCaptions(range:)`); cues elsewhere
//   stay.
//
// The logic lives in [CaptionRegenerator] (no widgets) so it can be measured: a re-split of 30 min
// of speech applies in well under 300 ms with the fake service.

import 'dart:async';

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show AddGeneratedCaptionTrack, EditRejection, ReplaceGeneratedCaptions, TrackLocked;
import 'package:danaview_transcription/danaview_transcription.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../../app/editor_providers.dart';
import '../../../app/strings/captions_strings.dart';
import '../../state/editor_controller.dart';
import '../../state/editor_state.dart';
import 'auto_captions_controller.dart';
import 'auto_captions_sheet.dart';
import 'captions_progress_panel.dart' show CaptionsText;

// -------------------------------------------------------------------------------------------------
// Copy
// -------------------------------------------------------------------------------------------------

/// Copy of the Regenerate sheet (ai.md §10.3). Plain, specific, with a next step (ARCH §19).
abstract final class RegenerateStrings {
  /// Sheet title (also the track-menu row).
  static const String title = 'Regenerate captions';

  /// Mode: re-split.
  static const String resplit = 'Re-split';

  /// Re-split explanation.
  static const String resplitHint = 'Instant. Uses the words already recognised with a new layout.';

  /// Mode: transcribe again.
  static const String transcribe = 'Transcribe again';

  /// Transcribe-again explanation.
  static const String transcribeHint = 'Listens again. You can change the language or quality.';

  /// Layout label.
  static const String layout = 'Layout';

  /// Primary button for re-split.
  static const String resplitAction = 'Re-split captions';

  /// Primary button while re-splitting.
  static const String resplitting = 'Re-splitting…';

  /// Primary button for transcribe again.
  static const String continueAction = 'Continue';

  /// Cancel.
  static const String cancel = 'Cancel';

  /// Close (nothing to regenerate).
  static const String close = 'Close';

  /// The lane is gone or was not generated.
  static const String notGenerated = "These captions weren't created with Auto captions, so they can't be regenerated.";

  /// Summary of the earlier run: "Spanish · Fast · 2 Oct 2026".
  static String summary(CaptionProvenance p) {
    final spec = SpeechModelCatalog.byId(p.modelId);
    return [
      CaptionsStrings.languageName(p.language),
      if (spec != null) CaptionsStrings.tierName(spec.tier),
      date(p.generatedAt.toLocal()),
    ].join(' · ');
  }

  /// What is replaced.
  static String scope(TimeRange? range) =>
      range == null ? 'Replaces every caption on this track.' : 'Replaces the captions from ${clock(range.start)} to ${clock(range.end)}. Captions elsewhere stay.';

  /// The edited-cues confirmation title (ai.md §10.3).
  static String editedTitle(int count) => count == 1 ? '1 caption was edited. Replace it?' : '$count captions were edited. Replace them?';

  /// The edited-cues confirmation message.
  static const String editedMessage = 'Replacing removes those changes. You can undo it in one step.';

  /// Edited-cues: keep the lane and add the new captions as another track.
  static const String addAsNewTrack = 'Add as new track';

  /// Edited-cues: replace.
  static const String replace = 'Replace';

  /// The lane is locked (TrackLocked).
  static const String locked = 'Unlock the track to replace its captions.';

  /// The project can't be edited right now.
  static const String notEditable = "This project can't be edited right now.";

  /// The re-split produced nothing.
  static const String nothing = 'No captions came out of the re-split. Try Transcribe again.';

  /// Something else refused the change.
  static const String notApplied = "The captions couldn't be replaced. Your project didn't change.";

  /// Toast after a re-split.
  static String done(int cues, {required bool newTrack}) {
    final n = cues == 1 ? '1 caption' : '$cues captions';
    return newTrack ? 'Added $n as a new track' : 'Re-split into $n';
  }

  /// `m:ss` (or `h:mm:ss`).
  static String clock(TimeUs t) {
    final total = (t / microsPerSecond).round();
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = (total % 60).toString().padLeft(2, '0');
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
  }

  static const List<String> _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  /// `2 Oct 2026`.
  static String date(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';
}

// -------------------------------------------------------------------------------------------------
// Logic
// -------------------------------------------------------------------------------------------------

/// What a regenerate replaces.
@immutable
final class RegenerateTarget {
  /// Creates the target.
  const RegenerateTarget({
    required this.track,
    required this.trackName,
    required this.provenance,
    required this.range,
    required this.cueCount,
    required this.editedCount,
    required this.locked,
  });

  /// The generated lane.
  final TrackId track;

  /// Its name.
  final String trackName;

  /// How it was generated.
  final CaptionProvenance provenance;

  /// The replaced range, or null for the whole lane.
  final TimeRange? range;

  /// Cues the regenerate replaces.
  final int cueCount;

  /// Of those, cues the user edited after generation or added by hand.
  final int editedCount;

  /// Whether the lane is locked (the command is refused with TrackLocked).
  final bool locked;

  /// The scope of the earlier run as a request scope (preselects "This clip").
  TranscriptionScope get scope => transcriptionScopeOf(provenance.scope);
}

/// What a re-split did.
sealed class RegenerateOutcome {
  const RegenerateOutcome();
}

/// The new captions were applied as one history entry.
final class RegenerateApplied extends RegenerateOutcome {
  /// Creates the outcome.
  const RegenerateApplied(this.cues, {required this.newTrack});

  /// Cues in the result.
  final int cues;

  /// Added as a new track instead of replacing.
  final bool newTrack;
}

/// Some cached transcripts are gone: transcribe again (ai.md §10.3).
final class RegenerateNeedsTranscription extends RegenerateOutcome {
  /// Creates the outcome.
  const RegenerateNeedsTranscription(this.missingUnits);

  /// Units without a cached transcript.
  final int missingUnits;
}

/// Nothing changed; [message] says why.
final class RegenerateRefused extends RegenerateOutcome {
  /// Creates the outcome.
  const RegenerateRefused(this.message, {this.rejection, this.failure});

  /// User copy.
  final String message;

  /// The editor's rejection, if any.
  final EditRejection? rejection;

  /// The service's failure, if any.
  final TranscriptionFailure? failure;
}

/// Regenerate logic without widgets (ai.md §10.3).
class CaptionRegenerator {
  /// Creates the regenerator over [service] for [editor]. [state] reads the editor's state (usually
  /// `ref.read(editorControllerProvider(id))`); [timeline] reads the committed project.
  CaptionRegenerator({
    required TranscriptionService service,
    required EditorController editor,
    required EditorState Function() state,
    required TimelineView Function() timeline,
    DateTime Function()? clock,
  })  : _service = service,
        _editor = editor,
        _state = state,
        _timeline = timeline,
        _clock = clock ?? DateTime.now;

  final TranscriptionService _service;
  final EditorController _editor;
  final EditorState Function() _state;
  final TimelineView Function() _timeline;
  final DateTime Function() _clock;

  /// The target of regenerating [track], or null when it is not a generated subtitle lane.
  RegenerateTarget? targetOf(TrackId track) {
    final project = _state().project;
    if (project == null) return null;
    Track? lane;
    for (final t in project.tracks) {
      if (t.id == track) lane = t;
    }
    final provenance = lane?.subtitle?.provenance;
    if (lane == null || lane.kind != TrackKind.subtitle || provenance == null) return null;
    final range = rangeOf(project, provenance.scope);
    var count = 0;
    var edited = 0;
    for (final item in lane.items) {
      if (range != null && !(item.start < range.end && range.start < item.start + item.duration)) continue;
      count++;
      if (item is SubtitleCue && (item.editedAfterGeneration || item.origin != CueOrigin.generated)) edited++;
    }
    return RegenerateTarget(
      track: lane.id,
      trackName: lane.name,
      provenance: provenance,
      range: range,
      cueCount: count,
      editedCount: edited,
      locked: lane.locked,
    );
  }

  /// The timeline range a run of [scope] covers now: the union of the scoped clips' current
  /// ranges, the scoped range, or null for the whole lane.
  static TimeRange? rangeOf(EditProject project, CaptionScopeData scope) {
    if (scope.clips.isEmpty) return scope.range;
    TimeRange? out;
    for (final id in scope.clips) {
      final item = project.index.locate(id)?.item;
      if (item == null) continue;
      final r = TimeRange(item.start, item.start + item.duration);
      out = out == null ? r : TimeRange(out.start < r.start ? out.start : r.start, out.end > r.end ? out.end : r.end);
    }
    return out ?? scope.range;
  }

  /// Re-splits [target] with [settings] from the cached transcripts and applies the result as one
  /// history entry: replacing the target, or as a new track when [asNewTrack].
  Future<RegenerateOutcome> resplit(RegenerateTarget target, SegmentationSettings settings, {bool asNewTrack = false}) async {
    if (!_editor.canEdit || _editor.readOnly) return const RegenerateRefused(RegenerateStrings.notEditable);
    final List<SubtitleCueDraft> drafts;
    try {
      drafts = await _service.resegment(target.provenance, settings, _timeline());
    } on CachedTranscriptsMissing catch (e) {
      return RegenerateNeedsTranscription(e.units);
    } on TranscriptionFailure catch (f) {
      return RegenerateRefused(CaptionsStrings.failure(f)?.message ?? RegenerateStrings.notApplied, failure: f);
    } on Object {
      return const RegenerateRefused(RegenerateStrings.notApplied);
    }
    if (drafts.isEmpty) return const RegenerateRefused(RegenerateStrings.nothing);
    final provenance = target.provenance.copyWith(segmentation: settings, generatedAt: _clock().toUtc());
    final result = _editor.apply(asNewTrack
        ? AddGeneratedCaptionTrack(
            trackName: CaptionsStrings.trackName(provenance.language),
            language: provenance.language,
            provenance: provenance,
            cues: drafts,
          )
        : ReplaceGeneratedCaptions(track: target.track, range: target.range, provenance: provenance, cues: drafts));
    return switch (result) {
      EditApplied() => RegenerateApplied(_cuesAfter(target, asNewTrack: asNewTrack, fallback: drafts.length), newTrack: asNewTrack),
      EditRejected(:final reason) => RegenerateRefused(reason is TrackLocked ? RegenerateStrings.locked : RegenerateStrings.notApplied, rejection: reason),
      EditUnchanged() => const RegenerateRefused(RegenerateStrings.notApplied),
    };
  }

  int _cuesAfter(RegenerateTarget target, {required bool asNewTrack, required int fallback}) {
    if (asNewTrack) return fallback;
    final after = targetOf(target.track);
    return after?.cueCount ?? fallback;
  }
}

// -------------------------------------------------------------------------------------------------
// Opening the Auto captions sheet with a follow-up step
// -------------------------------------------------------------------------------------------------

/// Shows the Auto captions sheet for [projectId] and, once its checks finish and it reaches the
/// configure step, runs [onConfigure] with the controller (once). Used by "Transcribe again", the
/// re-split fallback and "Resume" (UX-38). While a job already runs the sheet just shows it.
Future<void> showAutoCaptionsWith(
  BuildContext context, {
  required ProjectId projectId,
  TranscriptionScope? scope,
  CaptionProvenance? regenerateFrom,
  TrackId? replaceTrack,
  void Function(AutoCaptionsController controller)? onConfigure,
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final provider = autoCaptionsControllerProvider(projectId);
  ProviderSubscription<AutoCaptionsState>? sub;
  if (onConfigure != null) {
    var checking = false;
    sub = container.listen<AutoCaptionsState>(provider, (previous, next) {
      if (next.stage == AutoCaptionsStage.checking) {
        checking = true;
        return;
      }
      if (!checking) return;
      final s = sub;
      sub = null;
      s?.close();
      if (next.stage != AutoCaptionsStage.configure) return;
      final controller = container.read(provider.notifier);
      // Not inside the notifier's own notification.
      scheduleMicrotask(() {
        if (!controller.mounted) return;
        if (container.read(provider).stage != AutoCaptionsStage.configure) return;
        onConfigure(controller);
      });
    }, fireImmediately: true);
    // A fresh controller already sits at `checking` (its initial state), and opening it again does
    // not notify that stage: the immediate call above has recorded it.
  }
  try {
    await AutoCaptionsSheet.show(context, projectId: projectId, scope: scope, regenerateFrom: regenerateFrom, replaceTrack: replaceTrack);
  } finally {
    sub?.close();
  }
}

// -------------------------------------------------------------------------------------------------
// Sheet
// -------------------------------------------------------------------------------------------------

/// Regenerate mode.
enum RegenerateMode {
  /// Instant re-split from cached transcripts.
  resplit,

  /// A new transcription.
  transcribe,
}

/// What the sheet asks [RegenerateSheet.show] to do after it closed.
@immutable
final class _Followup {
  const _Followup({required this.target, this.segmentation, this.asNewTrack = false, this.autoStart = false});

  final RegenerateTarget target;

  /// The layout chosen (re-split fallback), or null to keep the provenance's.
  final SegmentationSettings? segmentation;
  final bool asNewTrack;
  final bool autoStart;
}

/// The Regenerate captions sheet (ai.md §10.3).
class RegenerateSheet extends ConsumerStatefulWidget {
  /// Creates the sheet content for lane [track] of [projectId]; use [show] to present it.
  const RegenerateSheet({super.key, required this.projectId, required this.track, this.onFollowup});

  /// The project.
  final ProjectId projectId;

  /// The generated lane.
  final TrackId track;

  /// Receives the step to run after the sheet closed ([show] sets it).
  final void Function(Object followup)? onFollowup;

  /// Shows the sheet for lane [track]; "Transcribe again" (and a re-split without cached
  /// transcripts) continues in the Auto captions sheet.
  static Future<void> show(BuildContext context, {required ProjectId projectId, required TrackId track}) async {
    _Followup? next;
    await showDanaviewSheet<void>(
      context,
      title: RegenerateStrings.title,
      builder: (_) => RegenerateSheet(projectId: projectId, track: track, onFollowup: (f) => next = f as _Followup),
    );
    final f = next;
    if (f == null || !context.mounted) return;
    final provenance = f.segmentation == null ? f.target.provenance : f.target.provenance.copyWith(segmentation: f.segmentation);
    final scope = f.target.scope;
    await showAutoCaptionsWith(
      context,
      projectId: projectId,
      scope: scope is TimelineScope ? null : scope,
      regenerateFrom: provenance,
      replaceTrack: f.target.track,
      onConfigure: (!f.asNewTrack && !f.autoStart)
          ? null
          : (controller) {
              if (f.asNewTrack) controller.update((d) => d.copyWith(replaceGenerated: false));
              if (f.autoStart) unawaited(controller.start());
            },
    );
  }

  @override
  ConsumerState<RegenerateSheet> createState() => _RegenerateSheetState();
}

class _RegenerateSheetState extends ConsumerState<RegenerateSheet> {
  RegenerateMode _mode = RegenerateMode.resplit;
  SegmentationPreset? _preset;
  bool _working = false;
  String? _error;

  CaptionRegenerator _regenerator() {
    final id = widget.projectId;
    final session = ref.read(editorSessionProvider(id));
    final engine = ref.read(editorEngineProvider);
    return CaptionRegenerator(
      service: ref.read(transcriptionServiceProvider),
      editor: ref.read(editorControllerProvider(id).notifier),
      state: () => ref.read(editorControllerProvider(id)),
      timeline: () => DomainTimelineView(session.committedProject!, access: engine.access),
    );
  }

  void _close() {
    if (mounted) Navigator.of(context).maybePop();
  }

  void _followup(_Followup f) {
    widget.onFollowup?.call(f);
    _close();
  }

  /// Asks about edited cues; null = cancelled, true = add as new track, false = replace.
  Future<bool?> _confirmEdited(int count) => showDanaviewDialog<bool>(
        context,
        builder: (dialogContext) => DanaviewDialog(
          icon: Icons.edit_note_rounded,
          title: RegenerateStrings.editedTitle(count),
          message: RegenerateStrings.editedMessage,
          actions: [
            DanaviewButton.secondary(
              key: const ValueKey('regenerate-edited-new'),
              label: RegenerateStrings.addAsNewTrack,
              onPressed: () => Navigator.of(dialogContext).pop(true),
            ),
            DanaviewButton.primary(
              key: const ValueKey('regenerate-edited-replace'),
              label: RegenerateStrings.replace,
              onPressed: () => Navigator.of(dialogContext).pop(false),
            ),
          ],
        ),
      );

  Future<void> _apply(RegenerateTarget target) async {
    if (_working) return;
    var asNewTrack = false;
    if (target.editedCount > 0) {
      final choice = await _confirmEdited(target.editedCount);
      if (choice == null || !mounted) return;
      asNewTrack = choice;
    }
    if (_mode == RegenerateMode.transcribe) {
      _followup(_Followup(target: target, asNewTrack: asNewTrack));
      return;
    }
    final settings = target.provenance.segmentation.copyWith(preset: _preset ?? target.provenance.segmentation.preset);
    setState(() {
      _working = true;
      _error = null;
    });
    final outcome = await _regenerator().resplit(target, settings, asNewTrack: asNewTrack);
    if (!mounted) return;
    switch (outcome) {
      case RegenerateApplied(:final cues, :final newTrack):
        DanaviewToast.show(context, RegenerateStrings.done(cues, newTrack: newTrack), kind: DanaviewToastKind.success, icon: Icons.closed_caption_rounded);
        _close();
      case RegenerateNeedsTranscription():
        _followup(_Followup(target: target, segmentation: settings, asNewTrack: asNewTrack, autoStart: true));
      case RegenerateRefused(:final message):
        setState(() {
          _working = false;
          _error = message;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.projectId;
    final editorState = ref.watch(editorControllerProvider(id));
    final controller = ref.read(editorControllerProvider(id).notifier);
    final target = editorState.project == null ? null : _regenerator().targetOf(widget.track);
    if (target == null) {
      return Column(
        key: const ValueKey('regenerate-sheet'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(RegenerateStrings.notGenerated, key: const ValueKey('regenerate-not-generated'), style: CaptionsText.body),
          const SizedBox(height: DanaviewSpacing.lg),
          DanaviewButtonBar(children: [DanaviewButton.secondary(key: const ValueKey('regenerate-cancel'), label: RegenerateStrings.close, onPressed: _close)]),
        ],
      );
    }
    final preset = _preset ?? target.provenance.segmentation.preset;
    final editable = controller.canEdit && !controller.readOnly;
    final resplit = _mode == RegenerateMode.resplit;
    return Semantics(
      container: true,
      label: RegenerateStrings.title,
      child: Column(
        key: const ValueKey('regenerate-sheet'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(target.trackName, key: const ValueKey('regenerate-track'), maxLines: 1, overflow: TextOverflow.ellipsis, style: CaptionsText.headline),
          const SizedBox(height: 2),
          Text(RegenerateStrings.summary(target.provenance), key: const ValueKey('regenerate-summary'), style: CaptionsText.caption),
          const SizedBox(height: DanaviewSpacing.md),
          _ModeTile(
            key: const ValueKey('regenerate-mode-resplit'),
            icon: Icons.view_agenda_rounded,
            title: RegenerateStrings.resplit,
            subtitle: RegenerateStrings.resplitHint,
            selected: resplit,
            onTap: _working ? null : () => setState(() => _mode = RegenerateMode.resplit),
          ),
          const SizedBox(height: DanaviewSpacing.xs),
          _ModeTile(
            key: const ValueKey('regenerate-mode-transcribe'),
            icon: Icons.hearing_rounded,
            title: RegenerateStrings.transcribe,
            subtitle: RegenerateStrings.transcribeHint,
            selected: !resplit,
            onTap: _working ? null : () => setState(() => _mode = RegenerateMode.transcribe),
          ),
          if (resplit) ...[
            const SizedBox(height: DanaviewSpacing.md),
            Text(RegenerateStrings.layout, style: CaptionsText.section),
            const SizedBox(height: DanaviewSpacing.xs),
            KeyedSubtree(
              key: const ValueKey('regenerate-layout'),
              child: DanaviewSegmentedControl<SegmentationPreset>(
                value: preset,
                enabled: !_working,
                options: [
                  for (final p in SegmentationPreset.values) DanaviewOption(value: p, label: CaptionsStrings.presetName(p)),
                ],
                onChanged: (p) => setState(() => _preset = p),
              ),
            ),
          ],
          const SizedBox(height: DanaviewSpacing.md),
          Text(RegenerateStrings.scope(target.range), key: const ValueKey('regenerate-scope'), style: CaptionsText.caption),
          if (_error case final error?) ...[
            const SizedBox(height: DanaviewSpacing.sm),
            Semantics(
              liveRegion: true,
              child: Text(error, key: const ValueKey('regenerate-error'), style: CaptionsText.caption.copyWith(color: DanaviewColors.errorLight)),
            ),
          ],
          const SizedBox(height: DanaviewSpacing.lg),
          DanaviewButtonBar(
            children: [
              DanaviewButton.secondary(key: const ValueKey('regenerate-cancel'), label: RegenerateStrings.cancel, onPressed: _working ? null : _close),
              DanaviewButton.primary(
                key: const ValueKey('regenerate-apply'),
                label: resplit ? (_working ? RegenerateStrings.resplitting : RegenerateStrings.resplitAction) : RegenerateStrings.continueAction,
                onPressed: (!editable || _working) ? null : () => unawaited(_apply(target)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ModeTile extends StatelessWidget {
  const _ModeTile({super.key, required this.icon, required this.title, required this.subtitle, required this.selected, required this.onTap});

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => DanaviewSurface(
        color: DanaviewColors.surface,
        child: DanaviewListTile(
          leading: DanaviewIconTile(icon, size: 36, color: selected ? DanaviewColors.primaryLight : DanaviewColors.textSecondary),
          title: title,
          subtitle: subtitle,
          subtitleMaxLines: 3,
          selected: selected,
          toggled: selected,
          enabled: onTap != null,
          onTap: onTap,
          trailing: selected ? const Icon(Icons.check_rounded, size: 20, color: DanaviewColors.primaryLight) : null,
        ),
      );
}
