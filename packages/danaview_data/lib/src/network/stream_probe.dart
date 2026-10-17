import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'speed_test.dart' show NetworkCancelToken;

enum StreamKind { hls, dash, video, audio, webPage, unknown }

enum StreamVerdict { playable, mightNotPlay, notPlayable }

enum StreamIssueLevel { error, warning, info }

class StreamIssue {
  const StreamIssue(this.level, this.message);

  final StreamIssueLevel level;
  final String message;

  @override
  String toString() => '${level.name}: $message';
}

class StreamRedirect {
  const StreamRedirect(this.statusCode, this.from, this.to);

  final int statusCode;
  final Uri from;
  final Uri to;
}

/// One quality level of an HLS master playlist or a DASH manifest.
class StreamVariant {
  const StreamVariant({
    this.bandwidth,
    this.averageBandwidth,
    this.width,
    this.height,
    this.codecs,
    this.frameRate,
    this.uri,
  });

  /// Peak bits per second.
  final int? bandwidth;
  final int? averageBandwidth;
  final int? width;
  final int? height;
  final String? codecs;
  final double? frameRate;
  final String? uri;
}

/// What an HLS playlist or DASH manifest says about the stream.
class StreamManifestInfo {
  const StreamManifestInfo({
    required this.isMaster,
    this.variants = const [],
    this.isLive,
    this.duration,
    this.segmentCount = 0,
    this.targetDuration,
    this.audioTracks = 0,
    this.subtitleTracks = 0,
    this.encryption,
    this.drm = false,
    this.truncated = false,
  });

  /// An HLS master playlist (quality levels) rather than a media playlist (segments).
  final bool isMaster;
  final List<StreamVariant> variants;

  /// Null when it couldn't be told (a truncated playlist without an end marker).
  final bool? isLive;

  /// Total of the segment durations; for a live stream, the window currently listed.
  final Duration? duration;
  final int segmentCount;
  final Duration? targetDuration;
  final int audioTracks;
  final int subtitleTracks;

  /// `AES-128`, `SAMPLE-AES`, …; null when the segments aren't encrypted.
  final String? encryption;

  /// Protected with FairPlay, Widevine or PlayReady, which only their own apps can play.
  final bool drm;

  /// Only the first part of the file was read.
  final bool truncated;
}

class StreamProbeResult {
  const StreamProbeResult({
    required this.requestedUrl,
    required this.finalUrl,
    this.redirects = const [],
    this.statusCode,
    this.reasonPhrase,
    this.contentType,
    this.contentLength,
    this.acceptsRanges,
    this.seekable,
    this.timeToFirstByte,
    this.kind = StreamKind.unknown,
    this.container,
    this.manifest,
    this.server,
    this.issues = const [],
  });

  final Uri requestedUrl;
  final Uri finalUrl;
  final List<StreamRedirect> redirects;

  /// Null when no response arrived (network failure).
  final int? statusCode;
  final String? reasonPhrase;

  /// The `Content-Type` header as sent.
  final String? contentType;
  final int? contentLength;

  /// The server advertised `Accept-Ranges: bytes`.
  final bool? acceptsRanges;

  /// A `Range: bytes=0-1` request came back as 206; null when not checked.
  final bool? seekable;

  /// From the start of the check until the final response began, redirects included.
  final Duration? timeToFirstByte;
  final StreamKind kind;

  /// `MP4`, `Matroska`, `MPEG-TS`, … when the first bytes gave it away.
  final String? container;
  final StreamManifestInfo? manifest;
  final String? server;
  final List<StreamIssue> issues;

  StreamVerdict get verdict {
    if (issues.any((i) => i.level == StreamIssueLevel.error)) return StreamVerdict.notPlayable;
    if (issues.any((i) => i.level == StreamIssueLevel.warning)) return StreamVerdict.mightNotPlay;
    return StreamVerdict.playable;
  }

  bool get wasRedirected => redirects.isNotEmpty;
}

class StreamProbeException implements Exception {
  const StreamProbeException(this.message, {this.cancelled = false});

  final String message;
  final bool cancelled;

  @override
  String toString() => 'StreamProbeException: $message';
}

