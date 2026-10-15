// OWNER: UX-38
//
// The interrupted Auto captions notice (ai.md §8.6, §11.5; ARCH §16.5). When the editor opens a
// project whose captions job was interrupted (the app was killed or the editor closed mid-job), the
// service keeps a job record for 7 days (`TranscriptionService.resumableFor`). This notice shows it:
//
//   "Auto captions were interrupted. Resume?"   [Discard] [Resume]
//
// * **Resume** re-runs the stored request through the Auto captions sheet (UX-37): the language,
//   quality, layout, scope and target of the interrupted run are put back and the job starts at
//   once. Finished units are cache hits and the unit in progress continues from its last checkpoint,
//   so only the rest is transcribed. When the request can't be read back the sheet opens prefilled
//   with the defaults and the user starts it.
// * **Discard** drops the record and its checkpoints; the notice does not come back.
//
// The notice is a plain widget (it renders nothing without a record), so the Captions tool or the
// editor screen can host it. [InterruptedCaptionsStore] wraps the parts of the service the contract
// does not name (reading the stored request, discarding a record).

import 'dart:async';

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_transcription/danaview_transcription.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../../app/editor_providers.dart';
import 'auto_captions_controller.dart';
import 'captions_progress_panel.dart' show CaptionsText;
import 'regenerate_sheet.dart' show showAutoCaptionsWith;

// -------------------------------------------------------------------------------------------------
// Copy
// -------------------------------------------------------------------------------------------------

/// Copy of the interrupted-job notice (ai.md §8.6). Plain, specific, with a next step (ARCH §19).
abstract final class InterruptedCaptionsStrings {
  /// Title.
  static const String title = 'Auto captions were interrupted. Resume?';

  /// Explanation with the share already done.
  static String message(double doneFraction) {
    final percent = (doneFraction.clamp(0, 1) * 100).round();
    return percent <= 0
        ? 'The work done so far is kept, so it continues where it stopped.'
        : '$percent% was done. That part is kept, so it continues where it stopped.';
  }

  /// Resume.
  static const String resume = 'Resume';

  /// Discard.
  static const String discard = 'Discard';

  /// Toast after Discard.
  static const String discarded = 'Interrupted captions discarded';

  /// Resume is unavailable (read-only or not ready yet).
  static const String notEditable = "This project can't be edited right now, so captions can't be resumed.";
}

// -------------------------------------------------------------------------------------------------
// Store
// -------------------------------------------------------------------------------------------------

/// Reads and discards interrupted captions jobs.
abstract interface class InterruptedCaptionsStore {
  /// The interrupted job of [project], or null (none, expired, discarded, or a job runs now).
  Future<ResumableTranscription?> pending(ProjectId project);

  /// The JSON form of the interrupted request (`encodeTranscriptionRequest`), or null when unknown.
  Future<Map<String, Object?>?> requestOf(ResumableTranscription job);

  /// Drops [job]: its record and checkpoints.
  Future<void> discard(ResumableTranscription job);
}

/// [InterruptedCaptionsStore] over a [TranscriptionService]. The stored request and Discard use the
/// real service's extras (`TranscriptionServiceImpl.resumableRequest` / `discardResumable`); with
/// any other service a discarded job is only hidden for the lifetime of this store.
final class ServiceInterruptedCaptionsStore implements InterruptedCaptionsStore {
  /// Creates the store over [service].
  ServiceInterruptedCaptionsStore(this.service);

  /// The service.
  final TranscriptionService service;

  final Set<String> _discarded = {};

  @override
  Future<ResumableTranscription?> pending(ProjectId project) async {
    if (service.activeJob != null) return null;
    final ResumableTranscription? record;
    try {
      record = await service.resumableFor(project);
    } on Object catch (e) {
      debugPrint('[Captions] Could not read interrupted jobs: ${e.runtimeType}');
      return null;
    }
    if (record == null || _discarded.contains(record.jobId)) return null;
    return record;
  }

  @override
  Future<Map<String, Object?>?> requestOf(ResumableTranscription job) async {
    final s = service;
    if (s is! TranscriptionServiceImpl) return null;
    try {
      return await s.resumableRequest(job.jobId);
    } on Object catch (e) {
      debugPrint('[Captions] Could not read the interrupted request: ${e.runtimeType}');
      return null;
    }
  }

  @override
  Future<void> discard(ResumableTranscription job) async {
    _discarded.add(job.jobId);
    final s = service;
    if (s is! TranscriptionServiceImpl) return;
    try {
      await s.discardResumable(job.jobId);
    } on Object catch (e) {
      debugPrint('[Captions] Could not discard the interrupted job: ${e.runtimeType}');
    }
  }
}

