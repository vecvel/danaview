// OWNER: HOM-01
//
// The sealed MediaItem model (ARCH v1.2 §5.1, BUILD_PLAN HOM-01): equality and hashing by id,
// validation, the document slot, exhaustive switches.

import 'package:danaview_library/danaview_library.dart';
import 'package:test/test.dart';

/// Stands in for HOM-16's DocumentItem, which extends the slot from another library.
final class _TestDocument extends DocumentMediaItem {
  _TestDocument(String id)
      : super(
          id: ItemId.parse(id),
          uri: 'danaview-library://$id',
          name: 'a.pdf',
          modifiedAt: DateTime.utc(2026),
          mimeType: 'application/pdf',
        );
}

VideoMediaItem _video(String id, {String name = 'v.mp4', Duration duration = Duration.zero}) => VideoMediaItem(
      id: ItemId.parse(id),
      uri: '/m/$name',
      name: name,
      modifiedAt: DateTime.utc(2026, 1, 2),
      mimeType: 'video/mp4',
      sizeBytes: 10,
      duration: duration,
    );

PhotoMediaItem _photo(String id, {int width = 4032, int height = 3024}) => PhotoMediaItem(
      id: ItemId.parse(id),
      uri: 'ph://$id',
      name: 'IMG_0001.HEIC',
      modifiedAt: DateTime.utc(2026, 3, 4),
      mimeType: 'image/heic',
      width: width,
      height: height,
      isHdr: true,
      isLivePhoto: true,
      iso: 100,
      aperture: 1.8,
      cameraModel: 'iPhone 16',
      takenAt: DateTime.utc(2026, 3, 4, 10),
    );

String _describe(MediaItem item) => switch (item) {
      VideoMediaItem() => 'video',
      PhotoMediaItem() => 'photo',
      DocumentMediaItem() => 'document',
    };

void main() {
  test('equality and hashing are by id only', () {
    final a = _video('fe_one', name: 'a.mp4', duration: const Duration(seconds: 1));
    final b = _video('fe_one', name: 'renamed.mp4', duration: const Duration(seconds: 9));
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect({a, b}, hasLength(1));
    expect(a == _video('fe_two'), isFalse);
    expect(_photo('ph:X/L0/001'), _photo('ph:X/L0/001', width: 1, height: 1));
    expect(_TestDocument('fe_doc'), _TestDocument('fe_doc'));
  });

  test('items of different kinds with the same id are the same item', () {
    expect(_video('fe_same') == _photo('fe_same'), isTrue);
  });

  test('switches over MediaItem are exhaustive across the three kinds', () {
    expect(_describe(_video('fe_v')), 'video');
    expect(_describe(_photo('ph:p')), 'photo');
    expect(_describe(_TestDocument('fe_d')), 'document');
  });

  test('photo fields', () {
    final p = _photo('ms:12');
    expect(p.width, 4032);
    expect(p.height, 3024);
    expect(p.megapixels, closeTo(12.19, 0.01));
    expect(p.isRaw, isFalse);
    expect(p.isHdr, isTrue);
    expect(p.isLivePhoto, isTrue);
    expect(p.iso, 100);
    expect(p.aperture, 1.8);
    expect(p.cameraModel, 'iPhone 16');
    expect(p.takenAt, DateTime.utc(2026, 3, 4, 10));
    expect(p.sizeBytes, isNull);
    expect(p.id.namespace, IdNamespace.mediaStore);
  });

  test('video defaults', () {
    final v = VideoMediaItem(
      id: ItemId.parse('lk:root/a.mkv'),
      uri: '/linked/a.mkv',
      name: 'a.mkv',
      modifiedAt: DateTime.utc(2026),
      mimeType: 'video/x-matroska',
    );
    expect(v.duration, Duration.zero);
    expect(v.frameRate, 0);
    expect(v.hasAudio, isTrue);
    expect(v.resumePosition, isNull);
    expect(v.isRemote, isFalse);
    expect(v.seasonNumber, 0);
    expect(v.episodeNumber, 0);
  });

  test('validation', () {
    expect(() => _video('fd_folder'), throwsArgumentError, reason: 'folder ids are not item ids');
    expect(
      () => VideoMediaItem(
        id: ItemId.parse('fe_a'),
        uri: 'u',
        name: 'n',
        modifiedAt: DateTime.utc(2026),
        mimeType: 'video/mp4',
        sizeBytes: -1,
      ),
      throwsArgumentError,
    );
    expect(
      () => VideoMediaItem(
        id: ItemId.parse('fe_a'),
        uri: 'u',
        name: 'n',
        modifiedAt: DateTime.utc(2026),
        mimeType: 'video/mp4',
        frameRate: -1,
      ),
      throwsArgumentError,
    );
    expect(() => _photo('ph:a', width: -1), throwsArgumentError);
    expect(() => _photo('ph:a', height: -1), throwsArgumentError);
  });

  test('toString names the kind and id', () {
    expect(_video('fe_v').toString(), 'VideoMediaItem(fe_v)');
  });
}
