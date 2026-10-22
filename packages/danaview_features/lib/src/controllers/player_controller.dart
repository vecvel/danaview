import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_data/danaview_data.dart';
import 'package:danaview_domain/danaview_domain.dart';
import 'package:danaview_engine/danaview_engine.dart';
import 'package:danaview_platform/danaview_platform.dart';
import 'providers.dart';

class PlayerController extends StateNotifier<PlayerState> {
  final PlaybackEngine _engine;
  final SessionRepository _sessionRepo;
  final LibraryRepository _libraryRepo;
  final Ref _ref;

  StreamSubscription<PlayerSnapshot>? _snapshotSub;
  StreamSubscription<PlayerError>? _errorSub;
  Timer? _resumeSaveTimer;
  HwdecMode _hwdecMode = HwdecMode.autoSafe;
  bool _awaitingHistoryDuration = false;
  bool _reportedNoAudio = false;
  bool _playedSinceOpen = false;

  /// Bumped by every [openMedia]; continuations of a superseded open bail out.
  int _openToken = 0;

  /// Snapshots queued before the engine reports the new file as loading still describe the
  /// previous one.
  bool _sawLoadSinceOpen = false;

  /// Whether position and duration describe [PlayerState.currentMediaRef] yet.
  bool _mediaLoaded = false;

  /// FIX M-23 (QA-02): the position held across an unexplained reset to 0 while paused.
  ///
  /// While the player is paused by a command, its position only moves through this controller's
  /// own commands (seek, frame step, open, stop, play). mpv can still report `time-pos` 0 after a
  /// landed seek, for example when media_kit's `open` rewrites `playlist-pos` and the file restarts
  /// late on a slow cold first launch. Such a report must not become the Edit handoff position,
  /// so [currentPosition] keeps the last real position until the engine reports a non-zero one.
  Duration? _heldPosition;

  /// Whether the last command can legitimately take the position to 0 (see [_heldPosition]).
  bool _zeroExplained = true;

  /// Whether [pause] was asked for since the last command that may start playback.
  bool _pauseRequested = false;

  /// Positions within this of 0 count as "at the start" for [_zeroExplained].
  static const Duration _nearStart = Duration(milliseconds: 50);

  HwdecMode get hwdecMode => _hwdecMode;

  /// The player's real current position: [PlayerState.position], except across an unexplained
  /// reset to 0 while paused (FIX M-23), when it is the position before that reset. The editor
  /// handoff and resume points use this.
  Duration get currentPosition => _heldPosition ?? state.position;

  PlayerController(this._engine, this._sessionRepo, this._libraryRepo, this._ref)
      : super(const PlayerState()) {
    _init();
  }

