// OWNER: HOM-04
//
// The native thumbnailers (ARCH v1.2 V2-28, V2-104; BUILD_PLAN HOM-04 / HOM-04A / HOM-26) over the
// frozen Pigeon surface: `PHCachingImageManager` for `ph:` assets and `QLThumbnailGenerator` for
// media files on iOS and macOS (HOM-04), `ContentResolver.loadThumbnail` / `ThumbnailUtils` on
// Android (HOM-04A); document thumbnails come from HOM-26 (Apple) and HOM-04A (Android). The
// platform writes the encoded thumbnail to the requested file (JPEG or HEIC on Apple, because
// ImageIO has no WebP encoder; WebP on Android) and reports the format it actually wrote. The
// thumbnail cache of the Home (danaview_features `library/thumbs/`) is the only caller. Nothing
// here logs names, ids or paths (rule 30) or touches the network (rule 21).

import 'package:flutter/services.dart';

import 'pigeon/library_api.g.dart';
import 'pigeon/library_channels.dart';

/// Encoded format of a thumbnail file.
enum NativeThumbnailFormat {
  /// JPEG (every platform that is not Android).
  jpeg,

  /// HEIC (iOS 17+; the platform falls back to JPEG elsewhere and says so in the result).
  heic,

  /// WebP (Android only; ImageIO has no WebP encoder, V2-V3).
  webp,

  /// PNG (lossless; for tests and alpha).
  png;

  /// The file extension, without the dot.
  String get extension => switch (this) {
        jpeg => 'jpg',
        heic => 'heic',
        webp => 'webp',
        png => 'png',
      };
}

/// How a thumbnail fits its target box.
enum NativeThumbnailMode {
  /// Cover the box exactly (centre crop), for grid cells.
  fill,

  /// Fit inside the box keeping the aspect ratio, for viewers and documents.
  fit,
}

/// A thumbnail the platform wrote to disk.
final class NativeThumbnail {
  /// A thumbnail at [path].
  const NativeThumbnail({required this.path, required this.width, required this.height, required this.format});

  /// The file written (the request's output path).
  final String path;

  /// Pixel width of the encoded image.
  final int width;

  /// Pixel height of the encoded image.
  final int height;

  /// The format actually written (may differ from the requested one, see [NativeThumbnailFormat.heic]).
  final NativeThumbnailFormat format;

  // Never prints the path (rule 30).
  @override
  String toString() => 'NativeThumbnail(${width}x$height ${format.name})';
}

/// The thumbnail generator the Home cache depends on; [NativeThumbnails] is the plugin's
/// implementation, tests use fakes.
abstract interface class ThumbnailGenerator {
  /// Writes a thumbnail of [source] (`ph:<id>`, `ms:<id>`, an absolute file path or a `content://`
  /// URI, opened read-only) to [outputPath] at most [width]×[height] pixels. Throws
  /// `LibraryNativeException` (`cancelled` after [cancel], `notFound`, `unavailableOffline` for an
  /// iCloud-only asset, `ioError` for an unreadable or corrupt file, `notSupportedOnDevice`).
  Future<NativeThumbnail> mediaThumbnail({
    required String requestId,
    required String source,
    required int width,
    required int height,
    required String outputPath,
    NativeThumbnailMode mode = NativeThumbnailMode.fill,
    NativeThumbnailFormat format = NativeThumbnailFormat.jpeg,
    double quality = 0.8,
  });

  /// Writes a thumbnail of the document at [path] to [outputPath]; null when the platform has no
  /// thumbnail for it (the caller shows a type icon).
  Future<NativeThumbnail?> documentThumbnail({
    required String requestId,
    required String path,
    required int width,
    required int height,
    required String outputPath,
    double scale = 1,
    NativeThumbnailFormat format = NativeThumbnailFormat.jpeg,
    double quality = 0.8,
  });

  /// Cancels the pending request [requestId]; it then fails with `cancelled`. Unknown ids are
  /// ignored.
  Future<void> cancel(String requestId);

