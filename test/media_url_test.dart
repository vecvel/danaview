import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_domain/danaview_domain.dart';

void main() {
  group('MediaUrl.tryParse', () {
    test('accepts http(s), HLS and DASH links as remote refs', () {
      final mp4 = MediaUrl.tryParse('  https://cdn.example.com/films/My%20Movie.mp4?token=abc#t=10 \n')!;
      expect(mp4.isRemote, isTrue);
      expect(mp4.id, 'https://cdn.example.com/films/My%20Movie.mp4?token=abc#t=10');
      expect(mp4.pathOrUri, mp4.id);
      expect(mp4.title, 'My Movie.mp4');

      expect(MediaUrl.tryParse('http://example.com/live/index.m3u8')!.title, 'index.m3u8');
      expect(MediaUrl.tryParse('https://example.com/dash/manifest.mpd')!.title, 'manifest.mpd');
    });

    test('accepts streaming schemes', () {
      for (final url in [
        'rtsp://192.168.1.10:554/stream1',
        'rtsps://cam.example.com/live',
        'rtmp://live.example.com/app/key',
        'rtmps://live.example.com/app/key',
        'mms://media.example.com/stream',
        'srt://relay.example.com:9000?mode=caller',
        'udp://239.0.0.1:1234',
        'udp://@:1234',
        'rtp://239.0.0.1:5004',
      ]) {
        expect(MediaUrl.tryParse(url), isNotNull, reason: url);
        expect(MediaUrl.validationError(url), isNull, reason: url);
      }
    });

    test('adds https:// to bare hosts', () {
      final ref = MediaUrl.tryParse('example.com/video.mp4')!;
      expect(ref.pathOrUri, 'https://example.com/video.mp4');
      expect(ref.title, 'video.mp4');

      expect(MediaUrl.tryParse('localhost:8080/movie.mkv')!.pathOrUri, 'https://localhost:8080/movie.mkv');
      expect(MediaUrl.tryParse('192.168.0.5:8000/a.mp4')!.pathOrUri, 'https://192.168.0.5:8000/a.mp4');
      expect(MediaUrl.tryParse('www.example.com')!.pathOrUri, 'https://www.example.com');
    });

    test('falls back to the host for titles and decodes path segments', () {
      expect(MediaUrl.tryParse('https://stream.example.com')!.title, 'stream.example.com');
      expect(MediaUrl.tryParse('https://stream.example.com/')!.title, 'stream.example.com');
      expect(MediaUrl.tryParse('https://example.com/shows/season%201/')!.title, 'season 1');
      expect(MediaUrl.tryParse('https://example.com/%E2%82%AC.mp4')!.title, '€.mp4');
    });

    test('encodes spaces typed into the path', () {
      final ref = MediaUrl.tryParse('https://example.com/my video.mp4')!;
      expect(ref.pathOrUri, 'https://example.com/my%20video.mp4');
      expect(ref.title, 'my video.mp4');
    });

    test('normalizes scheme and host case', () {
      expect(MediaUrl.tryParse('HTTPS://Example.COM/Video.MP4')!.pathOrUri, 'https://example.com/Video.MP4');
    });

    test('turns file:// links into local refs', () {
      final ref = MediaUrl.tryParse('file:///Users/me/My%20Clip.mkv')!;
      expect(ref.isRemote, isFalse);
      expect(ref.pathOrUri, '/Users/me/My Clip.mkv');
      expect(ref.id, '/Users/me/My Clip.mkv');
      expect(ref.title, 'My Clip.mkv');
    });
  });

  group('MediaUrl.validationError', () {
    test('rejects empty and multi-line input', () {
      expect(MediaUrl.validationError(''), isNotNull);
      expect(MediaUrl.validationError('   '), isNotNull);
      expect(MediaUrl.validationError('https://a.com/1.mp4\nhttps://a.com/2.mp4'), isNotNull);
      expect(MediaUrl.tryParse(''), isNull);
    });

    test('rejects schemes it cannot play', () {
      for (final input in [
        'javascript:alert(1)',
        'JavaScript://%0aalert(1)',
        'data:text/html;base64,AAAA',
        'mailto:someone@example.com',
        'ftp://example.com/a.mp4',
        'danaview://open',
      ]) {
        expect(MediaUrl.tryParse(input), isNull, reason: input);
        expect(MediaUrl.validationError(input), contains("can't be played"), reason: input);
      }
    });

    test('rejects malformed links', () {
      for (final input in [
        'https://',
        'https:///path/only.mp4',
        'http:example.com',
        'https://exa mple.com/x.mp4',
        'https://example.com:99999/x.mp4',
        'https://300.1.1.1/x.mp4',
        'https://example..com/x.mp4',
        'udp://',
        'justaword',
        'file:///',
      ]) {
        expect(MediaUrl.tryParse(input), isNull, reason: input);
        expect(MediaUrl.validationError(input), isNotNull, reason: input);
      }
    });

    test('points local paths to Open File', () {
      for (final input in ['/Users/me/a.mkv', '~/Movies/a.mkv', r'C:\Videos\a.mkv', r'\\nas\share\a.mkv', './a.mkv']) {
        expect(MediaUrl.validationError(input), contains('Open File'), reason: input);
      }
    });

    test('rejects a bare file name instead of guessing a host', () {
      expect(MediaUrl.tryParse('movie.mkv'), isNull);
      expect(MediaUrl.validationError('movie.mkv'), contains('full link'));
    });

    test('rejects unsupported file formats in url and file path', () {
      for (final input in [
        'https://example.com/photo.png',
        'https://example.com/document.pdf',
        'https://example.com/index.html',
        'https://example.com/archive.zip',
        'file:///Users/me/photo.jpg',
      ]) {
        expect(MediaUrl.tryParse(input), isNull, reason: input);
        expect(MediaUrl.validationError(input), contains('unsupported'), reason: input);
      }
    });
  });
}
