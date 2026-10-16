// OWNER: FIX-QA07
//
// QA-07 D4: the path E2E scenario 8 now drives. With a single subtitle track the export panel shows
// no track list (no `subtitleIo.exportTrack.<id>`), exports that track directly, and the SRT saved
// to Files parses back to the same cues.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/strings/subtitle_io_strings.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor_core/formats.dart';
import 'package:danaview_editor_core/model.dart';

import 'subtitle_io_rig.dart';

void main() {
  testWidgets('one subtitle track: no track list, SRT to Files parses back to the same cues', (tester) async {
    final rig = await SubtitleIoRig.pump(tester, subtitles: false);
    rig.offer('movie.en.srt', fixture('basic.srt'));
    await rig.invoke(EditorActionId.importSubtitles);
    await rig.tap(find.byKey(const ValueKey<String>('subtitleIo.importButton')));
    await rig.drainToasts();
    final track = rig.subtitleTracks.single;
    final cues = [for (final i in track.items) i as SubtitleCue];
    expect(cues, isNotEmpty);

    await rig.invoke(EditorActionId.exportSubtitles);
    expect(find.byKey(const ValueKey<String>('subtitleIo.export')), findsOneWidget);
    expect(find.byKey(ValueKey<String>('subtitleIo.exportTrack.${track.id.value}')), findsNothing);
    await rig.tap(find.descendant(of: find.byKey(const ValueKey<String>('subtitleIo.format')), matching: find.text(SubtitleIoStrings.srt)));
    await rig.tap(find.byKey(const ValueKey<String>('subtitleIo.saveToFiles')));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await rig.settle();

    final call = rig.handoff.calls.single;
    expect(call.kind, 'files');
    expect(call.name, endsWith('.srt'));
    final parsed = SubtitleCodec.parse(call.bytes, hint: SubtitleFormat.srt);
    // SRT carries milliseconds; s08 compares at that precision.
    int ms(int us) => (us / 1000).round();
    expect([for (final c in parsed.cues) (ms(c.startUs), ms(c.endUs), c.text)], [for (final c in cues) (ms(c.start), ms(c.end), c.text)]);
    await rig.drainToasts();
  });
}