  /// Moves the platform's prefetch window: [start] sources entered the viewport's neighbourhood,
  /// [stop] left it. Only `ph:` sources are cached natively (`PHCachingImageManager`); others are
  /// ignored.
  Future<void> updateCaching({
    required List<String> start,
    required List<String> stop,
    required int width,
    required int height,
    NativeThumbnailMode mode = NativeThumbnailMode.fill,
  });
}

ThumbnailFormatMsg _formatMsg(NativeThumbnailFormat f) => ThumbnailFormatMsg.values[f.index];

NativeThumbnailFormat _format(ThumbnailFormatMsg f) => NativeThumbnailFormat.values[f.index];

NativeThumbnail _result(ThumbnailResultMsg m) =>
    NativeThumbnail(path: m.path, width: m.widthPx, height: m.heightPx, format: _format(m.format));

void _checkBox(int width, int height, double quality) {
  if (width < 1 || width > 4096) throw ArgumentError.value(width, 'width', 'not in 1…4096');
  if (height < 1 || height > 4096) throw ArgumentError.value(height, 'height', 'not in 1…4096');
  if (quality < 0 || quality > 1) throw ArgumentError.value(quality, 'quality', 'not in 0…1');
}

/// The thumbnailers of the plugin. Every call throws `LibraryNativeException`; where a platform has
/// no native class (Windows, Linux) calls fail with `notSupportedOnDevice` and the cache shows type
/// icons.
final class NativeThumbnails implements ThumbnailGenerator {
  /// The thumbnailers of the default engine; tests pass a mock [binaryMessenger].
  NativeThumbnails({BinaryMessenger? binaryMessenger, String messageChannelSuffix = ''})
      : _api = ThumbnailHostApi(binaryMessenger: binaryMessenger, messageChannelSuffix: messageChannelSuffix);

  final ThumbnailHostApi _api;

  @override
  Future<NativeThumbnail> mediaThumbnail({
    required String requestId,
    required String source,
    required int width,
    required int height,
    required String outputPath,
    NativeThumbnailMode mode = NativeThumbnailMode.fill,
    NativeThumbnailFormat format = NativeThumbnailFormat.jpeg,
    double quality = 0.8,
  }) {
    _checkBox(width, height, quality);
    if (source.isEmpty) throw ArgumentError.value(source, 'source', 'empty');
    if (outputPath.isEmpty) throw ArgumentError.value(outputPath, 'outputPath', 'empty');
    return guardNative(() async => _result(await _api.mediaThumbnail(MediaThumbnailRequestMsg(
          requestId: requestId,
          source: source,
          widthPx: width,
          heightPx: height,
          mode: ThumbnailModeMsg.values[mode.index],
          format: _formatMsg(format),
          quality: quality,
          outputPath: outputPath,
        ))));
  }

  @override
  Future<NativeThumbnail?> documentThumbnail({
    required String requestId,
    required String path,
    required int width,
    required int height,
    required String outputPath,
    double scale = 1,
    NativeThumbnailFormat format = NativeThumbnailFormat.jpeg,
    double quality = 0.8,
  }) {
    _checkBox(width, height, quality);
    if (scale <= 0) throw ArgumentError.value(scale, 'scale', 'not positive');
    return guardNative(() async {
      final r = await _api.documentThumbnail(DocumentThumbnailRequestMsg(
        requestId: requestId,
        path: path,
        widthPx: width,
        heightPx: height,
        scale: scale,
        format: _formatMsg(format),
        quality: quality,
        outputPath: outputPath,
      ));
      return r == null ? null : _result(r);
    });
  }

  @override
  Future<void> cancel(String requestId) => guardNative(() => _api.cancel(requestId));

  @override
  Future<void> updateCaching({
    required List<String> start,
    required List<String> stop,
    required int width,
    required int height,
    NativeThumbnailMode mode = NativeThumbnailMode.fill,
  }) {
    _checkBox(width, height, 0);
    return guardNative(() => _api.updateCaching(ThumbnailCachingMsg(
          startSources: start,
          stopSources: stop,
          widthPx: width,
          heightPx: height,
          mode: ThumbnailModeMsg.values[mode.index],
        )));
  }
}
