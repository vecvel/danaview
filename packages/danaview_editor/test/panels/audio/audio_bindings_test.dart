// OWNER: UX-33
//
// The audio action bindings (ARCH §17.6, ux.md §10.4): volume, fades, extractAudio and addMusic are
// bound once by the audio file; volume and fades open the audio panel on the selected clip with
// sound (with their focus), extract audio produces a linked clip and explains why it can't run,
// and Add music picks audio files, imports them through the import sheet and lands them at the
// playhead on an audio lane with AudioRole.music.

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/strings/audio_strings.dart';
import 'package:danaview_editor/src/editor/actions/bindings/audio_bindings.dart';
import 'package:danaview_editor/src/editor/actions/editor_action_registry.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/panels/audio_panel.dart';
import 'package:danaview_editor/src/editor/wiring/action_bindings.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' show MediaPickKind, MediaPickSource;

import '../../support/support.dart';
import 'audio_rig.dart';

void main() {
  test('volume, fades, extractAudio and addMusic are bound exactly once, by the audio file', () {
    final source = editorBindingSources.singleWhere((s) => s.file == 'audio_bindings');
    expect(source.owner, 'UX-33');
    expect(source.bindings().map((b) => b.id),
        [EditorActionId.volume, EditorActionId.fades, EditorActionId.extractAudio, EditorActionId.addMusic]);
    expect(identical(source.bindings(), source.bindings()), isTrue);
    final merged = mergeEditorActionBindings();
    for (final b in source.bindings()) {
      expect(merged[b.id], same(b), reason: b.id.name);
    }
  });

  late AudioRig rig;
  late EditorActionRegistry registry;
  late WidgetActionContext ctx;

  Future<void> setUpRig(WidgetTester tester, {bool music = true, bool ripple = true, ScriptedPool? pool}) async {
    rig = await AudioRig.pump(tester, open: null, music: music, ripple: ripple, pool: pool);
    registry = rig.container.read(editorActionRegistryProvider);
    ctx = WidgetActionContext.container(
      projectId: rig.id,
      context: tester.element(find.byType(RegionFrame)),
      container: rig.container,
      source: EditorActionSource.toolTile,
    );
  }

  EditorActionSpec spec(EditorActionId id) => registry.spec(id);

  void testAudio(String description, Future<void> Function(WidgetTester tester) body) => testWidgets(description, (tester) async {
        await body(tester);
        await tester.pump(const Duration(seconds: 1));
      });

  group('volume and fades', () {
    testAudio('enabled for a video with sound: open the panel on it with their focus', (tester) async {
      await setUpRig(tester);
      rig.editor.select(AudioIds.video);
      await tester.pump();
      expect(spec(EditorActionId.volume).isEnabled(ctx), isTrue);
      expect(registry.invoke(EditorActionId.volume, ctx), EditorActionResult.ran);
      await tester.pump();
      expect(rig.state.inspector, const AudioInspector(AudioIds.video));
      expect(find.byType(AudioPanel), findsOneWidget);
      expect(registry.invoke(EditorActionId.fades, ctx), EditorActionResult.ran);
      await tester.pump();
      expect(rig.state.inspector, const AudioInspector(AudioIds.video, focus: AudioPanelFocus.fades));
    });

    testAudio('enabled for a music clip', (tester) async {
      await setUpRig(tester);
      rig.editor.select(AudioIds.music);
      await tester.pump();
      expect(spec(EditorActionId.fades).isEnabled(ctx), isTrue);
      registry.invoke(EditorActionId.fades, ctx);
      expect(rig.state.inspector, const AudioInspector(AudioIds.music, focus: AudioPanelFocus.fades));
    });

    testAudio('disabled without a clip with sound, and on a locked lane, with the reasons', (tester) async {
      await setUpRig(tester);
      expect(spec(EditorActionId.volume).isEnabled(ctx), isFalse);
      expect(spec(EditorActionId.volume).disabledReason(ctx), AudioStrings.selectClip);
      rig.editor.select(AudioIds.silent);
      await tester.pump();
      expect(spec(EditorActionId.volume).isEnabled(ctx), isFalse, reason: 'a silent video');
      expect(spec(EditorActionId.volume).disabledReason(ctx), AudioStrings.selectClip);
      rig.editor.select(AudioIds.locked);
      await tester.pump();
      expect(spec(EditorActionId.fades).isEnabled(ctx), isFalse);
      expect(spec(EditorActionId.fades).disabledReason(ctx), AudioStrings.actionTrackLocked);
      expect(registry.invoke(EditorActionId.fades, ctx), EditorActionResult.disabled);
      expect(rig.state.inspector, isNull);
    });

    testAudio('the Volume tile of the context tools opens the panel', (tester) async {
      await setUpRig(tester);
      rig.editor.select(AudioIds.music);
      await tester.pump();
      await tester.pump();
      await tester.tap(find.text('Volume').first);
      await tester.pump();
      await tester.pump();
      expect(rig.state.inspector, const AudioInspector(AudioIds.music));
      expect(find.byType(AudioPanel), findsOneWidget);
      expectNoOverflow(tester);
    });
  });

  group('extract audio', () {
    testAudio('produces a linked audio clip with the same media, range and an "original" lane, as one entry', (tester) async {
      await setUpRig(tester);
      rig.editor.select(AudioIds.video);
      await tester.pump();
      expect(spec(EditorActionId.extractAudio).isEnabled(ctx), isTrue);
      expect(registry.invoke(EditorActionId.extractAudio, ctx), EditorActionResult.ran);
      await tester.pump();
      final video = rig.clip(AudioIds.video);
      expect(video.detachedAudio, isTrue);
      final partner = AudioOperations.extractedPartner(rig.project, AudioIds.video)!;
      final audio = rig.clip(partner);
      expect(audio.link, video.link);
      expect((audio.media, audio.start, audio.duration, audio.speed), (video.media, video.start, video.duration, video.speed));
      expect(rig.project.timeline.tracks.singleWhere((t) => t.items.contains(audio)).audioRole, AudioRole.original);
      expect(rig.entries, 1);
      expect(rig.undoLabel, 'Extract audio');
      // Again on the same video: already done.
      rig.editor.select(AudioIds.video);
      await tester.pump();
      expect(spec(EditorActionId.extractAudio).isEnabled(ctx), isFalse);
      expect(spec(EditorActionId.extractAudio).disabledReason(ctx), AudioStrings.extractDone);
    });

    testAudio('disabled for audio clips, silent videos and nothing selected, with the reasons', (tester) async {
      await setUpRig(tester);
      expect(spec(EditorActionId.extractAudio).disabledReason(ctx), AudioStrings.extractNeedsVideo);
      rig.editor.select(AudioIds.music);
      await tester.pump();
      expect(spec(EditorActionId.extractAudio).isEnabled(ctx), isFalse);
      expect(spec(EditorActionId.extractAudio).disabledReason(ctx), AudioStrings.extractNeedsVideo);
      rig.editor.select(AudioIds.silent);
      await tester.pump();
      expect(spec(EditorActionId.extractAudio).isEnabled(ctx), isFalse);
      expect(spec(EditorActionId.extractAudio).disabledReason(ctx), AudioStrings.extractNoAudio);
      expect(registry.invoke(EditorActionId.extractAudio, ctx), EditorActionResult.disabled);
      expect(rig.entries, 0);
    });

    test('extractBlocker covers a locked lane', () {
      final project = audioProject(const ProjectId('p'));
      final locked = project.timeline.tracks.first.copyWith(locked: true);
      final p2 = project.copyWith(timeline: project.timeline.copyWith(tracks: [locked, ...project.timeline.tracks.skip(1)]));
      expect(AudioOperations.extractBlocker(project, AudioIds.video), isNull);
      expect(AudioOperations.extractBlocker(p2, AudioIds.video), ExtractBlocker.locked);
      expect(AudioOperations.reasonOf(ExtractBlocker.locked), AudioStrings.actionTrackLocked);
    });
  });

  group('add music', () {
    Future<void> runAddMusic(WidgetTester tester) async {
      expect(registry.invoke(EditorActionId.addMusic, ctx), EditorActionResult.ran);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
    }

    testAudio('picks audio files, imports them and lands them at the playhead on a music-role lane', (tester) async {
      final pool = ScriptedPool()..steps['song.m4a'] = const AddStep(kind: MediaKind.audio);
      await setUpRig(tester, ripple: false, pool: pool);
      await rig.seek(3 * s);
      rig.engine.picker.nextPicks = [pickOf('song.m4a', size: 1000)];
      expect(spec(EditorActionId.addMusic).isEnabled(ctx), isTrue);
      await runAddMusic(tester);
      final request = rig.engine.picker.requests.single;
      expect(request.source, MediaPickSource.files);
      expect(request.kinds, {MediaPickKind.audio});
      expect(pool.imported, ['song.m4a']);
      final added = rig.project.timeline.tracks
          .expand((t) => [for (final i in t.items) (t, i)])
          .where((e) => e.$2 is MediaClip && !{AudioIds.video, AudioIds.silent, AudioIds.music, AudioIds.locked}.contains(e.$2.id))
          .toList();
      expect(added, hasLength(1));
      final (lane, clip) = added.single;
      expect(lane.kind, TrackKind.audio);
      expect(lane.audioRole, AudioRole.music);
      expect(clip.start, 3 * s);
      expect(rig.project.pool[(clip as MediaClip).media]!.kind, MediaKind.audio);
      expect(rig.entries, 1, reason: 'the placement is one entry (the import is a pool change)');
    });

    testAudio('without a music lane one is created', (tester) async {
      final pool = ScriptedPool()..steps['bed.mp3'] = const AddStep(kind: MediaKind.audio);
      await setUpRig(tester, music: false, pool: pool);
      final lanes = rig.project.timeline.tracks.length;
      rig.engine.picker.nextPicks = [pickOf('bed.mp3', size: 1000)];
      await runAddMusic(tester);
      expect(rig.project.timeline.tracks.length, lanes + 1);
      final lane = rig.project.timeline.tracks.firstWhere((t) => t.audioRole == AudioRole.music);
      expect(lane.items.single.start, 0);
    });

    testAudio('a cancelled picker changes nothing', (tester) async {
      await setUpRig(tester);
      final before = rig.project;
      await runAddMusic(tester);
      expect(rig.project.timeline, before.timeline);
      expect(rig.project.pool.length, before.pool.length);
      expect(find.text(AudioStrings.importTitle), findsNothing);
    });
  });
}