/// Checks whether an http(s) link points at something a video player can open, using a few small
/// requests and reading at most [maxBodyBytes] of any response.
class StreamProbe {
  StreamProbe({
    HttpClient Function()? clientFactory,
    this.timeout = const Duration(seconds: 12),
    this.maxBodyBytes = 256 * 1024,
    this.maxRedirects = 10,
    this.slowResponse = const Duration(seconds: 3),
    this.userAgent = 'Danaview/1.0',
  }) : _clientFactory = clientFactory ?? HttpClient.new;

  final HttpClient Function() _clientFactory;

  /// For connecting and for each response, separately.
  final Duration timeout;
  final int maxBodyBytes;
  final int maxRedirects;

  /// A first response slower than this is noted in the issues.
  final Duration slowResponse;
  final String userAgent;

  /// Enough to recognize a container from its first bytes.
  static const int _sniffBytes = 16 * 1024;

  /// Throws [StreamProbeException] for links that aren't http(s), or when [cancel] fires; network
  /// and server failures come back as a result with an error issue.
  Future<StreamProbeResult> check(Uri url, {NetworkCancelToken? cancel}) async {
    final scheme = url.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      throw StreamProbeException(
        'Only http:// and https:// links can be checked. '
        '${scheme.isEmpty ? 'Other' : scheme.toUpperCase()} links can still be played in Danaview.',
      );
    }
    final client = _clientFactory()
      ..connectionTimeout = timeout
      ..userAgent = userAgent;
    final cancelled = cancel?.whenCancelled.then((_) => client.close(force: true));
    try {
      return await _check(client, url, cancel);
    } catch (error) {
      if (cancel?.isCancelled ?? false) throw const StreamProbeException('Check cancelled.', cancelled: true);
      rethrow;
    } finally {
      client.close(force: true);
      if (cancelled != null) unawaited(cancelled);
    }
  }

  Future<StreamProbeResult> _check(HttpClient client, Uri url, NetworkCancelToken? cancel) async {
    final clock = Stopwatch()..start();
    final redirects = <StreamRedirect>[];
    final issues = <StreamIssue>[];
    var current = url;
    HttpClientResponse response;

    // Redirects are followed by hand so the chain can be shown.
    while (true) {
      try {
        final request = await client.getUrl(current).timeout(timeout);
        request
          ..followRedirects = false
          ..headers.set(HttpHeaders.acceptHeader, '*/*');
        response = await request.close().timeout(timeout);
      } catch (error) {
        if (cancel?.isCancelled ?? false) rethrow;
        return StreamProbeResult(
          requestedUrl: url,
          finalUrl: current,
          redirects: redirects,
          issues: [StreamIssue(StreamIssueLevel.error, _networkMessage(error, current))],
        );
      }
      final location = _header(response.headers, HttpHeaders.locationHeader);
      if (!_isRedirect(response.statusCode) || location == null) break;
      final next = _tryResolve(current, location.trim());
      await _discard(response);
      if (next == null) {
        return StreamProbeResult(
          requestedUrl: url,
          finalUrl: current,
          redirects: redirects,
          statusCode: response.statusCode,
          reasonPhrase: response.reasonPhrase,
          timeToFirstByte: clock.elapsed,
          issues: const [StreamIssue(StreamIssueLevel.error, 'The server redirected to an invalid address.')],
        );
      }
      redirects.add(StreamRedirect(response.statusCode, current, next));
      final nextScheme = next.scheme.toLowerCase();
      if (nextScheme != 'http' && nextScheme != 'https') {
        return StreamProbeResult(
          requestedUrl: url,
          finalUrl: next,
          redirects: redirects,
          issues: [
            StreamIssue(
              StreamIssueLevel.warning,
              'The link redirects to a ${nextScheme.toUpperCase()} address, which this check can\'t follow.',
            ),
          ],
        );
      }
      if (redirects.length > maxRedirects) {
        return StreamProbeResult(
          requestedUrl: url,
          finalUrl: next,
          redirects: redirects,
          issues: const [StreamIssue(StreamIssueLevel.error, 'Too many redirects: the link goes round in circles.')],
        );
      }
      if (current.scheme == 'https' && nextScheme == 'http') {
        issues.add(const StreamIssue(StreamIssueLevel.info, 'Redirects from a secure https:// link to plain http://.'));
      }
      current = next;
    }

    final ttfb = clock.elapsed;
    final status = response.statusCode;
    final headers = response.headers;
    final contentType = _header(headers, HttpHeaders.contentTypeHeader);
    final mime = _mimeOf(contentType);
    final acceptsRanges = _header(headers, HttpHeaders.acceptRangesHeader)?.toLowerCase().contains('bytes');
    var contentLength = response.contentLength >= 0 ? response.contentLength : null;
    final server = _header(headers, HttpHeaders.serverHeader);

    StreamProbeResult result({
      StreamKind kind = StreamKind.unknown,
      String? container,
      StreamManifestInfo? manifest,
      bool? seekable,
    }) {
      return StreamProbeResult(
        requestedUrl: url,
        finalUrl: current,
        redirects: redirects,
        statusCode: status,
        reasonPhrase: response.reasonPhrase,
        contentType: contentType,
        contentLength: contentLength,
        acceptsRanges: acceptsRanges,
        seekable: seekable,
        timeToFirstByte: ttfb,
        kind: kind,
        container: container,
        manifest: manifest,
        server: server,
        issues: issues,
      );
    }

    if (status < 200 || status >= 300 || status == HttpStatus.noContent) {
      await _discard(response);
      issues.add(StreamIssue(StreamIssueLevel.error, _statusMessage(status)));
      return result();
    }
    // Slow to start isn't the same as unplayable, so this is a note, not a warning.
    if (ttfb > slowResponse) {
      issues.add(StreamIssue(
        StreamIssueLevel.info,
        'The server is slow to respond (${(ttfb.inMilliseconds / 1000).toStringAsFixed(1)} s). '
        'Playback may take a while to start.',
      ));
    }

    final binary = mime != null && (mime.startsWith('video/') || mime.startsWith('audio/')) && !_hlsTypes.contains(mime);
    final _Body body;
    try {
      body = await _readBounded(response, binary ? _sniffBytes : maxBodyBytes);
    } catch (error) {
      if (cancel?.isCancelled ?? false) rethrow;
      issues.add(StreamIssue(StreamIssueLevel.error, _networkMessage(error, current)));
      return result();
    }

    final sniffed = _sniff(body.bytes);
    final typed = _kindFromMime(mime);
    final named = _kindFromPath(current.path);
    var kind = sniffed?.kind ?? typed ?? named ?? StreamKind.unknown;
    // An MP4 or Ogg container holding only sound.
    if (kind == StreamKind.video && (mime?.startsWith('audio/') ?? false)) kind = StreamKind.audio;
    if (sniffed != null && typed != null && sniffed.kind != typed && !_genericTypes.contains(mime)) {
      issues.add(StreamIssue(
        StreamIssueLevel.info,
        'The server labels this as "$mime", but it looks like ${_kindNoun(sniffed.kind)}.',
      ));
    }

    switch (kind) {
      case StreamKind.webPage:
        issues.add(const StreamIssue(
          StreamIssueLevel.error,
          'This is a web page, not a video. Open it in a browser and copy the direct video link.',
        ));
        return result(kind: kind);
      case StreamKind.unknown:
        issues.add(StreamIssue(
          StreamIssueLevel.warning,
          "Danaview couldn't recognize this format${mime == null ? '' : ' ($mime)'}. It may still play.",
        ));
        final seekable = await _probeRange(client, current, cancel, (total) => contentLength ??= total);
        return result(kind: kind, seekable: seekable);
      case StreamKind.hls:
        final manifest = await _inspectHls(client, current, body, issues, cancel);
        return result(kind: kind, manifest: manifest);
      case StreamKind.dash:
        final manifest = _parseDash(_text(body.bytes), body.truncated);
        _manifestIssues(manifest, issues);
        if (manifest.variants.isEmpty && !manifest.truncated) {
          issues.add(const StreamIssue(StreamIssueLevel.warning, 'The DASH manifest lists no video quality levels.'));
        }
        return result(kind: kind, manifest: manifest);
      case StreamKind.video:
      case StreamKind.audio:
        final seekable = await _probeRange(client, current, cancel, (total) => contentLength ??= total);
        if (seekable == false) {
          issues.add(const StreamIssue(
            StreamIssueLevel.warning,
            'Server does not support seeking. You may not be able to skip ahead.',
          ));
        }
        if (contentLength == null) {
          issues.add(const StreamIssue(StreamIssueLevel.info, "The server doesn't say how big the file is."));
        }
        return result(kind: kind, container: sniffed?.container, seekable: seekable);
    }
  }

  Future<StreamManifestInfo> _inspectHls(
    HttpClient client,
    Uri url,
    _Body body,
    List<StreamIssue> issues,
    NetworkCancelToken? cancel,
  ) async {
    final text = _text(body.bytes);
    if (!text.trimLeft().startsWith('#EXTM3U')) {
      issues.add(const StreamIssue(StreamIssueLevel.error, "The playlist is damaged: it doesn't start with #EXTM3U."));
      return StreamManifestInfo(isMaster: false, truncated: body.truncated);
    }
    final playlist = parseHlsPlaylist(text, truncated: body.truncated);
    if (!playlist.isMaster) {
      _manifestIssues(playlist, issues);
      if (playlist.segmentCount == 0 && !playlist.truncated) {
        issues.add(const StreamIssue(StreamIssueLevel.error, 'The playlist has no video segments.'));
      }
      return playlist;
    }

    _manifestIssues(playlist, issues);
    final first = playlist.variants.where((v) => v.uri != null).firstOrNull;
    if (first == null) {
      issues.add(const StreamIssue(StreamIssueLevel.error, 'The playlist lists no quality levels.'));
      return playlist;
    }

    // Live or on demand, and the length, are only in the quality levels' own playlists.
    final variantUrl = _tryResolve(url, first.uri!);
    if (variantUrl == null) {
      issues.add(const StreamIssue(
        StreamIssueLevel.warning,
        'The first quality level has an invalid address. The stream may not play.',
      ));
      return playlist;
    }
    try {
      final request = await client.getUrl(variantUrl).timeout(timeout);
      request.headers.set(HttpHeaders.acceptHeader, '*/*');
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        await _discard(response);
        issues.add(StreamIssue(
          StreamIssueLevel.warning,
          "Couldn't load the first quality level (HTTP ${response.statusCode}). The stream may not play.",
        ));
        return playlist;
      }
      final variantBody = await _readBounded(response, maxBodyBytes);
      final media = parseHlsPlaylist(_text(variantBody.bytes), truncated: variantBody.truncated);
      final mediaIssues = <StreamIssue>[];
      _manifestIssues(media, mediaIssues);
      issues.addAll(mediaIssues.where((i) => !issues.any((existing) => existing.message == i.message)));
      if (media.segmentCount == 0 && !media.truncated) {
        issues.add(const StreamIssue(StreamIssueLevel.warning, 'The first quality level lists no video segments.'));
      }
      return StreamManifestInfo(
        isMaster: true,
        variants: playlist.variants,
        isLive: media.isLive,
        duration: media.duration,
        segmentCount: media.segmentCount,
        targetDuration: media.targetDuration,
        audioTracks: playlist.audioTracks,
        subtitleTracks: playlist.subtitleTracks,
        encryption: playlist.encryption ?? media.encryption,
        drm: playlist.drm || media.drm,
        truncated: playlist.truncated || media.truncated,
      );
    } catch (error) {
      if (cancel?.isCancelled ?? false) rethrow;
      issues.add(StreamIssue(
        StreamIssueLevel.warning,
        "Couldn't load the first quality level: ${_networkMessage(error, variantUrl)}",
      ));
      return playlist;
    }
  }

  void _manifestIssues(StreamManifestInfo manifest, List<StreamIssue> issues) {
    if (manifest.drm) {
      issues.add(const StreamIssue(
        StreamIssueLevel.error,
        "This stream is DRM-protected and can't be played outside its official app.",
      ));
    } else if (manifest.encryption == 'AES-128') {
      issues.add(const StreamIssue(StreamIssueLevel.info, 'Segments are encrypted with AES-128, which Danaview supports.'));
    } else if (manifest.encryption != null) {
      issues.add(StreamIssue(
        StreamIssueLevel.warning,
        'Segments are encrypted with ${manifest.encryption}, which may not play.',
      ));
    }
    if (manifest.truncated) {
      issues.add(StreamIssue(
        StreamIssueLevel.info,
        'The playlist is large; only the first ${maxBodyBytes ~/ 1024} KB were checked.',
      ));
    }
  }

  /// Asks for the first two bytes: 206 means the player can jump anywhere in the file.
  Future<bool?> _probeRange(HttpClient client, Uri url, NetworkCancelToken? cancel, void Function(int) onTotal) async {
    try {
      final request = await client.getUrl(url).timeout(timeout);
      request.headers
        ..set(HttpHeaders.rangeHeader, 'bytes=0-1')
        ..set(HttpHeaders.acceptHeader, '*/*');
      final response = await request.close().timeout(timeout);
      await _discard(response);
      if (response.statusCode == HttpStatus.partialContent) {
        final range = _header(response.headers, HttpHeaders.contentRangeHeader);
        final total = range == null ? null : int.tryParse(range.split('/').last.trim());
        if (total != null) onTotal(total);
        return true;
      }
      if (response.statusCode == HttpStatus.ok) return false;
      return null;
    } catch (_) {
      if (cancel?.isCancelled ?? false) rethrow;
      return null;
    }
  }

  /// The first value; `headers.value` throws when a header is repeated.
  static String? _header(HttpHeaders headers, String name) => headers[name]?.first;

  /// [reference] against [base], or null when the server sent something that isn't an address.
  static Uri? _tryResolve(Uri base, String reference) {
    try {
      return base.resolve(reference);
    } on FormatException {
      return null;
    }
  }

  static bool _isRedirect(int status) =>
      status == 301 || status == 302 || status == 303 || status == 307 || status == 308;

  static String? _mimeOf(String? contentType) {
    if (contentType == null) return null;
    final mime = contentType.split(';').first.trim().toLowerCase();
    return mime.isEmpty ? null : mime;
  }

  /// Reads up to [limit] bytes, then hangs up.
  Future<_Body> _readBounded(HttpClientResponse response, int limit) {
    final builder = BytesBuilder(copy: false);
    final completer = Completer<_Body>();
    late final StreamSubscription<List<int>> subscription;
    subscription = response.listen(
      (chunk) {
        final room = limit - builder.length;
        builder.add(chunk.length <= room ? chunk : chunk.sublist(0, room));
        if (builder.length >= limit && !completer.isCompleted) {
          completer.complete(_Body(builder.takeBytes(), truncated: true));
          subscription.cancel();
        }
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete(_Body(builder.takeBytes(), truncated: false));
      },
      onError: (Object error) {
        if (completer.isCompleted) return;
        if (builder.length > 0) {
          completer.complete(_Body(builder.takeBytes(), truncated: true));
        } else {
          completer.completeError(error);
        }
        subscription.cancel();
      },
      cancelOnError: true,
    );
    return completer.future.timeout(timeout, onTimeout: () {
      subscription.cancel();
      if (builder.length > 0) return _Body(builder.takeBytes(), truncated: true);
      throw TimeoutException('No data', timeout);
    });
  }

  static Future<void> _discard(HttpClientResponse response) async {
    try {
      await response.listen(null).cancel();
    } catch (_) {
      // The connection is dropped either way.
    }
  }
}

