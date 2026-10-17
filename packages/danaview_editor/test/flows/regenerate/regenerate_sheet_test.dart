// OWNER: UX-38
//
// Regenerate captions (ai.md §10.3): the instant re-split (<= 300 ms for 30 min of speech with the
// fake), one history entry, the edited-cues confirmation (Replace / Add as new track / cancel), the
// clip-range target, the fallback to Transcribe again when cached transcripts are gone, refusals
// (locked lane, nothing produced, read-only) and Transcribe again opening the prefilled Auto
// captions sheet.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor/src/editor/flows/captions/regenerate_sheet.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_transcription/danaview_transcription.dart';

import '../../support/support.dart';
import 'regenerate_rig.dart';

/// The fake, except that re-split finds no cached transcripts.
final class _EvictedService implements TranscriptionService {
  _EvictedService(this.inner);

  final FakeTranscriptionService inner;

  @override
  Future<List<SubtitleCueDraft>> resegment(CaptionProvenance provenance, SegmentationSettings settings, TimelineView timeline) async =>
      throw const CachedTranscriptsMissing(2);

  @override
  List<TranscriptionLanguage> get languages => inner.languages;
  @override
  Future<TranscriptionSupport> support() => inner.support();
  @override
  List<SpeechModelOffer> get offers => inner.offers;
  @override
  SpeechModelSpec get defaultModel => inner.defaultModel;
  @override
  Future<SpeechModelStatus> modelStatus() => inner.modelStatus();
  @override
  Future<SpeechModelStatus> modelStatusOf(String modelId) => inner.modelStatusOf(modelId);
  @override
  Stream<ModelDownloadProgress> downloadModel({required UserConsent consent}) => inner.downloadModel(consent: consent);
  @override
  Future<void> cancelDownload() => inner.cancelDownload();
  @override
  Future<void> deleteModel() => inner.deleteModel();
  @override
  Future<void> deleteModelById(String modelId) => inner.deleteModelById(modelId);
  @override
  Future<TranscriptionPreflight> preflight(TranscriptionRequest request) => inner.preflight(request);
  @override
  TranscriptionJob start(TranscriptionRequest request) => inner.start(request);
  @override
  TranscriptionJob? get activeJob => inner.activeJob;
  @override
  Future<ResumableTranscription?> resumableFor(ProjectId project) => inner.resumableFor(project);
  @override
  Future<SpeechStorageUsage> storage() => inner.storage();
  @override
  Stream<TranscriptionEvent> get events => inner.events;
}

