// OWNER: QA-00
//
// ARCH §21.2 scenario 7: export of a project built through the UI — frame_counter split with a
// cross dissolve and an imported LUT, a typewriter text, one burned SRT track, one track with
// burn-in off, music for the AAC track — at 720p H.264 MP4, verified with MediaInspector (container,
// avc1, size, duration ± 1 frame, AAC) and, where the capabilities allow, HEVC/MOV. Frames of the
// exported file are pulled with the engine's freeze job:
//
// * export A burns track T1; export B is the same project with T1's burn-in switched off in the
//   export sheet and the text and T2 removed. The subtitle safe area (bottom 30 %) differs between A
//   and B at each T1 cue midpoint and is identical between cues; at T2's cue midpoint A and B are
//   identical, so the burn-in-off track never appears;
// * the typewriter's ink (pixels where A and B differ outside the subtitle area) grows across its
//   in-animation;
// * barcodes stay readable outside [cut − d/2, cut + d/2) and blend only inside it;
// * the SRT and VTT side files parse back to the cues of a subtitle track of the project.

// ignore_for_file: implementation_imports

import 'dart:io';

import 'package:danaview_editor/src/editor/contracts/action_ids.dart';
import 'package:danaview_editor_core/formats.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';
import 'package:danaview_editor_core/plan.dart';
import 'package:danaview_editor_engine/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/e2e.dart';

/// Pixels (sampled every 2 px) whose luma differs by more than 40 between [a] and [b] in the rows
/// [y0, y1) (fractions of the height). A burned cue changes a compact box (about 2 % of the band at
/// 720p), which a mean over the band would hide under codec noise, so cues are counted, not averaged.
int changedIn(E2eFrame a, E2eFrame b, double y0, double y1) {
  expect((a.width, a.height), (b.width, b.height));
  var count = 0;
  for (var y = (a.height * y0).floor(); y < a.height * y1; y += 2) {
    for (var x = 0; x < a.width; x += 2) {
      final (ar, ag, ab, _) = a.pixel(x, y);
      final (br, bg, bb, _) = b.pixel(x, y);
      if (((ar * 299 + ag * 587 + ab * 114) - (br * 299 + bg * 587 + bb * 114)).abs() > 40000) count++;
    }
  }
  return count;
}

