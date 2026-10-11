import 'package:flutter/foundation.dart';
import 'package:danaview_domain/danaview_domain.dart';

@immutable
class EngineConfig {
  final String vo;
  final String hwdec;
  final String? gpuApi;
  final bool cache;
  final int demuxerMaxBytes;
  final int demuxerReadaheadSecs;
  final String subAuto;
  final List<String> subFilePaths;
  final String audioFileAuto;
  final bool keepOpen;
  final bool ytdl;
  final String screenshotFormat;
  final double volumeMax;
  final bool audioPitchCorrection;
  final bool forceWindow;
  final bool osc;
  final int osdLevel;
  final bool inputDefaultBindings;

  const EngineConfig({
    this.vo = 'libmpv',
    this.hwdec = 'auto-safe',
    this.gpuApi,
    this.cache = true,
    this.demuxerMaxBytes = 150 * 1024 * 1024,
    this.demuxerReadaheadSecs = 20,
    this.subAuto = 'fuzzy',
    this.subFilePaths = const ['subs', 'Subs', 'subtitles', 'Subtitles'],
    this.audioFileAuto = 'fuzzy',
    this.keepOpen = true,
    this.ytdl = true,
    this.screenshotFormat = 'png',
    this.volumeMax = 300,
    this.audioPitchCorrection = true,
    this.forceWindow = false,
    this.osc = false,
    this.osdLevel = 0,
    this.inputDefaultBindings = false,
  });

  static const EngineConfig defaultDesktop = EngineConfig();
}

abstract interface class PlaybackEngine {
  Future<void> initialize({EngineConfig config = EngineConfig.defaultDesktop});
  Future<void> dispose();

  // Source
  Future<void> open(MediaSource source, {Duration? startAt});
  Future<void> stop();

  // Transport
  Future<void> play();
  Future<void> pause();
  Future<void> playOrPause();
  Future<void> seek(Duration position, {SeekMode mode = SeekMode.keyframe});
  Future<void> seekBy(Duration delta);
  Future<void> frameStep(int direction); // +1 / -1

  // Audio
  Future<void> setVolume(double percent); // 0–300, >100 boosts
  Future<void> setMuted(bool muted);
  Future<void> setAudioDelay(Duration delay);
  Future<void> setAudioTrack(String? id);
  Future<void> setAudioFilters(AudioFilter filter);

  // Video
  Future<void> setSpeed(double speed); // 0.0625–16
  Future<void> setVideoTrack(String? id);
  Future<void> setVideoAdjust(VideoAdjust adjust);
  Future<void> setVideoTransform(VideoTransform t);
  Future<void> setDeinterlace(bool on);
  Future<void> setHwdec(HwdecMode mode);

  // Subtitles
  Future<void> setSubtitleTrack(String? id);
  Future<void> addSubtitleFile(String path, {bool select = true});
  Future<void> setSubtitleDelay(Duration delay);
  Future<void> setSubtitleStyle(SubtitleStyle style);
  Future<void> setSecondarySubtitleTrack(String? id);

  // Misc
  Future<void> setAbLoop(Duration? a, Duration? b);
  Future<Uint8List?> screenshot({bool includeSubtitles = true});
  Future<T?> getProperty<T>(String name);
  Future<void> setProperty(String name, Object? value);
  Future<void> command(List<String> args);

  // Observation
  Stream<PlayerSnapshot> get snapshots;
  Stream<PlayerError> get errors;
  ValueListenable<int?> get textureId;
  dynamic get videoController;
}
