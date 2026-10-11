// OWNER: CORE-09
//
// Shared fixtures for the command tests (test/ops/framework, test/ops/clip, test/ops/clipboard):
// a pool of media, small lane/item builders on a 30 fps grid, a readable timeline dump for the
// before/after golden files, and the golden-file helper.
//
// Goldens: each `GoldenFile` holds named blocks (`== name`). Run with `UPDATE_GOLDENS=1` to
// rewrite them, then review the diff.

import 'dart:io';

import 'package:test/test.dart';
import 'package:danaview_editor_core/eval.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';

const FrameRate rate = FrameRate.fps30;

/// Start of frame [k] on the 30 fps grid.
TimeUs f(int k) => rate.timeOfFrame(k);

/// Seconds as µs.
TimeUs sec(num s) => (s * microsPerSecond).round();

final DateTime when = DateTime.utc(2026, 10, 10, 9);

/// A pool asset.
MediaAsset asset(
  String id,
  MediaKind kind, {
  TimeUs duration = 0,
  bool hasAudio = false,
  String? hash,
  int size = 1000,
  DerivedSpec? derived,
  AssetStatus status = AssetStatus.ready,
  int audioStreams = 0,
}) {
  final visual = kind == MediaKind.video || kind == MediaKind.image || kind == MediaKind.still;
  return MediaAsset(
    id: MediaId(id),
    kind: kind,
    displayName: id,
    locator: AppRelativeLocator(AppRoot.documents, 'media/$id'),
    ownership: MediaOwnership.managedCopy,
    fingerprint: MediaFingerprint(sizeBytes: size, quickHash: hash ?? 'q-$id', duration: duration),
    probe: MediaProbe(
      kind: kind,
      duration: duration,
      hasVideo: visual,
      hasAudio: hasAudio,
      width: visual ? 1920 : null,
      height: visual ? 1080 : null,
      audioStreams: hasAudio ? (audioStreams == 0 ? 1 : audioStreams) : 0,
    ),
    origin: MediaOrigin.files,
    derived: derived,
    status: status,
    addedAt: when,
  );
}

/// The standard pool.
final MediaPool basePool = MediaPool({
  for (final a in [
    asset('md_video', MediaKind.video, duration: sec(60), hasAudio: true),
    asset('md_video2', MediaKind.video, duration: sec(10), hasAudio: true),
    asset('md_short', MediaKind.video, duration: sec(1), hasAudio: true),
    asset('md_noaudio', MediaKind.video, duration: sec(20)),
    asset('md_image', MediaKind.image),
    asset('md_music', MediaKind.audio, duration: sec(120), hasAudio: true),
    asset('md_rec', MediaKind.recording, duration: sec(30), hasAudio: true),
    asset('md_lut', MediaKind.lut),
  ])
    a.id: a,
});

/// A visual clip on frames `[k0, k0 + n)`.
MediaClip vclip(
  String id,
  int k0,
  int n, {
  String media = 'md_video',
  TimeUs sourceIn = 0,
  String? link,
  SpeedSpec speed = SpeedSpec.normal,
  bool reversed = false,
  bool detachedAudio = false,
  KeyframeSet keyframes = KeyframeSet.empty,
  AudioProps audio = AudioProps.unity,
}) =>
    MediaClip(
      id: ItemId(id),
      start: f(k0),
      duration: f(k0 + n) - f(k0),
      media: MediaId(media),
      sourceIn: sourceIn,
      link: link == null ? null : LinkId(link),
      speed: speed,
      reversed: reversed,
      detachedAudio: detachedAudio,
      visual: VisualProps.neutral,
      keyframes: keyframes,
      audio: audio,
    );

/// An audio clip on frames `[k0, k0 + n)`.
MediaClip aclip(
  String id,
  int k0,
  int n, {
  String media = 'md_music',
  TimeUs sourceIn = 0,
  String? link,
  SpeedSpec speed = SpeedSpec.normal,
  bool reversed = false,
  KeyframeSet keyframes = KeyframeSet.empty,
  AudioProps audio = AudioProps.unity,
}) =>
    MediaClip(
      id: ItemId(id),
      start: f(k0),
      duration: f(k0 + n) - f(k0),
      media: MediaId(media),
      sourceIn: sourceIn,
      link: link == null ? null : LinkId(link),
      speed: speed,
      reversed: reversed,
      keyframes: keyframes,
      audio: audio,
    );

/// A text item on frames `[k0, k0 + n)`.
TextItem text(String id, int k0, int n, {String value = 'Title', TextAnimation animation = TextAnimation.none, String? link}) =>
    TextItem(
      id: ItemId(id),
      start: f(k0),
      duration: f(k0 + n) - f(k0),
      text: value,
      animation: animation,
      link: link == null ? null : LinkId(link),
    );

