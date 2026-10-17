// OWNER: CORE-17
//
// Fixtures of the track, marker and project command tests: a project with every lane kind (a
// linked extracted-audio pair, a locked lane, a lane with a transition, markers) and a golden
// runner that adds the details `describe` does not show (lane flags and names, markers,
// canvas, frame rate, background).

import 'package:test/test.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';

import '../framework/ops_support.dart';

Track laneOf(
  String id,
  TrackKind kind,
  List<TimelineItem> items, {
  bool main = false,
  bool locked = false,
  bool hidden = false,
  bool muted = false,
  bool solo = false,
  AudioRole? role,
  String name = '',
  List<Transition> transitions = const [],
}) =>
    Track(
      id: TrackId(id),
      kind: kind,
      name: name,
      isMain: main,
      locked: locked,
      hidden: hidden,
      muted: muted,
      solo: solo,
      audioRole: kind == TrackKind.audio ? role : null,
      subtitle: kind == TrackKind.subtitle ? const SubtitleTrackData() : null,
      items: items,
      transitions: transitions,
    );

/// Canonical lane order (indexes in brackets):
/// [0] v_main (main, linked clip a, b) · [1] v2 (c, d with a transition) · [2] v3 (empty) ·
/// [3] ov1 · [4] ov2 (locked) · [5] t1 · [6] s1 · [7] a_orig (original, linked partner) ·
/// [8] a_music · [9] a_fx (empty, effects).
/// Markers: mk1 at frame 30 ("Intro"), mk2 at frame 90, mk3 at frame 150.
EditProject lanes() {
  final p = project([
    laneOf('v_main', TrackKind.video, [vclip('a', 0, 60, link: 'ln_a', detachedAudio: true), vclip('b', 60, 60)], main: true),
    laneOf('v2', TrackKind.video, [vclip('c', 0, 60, sourceIn: sec(10)), vclip('d', 60, 60, sourceIn: sec(10))],
        transitions: [transition('t_cd', 'c', 'd', frames: 12)]),
    laneOf('v3', TrackKind.video, const []),
    laneOf('ov1', TrackKind.overlay, [vclip('o1', 0, 30, media: 'md_image')]),
    laneOf('ov2', TrackKind.overlay, [vclip('o2', 0, 30, media: 'md_image')], locked: true),
    laneOf('t1', TrackKind.text, [text('x', 0, 30)]),
    laneOf('s1', TrackKind.subtitle, [cue('q', 0, 30)]),
    laneOf('a_orig', TrackKind.audio, [aclip('au', 0, 60, media: 'md_video', link: 'ln_a')], role: AudioRole.original),
    laneOf('a_music', TrackKind.audio, [aclip('m', 0, 90)], role: AudioRole.music, name: 'Score'),
    laneOf('a_fx', TrackKind.audio, const [], role: AudioRole.effects),
  ]);
  return p.copyWith(
    timeline: p.timeline.copyWith(markers: [
      Marker(id: const MarkerId('mk1'), time: f(30), name: 'Intro', colorIndex: 2, note: 'Start here'),
      Marker(id: const MarkerId('mk2'), time: f(90)),
      Marker(id: const MarkerId('mk3'), time: f(150), name: 'Outro', colorIndex: 5),
    ]),
  );
}

String _name(String id, int index) => id.length == 15 ? 'new$index' : id;

/// Lanes with flags, then markers and settings.
String projectDetails(EditProject p) {
  final b = StringBuffer();
  final r = p.settings.frameRate;
  var n = 0;
  for (final t in p.tracks) {
    final flags = [
      if (t.isMain) 'main',
      if (t.locked) 'locked',
      if (t.hidden) 'hidden',
      if (t.muted) 'muted',
      if (t.solo) 'solo',
    ];
    b.writeln('lane ${_name(t.id.value, n++)} ${t.kind.name}${t.name.isEmpty ? '' : ' "${t.name}"'}'
        '${t.audioRole == null ? '' : ' role=${t.audioRole!.name}'}${flags.isEmpty ? '' : ' [${flags.join(' ')}]'}'
        '${t.subtitle?.language == null ? '' : ' lang=${t.subtitle!.language}'} items=${t.items.length}');
  }
  for (final m in p.markers) {
    b.writeln('marker ${_name(m.id.value, 0)} @${r.frameIndexOf(m.time)}f${r.isOnGrid(m.time) ? '' : ' OFF-GRID'} "${m.name}" color=${m.colorIndex}'
        '${m.note == null ? '' : ' note="${m.note}"'}');
  }
  final s = p.settings;
  final bg = switch (s.background) {
    SolidBackground(:final color) => 'solid ${color.toRadixString(16)}',
    BlurOfMainBackground(:final radius) => 'blur $radius',
  };
  b.writeln('settings canvas=${s.canvas} rate=$r background=$bg');
  return b.toString();
}

/// `runCase` plus the project details of the result.
String runProjectCase(String name, EditProject before, EditCommand command) {
  final block = runCase(name, before, command);
  final out = applyCommand(before, command, ctx());
  if (out.rejection != null || out.noop) return block;
  return '$block-- details\n${projectDetails(out.project)}';
}

typedef Case = (String, EditProject Function(), EditCommand);

void goldenCases(GoldenFile golden, String prefix, List<Case> cases) {
  for (final (name, make, command) in cases) {
    test(name, () => golden.check('$prefix: $name', runProjectCase('$prefix: $name', make(), command)));
  }
}

Track trackIn(EditProject p, String id) => p.tracks.firstWhere((t) => t.id == TrackId(id));