/// The interrupted-job store (overridable in tests).
final interruptedCaptionsStoreProvider = Provider<InterruptedCaptionsStore>(
  (ref) => ServiceInterruptedCaptionsStore(ref.watch(transcriptionServiceProvider)),
  name: 'interruptedCaptionsStoreProvider',
);

// -------------------------------------------------------------------------------------------------
// Request → draft
// -------------------------------------------------------------------------------------------------

/// What the stored request of an interrupted job says, in the terms of the Auto captions sheet.
@immutable
final class InterruptedRequest {
  /// Creates the decoded request.
  const InterruptedRequest({
    required this.scope,
    required this.language,
    required this.tier,
    required this.segmentation,
    required this.includeSoundDescriptions,
    required this.replaceTrack,
  });

  /// Decodes `encodeTranscriptionRequest` JSON; null when it is not readable.
  static InterruptedRequest? decode(Map<String, Object?> json) {
    try {
      final lang = json['language'];
      final model = SpeechModelCatalog.byId(json['model']! as String);
      if (model == null || lang is! String) return null;
      final seg = (json['segmentation'] as Map?)?.cast<String, Object?>() ?? const {};
      final preset = SegmentationPreset.values.where((p) => p.name == seg['preset']).firstOrNull ?? SegmentationPreset.standard;
      final scopeJson = (json['scope']! as Map).cast<String, Object?>();
      List<String> strings(Object? v) => v == null ? const [] : [for (final e in v as List) e as String];
      final TranscriptionScope scope = switch (scopeJson['kind']) {
        'clip' => ClipScope(ItemId(scopeJson['item']! as String)),
        'items' => ItemsScope({for (final i in strings(scopeJson['items'])) ItemId(i)}),
        _ => TimelineScope(
            tracks: scopeJson['tracks'] == null ? null : {for (final t in strings(scopeJson['tracks'])) TrackId(t)},
            range: scopeJson['startUs'] == null ? null : TimeRange(scopeJson['startUs']! as int, scopeJson['endUs']! as int),
          ),
      };
      final target = (json['target'] as Map?)?.cast<String, Object?>() ?? const {'kind': 'new'};
      final kind = target['kind'];
      return InterruptedRequest(
        scope: scope,
        language: lang == 'auto' ? const AutoLanguage() : FixedLanguage(lang),
        tier: model.tier,
        segmentation: SegmentationSettings(
          preset: preset,
          maxLines: (seg['maxLines'] as num?)?.toInt() ?? 0,
          maxCharsPerLine: (seg['maxCharsPerLine'] as num?)?.toInt() ?? 0,
          maxCharsPerSecond: (seg['maxCps'] as num?)?.toDouble() ?? 0,
        ),
        includeSoundDescriptions: json['sounds'] == true,
        replaceTrack: kind == 'replace' || kind == 'replaceInRange' ? TrackId(target['track']! as String) : null,
      );
    } on Object {
      return null;
    }
  }

  /// What was captioned.
  final TranscriptionScope scope;

  /// Spoken language.
  final SpokenLanguage language;

  /// Quality tier.
  final SpeechModelTier tier;

  /// Layout.
  final SegmentationSettings segmentation;

  /// Sound descriptions.
  final bool includeSoundDescriptions;

  /// The generated lane it replaces, or null for a new track.
  final TrackId? replaceTrack;

  /// [draft] with this request's choices. [project] maps a track-limited timeline scope onto the
  /// sheet's Advanced audio switches.
  AutoCaptionsDraft applyTo(AutoCaptionsDraft draft, EditProject? project) {
    var excluded = draft.excludedTracks;
    var music = draft.includedMusic;
    final s = scope;
    if (s is TimelineScope && s.tracks != null && project != null) {
      excluded = {};
      music = {};
      for (final t in project.tracks) {
        if (t.kind != TrackKind.video && t.kind != TrackKind.audio) continue;
        final on = s.tracks!.contains(t.id);
        if (t.audioRole == AudioRole.music) {
          if (on) music.add(t.id);
        } else if (!on) {
          excluded.add(t.id);
        }
      }
    }
    return draft.copyWith(
      scope: s is TimelineScope ? CaptionsScopeKind.wholeVideo : CaptionsScopeKind.selection,
      language: language,
      tier: tier,
      segmentation: segmentation,
      includeSoundDescriptions: includeSoundDescriptions,
      replaceGenerated: replaceTrack != null,
      excludedTracks: excluded,
      includedMusic: music,
    );
  }
}