class _Body {
  const _Body(this.bytes, {required this.truncated});

  final Uint8List bytes;
  final bool truncated;
}

const _hlsTypes = {
  'application/vnd.apple.mpegurl',
  'application/x-mpegurl',
  'audio/mpegurl',
  'audio/x-mpegurl',
  'application/mpegurl',
};

/// Labels that say nothing about the content.
const _genericTypes = {'application/octet-stream', 'binary/octet-stream', 'text/plain', 'application/unknown'};

StreamKind? _kindFromMime(String? mime) {
  if (mime == null || _genericTypes.contains(mime)) return null;
  if (_hlsTypes.contains(mime)) return StreamKind.hls;
  if (mime == 'application/dash+xml') return StreamKind.dash;
  if (mime == 'text/html' || mime == 'application/xhtml+xml') return StreamKind.webPage;
  if (mime.startsWith('video/')) return StreamKind.video;
  if (mime.startsWith('audio/')) return StreamKind.audio;
  if (const {'application/mp4', 'application/x-matroska', 'application/ogg', 'application/x-mpegts'}.contains(mime)) {
    return StreamKind.video;
  }
  return null;
}

StreamKind? _kindFromPath(String path) {
  final dot = path.lastIndexOf('.');
  if (dot < 0 || dot < path.lastIndexOf('/')) return null;
  return switch (path.substring(dot + 1).toLowerCase()) {
    'm3u8' || 'm3u' => StreamKind.hls,
    'mpd' => StreamKind.dash,
    'mp4' || 'm4v' || 'mkv' || 'webm' || 'mov' || 'ts' || 'm2ts' || 'avi' || 'flv' || 'wmv' || 'ogv' || '3gp' || 'mpg' ||
    'mpeg' =>
      StreamKind.video,
    'mp3' || 'aac' || 'm4a' || 'flac' || 'ogg' || 'opus' || 'wav' => StreamKind.audio,
    _ => null,
  };
}

