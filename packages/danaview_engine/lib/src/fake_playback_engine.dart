import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:danaview_domain/danaview_domain.dart';
import 'playback_engine.dart';

class FakePlaybackEngine implements PlaybackEngine {
  final StreamController<PlayerSnapshot> _snapshotController =
      StreamController<PlayerSnapshot>.broadcast();
  final StreamController<PlayerError> _errorController =
      StreamController<PlayerError>.broadcast();

  final ValueNotifier<int?> _textureIdNotifier = ValueNotifier<int?>(1);

  PlayerSnapshot _currentSnapshot = const PlayerSnapshot();
  Timer? _ticker;

  PlayerSnapshot get currentSnapshot => _currentSnapshot;

  void emitMockSnapshot(PlayerSnapshot snapshot) {
    _currentSnapshot = snapshot;
    _snapshotController.add(snapshot);
  }

  void emitMockError(PlayerError error) {
    _errorController.add(error);
  }

  @override
  ValueListenable<int?> get textureId => _textureIdNotifier;

  @override
  dynamic get videoController => null;

  @override
  Stream<PlayerSnapshot> get snapshots => _snapshotController.stream;

  @override
  Stream<PlayerError> get errors => _errorController.stream;

  @override
  Future<void> initialize({EngineConfig config = EngineConfig.defaultDesktop}) async {
    emitMockSnapshot(const PlayerSnapshot());
  }

