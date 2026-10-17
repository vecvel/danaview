// OWNER: UX-38
//
// The interrupted Auto captions notice (ai.md §8.6): after a simulated kill (the fake job fails with
// TranscriptionInterrupted and keeps a resumable record) the notice appears when the editor opens;
// Resume re-runs the stored request through the Auto captions sheet and the job continues from the
// record; without a stored request the sheet opens for the user to start; Discard drops the record;
// records older than 7 days and running jobs show nothing; the stored request decodes; the message
// copy shows the checkpointed share and says Resume starts over when nothing was kept (FIX-QA07-D5).

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/flows/captions/interrupted_notice.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_transcription/danaview_transcription.dart';

import '../../support/support.dart';
import 'regenerate_rig.dart';

/// Starts a job for the rig's project and kills it at 40 %.
FakeTranscriptionJob _kill(RegenRig rig, {TranscriptionRequest? request}) {
  final job = rig.transcription.start(request ?? rigRequest(rig.id)) as FakeTranscriptionJob;
  rig.transcription.interrupt(job);
  return job;
}

void main() {
  group('decode', () {
    test('the stored request decodes into the sheet draft', () {
      final json = encodeTranscriptionRequest(TranscriptionRequest(
        project: const ProjectId('p'),
        scope: const TimelineScope(tracks: {Regen.main, Regen.music}),
        language: const FixedLanguage('es'),
        modelId: SpeechModelCatalog.fast.id,
        segmentation: const SegmentationSettings(preset: SegmentationPreset.singleLine, maxCharsPerLine: 30),
        includeSoundDescriptions: true,
        target: const ReplaceTrackTarget(Regen.lane),
        timeline: () => throw UnimplementedError(),
      ));
      final r = InterruptedRequest.decode(json)!;
      expect((r.language as FixedLanguage).code, 'es');
      expect(r.tier, SpeechModelTier.fast);
      expect(r.segmentation.preset, SegmentationPreset.singleLine);
      expect(r.segmentation.maxCharsPerLine, 30);
      expect(r.includeSoundDescriptions, isTrue);
      expect(r.replaceTrack, Regen.lane);
      expect((r.scope as TimelineScope).tracks, {Regen.main, Regen.music});

      final clip = InterruptedRequest.decode(encodeTranscriptionRequest(rigRequest(const ProjectId('p'), scope: const ClipScope(Regen.clip), language: const AutoLanguage())))!;
      expect(clip.scope, isA<ClipScope>());
      expect(clip.language, isA<AutoLanguage>());
      expect(InterruptedRequest.decode({'model': 'nope'}), isNull);
    });
  });

  group('InterruptedNotice', () {
    testWidgets('nothing is shown without an interrupted job', (tester) async {
      final rig = RegenRig();
      await rig.pump(tester);
      expect(find.byKey(const ValueKey('captions-interrupted')), findsNothing);
    });

    testWidgets('after a simulated kill the notice offers Resume; the job continues from the record', (tester) async {
      final store = <RecordingInterruptedStore>[];
      late RegenRig rig;
      rig = RegenRig(overrides: [
        interruptedCaptionsStoreProvider.overrideWith((ref) {
          final s = RecordingInterruptedStore(rig.transcription, requests: {'tj-0': encodeTranscriptionRequest(rigRequest(rig.id))});
          store.add(s);
          return s;
        }),
      ]);
      rig.install();
      final killed = _kill(rig);
      await tester.runAsync(rig.settle);
      await rig.pump(tester);
      expect(find.byKey(const ValueKey('captions-interrupted')), findsOneWidget);
      expect(find.text(InterruptedCaptionsStrings.title), findsOneWidget);
      expect(find.text(InterruptedCaptionsStrings.message(0.4)), findsOneWidget);
      expect(find.text('40% was done. That part is kept, so it continues where it stopped.'), findsOneWidget);
      expectOwnerUiRules(tester);

      await rig.tapKey(tester, 'captions-interrupted-resume');
      await tester.runAsync(rig.settle);
      await rig.pumpSome(tester, 12);
      expect(rig.transcription.jobs, hasLength(2), reason: 'Resume re-ran the request');
      final resumed = rig.transcription.jobs.last;
      expect(resumed.resumedFromFraction, 0.4);
      expect(resumed.request.modelId, killed.request.modelId);
      expect((resumed.request.language as FixedLanguage).code, 'es');
      expect(resumed.request.segmentation.preset, SegmentationPreset.singleLine);
      expect(resumed.request.target, isA<ReplaceTrackTarget>());
      expect(find.byKey(const ValueKey('captions-interrupted')), findsNothing, reason: 'a job runs now');
      resumed.cancel();
      await tester.runAsync(rig.settle);
      await rig.pumpSome(tester);
    });

    testWidgets('without a stored request Resume opens the sheet for the user to start', (tester) async {
      final rig = RegenRig();
      for (final m in SpeechModelCatalog.models) {
        rig.install(m);
      }
      _kill(rig);
      await tester.runAsync(rig.settle);
      await rig.pump(tester);
      await rig.tapKey(tester, 'captions-interrupted-resume');
      await tester.runAsync(rig.settle);
      await rig.pumpSome(tester, 12);
      expect(find.byKey(const ValueKey('captions-configure')), findsOneWidget);
      expect(rig.transcription.jobs, hasLength(1), reason: 'nothing starts without the user');
      await rig.tapKey(tester, 'captions-create');
      await tester.runAsync(rig.settle);
      await rig.pumpSome(tester);
      expect(rig.transcription.jobs, hasLength(2));
      expect(rig.transcription.jobs.last.resumedFromFraction, 0.4);
      rig.transcription.jobs.last.cancel();
      await tester.runAsync(rig.settle);
      await rig.pumpSome(tester);
    });

    testWidgets('Discard drops the record and the notice does not come back', (tester) async {
      late RecordingInterruptedStore store;
      late RegenRig rig;
      rig = RegenRig(overrides: [
        interruptedCaptionsStoreProvider.overrideWith((ref) => store = RecordingInterruptedStore(rig.transcription)),
      ]);
      _kill(rig);
      await tester.runAsync(rig.settle);
      await rig.pump(tester);
      await rig.tapKey(tester, 'captions-interrupted-discard');
      await tester.runAsync(rig.settle);
      await rig.pumpSome(tester);
      expect(find.byKey(const ValueKey('captions-interrupted')), findsNothing);
      expect(store.discarded, ['tj-0']);
      expect(rig.transcription.resumable, isEmpty);
      expect(rig.transcription.jobs, hasLength(1));
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('the default store hides a discarded job for the session', (tester) async {
      final rig = RegenRig();
      _kill(rig);
      await tester.runAsync(rig.settle);
      await rig.pump(tester);
      await rig.tapKey(tester, 'captions-interrupted-discard');
      await tester.runAsync(rig.settle);
      await rig.pumpSome(tester);
      expect(find.byKey(const ValueKey('captions-interrupted')), findsNothing);
      final s = rig.container.read(interruptedCaptionsStoreProvider);
      expect(await tester.runAsync(() => s.pending(rig.id)), isNull);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('records older than 7 days are not offered', (tester) async {
      final rig = RegenRig();
      rig.transcription.resumable[const ProjectId('x')] = ResumableTranscription(jobId: 'old', project: const ProjectId('x'), doneFraction: 0.5, createdAt: DateTime.utc(2026, 10, 1));
      final id = rig.id;
      rig.transcription.resumable[id] = ResumableTranscription(jobId: 'old', project: id, doneFraction: 0.5, createdAt: DateTime.utc(2026, 10, 7));
      await rig.pump(tester);
      expect(find.byKey(const ValueKey('captions-interrupted')), findsNothing);
    });
  });
  group('message copy (FIX-QA07-D5)', () {
    test('a checkpointed share shows its percent; nothing done says Resume starts over', () {
      expect(InterruptedCaptionsStrings.message(0.46), '46% was done. That part is kept, so it continues where it stopped.');
      expect(InterruptedCaptionsStrings.message(0),
          'It stopped before any part was finished. Resume starts it again with the same settings.');
      expect(InterruptedCaptionsStrings.message(double.nan), InterruptedCaptionsStrings.message(0));
      expect(InterruptedCaptionsStrings.message(-1), InterruptedCaptionsStrings.message(0));
    });

    test('small shares never read 0%, unfinished jobs never read 100%', () {
      expect(InterruptedCaptionsStrings.message(0.004), startsWith('Less than 1% was done.'));
      expect(InterruptedCaptionsStrings.message(0.006), startsWith('1% was done.'));
      expect(InterruptedCaptionsStrings.message(0.998), startsWith('99% was done.'));
      expect(InterruptedCaptionsStrings.message(1), startsWith('100% was done.'));
      expect(InterruptedCaptionsStrings.message(3), startsWith('100% was done.'));
    });
  });
}
