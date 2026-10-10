// OWNER: CORE-15
//
// Fixtures of the subtitle and caption command tests: a project with manual, imported and
// generated cues on several lanes (one locked), a provenance, and a golden runner that adds the
// cue details `describe` does not show (origin, editedAfterGeneration, lane data).

import 'package:test/test.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/ops.dart';

import '../framework/ops_support.dart';

SubtitleCue cueOf(String id, int k0, int n, String value, {CueOrigin origin = CueOrigin.manual, bool edited = false}) => SubtitleCue(
      id: ItemId(id),
      start: f(k0),
      duration: f(k0 + n) - f(k0),
      text: value,
      origin: origin,
      editedAfterGeneration: edited,
    );

CaptionProvenance provenance({String language = 'en', String model = 'whisper-base-q5_1'}) => CaptionProvenance(
      generator: 'whisper.cpp',
      engineVersion: '1.9.4',
      modelId: model,
      modelSha256: 'abc123',
      language: language,
      languageDetected: false,
      segmentation: const SegmentationSettings(),
      scope: CaptionScopeData(),
      generatedAt: DateTime.utc(2026, 10, 10, 9),
    );

Track subLane(String id, List<TimelineItem> cues,
        {bool locked = false, String name = '', SubtitleTrackData data = const SubtitleTrackData()}) =>
    Track(id: TrackId(id), kind: TrackKind.subtitle, name: name, locked: locked, subtitle: data, items: cues);

/// Main video lane, a manual lane `tr_s1` (c1 [0,30) c2 [30,60) touching, c3 [90,120)), a
/// generated lane `tr_s2` (g1 [0,30) g2 [45,75), provenance), a locked lane `tr_sl` and a text
/// lane.
EditProject subs({bool withGenerated = true}) => project([
      lane('tr_main', TrackKind.video, [vclip('v', 0, 300)], main: true),
      lane('tr_txt', TrackKind.text, [text('x', 0, 30)]),
      subLane('tr_s1', [
        cueOf('c1', 0, 30, 'Hello world'),
        cueOf('c2', 30, 30, 'Second one'),
        cueOf('c3', 90, 30, 'Third'),
      ]),
      if (withGenerated)
        subLane('tr_s2', [
          cueOf('g1', 0, 30, 'Generated one', origin: CueOrigin.generated),
          cueOf('g2', 45, 30, 'Generated two', origin: CueOrigin.generated, edited: true),
        ], data: SubtitleTrackData(language: 'en', provenance: provenance())),
      subLane('tr_sl', [cueOf('l1', 0, 30, 'Locked')], locked: true),
    ]);

/// A project with no subtitle lane.
EditProject noSubs() => project([lane('tr_main', TrackKind.video, [vclip('v', 0, 300)], main: true)]);

String _name(String id, int index) => id.length == 15 ? 'new$index' : id;

/// Subtitle lanes and cues in detail: lane data, then per cue frames, origin, edited flag, text.
String cueDetails(EditProject p) {
  final r = p.settings.frameRate;
  final b = StringBuffer();
  var n = 0;
  for (final t in p.tracks) {
    if (t.kind != TrackKind.subtitle) continue;
    final data = t.subtitle!;
    final pos = switch (data.position) {
      BottomSubtitlePosition() => 'bottom',
      TopSubtitlePosition() => 'top',
      CustomSubtitlePosition(:final yFraction) => 'y=$yFraction',
    };
    b.writeln('lane ${_name(t.id.value, n++)} "${t.name}" lang=${data.language} burn=${data.burnIn} pos=$pos '
        'lines=${data.style.maxLines} size=${data.style.fontSizePt} prov=${data.provenance?.modelId}${t.locked ? ' locked' : ''}');
    for (final c in t.items.whereType<SubtitleCue>()) {
      b.writeln('  [${r.frameIndexOf(c.start)},${r.frameIndexOf(c.end)}) ${c.origin.name}${c.editedAfterGeneration ? ' edited' : ''} ${_quote(c.text)}');
    }
  }
  return b.toString();
}

String _quote(String s) => '"${s.replaceAll('\n', r'\n')}"';

/// `runCase` plus the cue details of the result.
String runSubCase(String name, EditProject before, EditCommand command, {EditPolicy policy = const EditPolicy()}) {
  final block = runCase(name, before, command, policy: policy);
  final out = applyCommand(before, command, ctx(policy: policy));
  if (out.rejection != null || out.noop) return block;
  return '$block-- cues\n${cueDetails(out.project)}';
}

typedef Case = (String, EditProject Function(), EditCommand);

/// Registers a golden test per case.
void goldenCases(GoldenFile golden, String prefix, List<Case> cases) {
  for (final (name, make, command) in cases) {
    test(name, () => golden.check('$prefix: $name', runSubCase('$prefix: $name', make(), command)));
  }
}

SubtitleCue cueIn(EditProject p, String id) => p.index.item(ItemId(id)) as SubtitleCue;

List<SubtitleCue> cuesOf(EditProject p, String lane) =>
    p.tracks.firstWhere((t) => t.id == TrackId(lane)).items.whereType<SubtitleCue>().toList();

/// Asserts the cues of [lane] are `(startFrame, endFrame)` pairs.
void expectFrames(EditProject p, String lane, List<(int, int)> frames) {
  expect([for (final c in cuesOf(p, lane)) (rate.frameIndexOf(c.start), rate.frameIndexOf(c.end))], frames);
}
