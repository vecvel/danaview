import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart' as mkv;
import 'package:path_provider/path_provider.dart';
import 'package:danaview_domain/danaview_domain.dart';
import 'mpv_events.dart';
import 'playback_engine.dart';

class MpvPlaybackEngine implements PlaybackEngine {
  MpvPlaybackEngine({this.subtitleFontAssets = const []});

  /// Font files (asset keys) that subtitles and the OSD render with, so they use the app's own
  /// typeface rather than whatever the system has installed.
  final List<String> subtitleFontAssets;

  mk.Player? _player;
  mkv.VideoController? _videoController;

  final StreamController<PlayerSnapshot> _snapshotController =
      StreamController<PlayerSnapshot>.broadcast();
  final StreamController<PlayerError> _errorController =
      StreamController<PlayerError>.broadcast();

  final ValueNotifier<int?> _textureIdNotifier = ValueNotifier<int?>(null);

  PlayerSnapshot _currentSnapshot = const PlayerSnapshot();
  Timer? _statsTimer;
  final List<StreamSubscription> _subscriptions = [];

  bool _isDisposed = false;
  bool _playing = false;
  bool _buffering = false;
  bool _completed = false;

  @override
  ValueListenable<int?> get textureId => _textureIdNotifier;

  @override
  mkv.VideoController? get videoController => _videoController;

  @override
  Stream<PlayerSnapshot> get snapshots => _snapshotController.stream;

  @override
  Stream<PlayerError> get errors => _errorController.stream;

  @override
  Future<void> initialize({EngineConfig config = EngineConfig.defaultDesktop}) async {
    mk.MediaKit.ensureInitialized();

    final playerConfig = mk.PlayerConfiguration(
      title: 'Danaview',
      ready: () {
        debugPrint('[MpvPlaybackEngine] libmpv is ready');
      },
      bufferSize: config.demuxerMaxBytes,
      logLevel: mk.MPVLogLevel.warn,
    );

    _player = mk.Player(configuration: playerConfig);
    _videoController = mkv.VideoController(_player!);

    // Not awaited: media_kit's setProperty waits for the VideoController's
    // native texture, which is only created once the Video widget mounts after
    // runApp(). Awaiting here deadlocks startup.
    unawaited(_configureMpv(config));

    _wireSubscriptions();
    _startStatsPolling();
  }

  /// Copies [subtitleFontAssets] to a real folder (libass can't read the asset bundle) and points
  /// mpv at it. Kept out of the cache folders, which the Storage tool may clear.
  Future<void> _installSubtitleFonts() async {
    if (subtitleFontAssets.isEmpty) return;
    try {
      final dir = Directory('${(await getApplicationSupportDirectory()).path}/fonts');
      await dir.create(recursive: true);
      for (final asset in subtitleFontAssets) {
        final file = File('${dir.path}/${asset.split('/').last}');
        if (await file.exists()) continue;
        final data = await rootBundle.load(asset);
        await file.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
      }
      await setProperty('sub-fonts-dir', dir.path);
      await setProperty('osd-fonts-dir', dir.path);
      // Used until a SubtitleStyle is applied; the style's default is the same family.
      await setProperty('sub-font', const SubtitleStyle().fontFamily);
      await setProperty('osd-font', const SubtitleStyle().fontFamily);
    } catch (e) {
      debugPrint('[MpvPlaybackEngine] Subtitle fonts unavailable: $e');
    }
  }

  Future<void> _configureMpv(EngineConfig config) async {
    if (_player == null) return;
    await _installSubtitleFonts();
    try {
      await setProperty('keep-open', 'yes');
      await setProperty('osc', 'no');
      await setProperty('osd-level', '0');
      await setProperty('input-default-bindings', 'no');
      await setProperty('volume-max', '${config.volumeMax}');
      await setProperty('audio-pitch-correction', 'yes');
      await setProperty('sub-auto', config.subAuto);
      await setProperty('sub-file-paths', config.subFilePaths.join(':'));
      await setProperty('audio-file-auto', config.audioFileAuto);
      await setProperty('demuxer-max-bytes', '${config.demuxerMaxBytes}');
      await setProperty('demuxer-readahead-secs', '${config.demuxerReadaheadSecs}');
      await setProperty('hwdec', config.hwdec);
    } catch (e) {
      debugPrint('[MpvPlaybackEngine] Note: mpv initial options config: $e');
    }
  }