  void _init() {
    _snapshotSub = _engine.snapshots.listen(_handleSnapshot);
    _errorSub = _engine.errors.listen(_handleError);

    // Initial global settings
    final vol = _sessionRepo.getGlobalVolume();
    final speed = _sessionRepo.getGlobalSpeed();
    _engine.setVolume(vol);
    _engine.setSpeed(speed);

    // Periodic resume save every 5s
    _resumeSaveTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _saveCurrentResume();
    });
  }

  void _handleSnapshot(PlayerSnapshot s) {
    if (_openToken > 0 && !_sawLoadSinceOpen) {
      if (s.status != PlaybackStatus.loading) return;
      _sawLoadSinceOpen = true;
    }
    if (!_mediaLoaded && s.status != PlaybackStatus.loading && s.duration > Duration.zero) {
      _mediaLoaded = true;
    }
    if (s.status == PlaybackStatus.playing) _playedSinceOpen = true;
    _trackHeldPosition(s);
    final wasEnded = state.status == PlaybackStatus.ended;
    final nextStatus = state.status == PlaybackStatus.error && state.error != null
        ? PlaybackStatus.error
        : s.status;

    // Handle sleep inhibitor
    if (nextStatus == PlaybackStatus.playing && state.status != PlaybackStatus.playing) {
      PlatformBridge.setSleepInhibited(true);
    } else if (nextStatus != PlaybackStatus.playing && state.status == PlaybackStatus.playing) {
      PlatformBridge.setSleepInhibited(false);
    }

    state = state.copyWith(
      status: nextStatus,
      position: s.position,
      duration: s.duration,
      cacheEnd: s.cacheEnd,
      speed: s.speed,
      volume: s.volume,
      muted: s.muted,
      tracks: s.tracks,
      chapters: s.chapters,
      adjust: s.adjust,
      transform: s.transform,
      subtitleStyle: s.subtitleStyle,
      audioFilter: s.audioFilter,
      subtitleDelay: s.subtitleDelay,
      audioDelay: s.audioDelay,
      abLoop: s.abLoop,
      stats: s.stats,
    );
    _syncHistoryDuration();

    // Position updates keep arriving at EOF; advance the queue once.
    if (s.status == PlaybackStatus.ended && !wasEnded) {
      _saveCurrentResume();
      _ref.read(queueControllerProvider.notifier).onPlaybackEnded();
    }
  }

  /// FIX M-23: see [_heldPosition].
  void _trackHeldPosition(PlayerSnapshot s) {
    final steady = _mediaLoaded &&
        _pauseRequested &&
        s.status != PlaybackStatus.playing &&
        s.status != PlaybackStatus.loading &&
        s.status != PlaybackStatus.idle &&
        s.status != PlaybackStatus.ended;
    if (!steady) {
      _heldPosition = null;
      return;
    }
    if (s.position > Duration.zero) {
      _heldPosition = null;
      _zeroExplained = false;
      return;
    }
    final before = currentPosition;
    if (_zeroExplained || before <= Duration.zero || _heldPosition != null) return;
    _heldPosition = before;
    if (kDebugMode) {
      debugPrint('[PlayerController] Unexplained position reset to 0 while paused; holding ${before.inMicroseconds} us');
    }
  }

  /// A command that may move the position anywhere, 0 included.
  void _positionMayReset() {
    _zeroExplained = true;
    _heldPosition = null;
  }

  /// A seek towards [target]: only a target near the start explains a later 0.
  void _seekingTo(Duration target) {
    _heldPosition = null;
    _zeroExplained = target <= _nearStart;
  }

  void _handleError(PlayerError err) {
    if (err is PlaybackWarning) return;
    // Unclassified mpv errors after playback started (e.g. an undecodable extra track) don't stop the video.
    if (err is GenericPlayerError && _playedSinceOpen) {
      debugPrint('[PlayerController] Ignoring non-fatal error during playback: ${err.message}');
      return;
    }
    if (err is AudioOutputUnavailable) {
      if (_reportedNoAudio) return;
      _reportedNoAudio = true;
    }
    final isFatal = err is! AudioOutputUnavailable && err is! DecoderInitFailed;
    if (isFatal) {
      PlatformBridge.setSleepInhibited(false);
      _engine.pause();
    }
    state = state.copyWith(
      error: err,
      status: isFatal ? PlaybackStatus.error : state.status,
    );
  }

  void _syncHistoryDuration() {
    final media = state.currentMediaRef;
    final duration = state.duration;
    if (!_awaitingHistoryDuration || !_mediaLoaded || media == null || duration <= Duration.zero) return;
    _awaitingHistoryDuration = false;
    _libraryRepo.updateHistoryDuration(media.pathOrUri, duration);
  }

  void _saveCurrentResume() {
    final ref = state.currentMediaRef;
    if (ref != null && _mediaLoaded && state.duration > Duration.zero) {
      _sessionRepo.saveResumePosition(ref.id, currentPosition, state.duration);
    }
  }

  /// Saves the current resume point now, e.g. before the app is backgrounded.
  void saveResumePoint() => _saveCurrentResume();

  Future<void> openMedia(MediaRef media, {Duration? startAt}) async {
    final token = ++_openToken;
    _saveCurrentResume();
    _positionMayReset();
    _pauseRequested = false;
    _playedSinceOpen = false;
    _sawLoadSinceOpen = false;
    _mediaLoaded = false;
    _awaitingHistoryDuration = false;

    state = state.copyWith(
      currentMediaRef: media,
      currentSource: media.isRemote
          ? MediaSource.network(media.pathOrUri, title: media.title)
          : MediaSource.file(media.pathOrUri, title: media.title),
      status: PlaybackStatus.loading,
      position: Duration.zero,
      duration: Duration.zero,
      error: null,
    );

    // Check for saved resume position if startAt is null
    final resumePos = startAt ?? _sessionRepo.getResumePosition(media.id, media.duration);

    await _engine.open(
      state.currentSource!,
      startAt: resumePos,
    );
    if (token != _openToken) return;

    // Per-file preferences; defaults too, since mpv keeps the previous file's values.
    await _engine.setSubtitleDelay(_sessionRepo.getSubtitleDelay(media.id));
    await _engine.setAudioDelay(_sessionRepo.getAudioDelay(media.id));
    await _engine.setVideoAdjust(_sessionRepo.getVideoAdjust(media.id));
    if (token != _openToken) return;

    // Sidecar subtitles (file.srt, Subs/file.en.srt) are loaded by mpv's sub-auto.

    await _libraryRepo.recordPlayed(media);
    if (token != _openToken) return;
    _awaitingHistoryDuration = true;
    _syncHistoryDuration();
  }

  Future<void> togglePlay() {
    _pauseRequested = false;
    _positionMayReset();
    if (state.status == PlaybackStatus.error && state.currentMediaRef != null) {
      return openMedia(state.currentMediaRef!);
    }
    return _engine.playOrPause();
  }

  Future<void> play() {
    _pauseRequested = false;
    _positionMayReset();
    if (state.status == PlaybackStatus.error && state.currentMediaRef != null) {
      return openMedia(state.currentMediaRef!);
    }
    return _engine.play();
  }

  Future<void> pause() {
    _pauseRequested = true;
    return _engine.pause();
  }

  Future<void> stop() {
    _positionMayReset();
    return _engine.stop();
  }

  Future<void> stopAndClear() async {
    _openToken++;
    _saveCurrentResume();
    _positionMayReset();
    await _engine.stop();
    PlatformBridge.setSleepInhibited(false);
    state = state.copyWith(
      currentMediaRef: null,
      currentSource: null,
      status: PlaybackStatus.idle,
      position: Duration.zero,
      duration: Duration.zero,
      error: null,
    );
  }

  Future<void> seek(Duration pos, {SeekMode mode = SeekMode.keyframe}) {
    _seekingTo(pos);
    return _engine.seek(pos, mode: mode);
  }

  /// Relative to [currentPosition], so a held position (FIX M-23) is the base, not a stray 0.
  Future<void> seekBy(Duration delta) {
    final target = currentPosition + delta;
    return seek(target < Duration.zero ? Duration.zero : target);
  }

  Future<void> frameStep(int direction) {
    if (direction < 0) {
      _seekingTo(currentPosition - _nearStart);
    } else {
      _seekingTo(currentPosition + _nearStart * 2);
    }
    return _engine.frameStep(direction);
  }

  Future<void> setVolume(double vol) async {
    await _engine.setVolume(vol);
    await _sessionRepo.saveGlobalVolume(vol);
  }

  Future<void> setVolumeDelta(double delta) async {
    final nextVol = (state.volume + delta).clamp(0.0, 300.0);
    await setVolume(nextVol);
  }

  Future<void> toggleMute() => _engine.setMuted(!state.muted);

  Future<void> setSpeed(double speed) async {
    await _engine.setSpeed(speed);
    await _sessionRepo.saveGlobalSpeed(speed);
  }

  Future<void> setSpeedDelta(double delta) async {
    final nextSpeed = (state.speed + delta).clamp(0.1, 16.0);
    await setSpeed(nextSpeed);
  }

  Future<void> setAudioTrack(String? id) => _engine.setAudioTrack(id);
  Future<void> setVideoTrack(String? id) => _engine.setVideoTrack(id);
  Future<void> setSubtitleTrack(String? id) => _engine.setSubtitleTrack(id);
  Future<void> setSecondarySubtitleTrack(String? id) =>
      _engine.setSecondarySubtitleTrack(id);

  Future<void> setSubtitleDelay(Duration delay) async {
    await _engine.setSubtitleDelay(delay);
    if (state.currentMediaRef != null) {
      await _sessionRepo.saveSubtitleDelay(state.currentMediaRef!.id, delay);
    }
  }

  Future<void> setAudioDelay(Duration delay) async {
    await _engine.setAudioDelay(delay);
    if (state.currentMediaRef != null) {
      await _sessionRepo.saveAudioDelay(state.currentMediaRef!.id, delay);
    }
  }

  Future<void> setVideoAdjust(VideoAdjust adjust) async {
    await _engine.setVideoAdjust(adjust);
    if (state.currentMediaRef != null) {
      await _sessionRepo.saveVideoAdjust(state.currentMediaRef!.id, adjust);
    }
  }

  Future<void> setHwdec(HwdecMode mode) {
    _hwdecMode = mode;
    return _engine.setHwdec(mode);
  }

  Future<void> setVideoTransform(VideoTransform t) => _engine.setVideoTransform(t);
  Future<void> setAudioFilters(AudioFilter filter) => _engine.setAudioFilters(filter);
  Future<void> setSubtitleStyle(SubtitleStyle style) => _engine.setSubtitleStyle(style);
  Future<void> setAbLoop(Duration? a, Duration? b) => _engine.setAbLoop(a, b);

  Future<void> toggleFullscreen() async {
    final nextMode = state.viewMode == ViewMode.fullscreen
        ? ViewMode.windowed
        : ViewMode.fullscreen;
    state = state.copyWith(viewMode: nextMode);
    await PlatformBridge.setFullscreen(nextMode == ViewMode.fullscreen);
  }

  Future<void> exitFullscreen() async {
    if (state.viewMode != ViewMode.fullscreen) return;
    state = state.copyWith(viewMode: ViewMode.windowed);
    await PlatformBridge.setFullscreen(false);
  }

  /// Mirrors a fullscreen change the window made on its own (e.g. through the OS).
  void syncFullscreen(bool fullscreen) {
    if ((state.viewMode == ViewMode.fullscreen) == fullscreen) return;
    state = state.copyWith(viewMode: fullscreen ? ViewMode.fullscreen : ViewMode.windowed);
  }

  Future<void> toggleAlwaysOnTop() async {
    final next = !state.isAlwaysOnTop;
    state = state.copyWith(isAlwaysOnTop: next);
    await PlatformBridge.setAlwaysOnTop(next);
  }

  Future<Uint8List?> captureScreenshot({bool includeSubtitles = true}) =>
      _engine.screenshot(includeSubtitles: includeSubtitles);

  // ---- Editor handoff (ARCH §17.1, ux.md §4.6). `danaview_features` never imports the editor; the
  // app root adapts these calls to the editor launcher's port.

  /// Pauses (and with [PlayerHandoffMode.release] stops the engine) and returns where to come back
  /// to, or null when nothing is open. [position] overrides the current position (the Edit
  /// request's snapshot).
  Future<PlayerResumeToken?> suspendForEditor(PlayerHandoffMode mode, {Duration? position}) async {
    final media = state.currentMediaRef;
    if (media == null) return null;
    final wasPlaying = state.isPlaying;
    final at = position ?? currentPosition;
    await pause();
    _saveCurrentResume();
    final release = mode == PlayerHandoffMode.release;
    if (release) {
      // A superseded open must not resume behind the editor.
      _openToken++;
      await _engine.stop();
      PlatformBridge.setSleepInhibited(false);
    }
    return PlayerResumeToken(media: media, position: at, released: release, wasPlaying: wasPlaying);
  }

  /// Restores the player after the editor closed: the same media, paused at the original position
  /// (a released engine reopens the file there). Playback never starts on its own.
  Future<void> resumeAfterEditor(PlayerResumeToken token) async {
    if (token.released) {
      final current = state.currentMediaRef;
      // The queue moved on (e.g. the item was removed): nothing to restore.
      if (current != null && current.id != token.media.id) return;
      // mpv keeps `pause` across loads, so the reopened file starts paused.
      await pause();
      await openMedia(token.media, startAt: token.position);
      await pause();
      return;
    }
    await pause();
    if (state.currentMediaRef?.id != token.media.id) return;
    final drift = (state.position - token.position).abs();
    if (drift > const Duration(milliseconds: 40)) await seek(token.position, mode: SeekMode.exact);
  }

  @override
  void dispose() {
    _resumeSaveTimer?.cancel();
    _snapshotSub?.cancel();
    _errorSub?.cancel();
    super.dispose();
  }
}

// -------------------------------------------------------------------------------------------------
// Editor handoff (ARCH §17.1, ux.md §4.6)
// -------------------------------------------------------------------------------------------------

/// How the player steps aside while the video editor is open (ux.md §4.6).
enum PlayerHandoffMode {
  /// Pause and keep the engine loaded, so returning is instant.
  pause,

  /// Pause, save the resume point and stop the engine, so the editor's decoders get the hardware
  /// and memory (low-memory devices). The queue keeps the item, so Home still shows it.
  release,
}

/// Where the player was when the editor opened; [PlayerController.resumeAfterEditor] restores it.
@immutable
final class PlayerResumeToken {
  /// Creates a token.
  const PlayerResumeToken({
    required this.media,
    required this.position,
    required this.released,
    this.wasPlaying = false,
  });

  /// The media that was showing.
  final MediaRef media;

  /// The playback position when the editor opened.
  final Duration position;

  /// Whether the engine was stopped ([PlayerHandoffMode.release]).
  final bool released;

  /// Whether it was playing before the handoff (playback is never restarted on return).
  final bool wasPlaying;

  @override
  String toString() => 'PlayerResumeToken(${position.inMilliseconds} ms, released: $released)';
}