  @override
  Future<void> open(MediaSource source, {Duration? startAt}) async {
    _ticker?.cancel();
    // Like mpv: a loading snapshot with the previous file's position and duration cleared.
    emitMockSnapshot(_cloneWith(
      status: PlaybackStatus.loading,
      position: Duration.zero,
      duration: Duration.zero,
      cacheEnd: Duration.zero,
    ));
    emitMockSnapshot(_currentSnapshot = PlayerSnapshot(
      status: PlaybackStatus.playing,
      position: startAt ?? Duration.zero,
      duration: const Duration(minutes: 10),
      cacheEnd: const Duration(minutes: 4),
      speed: 1.0,
      volume: 100.0,
      tracks: const TrackSelection(
        videoTracks: [
          MediaTrack(id: '1', type: TrackType.video, title: '1080p HEVC', codec: 'hevc', width: 1920, height: 1080, fps: 60.0),
        ],
        audioTracks: [
          MediaTrack(id: '1', type: TrackType.audio, title: 'English 5.1', language: 'eng', codec: 'eac3', channels: 6),
        ],
        subtitleTracks: [
          MediaTrack(id: '1', type: TrackType.subtitle, title: 'English SDH', language: 'eng', codec: 'subrip'),
        ],
        selectedVideoTrackId: '1',
        selectedAudioTrackId: '1',
        selectedSubtitleTrackId: '1',
      ),
      chapters: const [
        Chapter(id: 1, title: 'Prologue', start: Duration.zero, end: Duration(minutes: 2)),
        Chapter(id: 2, title: 'Main Event', start: Duration(minutes: 2), end: Duration(minutes: 8)),
        Chapter(id: 3, title: 'Credits', start: Duration(minutes: 8), end: Duration(minutes: 10)),
      ],
    ));

    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_currentSnapshot.status == PlaybackStatus.playing) {
        final nextPos = _currentSnapshot.position + const Duration(seconds: 1);
        if (nextPos >= _currentSnapshot.duration) {
          emitMockSnapshot(_currentSnapshot = _cloneWith(status: PlaybackStatus.ended));
          _ticker?.cancel();
        } else {
          emitMockSnapshot(_currentSnapshot = _cloneWith(position: nextPos));
        }
      }
    });
  }

  static const Object _keep = Object();

  PlayerSnapshot _cloneWith({
    PlaybackStatus? status,
    Duration? position,
    Duration? duration,
    Duration? cacheEnd,
    double? speed,
    double? volume,
    bool? muted,
    TrackSelection? tracks,
    List<Chapter>? chapters,
    VideoAdjust? adjust,
    VideoTransform? transform,
    SubtitleStyle? subtitleStyle,
    AudioFilter? audioFilter,
    Duration? subtitleDelay,
    Duration? audioDelay,
    Object? abLoop = _keep,
  }) {
    return PlayerSnapshot(
      status: status ?? _currentSnapshot.status,
      position: position ?? _currentSnapshot.position,
      duration: duration ?? _currentSnapshot.duration,
      cacheEnd: cacheEnd ?? _currentSnapshot.cacheEnd,
      speed: speed ?? _currentSnapshot.speed,
      volume: volume ?? _currentSnapshot.volume,
      muted: muted ?? _currentSnapshot.muted,
      tracks: tracks ?? _currentSnapshot.tracks,
      chapters: chapters ?? _currentSnapshot.chapters,
      adjust: adjust ?? _currentSnapshot.adjust,
      transform: transform ?? _currentSnapshot.transform,
      subtitleStyle: subtitleStyle ?? _currentSnapshot.subtitleStyle,
      audioFilter: audioFilter ?? _currentSnapshot.audioFilter,
      subtitleDelay: subtitleDelay ?? _currentSnapshot.subtitleDelay,
      audioDelay: audioDelay ?? _currentSnapshot.audioDelay,
      abLoop: identical(abLoop, _keep) ? _currentSnapshot.abLoop : abLoop as AbLoop?,
    );
  }

  @override
  Future<void> play() async => emitMockSnapshot(_cloneWith(status: PlaybackStatus.playing));

  @override
  Future<void> pause() async => emitMockSnapshot(_cloneWith(status: PlaybackStatus.paused));

  @override
  Future<void> playOrPause() async {
    if (_currentSnapshot.status == PlaybackStatus.playing) {
      await pause();
    } else {
      await play();
    }
  }

  @override
  Future<void> stop() async {
    _ticker?.cancel();
    emitMockSnapshot(_cloneWith(status: PlaybackStatus.idle, position: Duration.zero));
  }

  @override
  Future<void> seek(Duration position, {SeekMode mode = SeekMode.keyframe}) async {
    emitMockSnapshot(_cloneWith(position: position));
  }

  @override
  Future<void> seekBy(Duration delta) async {
    final target = _currentSnapshot.position + delta;
    await seek(target < Duration.zero ? Duration.zero : target);
  }

  @override
  Future<void> frameStep(int direction) async {
    await seekBy(Duration(milliseconds: direction * 40));
  }

  @override
  Future<void> setVolume(double percent) async {
    emitMockSnapshot(_cloneWith(volume: percent.clamp(0.0, 300.0)));
  }

  @override
  Future<void> setMuted(bool muted) async {
    emitMockSnapshot(_cloneWith(muted: muted));
  }

  @override
  Future<void> setAudioDelay(Duration delay) async {
    emitMockSnapshot(_cloneWith(audioDelay: delay));
  }

  @override
  Future<void> setAudioTrack(String? id) async {
    emitMockSnapshot(_cloneWith(
      tracks: _currentSnapshot.tracks.copyWith(selectedAudioTrackId: id),
    ));
  }

  @override
  Future<void> setAudioFilters(AudioFilter filter) async {
    emitMockSnapshot(_cloneWith(audioFilter: filter));
  }

  @override
  Future<void> setSpeed(double speed) async {
    emitMockSnapshot(_cloneWith(speed: speed));
  }

  @override
  Future<void> setVideoTrack(String? id) async {
    emitMockSnapshot(_cloneWith(
      tracks: _currentSnapshot.tracks.copyWith(selectedVideoTrackId: id),
    ));
  }

  @override
  Future<void> setVideoAdjust(VideoAdjust adjust) async {
    emitMockSnapshot(_cloneWith(adjust: adjust));
  }

  @override
  Future<void> setVideoTransform(VideoTransform t) async {
    emitMockSnapshot(_cloneWith(transform: t));
  }

  @override
  Future<void> setDeinterlace(bool on) async {}

  @override
  Future<void> setHwdec(HwdecMode mode) async {}

  @override
  Future<void> setSubtitleTrack(String? id) async {
    emitMockSnapshot(_cloneWith(
      tracks: _currentSnapshot.tracks.copyWith(selectedSubtitleTrackId: id),
    ));
  }

  @override
  Future<void> addSubtitleFile(String path, {bool select = true}) async {}

  @override
  Future<void> setSubtitleDelay(Duration delay) async {
    emitMockSnapshot(_cloneWith(subtitleDelay: delay));
  }

  @override
  Future<void> setSubtitleStyle(SubtitleStyle style) async {
    emitMockSnapshot(_cloneWith(subtitleStyle: style));
  }

  @override
  Future<void> setSecondarySubtitleTrack(String? id) async {
    emitMockSnapshot(_cloneWith(
      tracks: _currentSnapshot.tracks.copyWith(selectedSecondarySubtitleTrackId: id),
    ));
  }

  @override
  Future<void> setAbLoop(Duration? a, Duration? b) async {
    if (a == null) {
      emitMockSnapshot(_cloneWith(abLoop: null));
    } else {
      emitMockSnapshot(_cloneWith(abLoop: AbLoop(a: a, b: b)));
    }
  }

  @override
  Future<Uint8List?> screenshot({bool includeSubtitles = true}) async {
    return Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]); // PNG signature
  }

  @override
  Future<T?> getProperty<T>(String name) async => null;

  @override
  Future<void> setProperty(String name, Object? value) async {}

  @override
  Future<void> command(List<String> args) async {}

  @override
  Future<void> dispose() async {
    _ticker?.cancel();
    await _snapshotController.close();
    await _errorController.close();
    _textureIdNotifier.dispose();
  }
}
