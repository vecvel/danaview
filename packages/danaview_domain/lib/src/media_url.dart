import 'models/media_source.dart';

/// Parses user-typed links into playable [MediaRef]s.
class MediaUrl {
  MediaUrl._();

  static const Set<String> supportedSchemes = {
    'http', 'https', 'rtsp', 'rtsps', 'rtmp', 'rtmps', 'mms', 'mmsh', 'mmst', 'srt', 'udp', 'rtp', 'file',
  };

  static const _hostlessSchemes = {'udp', 'rtp', 'srt'};

  static const _mediaExtensions = {
    'mp4', 'mkv', 'm4v', 'mov', 'avi', 'webm', 'ts', 'm2ts', 'flv', 'wmv', 'ogv', '3gp', 'mpg', 'mpeg', 'm3u8', 'mpd',
  };

  static const _unsupportedExtensions = {
    'html', 'htm', 'php', 'asp', 'aspx', 'jsp',
    'pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'txt', 'csv', 'json', 'xml',
    'zip', 'rar', 'tar', 'gz', '7z', 'bz2', 'iso', 'exe', 'apk', 'dmg', 'pkg', 'deb', 'rpm',
    'jpg', 'jpeg', 'png', 'gif', 'webp', 'svg', 'ico', 'bmp', 'tiff', 'tif', 'avif',
    'css', 'js',
  };

  static final _schemePrefix = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.\-]*):(.*)$');
  static final _hostPort = RegExp(r'^\d+(?:[/?#]|$)');
  static final _lineBreaks = RegExp(r'[\r\n\t]');
  static final _localPath = RegExp(r'^(?:/|~|\\\\|\.{1,2}[/\\]|[a-zA-Z]:[/\\])');
  static final _hostChars = RegExp(r'^[a-zA-Z0-9\-._~%]+$');
  static final _ipv4 = RegExp(r'^\d{1,3}(?:\.\d{1,3}){3}$');

  static const _invalidMessage = "That doesn't look like a valid link. Check it and try again.";

  /// The playable reference for [input], or null when [validationError] is non-null.
  ///
  /// http(s)/HLS/DASH/RTSP/RTMP/MMS/SRT/UDP/RTP links become remote refs keyed by
  /// the normalized URL; `file://` links become local refs keyed by the file path.
  /// A bare host such as `example.com/video.mp4` is treated as `https://`.
  static MediaRef? tryParse(String input) => _parse(input).ref;

  /// A user-facing message explaining why [input] can't be played, or null when it can.
  static String? validationError(String input) => _parse(input).error;

  static _ParseResult _parse(String input) {
    final text = input.trim();
    if (text.isEmpty) return const _ParseResult.error('Paste or type a video link.');
    if (_lineBreaks.hasMatch(text)) return const _ParseResult.error('Enter one link at a time.');
    if (_localPath.hasMatch(text)) {
      return const _ParseResult.error('That looks like a file on this device. Use Open File to play it.');
    }

    final prefix = _schemePrefix.firstMatch(text);
    final assumedHttps = prefix == null || (!text.contains('://') && _hostPort.hasMatch(prefix.group(2)!));

    final Uri uri;
    try {
      uri = Uri.parse(assumedHttps ? 'https://$text' : text);
    } on FormatException {
      return const _ParseResult.error(_invalidMessage);
    }

    final scheme = uri.scheme.toLowerCase();
    if (!supportedSchemes.contains(scheme)) {
      return _ParseResult.error('Links starting with "$scheme:" can\'t be played here.');
    }
    if (scheme == 'file') return _parseFile(uri);

    if (uri.hasPort && (uri.port < 1 || uri.port > 65535)) return const _ParseResult.error(_invalidMessage);
    final host = uri.host;
    if (host.isEmpty) {
      if (!_hostlessSchemes.contains(scheme) || !uri.hasPort) return const _ParseResult.error(_invalidMessage);
    } else if (!_isValidHost(host)) {
      return const _ParseResult.error(_invalidMessage);
    }

    if (assumedHttps) {
      final looksLikeHost = host == 'localhost' || host.contains('.') || host.contains(':');
      if (!looksLikeHost) return const _ParseResult.error(_invalidMessage);
      final lastLabel = host.split('.').last.toLowerCase();
      if (uri.pathSegments.every((s) => s.isEmpty) && _mediaExtensions.contains(lastLabel)) {
        return const _ParseResult.error(
            'That looks like a file name. Enter the full link, like https://example.com/video.mp4');
      }
    }

    final lastSegment = uri.pathSegments.where((s) => s.isNotEmpty).lastOrNull;
    if (lastSegment != null && lastSegment.contains('.')) {
      final ext = lastSegment.split('.').last.toLowerCase();
      if (_unsupportedExtensions.contains(ext)) {
        return _ParseResult.error(
            'This link points to an unsupported file format (.$ext). Enter a link to a video or stream.');
      }
    }

    final url = uri.toString();
    return _ParseResult.ref(MediaRef(id: url, title: _titleFor(uri), pathOrUri: url, isRemote: true));
  }

  static _ParseResult _parseFile(Uri uri) {
    final String path;
    try {
      path = uri.toFilePath();
    } catch (_) {
      return const _ParseResult.error(_invalidMessage);
    }
    final name = uri.pathSegments.where((s) => s.isNotEmpty).lastOrNull;
    if (name == null) return const _ParseResult.error(_invalidMessage);
    if (name.contains('.')) {
      final ext = name.split('.').last.toLowerCase();
      if (_unsupportedExtensions.contains(ext)) {
        return _ParseResult.error(
            'This file format (.$ext) is unsupported. Choose a video or audio file.');
      }
    }
    return _ParseResult.ref(MediaRef(id: path, title: name, pathOrUri: path));
  }

  static bool _isValidHost(String host) {
    if (host.contains(':')) return true;
    if (_ipv4.hasMatch(host)) return host.split('.').every((o) => int.parse(o) <= 255);
    if (!_hostChars.hasMatch(host) || host.contains('%20')) return false;
    return host.split('.').every((label) => label.isNotEmpty);
  }

  static String _titleFor(Uri uri) {
    final segment = uri.pathSegments.where((s) => s.isNotEmpty).lastOrNull;
    if (segment != null) return segment;
    if (uri.host.isNotEmpty) return uri.host;
    return uri.toString();
  }
}

class _ParseResult {
  final MediaRef? ref;
  final String? error;

  const _ParseResult.ref(MediaRef this.ref) : error = null;
  const _ParseResult.error(String this.error) : ref = null;
}