  void _wireSubscriptions() {
    if (_player == null) return;

    _subscriptions.add(_player!.stream.playing.listen((playing) {
      _playing = playing;
      if (playing) _completed = false;
      _emitTransportStatus();
    }));

    _subscriptions.add(_player!.stream.buffering.listen((buffering) {
      _buffering = buffering;
      _emitTransportStatus();
    }));

    _subscriptions.add(_player!.stream.completed.listen((completed) {
      _completed = completed;
      _emitTransportStatus();
    }));

    _subscriptions.add(_player!.stream.position.listen((pos) {
      _countAbLoop(_currentSnapshot.position, pos);
      _emitSnapshot(_currentSnapshot = _cloneWith(position: pos));
    }));

    _subscriptions.add(_player!.stream.duration.listen((dur) {
      _emitSnapshot(_currentSnapshot = _cloneWith(duration: dur));
    }));

    _subscriptions.add(_player!.stream.buffer.listen((buf) {
      _emitSnapshot(_currentSnapshot = _cloneWith(cacheEnd: buf));
    }));

    _subscriptions.add(_player!.stream.volume.listen((vol) {
      _emitSnapshot(_currentSnapshot = _cloneWith(volume: vol));
    }));

    _subscriptions.add(_player!.stream.rate.listen((rate) {
      _emitSnapshot(_currentSnapshot = _cloneWith(speed: rate));
    }));

    _subscriptions.add(_player!.stream.tracks.listen((tracks) {
      _mapTracks(tracks);
    }));

    _subscriptions.add(_player!.stream.track.listen((track) {
      _updateActiveTracks(track);
    }));

    _subscriptions.add(_player!.stream.error.listen((err) {
      debugPrint('[MpvPlaybackEngine] Player error: $err');
      _errorController.add(classifyMpvError(err));
    }));
  }

  void _emitTransportStatus() {
    _emitSnapshot(_currentSnapshot = _cloneWith(
      status: mpvTransportStatus(playing: _playing, buffering: _buffering, completed: _completed),
    ));
  }

  /// media_kit only reports `completed` while its play state is unlocked, so EOF reached after a
  /// pause-and-seek would otherwise go unnoticed.
  void _syncEndOfFile(bool eofReached) {
    final status = _currentSnapshot.status;
    if (eofReached == _completed || status == PlaybackStatus.loading || status == PlaybackStatus.idle) return;
    if (eofReached && _playing) return;
    _completed = eofReached;
    _emitTransportStatus();
  }

  /// mpv loops natively via ab-loop-a/b, but only clips at B when playback was before B once B
  /// was set; anything that still runs well past B is sent back here. Also counts the loops.
  void _countAbLoop(Duration previous, Duration pos) {
    final loop = _currentSnapshot.abLoop;
    final b = loop?.b;
    if (loop == null || b == null) return;
    if (pos >= b + const Duration(milliseconds: 500)) {
      seek(loop.a, mode: SeekMode.exact);
      return;
    }
    if (previous >= b - const Duration(milliseconds: 500) && pos < previous && pos <= loop.a + const Duration(seconds: 1)) {
      _currentSnapshot = _cloneWith(abLoop: loop.copyWith(count: loop.count + 1));
    }
  }

