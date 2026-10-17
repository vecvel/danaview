import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_domain/danaview_domain.dart';
import 'package:danaview_engine/danaview_engine.dart';

void main() {
  group('op_engine FakePlaybackEngine Tests', () {
    late FakePlaybackEngine engine;

    setUp(() {
      engine = FakePlaybackEngine();
    });

    tearDown(() async {
      await engine.dispose();
    });

    test('Open media emits playing snapshot with metadata and chapters', () async {
      await engine.initialize();
      await engine.open(MediaSource.file('/test/media.mkv'));

      expect(engine.currentSnapshot.status, PlaybackStatus.playing);
      expect(engine.currentSnapshot.chapters.length, 3);
      expect(engine.currentSnapshot.duration, const Duration(minutes: 10));
    });

    test('Transport controls mutate snapshot state correctly', () async {
      await engine.initialize();
      await engine.open(MediaSource.file('/test/media.mkv'));

      await engine.pause();
      expect(engine.currentSnapshot.status, PlaybackStatus.paused);

      await engine.setVolume(150.0);
      expect(engine.currentSnapshot.volume, 150.0);

      await engine.setSpeed(1.5);
      expect(engine.currentSnapshot.speed, 1.5);

      await engine.seek(const Duration(minutes: 5));
      expect(engine.currentSnapshot.position, const Duration(minutes: 5));
    });
  });

  group('mpv error classification', () {
    test('audio device failures are a recoverable notice, not a playback failure', () {
      final error = classifyMpvError('Could not open/initialize audio device -> no sound.');
      expect(error, isA<AudioOutputUnavailable>());
      expect(error.recoverable, isTrue);
    });

    test('glitches mpv recovers from are warnings', () {
      for (final line in [
        'Error while decoding frame!',
        'Error while decoding frame (hardware decoding)!',
        'Can not open external file /videos/a.en.srt.',
        'Could not create device.',
        'Invalid video timestamp: 1.000 -> 0.900',
      ]) {
        expect(classifyMpvError(line), isA<PlaybackWarning>(), reason: line);
      }
    });

    test('real failures keep their specific type', () {
      final missing = classifyMpvError("Cannot open file '/videos/gone.mkv': No such file or directory");
      expect(missing, isA<FileNotFound>());
      expect((missing as FileNotFound).path, '/videos/gone.mkv');
      expect(classifyMpvError('Failed to recognize file format.'), isA<UnsupportedFormat>());
      expect(classifyMpvError('tcp: Connection refused'), isA<NetworkUnreachable>());
      expect(classifyMpvError('Something unexpected happened'), isA<GenericPlayerError>());
    });
  });

  group('mpv transport status', () {
    test('EOF reads as ended whatever order media_kit reports it in', () {
      const events = ['playing', 'completed', 'buffering'];
      final orders = [
        for (final a in events)
          for (final b in events)
            for (final c in events)
              if ({a, b, c}.length == 3) [a, b, c],
      ];
      for (final order in orders) {
        var playing = true, buffering = true, completed = false;
        for (final event in order) {
          switch (event) {
            case 'playing':
              playing = false;
            case 'completed':
              completed = true;
            case 'buffering':
              buffering = false;
          }
        }
        expect(
          mpvTransportStatus(playing: playing, buffering: buffering, completed: completed),
          PlaybackStatus.ended,
          reason: order.join(' -> '),
        );
      }
    });

    test('playing and paused are unaffected outside EOF', () {
      expect(mpvTransportStatus(playing: true, buffering: false, completed: false), PlaybackStatus.playing);
      expect(mpvTransportStatus(playing: false, buffering: false, completed: false), PlaybackStatus.paused);
      expect(mpvTransportStatus(playing: true, buffering: true, completed: false), PlaybackStatus.buffering);
    });
  });
}