String _kindNoun(StreamKind kind) => switch (kind) {
      StreamKind.hls => 'an HLS playlist',
      StreamKind.dash => 'a DASH manifest',
      StreamKind.video => 'a video file',
      StreamKind.audio => 'an audio file',
      StreamKind.webPage => 'a web page',
      StreamKind.unknown => 'something else',
    };

String _text(Uint8List bytes) {
  final text = utf8.decode(bytes, allowMalformed: true);
  return text.startsWith('﻿') ? text.substring(1) : text;
}

bool _startsWith(Uint8List bytes, List<int> magic, [int offset = 0]) {
  if (bytes.length < offset + magic.length) return false;
  for (var i = 0; i < magic.length; i++) {
    if (bytes[offset + i] != magic[i]) return false;
  }
  return true;
}

/// Recognizes a format from its first bytes.
({StreamKind kind, String? container})? _sniff(Uint8List bytes) {
  if (bytes.isEmpty) return null;
  if (_startsWith(bytes, ascii.encode('ftyp'), 4)) {
    final brand = bytes.length >= 12 ? ascii.decode(bytes.sublist(8, 12), allowInvalid: true) : '';
    if (brand == 'M4A ' || brand == 'M4B ') return (kind: StreamKind.audio, container: 'MP4 audio');
    return (kind: StreamKind.video, container: brand == 'qt  ' ? 'QuickTime' : 'MP4');
  }
  if (_startsWith(bytes, const [0x1A, 0x45, 0xDF, 0xA3])) {
    final head = ascii.decode(bytes.sublist(0, bytes.length.clamp(0, 64)), allowInvalid: true);
    return (kind: StreamKind.video, container: head.contains('webm') ? 'WebM' : 'Matroska');
  }
  if (_startsWith(bytes, ascii.encode('FLV'))) return (kind: StreamKind.video, container: 'FLV');
  // Transport stream packets are 188 bytes, each starting with the 0x47 sync byte.
  if (bytes.length > 188 && bytes[0] == 0x47 && bytes[188] == 0x47) {
    return (kind: StreamKind.video, container: 'MPEG-TS');
  }
  if (_startsWith(bytes, ascii.encode('RIFF')) && _startsWith(bytes, ascii.encode('AVI '), 8)) {
    return (kind: StreamKind.video, container: 'AVI');
  }
  if (_startsWith(bytes, const [0x00, 0x00, 0x01, 0xBA])) return (kind: StreamKind.video, container: 'MPEG-PS');
  if (_startsWith(bytes, const [0x30, 0x26, 0xB2, 0x75])) return (kind: StreamKind.video, container: 'ASF/WMV');
  if (_startsWith(bytes, ascii.encode('OggS'))) {
    final head = ascii.decode(bytes.sublist(0, bytes.length.clamp(0, 128)), allowInvalid: true);
    return head.contains('theora')
        ? (kind: StreamKind.video, container: 'Ogg')
        : (kind: StreamKind.audio, container: 'Ogg');
  }
  if (_startsWith(bytes, ascii.encode('fLaC'))) return (kind: StreamKind.audio, container: 'FLAC');
  if (_startsWith(bytes, ascii.encode('ID3')) ||
      (bytes.length > 1 && bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0 && (bytes[1] & 0x06) != 0)) {
    return (kind: StreamKind.audio, container: 'MP3');
  }

  final head = _text(bytes.sublist(0, bytes.length.clamp(0, 1024))).trimLeft();
  if (head.startsWith('#EXTM3U')) return (kind: StreamKind.hls, container: null);
  final lower = head.toLowerCase();
  if (lower.contains('<mpd')) return (kind: StreamKind.dash, container: null);
  if (lower.startsWith('<!doctype html') || lower.startsWith('<html') || lower.contains('<head') || lower.contains('<body')) {
    return (kind: StreamKind.webPage, container: null);
  }
  return null;
}