  void _mapTracks(mk.Tracks mkTracks) {
    final videoTracks = mkTracks.video
        .where((t) => _isRealTrackId(t.id))
        .map((t) => MediaTrack(
              id: t.id,
              type: TrackType.video,
              title: t.title,
              language: t.language,
              codec: t.codec,
              width: t.w,
              height: t.h,
              fps: t.fps,
              bitrate: t.bitrate,
            ))
        .toList();

    final audioTracks = mkTracks.audio
        .where((t) => _isRealTrackId(t.id))
        .map((t) => MediaTrack(
              id: t.id,
              type: TrackType.audio,
              title: t.title,
              language: t.language,
              codec: t.codec,
              channels: int.tryParse(t.channels?.toString() ?? ''),
              bitrate: t.bitrate,
            ))
        .toList();

    final subtitleTracks = mkTracks.subtitle
        .where((t) => _isRealTrackId(t.id))
        .map((t) => MediaTrack(
              id: t.id,
              type: TrackType.subtitle,
              title: t.title,
              language: t.language,
              codec: t.codec,
            ))
        .toList();

    final trackSelection = _currentSnapshot.tracks.copyWith(
      videoTracks: videoTracks,
      audioTracks: audioTracks,
      subtitleTracks: subtitleTracks,
    );

    _emitSnapshot(_currentSnapshot = _cloneWith(tracks: trackSelection));
  }

  // media_kit lists mpv's 'auto' and 'no' pseudo-tracks alongside the real ones.
  static bool _isRealTrackId(String id) => id != 'auto' && id != 'no';

  void _updateActiveTracks(mk.Track currentTrack) {
    final sel = _currentSnapshot.tracks.copyWith(
      selectedVideoTrackId: currentTrack.video.id,
      selectedAudioTrackId: currentTrack.audio.id,
      selectedSubtitleTrackId: currentTrack.subtitle.id,
    );
    _emitSnapshot(_currentSnapshot = _cloneWith(tracks: sel));
  }

  void _startStatsPolling() {
    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(const Duration(milliseconds: 250), (_) async {
      if (_player == null || _isDisposed) return;
      try {
        final fps = await getProperty<double>('estimated-vf-fps') ?? 0.0;
        final dropped = await getProperty<int>('frame-drop-count') ?? 0;
        final voDelayed = await getProperty<int>('vo-delayed-frame-count') ?? 0;
        final vBitrate = await getProperty<double>('video-bitrate') ?? 0.0;
        final aBitrate = await getProperty<double>('audio-bitrate') ?? 0.0;
        final avDesync = await getProperty<double>('avsync') ?? 0.0;
        final hwdecCur = await getProperty<String>('hwdec-current');
        final vCodec = await getProperty<String>('video-codec');
        final aCodec = await getProperty<String>('audio-codec');
        final vWidth = await getProperty<int>('video-params/w');
        final vHeight = await getProperty<int>('video-params/h');
        final colormatrix = await getProperty<String>('video-params/colormatrix');
        final primaries = await getProperty<String>('video-params/primaries');
        final sampleRate = await getProperty<int>('audio-params/samplerate');
        final audioChannels = await getProperty<String>('audio-params/channels');
        final eof = await getProperty<String>('eof-reached');
        if (eof != null && !_isDisposed) _syncEndOfFile(eof == 'yes');

        final stats = DiagnosticsStats(
          videoCodec: vCodec,
          audioCodec: aCodec,
          resolution: vWidth != null && vHeight != null ? '${vWidth}x$vHeight' : null,
          colorSpace: colormatrix,
          primaries: primaries,
          hwdec: hwdecCur,
          fps: fps,
          droppedFrames: dropped,
          voDelayedFrames: voDelayed,
          avDesync: avDesync,
          videoBitrate: vBitrate / 1000.0,
          audioBitrate: aBitrate / 1000.0,
          audioChannels: audioChannels,
          audioSampleRate: sampleRate,
        );

        _emitSnapshot(_currentSnapshot = _cloneWith(
          hwdecCurrent: hwdecCur,
          stats: stats,
        ));
      } catch (_) {}
    });
  }

