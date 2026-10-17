// OWNER: AI-12
//
// DomainTimelineView: the read-only adapter over EditProject (ai.md §10.1).

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_transcription/danaview_transcription.dart';

import 'timeline_fixtures.dart';

final class _Access implements MediaAccessPort {
  _Access({this.fail = false});
  final bool fail;
  final resolved = <MediaLocator>[];

  @override
  Future<ResolvedMedia> resolve(MediaLocator locator) async {
    if (fail) throw StateError('offline');
    resolved.add(locator);
    return const ResolvedMedia(uri: 'file:///media/x.mp4', fingerprint: 'qh');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  final v1 = asset('md_v1');
  final v2 = asset('md_v2', duration: sec(30));
  final img = asset('md_img', kind: MediaKind.image);
  final mute = asset('md_mute', hasAudio: false);

  test('project facts: id, frame rate, canvas and duration', () {
    final p = project([mainTrack([clip('a', 0, 5000, 'md_v1')])], [v1],
        settings: const ProjectSettings(canvas: CanvasSpec(aspect: AspectRatio.portrait9x16)));
    final view = DomainTimelineView(p);
    expect(view.project, p.id);
    expect(view.frameRate, FrameRate.fps30);
    expect(view.duration, ms(5000));
    expect(view.canvasSize.width, lessThan(view.canvasSize.height));
  });

  test('audible clips carry volume, quick hash, ranges and flags', () {
    final p = project([
      mainTrack([clip('a', 0, 5000, 'md_v1', sourceInMs: 2000, volume: 0.5, audioStream: 1)]),
    ], [v1]);
    final c = DomainTimelineView(p).audibleClips().single;
    expect(c.id, const ItemId('a'));
    expect(c.media, const MediaId('md_v1'));
    expect(c.mediaQuickHash, 'qh_md_v1');
    expect(c.audioStream, 1);
    expect(c.effectiveVolume, 0.5);
    expect(c.timelineRange, TimeRange(0, ms(5000)));
    expect(c.sourceRange, TimeRange(ms(2000), ms(7000)));
    expect(c.reversed, isFalse);
    expect(c.isFreeze, isFalse);
    expect(c.timelineTimeOf(ms(3000)), ms(1000));
    expect(c.timelineTimeOf(ms(100)), isNull);
    expect(c.timelineTimeOf(ms(9000)), isNull);
  });

  test('effective volume is 0 for muted clips, muted tracks and soloed-out tracks', () {
    final p = project([
      mainTrack([clip('clipMuted', 0, 1000, 'md_v1', muted: true), clip('ok', 1000, 2000, 'md_v1')]),
      lane('tr_a', TrackKind.audio, [clip('trackMuted', 0, 1000, 'md_v2')], muted: true),
    ], [v1, v2]);
    final vol = {for (final c in DomainTimelineView(p).audibleClips()) c.id.value: c.effectiveVolume};
    expect(vol, {'clipMuted': 0.0, 'ok': 1.0, 'trackMuted': 0.0});

    final solo = project([
      mainTrack([clip('video', 0, 1000, 'md_v1')]),
      lane('tr_a', TrackKind.audio, [clip('voice', 0, 1000, 'md_v2')], solo: true),
    ], [v1, v2]);
    final soloVol = {for (final c in DomainTimelineView(solo).audibleClips()) c.id.value: c.effectiveVolume};
    expect(soloVol, {'video': 0.0, 'voice': 1.0});
  });

  test('images, text, subtitle clips and detached audio are not audible clips; stills are flagged', () {
    final still = asset('md_still', derived: const StillSpec(MediaId('md_v1'), 1000000, sourceQuickHash: 'qh_md_v1'), hasAudio: false);
    final p = project([
      mainTrack([clip('i', 0, 1000, 'md_img'), clip('s', 1000, 2000, 'md_still'), clip('d', 2000, 3000, 'md_v1', detached: true), clip('v', 3000, 4000, 'md_v1')]),
      lane('tr_t', TrackKind.text, [TextItem(id: const ItemId('t'), start: 0, duration: ms(1000), text: 'Hi')]),
    ], [v1, img, still]);
    final clips = {for (final c in DomainTimelineView(p).audibleClips()) c.id.value: c};
    expect(clips.keys, {'s', 'v'});
    expect(clips['s']!.isFreeze, isTrue);
    expect(clips['v']!.isFreeze, isFalse);
  });

  test('tracks expose kind, role and flags', () {
    final p = project([
      mainTrack(const []),
      lane('tr_a', TrackKind.audio, const [], role: AudioRole.voice, muted: true, solo: true),
    ], const []);
    final t = DomainTimelineView(p).tracks.toList();
    expect(t[0].isMain, isTrue);
    expect(t[0].kind, TrackKind.video);
    expect(t[1].kind, TrackKind.audio);
    expect(t[1].role, AudioRole.voice);
    expect(t[1].muted, isTrue);
    expect(t[1].solo, isTrue);
    expect(t[1].hidden, isFalse);
    expect(t[1].locked, isFalse);
  });

  test('cut points are the clip boundaries of audible clips, deduplicated and sorted', () {
    final p = project([
      mainTrack([clip('a', 0, 4000, 'md_v1'), clip('b', 4000, 9000, 'md_v1', sourceInMs: 4000), clip('m', 9000, 10000, 'md_v1', muted: true)]),
      lane('tr_a', TrackKind.audio, [clip('c', 2000, 9000, 'md_v2')]),
    ], [v1, v2]);
    expect(DomainTimelineView(p).cutPoints, [ms(2000), ms(4000), ms(9000)]);
  });

  test('audioInfo reports audio, duration and stills; unknown media is null', () {
    final view = DomainTimelineView(project([mainTrack(const [])], [v1, v2, img, mute]));
    expect(view.audioInfo(const MediaId('md_v2'))!.duration, sec(30));
    expect(view.audioInfo(const MediaId('md_v2'))!.hasAudio, isTrue);
    expect(view.audioInfo(const MediaId('md_mute'))!.hasAudio, isFalse);
    expect(view.audioInfo(const MediaId('md_img'))!.isStill, isTrue);
    expect(view.audioInfo(const MediaId('md_v1'))!.isStill, isFalse);
    expect(view.audioInfo(const MediaId('md_x')), isNull);
  });

  test('subtitle tracks list their cues and provenance', () {
    final p = project([
      mainTrack(const []),
      lane('tr_s', TrackKind.subtitle, [SubtitleCue(id: const ItemId('q'), start: 0, duration: ms(1000), text: 'Hello')]),
    ], const []);
    final tracks = DomainTimelineView(p).subtitleTracks.toList();
    expect(tracks, hasLength(1));
    expect(tracks.single.cues.single.text, 'Hello');
    expect(tracks.single.cues.single.range, TimeRange(0, ms(1000)));
    expect(tracks.single.cues.single.editedAfterGeneration, isFalse);
    expect(tracks.single.provenance, isNull);
  });

  test('resolveMedia goes through the access port and is null offline or for unknown media', () async {
    final p = project([mainTrack(const [])], [v1]);
    final access = _Access();
    final view = DomainTimelineView(p, access: access);
    expect((await view.resolveMedia(const MediaId('md_v1')))!.uri, 'file:///media/x.mp4');
    expect(access.resolved, [v1.locator]);
    expect(await view.resolveMedia(const MediaId('md_x')), isNull);
    expect(await DomainTimelineView(p).resolveMedia(const MediaId('md_v1')), isNull);
    expect(await DomainTimelineView(p, access: _Access(fail: true)).resolveMedia(const MediaId('md_v1')), isNull);
  });

  test('a ramp clip inverts through ClipTimeMap', () {
    final ramp = SpeedRamp([const SpeedPoint(0, 1), const SpeedPoint(1, 4)]);
    final p = project([mainTrack([clip('r', 1000, 9000, 'md_v1', speed: ramp)])], [v1]);
    final c = DomainTimelineView(p).audibleClips().single;
    final end = c.sourceRange.end;
    expect(c.timelineTimeOf(c.sourceRange.start), ms(1000));
    expect(c.timelineTimeOf(end), isNull); // the source range is half open
    expect(c.timelineTimeOf(end - 1), closeTo(ms(9000), 50));
    final mid = c.timelineTimeOf(end ~/ 2)!;
    expect(mid, greaterThan(ms(1000)));
    expect(mid, lessThan(ms(9000)));
  });
}