final _attributePattern = RegExp(r'([A-Z0-9-]+)=("[^"]*"|[^,]*)');

Map<String, String> _hlsAttributes(String text) {
  return {
    for (final match in _attributePattern.allMatches(text))
      match.group(1)!: match.group(2)!.startsWith('"') ? match.group(2)!.replaceAll('"', '') : match.group(2)!.trim(),
  };
}

const _drmKeyFormats = ['com.apple.streamingkeydelivery', 'com.widevine', 'com.microsoft.playready', 'urn:uuid:'];

/// Parses an HLS master or media playlist. Without `#EXT-X-ENDLIST` a media playlist is live,
/// unless it was [truncated], when that can't be told.
StreamManifestInfo parseHlsPlaylist(String text, {bool truncated = false}) {
  final lines = const LineSplitter().convert(text).map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
  final variants = <StreamVariant>[];
  var isMaster = false;
  var ended = false;
  var playlistType = '';
  var segments = 0;
  var totalMicros = 0;
  int? target;
  var audio = 0;
  var subtitles = 0;
  String? encryption;
  var drm = false;

  void key(String attributes) {
    final attrs = _hlsAttributes(attributes);
    final method = attrs['METHOD']?.toUpperCase();
    if (method == null || method == 'NONE') return;
    encryption ??= method;
    final format = attrs['KEYFORMAT']?.toLowerCase() ?? 'identity';
    if (method != 'AES-128' && format != 'identity') drm = true;
    if (_drmKeyFormats.any(format.startsWith)) drm = true;
  }

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (line.startsWith('#EXT-X-STREAM-INF:')) {
      isMaster = true;
      final attrs = _hlsAttributes(line.substring('#EXT-X-STREAM-INF:'.length));
      String? uri;
      for (var j = i + 1; j < lines.length; j++) {
        if (!lines[j].startsWith('#')) {
          uri = lines[j];
          i = j;
          break;
        }
      }
      final resolution = attrs['RESOLUTION']?.toLowerCase().split('x');
      variants.add(StreamVariant(
        bandwidth: int.tryParse(attrs['BANDWIDTH'] ?? ''),
        averageBandwidth: int.tryParse(attrs['AVERAGE-BANDWIDTH'] ?? ''),
        width: resolution?.length == 2 ? int.tryParse(resolution![0]) : null,
        height: resolution?.length == 2 ? int.tryParse(resolution![1]) : null,
        codecs: attrs['CODECS'],
        frameRate: double.tryParse(attrs['FRAME-RATE'] ?? ''),
        uri: uri,
      ));
    } else if (line.startsWith('#EXT-X-MEDIA:')) {
      final type = _hlsAttributes(line.substring('#EXT-X-MEDIA:'.length))['TYPE']?.toUpperCase();
      if (type == 'AUDIO') audio++;
      if (type == 'SUBTITLES') subtitles++;
    } else if (line.startsWith('#EXTINF:')) {
      final value = line.substring('#EXTINF:'.length).split(',').first.trim();
      final seconds = double.tryParse(value);
      if (seconds != null) totalMicros += (seconds * 1000000).round();
      segments++;
    } else if (line.startsWith('#EXT-X-TARGETDURATION:')) {
      target = int.tryParse(line.substring('#EXT-X-TARGETDURATION:'.length).trim());
    } else if (line.startsWith('#EXT-X-ENDLIST')) {
      ended = true;
    } else if (line.startsWith('#EXT-X-PLAYLIST-TYPE:')) {
      playlistType = line.substring('#EXT-X-PLAYLIST-TYPE:'.length).trim().toUpperCase();
    } else if (line.startsWith('#EXT-X-KEY:')) {
      key(line.substring('#EXT-X-KEY:'.length));
    } else if (line.startsWith('#EXT-X-SESSION-KEY:')) {
      key(line.substring('#EXT-X-SESSION-KEY:'.length));
    }
  }

  if (isMaster) {
    return StreamManifestInfo(
      isMaster: true,
      variants: variants,
      audioTracks: audio,
      subtitleTracks: subtitles,
      encryption: encryption,
      drm: drm,
      truncated: truncated,
    );
  }
  final bool? live = ended || playlistType == 'VOD' ? false : (truncated ? null : true);
  return StreamManifestInfo(
    isMaster: false,
    isLive: live,
    duration: segments == 0 ? null : Duration(microseconds: totalMicros),
    segmentCount: segments,
    targetDuration: target == null ? null : Duration(seconds: target),
    encryption: encryption,
    drm: drm,
    truncated: truncated,
  );
}

