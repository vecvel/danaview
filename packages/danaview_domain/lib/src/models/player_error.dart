import 'package:meta/meta.dart';

@immutable
sealed class PlayerError {
  final String message;
  final bool recoverable;
  final String? technicalDetails;

  const PlayerError(this.message, {this.recoverable = false, this.technicalDetails});

  @override
  String toString() => '$runtimeType: $message';
}

class FileNotFound extends PlayerError {
  final String path;
  const FileNotFound(this.path, {String? details})
      : super('File not found: $path', recoverable: false, technicalDetails: details);
}

class UnsupportedFormat extends PlayerError {
  final String format;
  const UnsupportedFormat(this.format, {String? details})
      : super('Unsupported format or codec: $format', recoverable: false, technicalDetails: details);
}

class DecoderInitFailed extends PlayerError {
  final String decoder;
  const DecoderInitFailed(this.decoder, {String? details})
      : super('Hardware decoder initialization failed for $decoder. Falling back to software decode.',
            recoverable: true, technicalDetails: details);
}

class NetworkUnreachable extends PlayerError {
  final String url;
  const NetworkUnreachable(this.url, {String? details})
      : super('Network stream unreachable. Retrying connection...',
            recoverable: true, technicalDetails: details);
}

class YtdlpFailed extends PlayerError {
  final String url;
  const YtdlpFailed(this.url, {String? details})
      : super('Stream extractor failed to resolve video URL. Please verify yt-dlp.',
            recoverable: false, technicalDetails: details);
}

class PermissionDenied extends PlayerError {
  final String path;
  const PermissionDenied(this.path, {String? details})
      : super('Permission denied accessing media path: $path',
            recoverable: false, technicalDetails: details);
}

class AudioDeviceLost extends PlayerError {
  final String deviceName;
  const AudioDeviceLost(this.deviceName, {String? details})
      : super('Audio device disconnected: $deviceName',
            recoverable: true, technicalDetails: details);
}

/// No audio device could be opened; video keeps playing silently.
class AudioOutputUnavailable extends PlayerError {
  const AudioOutputUnavailable({String? details})
      : super('No audio output available', recoverable: true, technicalDetails: details);
}

/// Something mpv reported that does not interrupt playback (a bad frame, a decoder fallback).
class PlaybackWarning extends PlayerError {
  const PlaybackWarning(super.message) : super(recoverable: true);
}

class GenericPlayerError extends PlayerError {
  const GenericPlayerError(super.message, {super.recoverable, super.technicalDetails});
}