/// A subtitle cue on frames `[k0, k0 + n)`.
SubtitleCue cue(String id, int k0, int n, {String value = 'Hello'}) =>
    SubtitleCue(id: ItemId(id), start: f(k0), duration: f(k0 + n) - f(k0), text: value);

/// A lane.
Track lane(
  String id,
  TrackKind kind,
  List<TimelineItem> items, {
  bool main = false,
  bool locked = false,
  AudioRole? role,
  List<Transition> transitions = const [],
}) =>
    Track(
      id: TrackId(id),
      kind: kind,
      isMain: main,
      locked: locked,
      audioRole: kind == TrackKind.audio ? role : null,
      subtitle: kind == TrackKind.subtitle ? const SubtitleTrackData() : null,
      items: items,
      transitions: transitions,
    );

/// A transition.
Transition transition(String id, String left, String right, {TransitionKind kind = TransitionKind.crossDissolve, int frames = 10}) =>
    Transition(id: TransitionId(id), left: ItemId(left), right: ItemId(right), kind: kind, durationFrames: frames);

/// A project with [tracks] and [pool].
EditProject project(List<Track> tracks, {MediaPool? pool, ViewState view = ViewState.initial, String id = 'pr_fixture', FrameRate frameRate = rate}) =>
    EditProject(
      id: ProjectId(id),
      meta: ProjectMeta(name: 'Fixture', createdAt: when, updatedAt: when),
      timeline: Timeline(settings: ProjectSettings(frameRate: frameRate), tracks: tracks),
      pool: pool ?? basePool,
      view: view,
    );

/// The standard project of the structural and clipboard goldens:
///
/// * main: a [0,60) md_video (linked ln_a, audio extracted) · b [60,120) md_video from 10 s ·
///   gap · c [150,210) md_video2; a cross dissolve a|b of 10 frames;
/// * overlay: p1 [30,60) image;
/// * text: t1 [0,45) "Title";
/// * subtitle: s1 [0,30) "Hello";
/// * audio (original): a_au [0,60) md_video (linked ln_a);
/// * audio (music): m [0,300) md_music.
EditProject standard({bool lockMain = false, bool rippleEnabled = true, List<TimelineItem>? extraOriginal}) => project(
      [
        lane('tr_main', TrackKind.video, [
          vclip('it_a', 0, 60, link: 'ln_a', detachedAudio: true),
          vclip('it_b', 60, 60, sourceIn: sec(10)),
          vclip('it_c', 150, 60, media: 'md_video2'),
        ], main: true, locked: lockMain, transitions: [transition('tx_ab', 'it_a', 'it_b')]),
        lane('tr_ov1', TrackKind.overlay, [vclip('it_p1', 30, 30, media: 'md_image')]),
        lane('tr_txt', TrackKind.text, [text('it_t1', 0, 45)]),
        lane('tr_sub', TrackKind.subtitle, [cue('it_s1', 0, 30)]),
        lane('tr_orig', TrackKind.audio, [aclip('it_a_au', 0, 60, media: 'md_video', link: 'ln_a'), ...?extraOriginal],
            role: AudioRole.original),
        lane('tr_music', TrackKind.audio, [aclip('it_m', 0, 300)], role: AudioRole.music),
      ],
      view: ViewState(rippleEnabled: rippleEnabled),
    );

/// A context with deterministic ids.
EditContext ctx({int seed = 7, EditPolicy policy = const EditPolicy(), int? stamp, MediaPool? pool}) =>
    EditContext(ids: SeededIdGenerator(seed), now: when, policy: policy, stamp: stamp, pool: pool);

/// Fails when [p] breaks any invariant (full validation, ARCH §6.9: "fully after every step in
/// tests").
void expectValid(EditProject p, [String reason = '']) {
  final v = validate(p);
  expect(v, isEmpty, reason: 'invariants broken $reason: ${v.join('\n')}');
}

// -------------------------------------------------------------------------------------------
// Readable dumps.
// -------------------------------------------------------------------------------------------

/// Names generated ids (`<prefix>` + 12 characters) `<prefix>#n` by first appearance, so goldens
/// stay readable; fixture ids are shown as they are.
final class Namer {
  final Map<String, String> _names = {};
  final Map<String, int> _counts = {};

  String call(String? id) {
    if (id == null) return '-';
    if (id.length != 15) return id;
    return _names.putIfAbsent(id, () {
      final prefix = id.substring(0, 3);
      final n = (_counts[prefix] ?? 0) + 1;
      _counts[prefix] = n;
      return '$prefix#$n';
    });
  }
}

String _speed(SpeedSpec s) => switch (s) {
      ConstantSpeed(:final rate) => rate == 1 ? '' : ' x$rate',
      SpeedRamp(:final points) => ' ramp(${points.map((p) => '${p.x.toStringAsFixed(3)}:${p.y}').join(' ')})',
    };

