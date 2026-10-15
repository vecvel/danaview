// OWNER: QA-00
//
// ARCH §21.2 scenario 15: Extract audio from a video clip, then Add music with a fade-in.

// ignore_for_file: implementation_imports

import 'package:danaview_editor/src/editor/contracts/action_ids.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/e2e.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('scenario 15: extract audio, then music with a fade-in', (tester) async {
    await E2eApp.launch(tester);
    final ed = await E2eEditor.createProject(tester, name: 'E2E audio ${DateTime.now().millisecondsSinceEpoch % 100000}', media: [E2eMedia.fixture(Fx.toneUnderVideo)]);
    final video = ed.mainTrack.items.single as MediaClip;

    // Extract audio: a linked clip on an "original" lane; the video's own audio is detached.
    await ed.select(video.id);
    await ed.invoke(EditorActionId.extractAudio);
    await ed.waitProject((p) => p.tracks.any((t) => t.kind == TrackKind.audio && t.audioRole == AudioRole.original && t.items.isNotEmpty),
        what: 'the extracted audio');
    final original = ed.project.tracks.firstWhere((t) => t.kind == TrackKind.audio && t.audioRole == AudioRole.original).items.single as MediaClip;
    expect(original.media, video.media);
    expect(original.range, video.range);
    expect(original.link, isNotNull);
    expect((ed.item(video.id) as MediaClip).detachedAudio, isTrue);

    // Add music at the playhead (Files picker → import sheet → music lane).
    await ed.seekFrame(0);
    ed.controller.clearSelection();
    E2eApp.world.engine.picker.queue([E2eMedia.fixture(Fx.tone1k, as: 'e2e-music-1khz.wav')]);
    await ed.invoke(EditorActionId.addMusic);
    await ed.waitProject((p) => p.tracks.any((t) => t.kind == TrackKind.audio && t.audioRole == AudioRole.music && t.items.isNotEmpty),
        what: 'the music clip', timeout: const Duration(seconds: 60));
    final music = ed.project.tracks.firstWhere((t) => t.kind == TrackKind.audio && t.audioRole == AudioRole.music).items.single as MediaClip;
    expect(music.start, 0);

    // Fade-in of one second (the Audio panel's Fade in row).
    ed.apply(SetAudio([music.id], music.audio.copyWith(fadeIn: 1000000)));
    await ed.waitProject((p) => (ed.item(music.id) as MediaClip).audio.fadeIn == 1000000, what: 'the fade-in');

    // The mix exports with AAC; the fade-in makes the first 100 ms quieter than the middle.
    final out = await E2eExport.run(ed);
    await E2eExport.expectConformant(out.video, width: 1280, height: 720, duration: ed.project.duration, rate: ed.rate);
    final (head, _) = await E2eExport.pcm(ed, out.video, const TimeRange(0, 100000));
    final (body, _) = await E2eExport.pcm(ed, out.video, const TimeRange(3000000, 3100000));
    // ignore: avoid_print
    print('DV_E2E_REPORT s15 head ${E2eExport.dbfs(head).toStringAsFixed(1)} dBFS, body ${E2eExport.dbfs(body).toStringAsFixed(1)} dBFS');
    expect(E2eExport.dbfs(head), lessThan(E2eExport.dbfs(body) - 1), reason: 'the music fades in');
    await ed.close();
  });
}