  void _emitSnapshot(PlayerSnapshot s) {
    if (!_snapshotController.isClosed) {
      _snapshotController.add(s);
    }
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
    String? hwdecCurrent,
    DiagnosticsStats? stats,
    PlayerError? error,
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
      hwdecCurrent: hwdecCurrent ?? _currentSnapshot.hwdecCurrent,
      stats: stats ?? _currentSnapshot.stats,
      error: error ?? _currentSnapshot.error,
    );
  }

  @override
  Future<void> open(MediaSource source, {Duration? startAt}) async {
    if (_player == null) return;
    _completed = false;
    final hadAbLoop = _currentSnapshot.abLoop != null;
    // Position and duration belong to the previous file until the new one reports its own.
    _emitSnapshot(_currentSnapshot = _cloneWith(
      status: PlaybackStatus.loading,
      position: Duration.zero,
      duration: Duration.zero,
      cacheEnd: Duration.zero,
      abLoop: null,
    ));
    if (hadAbLoop) {
      await setProperty('ab-loop-a', 'no');
      await setProperty('ab-loop-b', 'no');
    }

    final mkMedia = mk.Media(
      source.uri,
      httpHeaders: source.httpHeaders,
      start: startAt ?? source.startAt,
    );

    try {
      await _player!.open(mkMedia, play: true);
    } catch (e) {
      _errorController.add(GenericPlayerError('Failed to open source: $e', technicalDetails: '$e'));
    }
  }

  @override
  Future<void> stop() async {
    await _player?.stop();
    _emitSnapshot(_currentSnapshot = _cloneWith(status: PlaybackStatus.idle));
  }

  @override
  Future<void> play() async => await _player?.play();

  @override
  Future<void> pause() async => await _player?.pause();

  @override
  Future<void> playOrPause() async => await _player?.playOrPause();

  @override
  Future<void> seek(Duration position, {SeekMode mode = SeekMode.keyframe}) async {
    if (_player == null) return;
    if (mode == SeekMode.exact) {
      await command(['seek', '${position.inMilliseconds / 1000.0}', 'absolute+exact']);
    } else {
      await _player!.seek(position);
    }
  }

  @override
  Future<void> seekBy(Duration delta) async {
    final current = _currentSnapshot.position;
    final target = current + delta;
    await seek(target < Duration.zero ? Duration.zero : target);
  }

  @override
  Future<void> frameStep(int direction) async {
    if (direction > 0) {
      await command(['frame-step']);
    } else {
      await command(['frame-back-step']);
    }
  }

  @override
  Future<void> setVolume(double percent) async {
    final clamped = percent.clamp(0.0, 300.0);
    await _player?.setVolume(clamped);
    _emitSnapshot(_currentSnapshot = _cloneWith(volume: clamped));
  }

  @override
  Future<void> setMuted(bool muted) async {
    await setProperty('mute', muted ? 'yes' : 'no');
    _emitSnapshot(_currentSnapshot = _cloneWith(muted: muted));
  }

  @override
  Future<void> setAudioDelay(Duration delay) async {
    final sec = delay.inMicroseconds / 1000000.0;
    await setProperty('audio-delay', '$sec');
    _emitSnapshot(_currentSnapshot = _cloneWith(audioDelay: delay));
  }

  @override
  Future<void> setAudioTrack(String? id) async {
    if (_player == null) return;
    if (id == null || id == 'auto') {
      await _player!.setAudioTrack(mk.AudioTrack.auto());
    } else if (id == 'no') {
      await _player!.setAudioTrack(mk.AudioTrack.no());
    } else {
      final track = _player!.state.tracks.audio.firstWhere(
        (t) => t.id == id,
        orElse: () => mk.AudioTrack.auto(),
      );
      await _player!.setAudioTrack(track);
    }
  }

  @override
  Future<void> setAudioFilters(AudioFilter filter) async {
    final afList = <String>[];

    // Equalizer: ffmpeg superequalizer
    final gains = filter.equalizerBands.map((b) => b.gain.toStringAsFixed(1)).join(':');
    afList.add('lavfi=[superequalizer=$gains]');

    // DRC / Night mode
    if (filter.nightModeDrc) {
      afList.add('lavfi=[dynaudnorm]');
    }

    // Loudness Normalization
    if (filter.loudnessNormalization) {
      afList.add('lavfi=[loudnorm=I=-16]');
    }

    // Channel downmix
    if (filter.channelDownmix == 'stereo') {
      await setProperty('audio-channels', 'stereo');
    } else if (filter.channelDownmix == 'mono') {
      await setProperty('audio-channels', 'mono');
    } else if (filter.channelDownmix == '5.1') {
      await setProperty('audio-channels', '5.1');
    } else {
      await setProperty('audio-channels', 'auto');
    }

    await setProperty('af', afList.join(','));
    _emitSnapshot(_currentSnapshot = _cloneWith(audioFilter: filter));
  }

  @override
  Future<void> setSpeed(double speed) async {
    final clamped = speed.clamp(0.0625, 16.0);
    await _player?.setRate(clamped);
    _emitSnapshot(_currentSnapshot = _cloneWith(speed: clamped));
  }

  @override
  Future<void> setVideoTrack(String? id) async {
    if (_player == null) return;
    if (id == null || id == 'auto') {
      await _player!.setVideoTrack(mk.VideoTrack.auto());
    } else if (id == 'no') {
      await _player!.setVideoTrack(mk.VideoTrack.no());
    } else {
      final track = _player!.state.tracks.video.firstWhere(
        (t) => t.id == id,
        orElse: () => mk.VideoTrack.auto(),
      );
      await _player!.setVideoTrack(track);
    }
  }

  @override
  Future<void> setVideoAdjust(VideoAdjust adjust) async {
    await setProperty('brightness', '${adjust.brightness.round()}');
    await setProperty('contrast', '${adjust.contrast.round()}');
    await setProperty('saturation', '${adjust.saturation.round()}');
    await setProperty('gamma', '${adjust.gamma.round()}');
    await setProperty('hue', '${adjust.hue.round()}');
    _emitSnapshot(_currentSnapshot = _cloneWith(adjust: adjust));
  }

  @override
  Future<void> setVideoTransform(VideoTransform t) async {
    await setProperty('video-zoom', '${t.zoom - 1.0}');
    await setProperty('video-pan-x', '${t.panX}');
    await setProperty('video-pan-y', '${t.panY}');
    await setProperty('video-rotate', '${t.rotation}');
    if (t.aspectOverride != null) {
      await setProperty('video-aspect-override', t.aspectOverride!);
    } else {
      await setProperty('video-aspect-override', '-1');
    }
    _emitSnapshot(_currentSnapshot = _cloneWith(transform: t));
  }

  @override
  Future<void> setDeinterlace(bool on) async {
    await setProperty('deinterlace', on ? 'yes' : 'no');
  }

  @override
  Future<void> setHwdec(HwdecMode mode) async {
    await setProperty('hwdec', mode.mpvValue);
  }

  @override
  Future<void> setSubtitleTrack(String? id) async {
    if (_player == null) return;
    if (id == null || id == 'no') {
      await _player!.setSubtitleTrack(mk.SubtitleTrack.no());
    } else if (id == 'auto') {
      await _player!.setSubtitleTrack(mk.SubtitleTrack.auto());
    } else {
      final track = _player!.state.tracks.subtitle.firstWhere(
        (t) => t.id == id,
        orElse: () => mk.SubtitleTrack.auto(),
      );
      await _player!.setSubtitleTrack(track);
    }
  }

  @override
  Future<void> addSubtitleFile(String path, {bool select = true}) async {
    if (_player == null) return;
    final flag = select ? 'select' : 'auto';
    await command(['sub-add', path, flag]);
  }

  @override
  Future<void> setSubtitleDelay(Duration delay) async {
    final sec = delay.inMicroseconds / 1000000.0;
    await setProperty('sub-delay', '$sec');
    _emitSnapshot(_currentSnapshot = _cloneWith(subtitleDelay: delay));
  }

  @override
  Future<void> setSubtitleStyle(SubtitleStyle style) async {
    await setProperty('sub-font', style.fontFamily);
    await setProperty('sub-font-size', '${style.fontSize.round()}');
    await setProperty('sub-border-size', '${style.borderSize}');
    await setProperty('sub-pos', '${style.verticalPosition}');
    await setProperty('sub-scale', '${style.scale}');
    await setProperty('sub-ass-override', style.assOverrideMode);
    _emitSnapshot(_currentSnapshot = _cloneWith(subtitleStyle: style));
  }

  @override
  Future<void> setSecondarySubtitleTrack(String? id) async {
    if (id == null || id == 'no') {
      await setProperty('secondary-sid', 'no');
    } else {
      await setProperty('secondary-sid', id);
    }
  }

  @override
  Future<void> setAbLoop(Duration? a, Duration? b) async {
    if (a == null) {
      await setProperty('ab-loop-a', 'no');
      await setProperty('ab-loop-b', 'no');
      _emitSnapshot(_currentSnapshot = _cloneWith(abLoop: null));
    } else {
      await setProperty('ab-loop-a', '${a.inMilliseconds / 1000.0}');
      await setProperty('ab-loop-b', b == null ? 'no' : '${b.inMilliseconds / 1000.0}');
      _emitSnapshot(_currentSnapshot = _cloneWith(abLoop: AbLoop(a: a, b: b)));
      // B is usually set at the playhead, which mpv treats as already past it; start the loop now.
      if (b != null && _currentSnapshot.position >= b - const Duration(milliseconds: 250)) {
        await seek(a, mode: SeekMode.exact);
      }
    }
  }

  @override
  Future<Uint8List?> screenshot({bool includeSubtitles = true}) async {
    if (_player == null) return null;
    final tempDir = Directory.systemTemp;
    final file = File('${tempDir.path}/danaview_snap_${DateTime.now().millisecondsSinceEpoch}.png');
    final flag = includeSubtitles ? 'subtitles' : 'video';
    await command(['screenshot-to-file', file.path, flag]);
    if (await file.exists()) {
      final bytes = await file.readAsBytes();
      await file.delete();
      return bytes;
    }
    return null;
  }

  @override
  Future<T?> getProperty<T>(String name) async {
    if (_player == null) return null;
    try {
      final dynamic platform = _player!.platform;
      if (platform != null) {
        final val = await platform.getProperty(name);
        // media_kit's native player returns every property as a string.
        if (val is String) return _parseProperty<T>(val);
        if (val is T) return val;
        if (T == double && val is num) return val.toDouble() as T;
        if (T == int && val is num) return val.toInt() as T;
        if (T == String) return val?.toString() as T?;
        return val as T?;
      }
    } catch (_) {}
    return null;
  }

  static T? _parseProperty<T>(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return null;
    final Object? parsed = switch (T) {
      const (double) => double.tryParse(value),
      const (int) => int.tryParse(value) ?? double.tryParse(value)?.toInt(),
      const (bool) => switch (value) { 'yes' || 'true' => true, 'no' || 'false' => false, _ => null },
      _ => value,
    };
    return parsed is T ? parsed : null;
  }

  @override
  Future<void> setProperty(String name, Object? value) async {
    if (_player == null) return;
    try {
      final dynamic platform = _player!.platform;
      if (platform != null) {
        await platform.setProperty(name, value?.toString() ?? '');
      }
    } catch (_) {}
  }

  @override
  Future<void> command(List<String> args) async {
    if (_player == null) return;
    try {
      final dynamic platform = _player!.platform;
      if (platform != null) {
        await platform.command(args);
      }
    } catch (_) {}
  }

  @override
  Future<void> dispose() async {
    _isDisposed = true;
    _statsTimer?.cancel();
    for (final s in _subscriptions) {
      await s.cancel();
    }
    _subscriptions.clear();
    await _player?.dispose();
    await _snapshotController.close();
    await _errorController.close();
    _textureIdNotifier.dispose();
  }
}