// -------------------------------------------------------------------------------------------------
// Notice
// -------------------------------------------------------------------------------------------------

/// "Auto captions were interrupted. Resume?" for [projectId] (or the enclosing editor's project).
/// Renders nothing when there is no interrupted job.
class InterruptedNotice extends ConsumerStatefulWidget {
  /// Creates the notice for [projectId].
  const InterruptedNotice({super.key, required this.projectId});

  /// The project.
  final ProjectId projectId;

  @override
  ConsumerState<InterruptedNotice> createState() => _InterruptedNoticeState();
}

class _InterruptedNoticeState extends ConsumerState<InterruptedNotice> {
  ResumableTranscription? _pending;
  bool _busy = false;
  int _token = 0;
  StreamSubscription<TranscriptionEvent>? _events;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    try {
      _events = ref.read(transcriptionServiceProvider).events.listen((e) {
        if (e is JobEnded || e is JobStarted) unawaited(_load());
      });
    } on Object {
      _events = null;
    }
  }

  @override
  void didUpdateWidget(InterruptedNotice oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.projectId != widget.projectId) unawaited(_load());
  }

  @override
  void dispose() {
    unawaited(_events?.cancel());
    super.dispose();
  }

  Future<void> _load() async {
    final token = ++_token;
    ResumableTranscription? pending;
    try {
      pending = await ref.read(interruptedCaptionsStoreProvider).pending(widget.projectId);
    } on Object {
      pending = null;
    }
    if (!mounted || token != _token) return;
    setState(() => _pending = pending);
  }

  Future<void> _discard(ResumableTranscription job) async {
    if (_busy) return;
    setState(() => _busy = true);
    await ref.read(interruptedCaptionsStoreProvider).discard(job);
    if (!mounted) return;
    _token++;
    setState(() {
      _busy = false;
      _pending = null;
    });
    DanaviewToast.show(context, InterruptedCaptionsStrings.discarded, icon: Icons.closed_caption_off_rounded);
  }

  Future<void> _resume(ResumableTranscription job) async {
    if (_busy) return;
    setState(() => _busy = true);
    final store = ref.read(interruptedCaptionsStoreProvider);
    final json = await store.requestOf(job);
    if (!mounted) return;
    final request = json == null ? null : InterruptedRequest.decode(json);
    _token++;
    setState(() {
      _busy = false;
      _pending = null;
    });
    final id = widget.projectId;
    final scope = request?.scope;
    await showAutoCaptionsWith(
      context,
      projectId: id,
      scope: scope is TimelineScope ? null : scope,
      replaceTrack: request?.replaceTrack,
      onConfigure: request == null
          ? null
          : (controller) {
              final project = ref.read(editorControllerProvider(id)).project;
              controller.update((d) => request.applyTo(d, project));
              unawaited(controller.start());
            },
    );
    if (mounted) unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    final job = _pending;
    if (job == null) return const SizedBox.shrink(key: ValueKey('captions-interrupted-none'));
    final editorState = ref.watch(editorControllerProvider(widget.projectId));
    final controller = ref.read(editorControllerProvider(widget.projectId).notifier);
    final editable = editorState.isReady && !controller.readOnly;
    return Semantics(
      container: true,
      liveRegion: true,
      child: DanaviewSurface(
        key: const ValueKey('captions-interrupted'),
        color: DanaviewColors.surface,
        borderColor: DanaviewColors.hairline,
        padding: const EdgeInsets.all(DanaviewSpacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const DanaviewTileIcon(Icons.closed_caption_rounded, size: 36, color: DanaviewColors.warning),
                const SizedBox(width: DanaviewSpacing.md),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Semantics(
                        header: true,
                        child: Text(InterruptedCaptionsStrings.title, key: const ValueKey('captions-interrupted-title'), style: CaptionsText.body.copyWith(fontWeight: FontWeight.w600)),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        editable ? InterruptedCaptionsStrings.message(job.doneFraction) : InterruptedCaptionsStrings.notEditable,
                        key: const ValueKey('captions-interrupted-message'),
                        style: CaptionsText.caption,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: DanaviewSpacing.md),
            DanaviewButtonBar(
              children: [
                DanaviewButton.secondary(
                  key: const ValueKey('captions-interrupted-discard'),
                  label: InterruptedCaptionsStrings.discard,
                  onPressed: _busy ? null : () => unawaited(_discard(job)),
                ),
                DanaviewButton.primary(
                  key: const ValueKey('captions-interrupted-resume'),
                  label: InterruptedCaptionsStrings.resume,
                  onPressed: (_busy || !editable) ? null : () => unawaited(_resume(job)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
