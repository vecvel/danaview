// OWNER: QA-00
//
// ARCH §21.2 scenario 5: a text item with an animation; subtitle cue add / split / merge; SRT import
// (Files picker answered with a sandbox file) and export (Save to Files) round trip.

// ignore_for_file: implementation_imports

import 'dart:io';

import 'package:danaview_editor/src/editor/contracts/action_ids.dart';
import 'package:danaview_editor_core/formats.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/e2e.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('scenario 5: text animation, cue add/split/merge, SRT import and export round trip', (tester) async {
    await E2eApp.launch(tester);
    final ed = await E2eEditor.createProject(tester, name: 'E2E subtitles ${DateTime.now().millisecondsSinceEpoch % 100000}', media: [E2eMedia.fixture(Fx.frameCounter)]);
    final r = ed.rate;

    // Text with an in-animation (the Text panel's Animation row issues SetTextAnimation).
    await ed.seekFrame(30);
    await ed.invoke(EditorActionId.addText);
    await ed.waitProject((p) => ed.items<TextItem>().isNotEmpty, what: 'a text item');
    final text = ed.items<TextItem>().single;
    ed.apply(SetText(text.id, 'Hello E2E'));
    ed.apply(SetTextAnimation([text.id], const TextAnimation(inKind: TextAnimKind.typewriter, inDuration: 1000000)));
    await ed.waitProject((p) => (ed.item(text.id) as TextItem).animation.inKind == TextAnimKind.typewriter, what: 'the typewriter animation');

    // Caption add at the playhead, split, merge.
    await ed.seekFrame(60);
    await ed.invoke(EditorActionId.addCaption);
    await ed.waitProject((p) => ed.items<SubtitleCue>().isNotEmpty, what: 'a caption');
    final cue = ed.items<SubtitleCue>().single;
    expect(cue.start, r.timeOfFrame(60));
    ed.apply(SetCueText(cue.id, 'first second'));
    final mid = cue.start + cue.duration ~/ 2;
    ed.apply(SplitCue(cue.id, mid));
    await ed.waitProject((p) => ed.items<SubtitleCue>().length == 2, what: 'two captions after the split');
    final halves = ed.items<SubtitleCue>()..sort((a, b) => a.start.compareTo(b.start));
    expect(halves.first.end, halves.last.start);
    ed.apply(MergeCues({for (final c in halves) c.id}));
    await ed.waitProject((p) => ed.items<SubtitleCue>().length == 1, what: 'one caption after the merge');
    expect(ed.items<SubtitleCue>().single.range, cue.range);

    // SRT import into a new track.
    final source = [(500000, 1500000, 'One'), (2000000, 3300000, 'Two, with a comma'), (4000000, 6000000, 'Three\nlines')]; // on the 30 fps grid and whole ms
    final srt = E2eMedia.srt('e2e-import', source);
    E2eApp.world.engine.picker.queue([srt]);
    final before = ed.tracksOf(TrackKind.subtitle).length;
    await ed.invoke(EditorActionId.importSubtitles);
    await E2eApp.waitKey(tester, 'subtitleIo.import');
    await E2eApp.tapKey(tester, 'subtitleIo.importButton');
    await ed.waitProject((p) => ed.tracksOf(TrackKind.subtitle).length == before + 1, what: 'the imported subtitle track');
    final imported = ed.tracksOf(TrackKind.subtitle).last;
    expect(imported.items, hasLength(3));
    expect([for (final i in imported.items) (i.start, i.end, (i as SubtitleCue).text)], source);

    // Export the imported track as SRT to Files and parse it back.
    await ed.select(imported.items.first.id);
    final handoffs = E2eApp.world.engine.files.records.length;
    await ed.invoke(EditorActionId.exportSubtitles);
    await E2eApp.waitKey(tester, 'subtitleIo.export');
    await E2eApp.tapKey(tester, 'subtitleIo.exportTrack.${imported.id.value}');
    await E2eApp.tapKey(tester, 'subtitleIo.saveToFiles');
    await E2eApp.pumpUntil(tester, () => E2eApp.world.engine.files.records.length > handoffs, what: 'the SRT handoff');
    final out = E2eApp.world.engine.files.records.last;
    expect(out.suggestedName, endsWith('.srt'));
    final parsed = SubtitleCodec.parse(File(out.copyPath).readAsBytesSync(), hint: SubtitleFormat.srt);
    expect(parsed.issues, isEmpty);
    expect([for (final c in parsed.cues) (c.startUs, c.endUs, c.text)], source);
    await E2eApp.screenshot(tester, 's05_subtitles');
    await ed.close();
  });
}