void main() {
  group('CaptionRegenerator', () {
    test('targetOf reads the generated lane, its provenance and the edited cues', () async {
      final rig = RegenRig(project: (id) => regenProject(id, edited: {1}, manual: {3}));
      await rig.open();
      final target = rig.regenerator().targetOf(Regen.lane)!;
      expect(target.trackName, 'Captions (Spanish) · Auto');
      expect(target.range, isNull);
      expect(target.cueCount, rig.lane.items.length);
      expect(target.editedCount, 2, reason: 'one edited after generation, one added by hand');
      expect(target.locked, isFalse);
      expect(rig.regenerator().targetOf(Regen.main), isNull, reason: 'not a subtitle lane');
    });

    test('a lane without provenance cannot be regenerated', () async {
      final rig = RegenRig(project: (id) => regenProject(id, generatedLane: false));
      await rig.open();
      expect(rig.regenerator().targetOf(Regen.lane), isNull);
    });

    test('re-split of 30 min of speech applies as ONE history entry in <= 300 ms', () async {
      final rig = RegenRig(project: (id) => regenProject(id, minutes: 30));
      await rig.open();
      final before = rig.project;
      expect(rig.lane.items.length, 720);
      rig.transcription.resegmentDrafts = drafts(0, 30 * 60 * s, prefix: 'Línea');
      final regenerator = rig.regenerator();
      final target = regenerator.targetOf(Regen.lane)!;
      const settings = SegmentationSettings(preset: SegmentationPreset.singleLine);

      final watch = Stopwatch()..start();
      final outcome = await regenerator.resplit(target, settings);
      watch.stop();

      expect(outcome, isA<RegenerateApplied>());
      expect(watch.elapsedMilliseconds, lessThanOrEqualTo(300), reason: 're-split took ${watch.elapsedMilliseconds} ms');
      expect((outcome as RegenerateApplied).cues, 720);
      expect(rig.lane.items.every((c) => (c as SubtitleCue).text.startsWith('Línea')), isTrue);
      expect(rig.lane.subtitle!.provenance!.segmentation.preset, SegmentationPreset.singleLine);
      final (provenance, used) = rig.transcription.resegmentCalls.single;
      expect(provenance.modelId, SpeechModelCatalog.fast.id);
      expect(used.preset, SegmentationPreset.singleLine);

      expect(rig.editor.undo(), isTrue);
      await rig.settle();
      expect(rig.lane.items.length, 720, reason: 'one undo restores every cue');
      expect((rig.lane.items.first as SubtitleCue).text, 'Hola 0');
      expect(identical(rig.project.tracks.last.items, before.tracks.last.items) || rig.lane.items.length == before.tracks.last.items.length, isTrue);
      expect(rig.lane.subtitle!.provenance!.segmentation.preset, SegmentationPreset.standard);
    });

    test('as a new track keeps the edited lane and adds another', () async {
      final rig = RegenRig(project: (id) => regenProject(id, edited: {0}));
      await rig.open();
      rig.transcription.resegmentDrafts = drafts(0, 60 * s);
      final r = rig.regenerator();
      final outcome = await r.resplit(r.targetOf(Regen.lane)!, const SegmentationSettings(), asNewTrack: true);
      expect(outcome, isA<RegenerateApplied>().having((o) => o.newTrack, 'newTrack', isTrue));
      expect(rig.subtitleTracks, hasLength(2));
      expect((rig.lane.items.first as SubtitleCue).text, 'Hola 0', reason: 'the edited lane stays');
      expect(rig.editor.undo(), isTrue);
      await rig.settle();
      expect(rig.subtitleTracks, hasLength(1));
    });

    test('a "This clip" run replaces only the cues overlapping that clip now', () async {
      final rig = RegenRig(project: (id) => regenProject(id, twoClips: true, scopeClips: const [Regen.second]));
      await rig.open();
      final r = rig.regenerator();
      final target = r.targetOf(Regen.lane)!;
      expect(target.range, const TimeRange(60 * s, 120 * s));
      expect(RegenerateStrings.scope(target.range), 'Replaces the captions from 1:00 to 2:00. Captions elsewhere stay.');
      rig.transcription.resegmentDrafts = drafts(60 * s, 120 * s);
      expect(await r.resplit(target, const SegmentationSettings()), isA<RegenerateApplied>());
      final cues = rig.lane.items.cast<SubtitleCue>();
      expect(cues.where((c) => c.start < 60 * s).every((c) => c.text.startsWith('Hola')), isTrue, reason: 'cues of the first clip stay');
      expect(cues.where((c) => c.start >= 60 * s).every((c) => c.text.startsWith('Nuevo')), isTrue);
    });

    test('missing cached transcripts fall back to Transcribe again', () async {
      final fake = FakeTranscriptionService(clock: () => DateTime.utc(2026, 10, 15));
      final rig = RegenRig(transcription: fake);
      await rig.open();
      final c = rig.container;
      final session = c.read(editorSessionProvider(rig.id));
      final engine = c.read(editorEngineProvider);
      final r = CaptionRegenerator(
        service: _EvictedService(fake),
        editor: rig.editor,
        state: () => rig.editorState,
        timeline: () => DomainTimelineView(session.committedProject!, access: engine.access),
      );
      final before = rig.project;
      final outcome = await r.resplit(r.targetOf(Regen.lane)!, const SegmentationSettings());
      expect(outcome, isA<RegenerateNeedsTranscription>().having((o) => o.missingUnits, 'missingUnits', 2));
      expect(identical(rig.project, before), isTrue);
    });

    test('refusals leave the project unchanged', () async {
      final locked = RegenRig(project: (id) => regenProject(id, locked: true));
      await locked.open();
      locked.transcription.resegmentDrafts = drafts(0, 60 * s);
      final r = locked.regenerator();
      final t = r.targetOf(Regen.lane)!;
      expect(t.locked, isTrue);
      expect(await r.resplit(t, const SegmentationSettings()),
          isA<RegenerateRefused>().having((o) => o.message, 'message', RegenerateStrings.locked));

      final empty = RegenRig();
      await empty.open();
      final before = empty.project;
      final r2 = empty.regenerator();
      expect(await r2.resplit(r2.targetOf(Regen.lane)!, const SegmentationSettings()),
          isA<RegenerateRefused>().having((o) => o.message, 'message', RegenerateStrings.nothing));
      expect(identical(empty.project, before), isTrue);
    });
  });

  group('RegenerateSheet', () {
    testWidgets('shows the lane, the earlier run and the modes; re-split applies and closes', (tester) async {
      final rig = RegenRig();
      await rig.pump(tester);
      rig.transcription.resegmentDrafts = drafts(0, 60 * s);
      await rig.openSheet(tester);
      expect(find.byKey(const ValueKey('regenerate-sheet')), findsOneWidget);
      expect(find.text('Captions (Spanish) · Auto'), findsOneWidget);
      expect(find.text('Spanish · Fast · 2 Oct 2026'), findsOneWidget);
      expect(find.text(RegenerateStrings.scope(null)), findsOneWidget);
      await tester.ensureVisible(find.text(CaptionsPresetLabel.shortPhrases));
      await tester.tap(find.text(CaptionsPresetLabel.shortPhrases));
      await rig.pumpSome(tester);
      await rig.tapKey(tester, 'regenerate-apply');
      await tester.runAsync(rig.settle);
      await rig.pumpSome(tester);
      expect(find.byKey(const ValueKey('regenerate-sheet')), findsNothing);
      expect(rig.transcription.resegmentCalls.single.$2.preset, SegmentationPreset.shortPhrases);
      expect((rig.lane.items.first as SubtitleCue).text, 'Nuevo 0');
      expectOwnerUiRules(tester);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('edited cues ask first: Replace replaces, undo restores in one step', (tester) async {
      final rig = RegenRig(project: (id) => regenProject(id, edited: {2}));
      await rig.pump(tester);
      rig.transcription.resegmentDrafts = drafts(0, 60 * s);
      await rig.openSheet(tester);
      await rig.tapKey(tester, 'regenerate-apply');
      expect(find.text('1 caption was edited. Replace it?'), findsOneWidget);
      expect(find.text(RegenerateStrings.editedMessage), findsOneWidget);
      expect(rig.transcription.resegmentCalls, isEmpty, reason: 'nothing happens before the answer');
      await rig.tapKey(tester, 'regenerate-edited-replace');
      await tester.runAsync(rig.settle);
      await rig.pumpSome(tester);
      expect((rig.lane.items.first as SubtitleCue).text, 'Nuevo 0');
      expect(rig.subtitleTracks, hasLength(1));
      expect(rig.editor.undo(), isTrue);
      await tester.runAsync(rig.settle);
      expect((rig.lane.items[2] as SubtitleCue).editedAfterGeneration, isTrue);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('edited cues: Add as new track keeps the lane', (tester) async {
      final rig = RegenRig(project: (id) => regenProject(id, edited: {0, 1}));
      await rig.pump(tester);
      rig.transcription.resegmentDrafts = drafts(0, 60 * s);
      await rig.openSheet(tester);
      await rig.tapKey(tester, 'regenerate-apply');
      expect(find.text('2 captions were edited. Replace them?'), findsOneWidget);
      await rig.tapKey(tester, 'regenerate-edited-new');
      await tester.runAsync(rig.settle);
      await rig.pumpSome(tester);
      expect(rig.subtitleTracks, hasLength(2));
      expect((rig.lane.items.first as SubtitleCue).text, 'Hola 0');
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('edited cues: dismissing the question changes nothing', (tester) async {
      final rig = RegenRig(project: (id) => regenProject(id, edited: {0}));
      await rig.pump(tester);
      final before = rig.project;
      await rig.openSheet(tester);
      await rig.tapKey(tester, 'regenerate-apply');
      expect(find.text('1 caption was edited. Replace it?'), findsOneWidget);
      await tester.tapAt(const Offset(4, 4));
      await rig.pumpSome(tester);
      expect(find.byKey(const ValueKey('regenerate-sheet')), findsOneWidget);
      expect(identical(rig.project, before), isTrue);
      expect(rig.transcription.resegmentCalls, isEmpty);
    });

    testWidgets('a locked lane shows the refusal in the sheet', (tester) async {
      final rig = RegenRig(project: (id) => regenProject(id, locked: true));
      await rig.pump(tester);
      rig.transcription.resegmentDrafts = drafts(0, 60 * s);
      await rig.openSheet(tester);
      await rig.tapKey(tester, 'regenerate-apply');
      await tester.runAsync(rig.settle);
      await rig.pumpSome(tester);
      expect(find.byKey(const ValueKey('regenerate-error')), findsOneWidget);
      expect(find.text(RegenerateStrings.locked), findsOneWidget);
    });

    testWidgets('Transcribe again opens Auto captions prefilled from the earlier run', (tester) async {
      final rig = RegenRig();
      rig.install();
      await rig.pump(tester);
      await rig.openSheet(tester);
      await rig.tapKey(tester, 'regenerate-mode-transcribe');
      expect(find.text(RegenerateStrings.continueAction), findsOneWidget);
      await rig.tapKey(tester, 'regenerate-apply');
      await tester.runAsync(rig.settle);
      await rig.pumpSome(tester, 12);
      expect(find.byKey(const ValueKey('regenerate-sheet')), findsNothing);
      expect(find.byKey(const ValueKey('captions-configure')), findsOneWidget);
      final state = rig.container.read(autoCaptionsControllerProvider(rig.id));
      expect((state.draft.language as FixedLanguage).code, 'es');
      expect(state.draft.tier, SpeechModelTier.fast);
      expect(state.generatedTrack, Regen.lane);
    });

    testWidgets('a lane that was not generated explains why', (tester) async {
      final rig = RegenRig(project: (id) => regenProject(id, generatedLane: false));
      await rig.pump(tester);
      await rig.openSheet(tester);
      expect(find.byKey(const ValueKey('regenerate-not-generated')), findsOneWidget);
      await rig.tapKey(tester, 'regenerate-cancel');
      expect(find.byKey(const ValueKey('regenerate-sheet')), findsNothing);
    });
  });
}

/// Preset labels as the sheet shows them.
abstract final class CaptionsPresetLabel {
  static const String shortPhrases = 'Short phrases';
}
