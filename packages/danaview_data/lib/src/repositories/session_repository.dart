import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:danaview_domain/danaview_domain.dart';

class SessionRepository {
  final SharedPreferences _prefs;

  SessionRepository(this._prefs);

  static const _kResumePrefix = 'danaview_resume_';
  static const _kResumeDurationPrefix = 'danaview_duration_';
  static const _kSubtitleDelayPrefix = 'danaview_sub_delay_';
  static const _kAudioDelayPrefix = 'danaview_audio_delay_';
  static const _kVideoAdjustPrefix = 'danaview_video_adjust_';
  static const _kGlobalVolume = 'danaview_global_volume';
  static const _kGlobalSpeed = 'danaview_global_speed';
  static const _kDoubleTapSeek = 'danaview_double_tap_seek_seconds';

  /// Choices for how far a double tap on either side of the video seeks.
  static const List<int> doubleTapSeekOptions = [5, 10, 15, 30];
  static const int defaultDoubleTapSeekSeconds = 10;

  /// Re-keys per-file values whose media id (a local path) [resolve] maps elsewhere, e.g.
  /// after iOS moved the app container. Returns how many values moved.
  Future<int> migrateMediaIds(String Function(String id) resolve) async {
    const prefixes = [_kResumePrefix, _kResumeDurationPrefix, _kSubtitleDelayPrefix, _kAudioDelayPrefix, _kVideoAdjustPrefix];
    var moved = 0;
    for (final key in _prefs.getKeys().toList()) {
      final prefix = prefixes.where(key.startsWith).firstOrNull;
      if (prefix == null) continue;
      final id = key.substring(prefix.length);
      final target = resolve(id);
      if (target == id) continue;
      final value = _prefs.get(key);
      if (!_prefs.containsKey('$prefix$target')) {
        if (value is int) await _prefs.setInt('$prefix$target', value);
        if (value is String) await _prefs.setString('$prefix$target', value);
        if (value is double) await _prefs.setDouble('$prefix$target', value);
      }
      await _prefs.remove(key);
      moved++;
    }
    return moved;
  }

  /// Save playback resume position (and the known duration) for media ID
  Future<void> saveResumePosition(String mediaId, Duration position, Duration duration) async {
    // If within last 15s or 98% completed, clear resume (consider finished)
    if (duration > Duration.zero && (duration - position < const Duration(seconds: 15) || position.inMilliseconds / duration.inMilliseconds > 0.98)) {
      await clearResumePosition(mediaId);
      return;
    }

    // Only save if played at least 5s
    if (position.inSeconds >= 5) {
      await _prefs.setInt('$_kResumePrefix$mediaId', position.inMilliseconds);
      if (duration > Duration.zero) {
        await _prefs.setInt('$_kResumeDurationPrefix$mediaId', duration.inMilliseconds);
      }
    }
  }

  /// Retrieve saved resume position
  Duration? getResumePosition(String mediaId, Duration duration) {
    final ms = _prefs.getInt('$_kResumePrefix$mediaId');
    if (ms == null) return null;
    final pos = Duration(milliseconds: ms);
    if (duration > Duration.zero && pos >= duration) return null;
    return pos;
  }

  /// Saved position plus the duration known at save time (zero if never known), for
  /// "Continue watching" progress. Null when there is nothing to resume.
  ResumeInfo? getResumeInfo(String mediaId) {
    final ms = _prefs.getInt('$_kResumePrefix$mediaId');
    if (ms == null) return null;
    final durationMs = _prefs.getInt('$_kResumeDurationPrefix$mediaId') ?? 0;
    return ResumeInfo(position: Duration(milliseconds: ms), duration: Duration(milliseconds: durationMs));
  }

  Future<void> clearResumePosition(String mediaId) async {
    await _prefs.remove('$_kResumePrefix$mediaId');
    await _prefs.remove('$_kResumeDurationPrefix$mediaId');
  }

  /// Subtitle delay sync per media
  Future<void> saveSubtitleDelay(String mediaId, Duration delay) async {
    await _prefs.setInt('$_kSubtitleDelayPrefix$mediaId', delay.inMilliseconds);
  }

  Duration getSubtitleDelay(String mediaId) {
    final ms = _prefs.getInt('$_kSubtitleDelayPrefix$mediaId');
    return ms != null ? Duration(milliseconds: ms) : Duration.zero;
  }

  /// Audio delay sync per media
  Future<void> saveAudioDelay(String mediaId, Duration delay) async {
    await _prefs.setInt('$_kAudioDelayPrefix$mediaId', delay.inMilliseconds);
  }

  Duration getAudioDelay(String mediaId) {
    final ms = _prefs.getInt('$_kAudioDelayPrefix$mediaId');
    return ms != null ? Duration(milliseconds: ms) : Duration.zero;
  }

  /// Video color adjustments per media
  Future<void> saveVideoAdjust(String mediaId, VideoAdjust adjust) async {
    await _prefs.setString('$_kVideoAdjustPrefix$mediaId', jsonEncode(adjust.toJson()));
  }

  VideoAdjust getVideoAdjust(String mediaId) {
    final raw = _prefs.getString('$_kVideoAdjustPrefix$mediaId');
    if (raw == null) return VideoAdjust.normal;
    try {
      return VideoAdjust.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return VideoAdjust.normal;
    }
  }

  /// Global volume setting
  Future<void> saveGlobalVolume(double volume) async {
    await _prefs.setDouble(_kGlobalVolume, volume);
  }

  double getGlobalVolume() {
    return _prefs.getDouble(_kGlobalVolume) ?? 100.0;
  }

  /// Global playback speed
  Future<void> saveGlobalSpeed(double speed) async {
    await _prefs.setDouble(_kGlobalSpeed, speed);
  }

  double getGlobalSpeed() {
    return _prefs.getDouble(_kGlobalSpeed) ?? 1.0;
  }

  /// Seconds a double tap on the left or right of the video seeks back or forward.
  int getDoubleTapSeekSeconds() {
    final seconds = _prefs.getInt(_kDoubleTapSeek);
    return seconds != null && seconds > 0 ? seconds : defaultDoubleTapSeekSeconds;
  }

  Future<void> saveDoubleTapSeekSeconds(int seconds) async {
    await _prefs.setInt(_kDoubleTapSeek, seconds);
  }
}
