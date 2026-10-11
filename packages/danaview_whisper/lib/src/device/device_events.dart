// OWNER: AI-06
//
// Events the native plugin pushes on the device event channel (ai.md §4.8): thermal state, memory
// warnings, low-power mode, app lifecycle and iOS background-task expiry. Parsed defensively:
// an unknown type or a malformed payload yields null and the stream drops it.

import 'package:meta/meta.dart';

import 'device_profile.dart';

/// App visibility as the native side reports it (UIApplication / Activity callbacks).
enum WhisperAppState {
  /// The app left the foreground (iOS `didEnterBackground`, Android last Activity stopped).
  background,

  /// The app is visible again.
  foreground;

  /// The state named [name], or null.
  static WhisperAppState? tryParse(Object? name) {
    if (name is! String) return null;
    for (final s in values) {
      if (s.name == name) return s;
    }
    return null;
  }
}

/// A device event.
@immutable
sealed class WhisperDeviceEvent {
  const WhisperDeviceEvent();

  /// Parses one event map (`{type: 'thermal', value: 'serious'}`), or null when it is malformed
  /// or of an unknown type.
  static WhisperDeviceEvent? tryParse(Object? raw) {
    if (raw is! Map<Object?, Object?>) return null;
    final type = raw['type'];
    final value = raw['value'];
    switch (type) {
      case 'thermal':
        final level = ThermalLevel.tryParse(value);
        return level == null ? null : ThermalChanged(level);
      case 'memoryWarning':
        return const MemoryWarning();
      case 'lowPower':
        return value is bool ? LowPowerChanged(value) : null;
      case 'lifecycle':
        final state = WhisperAppState.tryParse(value);
        return state == null ? null : AppStateChanged(state);
      case 'backgroundTaskExpiring':
        return value is int && value > 0 ? BackgroundTaskExpiring(value) : null;
    }
    return null;
  }
}

/// The thermal state changed.
final class ThermalChanged extends WhisperDeviceEvent {
  /// Creates the event.
  const ThermalChanged(this.level);

  /// The new level.
  final ThermalLevel level;

  @override
  bool operator ==(Object other) => other is ThermalChanged && other.level == level;

  @override
  int get hashCode => level.hashCode;
}

/// The system is low on memory (iOS memory warning; Android `onTrimMemory` at running-low or worse).
final class MemoryWarning extends WhisperDeviceEvent {
  /// Creates the event.
  const MemoryWarning();

  @override
  bool operator ==(Object other) => other is MemoryWarning;

  @override
  int get hashCode => (MemoryWarning).hashCode;
}

/// Low Power Mode / Battery Saver changed.
final class LowPowerChanged extends WhisperDeviceEvent {
  /// Creates the event.
  const LowPowerChanged(this.enabled);

  /// Whether it is on.
  final bool enabled;

  @override
  bool operator ==(Object other) => other is LowPowerChanged && other.enabled == enabled;

  @override
  int get hashCode => enabled.hashCode;
}

/// The app moved to the background or the foreground.
final class AppStateChanged extends WhisperDeviceEvent {
  /// Creates the event.
  const AppStateChanged(this.state);

  /// The new state.
  final WhisperAppState state;

  @override
  bool operator ==(Object other) => other is AppStateChanged && other.state == state;

  @override
  int get hashCode => state.hashCode;
}

/// iOS is about to end background task [id]: pause with the partial file kept.
final class BackgroundTaskExpiring extends WhisperDeviceEvent {
  /// Creates the event.
  const BackgroundTaskExpiring(this.id);

  /// Id returned by `beginBackgroundTask`.
  final int id;

  @override
  bool operator ==(Object other) => other is BackgroundTaskExpiring && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
