// OWNER: HOM-01
//
// MediaRef interop (BUILD_PLAN HOM-01 acceptance: MediaRef → VideoMediaItem → MediaRef equal for
// every field MediaRef has; no danaview_domain file changes).

import 'dart:io';

import 'package:danaview_domain/danaview_domain.dart';
import 'package:danaview_library/danaview_library.dart';
import 'package:test/test.dart';

/// Every field of MediaRef, by name. The guard test below keeps this list in step with the class.
final Map<String, Object? Function(MediaRef)> _fields = {
  'id': (r) => r.id,
  'title': (r) => r.title,
  'pathOrUri': (r) => r.pathOrUri,
  'isRemote': (r) => r.isRemote,
  'duration': (r) => r.duration,
  'width': (r) => r.width,
  'height': (r) => r.height,
  'videoCodec': (r) => r.videoCodec,
  'audioCodec': (r) => r.audioCodec,
  'container': (r) => r.container,
  'fileSize': (r) => r.fileSize,
  'quickHash': (r) => r.quickHash,
  'posterPath': (r) => r.posterPath,
  'seasonNumber': (r) => r.seasonNumber,
  'episodeNumber': (r) => r.episodeNumber,
};

void _expectSameFields(MediaRef actual, MediaRef expected) {
  for (final entry in _fields.entries) {
    expect(entry.value(actual), entry.value(expected), reason: 'MediaRef.${entry.key}');
  }
}

final _refs = <String, MediaRef>{
  'every field set (local)': const MediaRef(
    id: '/Users/me/Movies/Show.S02E05.mkv',
    title: 'Show S02E05',
    pathOrUri: '/Users/me/Movies/Show.S02E05.mkv',
    duration: Duration(minutes: 42, seconds: 7, milliseconds: 250),
    width: 3840,
    height: 2160,
    videoCodec: 'hevc',
    audioCodec: 'eac3',
    container: 'matroska',
    fileSize: 4294967296,
    quickHash: 'qh:abc123',
    posterPath: '/cache/poster.jpg',
    seasonNumber: 2,
    episodeNumber: 5,
  ),
  'every field set (remote)': const MediaRef(
    id: 'https://cdn.example.test/live/index.m3u8?token=1',
    title: 'Live',
    pathOrUri: 'https://cdn.example.test/live/index.m3u8?token=1',
    isRemote: true,
    duration: Duration(hours: 1),
    width: 1920,
    height: 1080,
    videoCodec: 'h264',
    audioCodec: 'aac',
    container: 'hls',
    fileSize: 0,
    quickHash: '',
    posterPath: 'https://cdn.example.test/p.png',
    seasonNumber: 1,
    episodeNumber: 1,
  ),
  'defaults only': const MediaRef(id: '/a.mp4', title: 'a.mp4', pathOrUri: '/a.mp4'),
  'id differs from path': const MediaRef(id: 'custom-id', title: 'T', pathOrUri: '/x/y.mov'),
  'namespaced id': const MediaRef(id: 'fe_abc', title: 'T', pathOrUri: 'danaview-library://fe_abc'),
  'malformed-looking id': const MediaRef(id: 'fe_', title: '', pathOrUri: ''),
  'windows path': const MediaRef(id: r'C:\Videos\a.avi', title: 'a.avi', pathOrUri: r'C:\Videos\a.avi'),
};