String _keys(KeyframeSet set) {
  if (set.isEmpty) return '';
  final parts = [
    for (final e in set.byChannel.entries)
      '${e.key}@${e.value.keys.map((k) => '${rate.frameIndexNearest(k.t)}f=${k.v}').join(',')}',
  ];
  return ' keys{${parts.join('; ')}}';
}

/// One line per lane and item: frames `[k0,k1)`, media, source µs, flags. With [unchangedFrom],
/// lanes equal to that project's lane of the same id are summarized in one `unchanged:` line.
String describe(EditProject p, Namer n, {EditProject? unchangedFrom}) {
  final r = p.settings.frameRate;
  int k(TimeUs t) => r.frameIndexOf(t);
  final b = StringBuffer();
  final old = {for (final t in unchangedFrom?.tracks ?? const <Track>[]) t.id: t};
  final same = <String>[];
  for (final t in p.tracks) {
    if (old[t.id] == t) {
      same.add(n(t.id));
      continue;
    }
    b.write('${n(t.id)} ${t.kind.name}');
    if (t.isMain) b.write(' main');
    if (t.locked) b.write(' locked');
    if (t.audioRole != null) b.write(' role=${t.audioRole!.name}');
    b.writeln();
    for (final i in t.items) {
      b.write('  ${n(i.id)} [${k(i.start)},${k(i.end)})');
      if (!r.isOnGrid(i.start) || !r.isOnGrid(i.end)) b.write(' OFF-GRID');
      switch (i) {
        case MediaClip():
          final out = i.sourceIn + ClipTimeMap.sourceLengthOf(i.duration, i.speed);
          b.write(' ${n(i.media)} src[${i.sourceIn},$out)${_speed(i.speed)}');
          if (i.reversed) b.write(' rev');
          if (i.visual == null) b.write(' audio');
          if (i.detachedAudio) b.write(' detached');
          final a = i.audio;
          if (a.fadeIn != 0 || a.fadeOut != 0) b.write(' fade ${r.frameIndexNearest(a.fadeIn)}f/${r.frameIndexNearest(a.fadeOut)}f');
          b.write(_keys(i.keyframes));
        case TextItem():
          b.write(' text "${i.text}"');
          final an = i.animation;
          if (an.inKind != TextAnimKind.none || an.outKind != TextAnimKind.none) {
            b.write(' anim ${an.inKind.name}:${r.frameIndexNearest(an.inDuration)}f/${an.outKind.name}:${r.frameIndexNearest(an.outDuration)}f');
          }
          b.write(_keys(i.keyframes));
        case SubtitleCue():
          b.write(' cue "${i.text}"');
      }
      if (i.link != null) b.write(' link=${n(i.link)}');
      if (i.label != null) b.write(' label="${i.label}"');
      b.writeln();
    }
    for (final tr in t.transitions) {
      b.writeln('  ~ ${n(tr.id)} ${n(tr.left)}|${n(tr.right)} ${tr.kind.name} ${tr.durationFrames}f');
    }
  }
  if (unchangedFrom != null) {
    final removed = [for (final id in old.keys) if (!p.tracks.any((t) => t.id == id)) n(id)];
    if (same.isNotEmpty) b.writeln('unchanged: ${same.join(', ')}');
    if (removed.isNotEmpty) b.writeln('removed lanes: ${removed.join(', ')}');
  }
  return b.toString();
}

String _rangeFrames(TimeRange r) => '[${rate.frameIndexOf(r.start)},${rate.frameIndexOf(r.end)})';