final _xmlAttribute = RegExp(r'([A-Za-z:]+)\s*=\s*"([^"]*)"');

Map<String, String> _xmlAttributes(String tag) => {
      for (final match in _xmlAttribute.allMatches(tag)) match.group(1)!: match.group(2)!,
    };

StreamManifestInfo _parseDash(String text, bool truncated) {
  final mpdTag = RegExp(r'<MPD\b[^>]*>', caseSensitive: false).firstMatch(text)?.group(0) ?? '';
  final mpd = _xmlAttributes(mpdTag);
  final live = mpd['type']?.toLowerCase() == 'dynamic';
  final variants = <StreamVariant>[];
  var audio = 0;
  for (final set in RegExp(r'<AdaptationSet\b[^>]*>', caseSensitive: false).allMatches(text)) {
    final attrs = _xmlAttributes(set.group(0)!);
    final type = '${attrs['contentType'] ?? ''} ${attrs['mimeType'] ?? ''}'.toLowerCase();
    if (type.contains('audio')) audio++;
  }
  for (final rep in RegExp(r'<Representation\b[^>]*>', caseSensitive: false).allMatches(text)) {
    final attrs = _xmlAttributes(rep.group(0)!);
    final height = int.tryParse(attrs['height'] ?? '');
    if (height == null) continue;
    variants.add(StreamVariant(
      bandwidth: int.tryParse(attrs['bandwidth'] ?? ''),
      width: int.tryParse(attrs['width'] ?? ''),
      height: height,
      codecs: attrs['codecs'],
      frameRate: _frameRate(attrs['frameRate']),
    ));
  }
  return StreamManifestInfo(
    isMaster: true,
    variants: variants,
    isLive: live,
    duration: _isoDuration(mpd['mediaPresentationDuration']),
    audioTracks: audio,
    drm: RegExp('<ContentProtection', caseSensitive: false).hasMatch(text),
    truncated: truncated,
  );
}