/// Pixels (sampled every 2 px) whose luma differs by more than 40 between [a] and [b] above row
/// fraction [yMax].
int ink(E2eFrame a, E2eFrame b, double yMax) {
  var count = 0;
  for (var y = (a.height * 0.12).ceil(); y < a.height * yMax; y += 2) {
    for (var x = 0; x < a.width; x += 2) {
      final (ar, ag, ab, _) = a.pixel(x, y);
      final (br, bg, bb, _) = b.pixel(x, y);
      if (((ar * 299 + ag * 587 + ab * 114) - (br * 299 + bg * 587 + bb * 114)).abs() > 40000) count++;
    }
  }
  return count;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('scenario 7: export of a UI-built project, verified frame by frame', (tester) async {
    await E2eApp.launch(tester);
    final ed = await E2eEditor.createProject(
      tester,
      name: 'E2E export ${DateTime.now().millisecondsSinceEpoch % 100000}',
      media: [E2eMedia.fixture(Fx.frameCounter), E2eMedia.fixture(Fx.speech)],
    );
    final r = ed.rate;
    const s = 1000000;

    // Music under the whole video (speech_10s trimmed to the video's 8 s) for the AAC track.
    final music = ed.items<MediaClip>().firstWhere((c) => ed.trackOf(c.id).kind == TrackKind.audio);
    ed.apply(TrimItem(music.id, TrimEdge.end, 8 * s));
    await ed.waitProject((p) => p.duration == 8 * s, what: 'an 8 s project');

    // Split at frame 120 and put a 15-frame cross dissolve on the cut.
    final video = ed.mainTrack.items.single as MediaClip;
    await ed.select(video.id);
    await ed.seekFrame(120);
    await ed.invoke(EditorActionId.split);
    await ed.waitProject((p) => p.timeline.mainTrack!.items.length == 2, what: 'the split');
    final pieces = ed.mainTrack.items;
    const d = 15;
    ed.apply(SetTransition(TransitionRef(ed.mainTrack.id, pieces[0].id, pieces[1].id), const TransitionSpec(TransitionKind.crossDissolve, d)));
    await ed.waitProject((p) => ed.mainTrack.transitions.isNotEmpty, what: 'the cross dissolve');

    // LUT import on both pieces (Filters panel).
    for (final piece in pieces) {
      await ed.select(piece.id);
      await ed.invoke(EditorActionId.filters);
      E2eApp.world.engine.picker.queue([E2eMedia.cubeLut()]);
      await E2eApp.tapKey(tester, 'lut.import');
      await ed.waitProject((p) => (ed.item(piece.id) as MediaClip).visual?.look is ImportedLut, what: 'the LUT on ${piece.id}');
    }

    // Typewriter text at 1 s, 1 s in-animation.
    await ed.seekFrame(30);
    await ed.invoke(EditorActionId.addText);
    await ed.waitProject((p) => ed.items<TextItem>().isNotEmpty, what: 'the text');
    final text = ed.items<TextItem>().single;
    ed.apply(SetText(text.id, 'TYPEWRITER E2E'));
    ed.apply(SetTextAnimation([text.id], const TextAnimation(inKind: TextAnimKind.typewriter, inDuration: s)));

    // Two subtitle tracks imported from SRT files: T1 burned, T2 with burn-in off.
    Future<Track> importSrt(String name, List<(int, int, String)> cues) async {
      final before = ed.tracksOf(TrackKind.subtitle).length;
      E2eApp.world.engine.picker.queue([E2eMedia.srt(name, cues)]);
      await ed.invoke(EditorActionId.importSubtitles);
      await E2eApp.waitKey(tester, 'subtitleIo.import');
      await E2eApp.tapKey(tester, 'subtitleIo.importButton');
      await ed.waitProject((p) => ed.tracksOf(TrackKind.subtitle).length == before + 1, what: 'subtitle track $name');
      return ed.tracksOf(TrackKind.subtitle).last;
    }

    final t1Cues = [(5 * s, 5600000, 'BURNED ONE'), (6600000, 7200000, 'BURNED TWO')];
    final t2Cues = [(2500000, 3 * s, 'NEVER SHOWN')];
    final t1 = await importSrt('e2e-burned', t1Cues);
    final t2 = await importSrt('e2e-not-burned', t2Cues);
    ed.apply(SetBurnIn(t1.id, true));
    ed.apply(SetBurnIn(t2.id, false));
    final duration = ed.project.duration;

    // Export A.
    final a = await E2eExport.run(ed, configure: (x) => x.copyWith(burnInSubtitles: {t1.id: true, t2.id: false}, sideFiles: {SideFileFormat.srt, SideFileFormat.vtt}));
    await E2eExport.expectConformant(a.video, width: 1280, height: 720, duration: duration, rate: r);

    // Side files parse back to the cues of a subtitle track.
    expect(a.sideFiles.keys.toSet(), {SideFileFormat.srt, SideFileFormat.vtt});
    final tracks = [for (final t in ed.tracksOf(TrackKind.subtitle)) [for (final i in t.items) (i.start, i.end, (i as SubtitleCue).text)]];
    for (final MapEntry(key: format, value: path) in a.sideFiles.entries) {
      final parsed = SubtitleCodec.parse(File(path).readAsBytesSync(), hint: format == SideFileFormat.srt ? SubtitleFormat.srt : SubtitleFormat.vtt);
      final cues = [for (final c in parsed.cues) (c.startUs, c.endUs, c.text)];
      expect(tracks, contains(equals(cues)), reason: '${format.name} side file');
    }

    // Export B: T1 not burned, the text and T2 removed.
    ed.apply(DeleteItems({text.id}));
    ed.apply(DeleteTrack(t2.id));
    final b = await E2eExport.run(ed, configure: (x) => x.copyWith(burnInSubtitles: {t1.id: false}, sideFiles: const {}));
    await E2eExport.expectConformant(b.video, width: 1280, height: 720, duration: duration, rate: r);

    TimeUs mid((int, int, String) c) => (c.$1 + c.$2) ~/ 2;
    final probes = <String, TimeUs>{
      't1a': mid(t1Cues[0]),
      't1b': mid(t1Cues[1]),
      'between': 6100000,
      't2': mid(t2Cues[0]),
      'tw1': 1200000,
      'tw2': 1500000,
      'tw3': 1900000,
    };
    final fa = await E2eExport.frames(ed, a.video, probes.values.toList());
    final fb = await E2eExport.frames(ed, b.video, probes.values.toList());
    final aAt = {for (final (i, k) in probes.keys.indexed) k: fa[i]};
    final bAt = {for (final (i, k) in probes.keys.indexed) k: fb[i]};
    const subY0 = 0.70;
    for (final k in ['t1a', 't1b']) {
      expect(changedIn(aAt[k]!, bAt[k]!, subY0, 1), greaterThan(300), reason: 'burned cue $k must show in the subtitle area');
    }
    for (final k in ['between', 't2']) {
      expect(changedIn(aAt[k]!, bAt[k]!, subY0, 1), lessThan(60), reason: 'nothing burned at $k');
    }
    final inks = [for (final k in ['tw1', 'tw2', 'tw3']) ink(aAt[k]!, bAt[k]!, subY0)];
    expect(inks[0], lessThan(inks[1]), reason: 'typewriter glyphs grow: $inks');
    expect(inks[1], lessThan(inks[2]), reason: 'typewriter glyphs grow: $inks');

    // Barcodes around the cut (frame 120, d = 15 → [112.5, 127.5)).
    final ks = [for (var k = 100; k <= 140; k++) k];
    final frames = await E2eExport.frames(ed, a.video, [for (final k in ks) r.timeOfFrame(k)]);
    var blendedInside = 0;
    for (final (i, k) in ks.indexed) {
      final reading = frames[i].barcode;
      final inside = k * 2 >= 2 * 120 - d && k * 2 < 2 * 120 + d;
      if (inside) {
        expect(reading.status == FrameBarcodeStatus.blended || reading.index == k, isTrue, reason: 'frame $k inside the dissolve: $reading');
        if (reading.status == FrameBarcodeStatus.blended) blendedInside++;
      } else {
        expect(reading.index, k, reason: 'frame $k outside the dissolve: $reading');
      }
    }
    expect(blendedInside, greaterThan(0), reason: 'the dissolve blends frames');

    // HEVC / MOV where the device allows it (simulators: no hardware HEVC, reported not failed).
    final caps = await E2eApp.world.engine.capabilities();
    if (caps.hevcEncode && caps.movContainer) {
      final c = await E2eExport.run(ed, configure: (x) => x.copyWith(codec: VideoCodec.hevc, container: ExportContainer.mov, burnInSubtitles: {t1.id: true}));
      await E2eExport.expectConformant(c.video, width: 1280, height: 720, duration: duration, rate: r, codec: VideoCodec.hevc, container: ExportContainer.mov);
    } else {
      // ignore: avoid_print
      print('DV_E2E_REPORT s07 HEVC/MOV not offered here (hevcEncode ${caps.hevcEncode}, mov ${caps.movContainer}): reported, not failed');
    }
    await ed.close();
  });
}