/// Applies [command] (and dry-runs it) and renders the case for a golden file. The applied result
/// must validate fully, and the dry run must agree with the apply.
String runCase(String name, EditProject before, EditCommand command, {EditPolicy policy = const EditPolicy(), bool showBefore = true}) {
  final n = Namer();
  final b = StringBuffer()..writeln('== $name');
  b.writeln('-- command: ${command.label} | $command');
  if (showBefore) {
    final dump = describe(before, n);
    if (dump == describe(standard(), Namer())) {
      b.writeln('-- before: standard()');
    } else {
      b
        ..writeln('-- before')
        ..write(dump);
    }
  }
  final outcome = applyCommand(before, command, ctx(policy: policy));
  final preview = dryRun(before, command, ctx(policy: policy));
  expect(preview.rejection, outcome.rejection, reason: '$name: dry run and apply disagree');
  final r = outcome.rejection;
  if (r != null) {
    expect(identical(outcome.project, before), isTrue, reason: '$name: a rejection must leave the project unchanged');
    b.writeln('-- rejected: ${_rejection(r, n)}');
    return b.toString();
  }
  if (outcome.noop) {
    b.writeln('-- noop');
    return b.toString();
  }
  expectValid(outcome.project, name);
  for (final e in preview.placements.entries) {
    final loc = outcome.project.index.locate(e.key);
    expect(loc, isNotNull, reason: '$name: preview places a missing item');
    expect(e.value.range, loc!.item.range, reason: '$name: preview range differs from apply');
  }
  b
    ..writeln('-- after')
    ..write(describe(outcome.project, n, unchangedFrom: before));
  final added = outcome.project.pool.assets.keys.where((id) => !before.pool.contains(id)).toList();
  if (added.isNotEmpty) b.writeln('-- pool added: ${added.map(n.call).join(', ')}');
  b.writeln('-- affected: ${(outcome.affected.map(n.call).toList()..sort()).join(', ')}');
  b.writeln('-- changed lanes: ${(outcome.changedTracks.map(n.call).toList()..sort()).join(', ')}');
  if (outcome.createdTracks.isNotEmpty) b.writeln('-- created lanes: ${outcome.createdTracks.map(n.call).join(', ')}');
  if (outcome.notices.isNotEmpty) {
    b.writeln('-- notices: ${outcome.notices.map((x) => '${x.code}${x.count == 0 ? '' : ' x${x.count}'}'
        '${x.items.isEmpty ? '' : ' {${(x.items.map(n.call).toList()..sort()).join(', ')}}'}').join('; ')}');
  }
  final sel = outcome.selection;
  if (sel != null) b.writeln('-- selection: {${(sel.items.map(n.call).toList()..sort()).join(', ')}} primary ${n(sel.primary)}');
  if (preview.createsTracks.isNotEmpty) {
    b.writeln('-- preview creates: ${preview.createsTracks.map((t) => '${t.kind.name}@${t.index}').join(', ')}');
  }
  final c = preview.clampedTo;
  if (c != null) b.writeln('-- clamped to: ${_rangeFrames(c)}');
  return b.toString();
}

String _rejection(EditRejection r, Namer n) => switch (r) {
      TrackLocked(:final track) => 'TrackLocked(${n(track)})',
      ItemNotFound(:final id) => 'ItemNotFound(${n(id)})',
      WouldOverlap(:final track, :final range) => 'WouldOverlap(${n(track)}, ${_rangeFrames(range)})',
      OutOfSourceRange(:final limit) => 'OutOfSourceRange(${limit == null ? '-' : '${rate.frameIndexOf(limit)}f'})',
      NothingAtTime(:final time) => 'NothingAtTime(${rate.frameIndexOf(time)}f)',
      RippleBlockedByLinkedItem(:final item) => 'RippleBlockedByLinkedItem(${n(item)})',
      IncompatibleTrack(:final track) => 'IncompatibleTrack(${n(track)})',
      MediaUnavailable(:final media) => 'MediaUnavailable(${n(media)})',
      InternalInconsistency(:final violations, :final detail) => 'InternalInconsistency($violations $detail)',
      _ => r.toString(),
    };

// -------------------------------------------------------------------------------------------
// Golden files.
// -------------------------------------------------------------------------------------------

/// Whether goldens are being rewritten (`UPDATE_GOLDENS=1`).
final bool updateGoldens = Platform.environment['UPDATE_GOLDENS'] == '1';

/// A golden file of named blocks.
final class GoldenFile {
  /// Creates the file at [path] (relative to the package root).
  GoldenFile(this.path);

  /// Path of the golden file.
  final String path;

  final Map<String, String> _actual = {};
  Map<String, String>? _expected;

  Map<String, String> get expected => _expected ??= _parse();

  Map<String, String> _parse() {
    final file = File(path);
    if (!file.existsSync()) return const {};
    final out = <String, String>{};
    String? name;
    final buf = StringBuffer();
    void flush() {
      if (name != null) out[name] = buf.toString();
      buf.clear();
    }

    for (final line in file.readAsLinesSync()) {
      if (line.startsWith('== ')) {
        flush();
        name = line.substring(3);
      }
      if (name != null) buf.writeln(line);
    }
    flush();
    return out;
  }

  /// Compares [block] (starting with `== name`) with the stored block, or records it for update.
  void check(String name, String block) {
    _actual[name] = block;
    if (updateGoldens) return;
    expect(expected.containsKey(name), isTrue, reason: 'golden "$name" missing in $path (run with UPDATE_GOLDENS=1)');
    expect(block.trimRight(), expected[name]!.trimRight(), reason: 'golden "$name" in $path differs');
  }

  /// Writes the recorded blocks when updating.
  void save() {
    if (!updateGoldens || _actual.isEmpty) return;
    File(path)
      ..createSync(recursive: true)
      ..writeAsStringSync(_actual.values.join('\n'));
  }
}
