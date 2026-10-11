import 'package:danaview_domain/danaview_domain.dart';

/// Order-independent: media_kit reports `playing`, `completed` and `buffering` as separate events
/// at EOF, and a late `buffering: false` must not turn "ended" back into "paused".
PlaybackStatus mpvTransportStatus({required bool playing, required bool buffering, required bool completed}) {
  if (completed && !playing) return PlaybackStatus.ended;
  if (buffering) return PlaybackStatus.buffering;
  return playing ? PlaybackStatus.playing : PlaybackStatus.paused;
}

final RegExp _quotedPath = RegExp(r"'([^']+)'");

/// Maps an mpv error-level log line (as forwarded by media_kit) to a [PlayerError].
///
/// Many of these lines are not playback failures: mpv keeps playing without audio, skips a bad
/// frame, or falls back to software decoding.
PlayerError classifyMpvError(String message) {
  final text = message.trim();
  final lower = text.toLowerCase();
  String? quotedPath() => _quotedPath.firstMatch(text)?.group(1);

  if (lower.contains('audio device') ||
      lower.contains('no sound') ||
      lower.contains('audio output') ||
      lower.contains('audio driver') ||
      lower.contains('cannot convert decoder/filter output')) {
    return AudioOutputUnavailable(details: text);
  }
  if (lower.contains('error while decoding frame') ||
      lower.contains('error decoding audio') ||
      lower.contains('hardware decod') ||
      lower.contains('hwdec') ||
      lower.contains('audio filter') ||
      lower.contains('could not create device') ||
      lower.contains('can not open external file') ||
      lower.contains('can\'t open external file') ||
      lower.contains('invalid video timestamp') ||
      lower.contains('invalid audio pts') ||
      lower.contains('too many packets')) {
    return PlaybackWarning(text);
  }
  if (lower.contains('no such file or directory') || lower.contains('file not found')) {
    return FileNotFound(quotedPath() ?? '', details: text);
  }
  if (lower.contains('permission denied') || lower.contains('operation not permitted')) {
    return PermissionDenied(quotedPath() ?? '', details: text);
  }
  if (lower.contains('failed to recognize file format') || lower.contains('unsupported codec')) {
    return UnsupportedFormat('', details: text);
  }
  if (lower.startsWith('tcp:') ||
      lower.contains('connection refused') ||
      lower.contains('connection timed out') ||
      lower.contains('failed to resolve hostname') ||
      lower.contains('network is unreachable')) {
    return NetworkUnreachable(quotedPath() ?? '', details: text);
  }
  return GenericPlayerError(text, technicalDetails: text);
}
