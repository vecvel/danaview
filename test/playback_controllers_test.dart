import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_data/danaview_data.dart';
import 'package:danaview_domain/danaview_domain.dart';
import 'package:danaview_engine/danaview_engine.dart';
import 'package:danaview_features/danaview_features.dart';

import 'library_test_utils.dart';

/// Records the per-file calls the controller makes on top of the fake engine.
class _RecordingEngine extends FakePlaybackEngine {
  final calls = <String>[];

  @override
  Future<void> open(MediaSource source, {Duration? startAt}) {
    calls.add('open ${source.uri}');
    return super.open(source, startAt: startAt);
  }

  @override
  Future<void> setSubtitleDelay(Duration delay) {
    calls.add('subDelay ${delay.inMilliseconds}');
    return super.setSubtitleDelay(delay);
  }

  @override
  Future<void> setAudioDelay(Duration delay) {
    calls.add('audioDelay ${delay.inMilliseconds}');
    return super.setAudioDelay(delay);
  }

  @override
  Future<void> setVideoAdjust(VideoAdjust adjust) {
    calls.add('adjust ${adjust == VideoAdjust.normal ? 'normal' : 'custom'}');
    return super.setVideoAdjust(adjust);
  }

  @override
  Future<void> seek(Duration position, {SeekMode mode = SeekMode.keyframe}) {
    calls.add('seek ${position.inSeconds}');
    return super.seek(position, mode: mode);
  }
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

PlayerSnapshot _snapshot(PlaybackStatus status, Duration position) => PlayerSnapshot(
      status: status,
      position: position,
      duration: const Duration(minutes: 10),
    );

void main() {
  late LibraryTestEnv env;
  late _RecordingEngine engine;
  late ProviderContainer container;
  final a = localRef('/videos/a.mkv');
  final b = localRef('/videos/b.mkv');
  final c = localRef('/videos/c.mkv');

  setUp(() async {
    env = await LibraryTestEnv.create();
    engine = _RecordingEngine();
    await engine.initialize();
    container = ProviderContainer(overrides: [
      ...env.overrides,
      playbackEngineProvider.overrideWithValue(engine),
    ]);
  });

  tearDown(() async {
    container.dispose();
    await engine.dispose();
    await env.dispose();
  });

  QueueController queue() => container.read(queueControllerProvider.notifier);
  PlayerController player() => container.read(playerControllerProvider.notifier);
  QueueState queueState() => container.read(queueControllerProvider);
  PlayerState playerState() => container.read(playerControllerProvider);

  Future<void> endPlayback() async {
    engine.emitMockSnapshot(_snapshot(PlaybackStatus.ended, const Duration(minutes: 10)));
    await _flush();
    await _flush();
  }

  group('QueueController', () {
    test('repeat one replays a single opened file at its end', () async {
      await queue().playFrom([a]);
      await _flush();
      queue().setRepeat(RepeatMode.one);
      engine.calls.clear();
      await endPlayback();
      expect(engine.calls, contains('seek 0'));
      expect(engine.currentSnapshot.status, PlaybackStatus.playing);
    });

    test('repeat one replays the last item of a queue', () async {
      await queue().playFrom([a, b], startIndex: 1);
      await _flush();
      queue().setRepeat(RepeatMode.one);
      engine.calls.clear();
      await endPlayback();
      expect(engine.calls, ['seek 0']);
      expect(queueState().currentIndex, 1);
    });

    test('removing the playing item plays the one that took its place', () async {
      await queue().playFrom([a, b, c]);
      await _flush();
      engine.calls.clear();
      await queue().remove(0);
      expect(queueState().items, [b, c]);
      expect(queueState().currentIndex, 0);
      expect(playerState().currentMediaRef, b);
      expect(engine.calls.first, 'open ${b.pathOrUri}');

      await queue().remove(1);
      expect(queueState().currentIndex, 0);
      await queue().remove(0);
      await _flush();
      expect(queueState().currentIndex, -1);
      expect(engine.currentSnapshot.status, PlaybackStatus.idle);
    });

    test('items queued while shuffled survive turning shuffle off; removed ones stay gone', () async {
      await queue().playFrom([a, b]);
      queue().setShuffle(true);
      await queue().addToQueue([c]);
      final extra = localRef('/videos/d.mkv');
      await queue().playNext(extra);
      await queue().remove(queueState().items.indexOf(b));
      queue().setShuffle(false);
      expect(queueState().items, [a, extra, c]);
      expect(queueState().currentItem, a);
    });

    test('clear resets queue items and clears player state', () async {
      await queue().playFrom([a, b]);
      await _flush();
      expect(queueState().items.length, 2);
      expect(playerState().currentMediaRef, a);

      await queue().clear();
      await _flush();

      expect(queueState().items, isEmpty);
      expect(queueState().currentItem, isNull);
      expect(queueState().currentIndex, -1);
      expect(playerState().currentMediaRef, isNull);
      expect(playerState().status, PlaybackStatus.idle);
      expect(playerState().error, isNull);
    });
  });

  group('PlayerController', () {
    test("the next file's resume point is never written with the previous file's position", () async {
      await queue().playFrom([a, b]);
      await _flush();
      engine.emitMockSnapshot(_snapshot(PlaybackStatus.playing, const Duration(minutes: 5)));
      await _flush();

      // A stale position from the first file is still queued when the second one opens.
      engine.emitMockSnapshot(_snapshot(PlaybackStatus.playing, const Duration(minutes: 6)));
      final opening = queue().next();
      player().saveResumePoint();
      await opening;
      player().saveResumePoint();
      await _flush();
      player().saveResumePoint();

      expect(env.session.getResumePosition(a.id, Duration.zero), const Duration(minutes: 5));
      expect(env.session.getResumePosition(b.id, Duration.zero), isNull);
      expect(playerState().position, Duration.zero);
    });

    test("per-file delays and colour are applied for every file, so one file's values never leak", () async {
      await env.session.saveSubtitleDelay(a.id, const Duration(seconds: 2));
      await env.session.saveAudioDelay(a.id, const Duration(milliseconds: 300));
      await queue().playFrom([a, b]);
      await _flush();
      engine.calls.clear();
      await queue().next();
      expect(engine.calls, ['open ${b.pathOrUri}', 'subDelay 0', 'audioDelay 0', 'adjust normal']);
    });

    test('a superseded open does not apply its settings or record history', () async {
      await env.session.saveSubtitleDelay(a.id, const Duration(seconds: 2));
      final first = player().openMedia(a);
      final second = player().openMedia(b);
      await Future.wait([first, second]);
      expect(engine.calls.where((call) => call.startsWith('subDelay')), ['subDelay 0']);
      expect(env.library.getRecentlyPlayed().map((m) => m.pathOrUri), [b.pathOrUri]);
      expect(playerState().currentMediaRef, b);
    });

    test('fatal error transitions status to error and does not revert on snapshot', () async {
      await player().openMedia(a);
      await _flush();

      engine.emitMockError(const UnsupportedFormat('test.xyz', details: 'Failed to recognize format'));
      await _flush();

      expect(playerState().status, PlaybackStatus.error);
      expect(playerState().error, isA<UnsupportedFormat>());

      // Subsequent engine snapshot reporting playing status should NOT overwrite error status
      engine.emitMockSnapshot(_snapshot(PlaybackStatus.playing, const Duration(seconds: 1)));
      await _flush();

      expect(playerState().status, PlaybackStatus.error);
      expect(playerState().error, isA<UnsupportedFormat>());
    });

    test('togglePlay when in error state retries openMedia', () async {
      await player().openMedia(a);
      await _flush();
      engine.calls.clear();

      engine.emitMockError(const UnsupportedFormat('test.xyz'));
      await _flush();
      expect(playerState().status, PlaybackStatus.error);

      await player().togglePlay();
      await _flush();
      expect(engine.calls, contains('open ${a.pathOrUri}'));
    });
  });

  group('Sidecar subtitles', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('danaview_subs'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('only match the video name, in its folder and Subs folders, without duplicates', () async {
      File(joinPath([dir.path, 'Show S01E01.mkv'])).writeAsStringSync('');
      for (final name in ['Show S01E01.srt', 'Show S01E01.en.ass', 'Show S01E02.srt', 'notes.txt']) {
        File(joinPath([dir.path, name])).writeAsStringSync('');
      }
      Directory(joinPath([dir.path, 'Subs'])).createSync();
      for (final name in ['Show S01E01.es.srt', 'Show S01E02.es.srt']) {
        File(joinPath([dir.path, 'Subs', name])).writeAsStringSync('');
      }

      final found = await LibraryRepository.discoverSidecarSubtitles(joinPath([dir.path, 'Show S01E01.mkv']));
      final names = found.map((path) => path.substring(dir.path.length + 1)).toList()..sort();
      expect(names, ['Show S01E01.en.ass', 'Show S01E01.srt', joinPath(['Subs', 'Show S01E01.es.srt'])]);
    });
  });

  test('SessionRepository moves per-file values to rebased ids', () async {
    const oldPath = '/var/mobile/Containers/Data/Application/11111111-2222-3333-4444-555555555555/Documents/a.mkv';
    const newPath = '/var/mobile/Containers/Data/Application/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE/Documents/a.mkv';
    await env.session.saveResumePosition(oldPath, const Duration(minutes: 3), const Duration(minutes: 40));
    await env.session.saveSubtitleDelay(oldPath, const Duration(seconds: 1));
    await env.session.saveResumePosition('/Volumes/x.mkv', const Duration(minutes: 2), const Duration(minutes: 40));

    final moved = await env.session.migrateMediaIds((id) => id == oldPath ? newPath : id);
    expect(moved, 3);
    expect(env.session.getResumePosition(newPath, Duration.zero), const Duration(minutes: 3));
    expect(env.session.getResumeInfo(newPath)?.duration, const Duration(minutes: 40));
    expect(env.session.getSubtitleDelay(newPath), const Duration(seconds: 1));
    expect(env.session.getResumePosition(oldPath, Duration.zero), isNull);
    expect(env.session.getResumePosition('/Volumes/x.mkv', Duration.zero), const Duration(minutes: 2));
  });
}