double? _frameRate(String? value) {
  if (value == null) return null;
  final parts = value.split('/');
  if (parts.length == 2) {
    final n = double.tryParse(parts[0]);
    final d = double.tryParse(parts[1]);
    return n == null || d == null || d == 0 ? null : n / d;
  }
  return double.tryParse(value);
}

/// `PT1H2M3.5S` → 1:02:03.5.
Duration? _isoDuration(String? value) {
  if (value == null) return null;
  final match = RegExp(r'^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:([\d.]+)S)?)?$').firstMatch(value.trim());
  if (match == null) return null;
  final days = int.tryParse(match.group(1) ?? '') ?? 0;
  final hours = int.tryParse(match.group(2) ?? '') ?? 0;
  final minutes = int.tryParse(match.group(3) ?? '') ?? 0;
  final seconds = double.tryParse(match.group(4) ?? '') ?? 0;
  return Duration(
    microseconds: (((days * 24 + hours) * 60 + minutes) * 60 * 1000000 + seconds * 1000000).round(),
  );
}

String _networkMessage(Object error, Uri url) {
  final host = url.host;
  if (error is TimeoutException) return "The server didn't respond in time.";
  if (error is HandshakeException || error is TlsException) {
    return "Secure connection failed: the server's certificate isn't trusted.";
  }
  if (error is SocketException) {
    final message = '${error.message} ${error.osError?.message ?? ''}'.toLowerCase();
    if (message.contains('host lookup') || message.contains('nodename') || message.contains('name or service')) {
      return 'Couldn\'t find the server "$host". Check the link and your internet connection.';
    }
    if (message.contains('refused')) return 'The server "$host" refused the connection.';
    return 'Couldn\'t connect to "$host". Check your internet connection.';
  }
  if (error is HttpException) return 'The server closed the connection unexpectedly.';
  return "Couldn't connect to the server.";
}

String _statusMessage(int status) => switch (status) {
      204 => '204 No Content: the server sent back nothing.',
      400 => '400 Bad Request: the server rejected the link. It may be incomplete.',
      401 => '401 Unauthorized: this link needs a login or an access token.',
      403 => '403 Forbidden: access was refused. The link may have expired, or only work on its own website.',
      404 => '404 Not Found: there is nothing at this address. The link may be broken or expired.',
      410 => '410 Gone: this video has been removed.',
      429 => '429 Too Many Requests: the server is limiting requests. Try again later.',
      451 => '451 Unavailable For Legal Reasons: this video is blocked in your region.',
      >= 500 && < 600 => '$status Server Error: the server had a problem. Try again later.',
      >= 300 && < 400 => '$status Redirect without a destination: the server didn\'t say where the video moved.',
      _ => 'HTTP $status: the server didn\'t return the video.',
    };
