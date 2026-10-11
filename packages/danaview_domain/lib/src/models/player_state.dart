import 'package:meta/meta.dart';
import 'audio_filter.dart';
import 'media_source.dart';
import 'player_error.dart';
import 'tracks.dart';
import 'video_options.dart';

enum PlaybackStatus {
  idle,
  loading,
  playing,
  paused,
  buffering,
  ended,
  error,
}

enum SeekMode {
  keyframe,
  exact,
}

@immutable
class Chapter {
  final int id;
  final String title;
  final Duration start;
  final Duration? end;

  const Chapter({
    required this.id,
    required this.title,
    required this.start,
    this.end,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Chapter &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          start == other.start;

  @override
  int get hashCode => id.hashCode ^ start.hashCode;
}

@immutable
class Bookmark {
  final String id;
  final String mediaId;
  final Duration position;
  final String label;
  final String? note;
  final DateTime createdAt;

  const Bookmark({
    required this.id,
    required this.mediaId,
    required this.position,
    required this.label,
    this.note,
    required this.createdAt,
  });
}

@immutable
class AbLoop {
  final Duration a;
  final Duration? b;
  final int count;

  const AbLoop({
    required this.a,
    this.b,
    this.count = 0,
  });

  bool get isActive => b != null;

  AbLoop copyWith({
    Duration? a,
    Duration? b,
    int? count,
  }) {
    return AbLoop(
      a: a ?? this.a,
      b: b ?? this.b,
      count: count ?? this.count,
    );
  }
}

@immutable
class DiagnosticsStats {
  final String? container;
  final String? videoCodec;
  final String? audioCodec;
  final String? resolution;
  final String? colorSpace;
  final String? primaries;
  final String? bitDepth;
  final String? hwdec;
  final double fps;
  final double estimatedFps;
  final int droppedFrames;
  final int voDelayedFrames;
  final double avDesync; // seconds or ms
  final Duration cacheDuration;
  final int cacheBytes;
  final double videoBitrate; // kbps
  final double audioBitrate; // kbps
  final String? audioDevice;
  final String? audioChannels;
  final int? audioSampleRate;

  const DiagnosticsStats({
    this.container,
    this.videoCodec,
    this.audioCodec,
    this.resolution,
    this.colorSpace,
    this.primaries,
    this.bitDepth,
    this.hwdec,
    this.fps = 0.0,
    this.estimatedFps = 0.0,
    this.droppedFrames = 0,
    this.voDelayedFrames = 0,
    this.avDesync = 0.0,
    this.cacheDuration = Duration.zero,
    this.cacheBytes = 0,
    this.videoBitrate = 0.0,
    this.audioBitrate = 0.0,
    this.audioDevice,
    this.audioChannels,
    this.audioSampleRate,
  });

  static const DiagnosticsStats empty = DiagnosticsStats();
}

@immutable
class PlayerSnapshot {
  final PlaybackStatus status;
  final Duration position;
  final Duration duration;
  final Duration cacheEnd;
  final double speed;
  final double volume;
  final bool muted;
  final TrackSelection tracks;
  final List<Chapter> chapters;
  final VideoAdjust adjust;
  final VideoTransform transform;
  final SubtitleStyle subtitleStyle;
  final AudioFilter audioFilter;
  final Duration subtitleDelay;
  final Duration audioDelay;
  final AbLoop? abLoop;
  final String? hwdecCurrent;
  final DiagnosticsStats stats;
  final PlayerError? error;

  const PlayerSnapshot({
    this.status = PlaybackStatus.idle,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.cacheEnd = Duration.zero,
    this.speed = 1.0,
    this.volume = 100.0,
    this.muted = false,
    this.tracks = const TrackSelection.empty(),
    this.chapters = const [],
    this.adjust = VideoAdjust.normal,
    this.transform = VideoTransform.normal,
    this.subtitleStyle = SubtitleStyle.normal,
    this.audioFilter = const AudioFilter(),
    this.subtitleDelay = Duration.zero,
    this.audioDelay = Duration.zero,
    this.abLoop,
    this.hwdecCurrent,
    this.stats = DiagnosticsStats.empty,
    this.error,
  });
}

enum ViewMode {
  windowed,
  fullscreen,
  pip,
}

@immutable
class PlayerState {
  final MediaSource? currentSource;
  final MediaRef? currentMediaRef;
  final PlaybackStatus status;
  final Duration position;
  final Duration duration;
  final Duration cacheEnd;
  final double speed;
  final double volume; // 0–300 (over 100 is boost)
  final bool muted;
  final TrackSelection tracks;
  final List<Chapter> chapters;
  final VideoTransform transform;
  final VideoAdjust adjust;
  final SubtitleStyle subtitleStyle;
  final AudioFilter audioFilter;
  final Duration subtitleDelay;
  final Duration audioDelay;
  final AbLoop? abLoop;
  final ViewMode viewMode;
  final bool isAlwaysOnTop;
  final DiagnosticsStats stats;
  final PlayerError? error;

  const PlayerState({
    this.currentSource,
    this.currentMediaRef,
    this.status = PlaybackStatus.idle,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.cacheEnd = Duration.zero,
    this.speed = 1.0,
    this.volume = 100.0,
    this.muted = false,
    this.tracks = const TrackSelection.empty(),
    this.chapters = const [],
    this.transform = VideoTransform.normal,
    this.adjust = VideoAdjust.normal,
    this.subtitleStyle = SubtitleStyle.normal,
    this.audioFilter = const AudioFilter(),
    this.subtitleDelay = Duration.zero,
    this.audioDelay = Duration.zero,
    this.abLoop,
    this.viewMode = ViewMode.windowed,
    this.isAlwaysOnTop = false,
    this.stats = DiagnosticsStats.empty,
    this.error,
  });

  static const PlayerState initial = PlayerState();

  bool get isPlaying => status == PlaybackStatus.playing;
  bool get isBuffering => status == PlaybackStatus.buffering;
  bool get isEnded => status == PlaybackStatus.ended;
  bool get isVolumeBoosted => volume > 100.0;

  double get progress {
    if (duration.inMilliseconds == 0) return 0.0;
    return (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
  }

  double get bufferProgress {
    if (duration.inMilliseconds == 0) return 0.0;
    return (cacheEnd.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
  }

  PlayerState copyWith({
    Object? currentSource = _sentinel,
    Object? currentMediaRef = _sentinel,
    PlaybackStatus? status,
    Duration? position,
    Duration? duration,
    Duration? cacheEnd,
    double? speed,
    double? volume,
    bool? muted,
    TrackSelection? tracks,
    List<Chapter>? chapters,
    VideoTransform? transform,
    VideoAdjust? adjust,
    SubtitleStyle? subtitleStyle,
    AudioFilter? audioFilter,
    Duration? subtitleDelay,
    Duration? audioDelay,
    Object? abLoop = _sentinel,
    ViewMode? viewMode,
    bool? isAlwaysOnTop,
    DiagnosticsStats? stats,
    Object? error = _sentinel,
  }) {
    return PlayerState(
      currentSource: currentSource == _sentinel ? this.currentSource : currentSource as MediaSource?,
      currentMediaRef: currentMediaRef == _sentinel ? this.currentMediaRef : currentMediaRef as MediaRef?,
      status: status ?? this.status,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      cacheEnd: cacheEnd ?? this.cacheEnd,
      speed: speed ?? this.speed,
      volume: volume ?? this.volume,
      muted: muted ?? this.muted,
      tracks: tracks ?? this.tracks,
      chapters: chapters ?? this.chapters,
      transform: transform ?? this.transform,
      adjust: adjust ?? this.adjust,
      subtitleStyle: subtitleStyle ?? this.subtitleStyle,
      audioFilter: audioFilter ?? this.audioFilter,
      subtitleDelay: subtitleDelay ?? this.subtitleDelay,
      audioDelay: audioDelay ?? this.audioDelay,
      abLoop: abLoop == _sentinel ? this.abLoop : abLoop as AbLoop?,
      viewMode: viewMode ?? this.viewMode,
      isAlwaysOnTop: isAlwaysOnTop ?? this.isAlwaysOnTop,
      stats: stats ?? this.stats,
      error: error == _sentinel ? this.error : error as PlayerError?,
    );
  }
}

const Object _sentinel = Object();