void main() {
  group('MediaRef → VideoMediaItem → MediaRef keeps every field', () {
    _refs.forEach((name, ref) {
      test(name, () {
        final item = MediaRefBridge.fromMediaRef(ref);
        _expectSameFields(item.toMediaRef(), ref);
        _expectSameFields(MediaRefBridge.toMediaRef(item), ref);
        expect(item.toMediaRef(), ref); // MediaRef's own == (id + pathOrUri)
        expect(item.id.value, ref.id);
      });
    });
  });

  test('the field list covers every field MediaRef declares', () {
    final source = File('../danaview_domain/lib/src/models/media_source.dart').readAsStringSync();
    final body = source.substring(source.indexOf('class MediaRef {'));
    final declared = {
      for (final m in RegExp(r'^  final [\w<>?, ]+ (\w+);', multiLine: true)
          .allMatches(body.substring(0, body.indexOf('const MediaRef(')))) m[1]!,
    };
    expect(declared, isNotEmpty);
    expect(_fields.keys.toSet(), declared);
  });

  test('fromMediaRef maps fields and the 1.2.0 extras', () {
    final ref = _refs['every field set (local)']!;
    final item = MediaRefBridge.fromMediaRef(
      ref,
      modifiedAt: DateTime.utc(2026, 5, 6),
      frameRate: 23.976,
      hasAudio: false,
      resumePosition: const Duration(minutes: 3),
    );
    expect(item.name, ref.title);
    expect(item.uri, ref.pathOrUri);
    expect(item.sizeBytes, ref.fileSize);
    expect(item.codec, ref.videoCodec);
    expect(item.modifiedAt, DateTime.utc(2026, 5, 6));
    expect(item.frameRate, 23.976);
    expect(item.hasAudio, isFalse);
    expect(item.resumePosition, const Duration(minutes: 3));
    expect(item.mimeType, 'video/x-matroska');
    expect(item.id.namespace, IdNamespace.legacy);
    _expectSameFields(item.toMediaRef(), ref);
  });

  test('defaults for the fields MediaRef lacks', () {
    final item = MediaRefBridge.fromMediaRef(_refs['defaults only']!);
    expect(item.modifiedAt, MediaRefBridge.unknownModifiedAt);
    expect(item.frameRate, 0);
    expect(item.hasAudio, isTrue);
    expect(item.resumePosition, isNull);
    expect(item.sizeBytes, isNull);
    expect(item.mimeType, 'video/mp4');
    expect(MediaRefBridge.fromMediaRef(_refs['defaults only']!, mimeType: 'video/x').mimeType, 'video/x');
  });

  test('namespaced MediaRef ids keep their namespace', () {
    expect(MediaRefBridge.fromMediaRef(_refs['namespaced id']!).id.namespace, IdNamespace.entry);
  });

  test('VideoMediaItem → MediaRef → VideoMediaItem keeps the MediaRef-backed fields and identity', () {
    final item = VideoMediaItem(
      id: ItemId.parse('ph:ASSET/L0/001'),
      uri: 'ph://ASSET/L0/001',
      name: 'IMG_0002.MOV',
      modifiedAt: DateTime.utc(2026, 2, 2),
      mimeType: 'video/quicktime',
      sizeBytes: 123,
      duration: const Duration(seconds: 12),
      codec: 'hevc',
      width: 1080,
      height: 1920,
    );
    final back = MediaRefBridge.fromMediaRef(item.toMediaRef(), modifiedAt: item.modifiedAt, mimeType: item.mimeType);
    expect(back, item);
    expect(back.id.namespace, IdNamespace.photoKit);
    expect(back.uri, item.uri);
    expect(back.sizeBytes, 123);
    expect(back.duration, item.duration);
    expect(back.codec, 'hevc');
    expect(back.width, 1080);
    expect(back.height, 1920);
  });

  test('playableRefs keeps videos in order and skips photos', () {
    final v1 = MediaRefBridge.fromMediaRef(_refs['defaults only']!);
    final v2 = MediaRefBridge.fromMediaRef(_refs['windows path']!);
    final photo = PhotoMediaItem(
      id: ItemId.parse('ph:p'),
      uri: 'ph://p',
      name: 'p.heic',
      modifiedAt: DateTime.utc(2026),
      mimeType: 'image/heic',
    );
    final refs = MediaRefBridge.playableRefs([v1, photo, v2]);
    expect(refs.map((r) => r.id), ['/a.mp4', r'C:\Videos\a.avi']);
  });

  group('videoMimeTypeFor', () {
    final cases = {
      '/a/b.MP4': 'video/mp4',
      '/a/b.mov': 'video/quicktime',
      r'C:\x\y.mkv': 'video/x-matroska',
      '/a/b.webm': 'video/webm',
      '/a/b.m2ts': 'video/mp2t',
      '/a/noext': 'application/octet-stream',
      '/a/.hidden': 'application/octet-stream',
      '/a/b.': 'application/octet-stream',
      '/a/b.txt': 'application/octet-stream',
    };
    cases.forEach((path, mime) {
      test(path, () => expect(MediaRefBridge.videoMimeTypeFor(path), mime));
    });
    test('remote URLs ignore query and fragment', () {
      expect(MediaRefBridge.videoMimeTypeFor('https://x.test/v.mp4?sig=a.b#t=1', isRemote: true), 'video/mp4');
      expect(MediaRefBridge.videoMimeTypeFor('https://x.test/live', isRemote: true), 'application/octet-stream');
    });
  });
}
