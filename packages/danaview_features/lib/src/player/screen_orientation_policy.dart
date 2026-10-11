import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:danaview_platform/danaview_platform.dart';

/// What a screen wants from the system while it is the topmost orientation owner.
enum OrientationMode {
  /// The app default: phones upright, tablets and desktops free.
  appDefault,

  /// The video player: on iPhone it follows how the phone is held, one orientation at a time;
  /// elsewhere every orientation is allowed. The rotate button pins an orientation
  /// ([ScreenOrientationPolicy.toggle]).
  followDevice,

  /// The editor: portrait and landscape follow the device on phones (tablets are already free).
  /// Handled like [followDevice] on iPhone, because handing iOS several orientations at once
  /// makes it flash through the last landscape before settling.
  free,
}

/// Owner stack for the preferred device orientations.
///
/// Screens that care call [enter] with themselves as owner and [release] when they go away. The
/// top owner's [OrientationMode] is applied; releasing an owner anywhere in the stack removes it,
/// and only re-applies when it was the top. When the stack empties the app default comes back.
/// This is what lets the editor open over the player and give the orientation back correctly.
///
/// Desktop and web are a no-op: the stack is kept but nothing reaches the platform.
abstract final class ScreenOrientationPolicy {
  static final List<_OrientationEntry> _stack = [];

  static StreamSubscription<DeviceOrientation>? _deviceSub;

  /// The last orientation the phone reported; only meaningful while [_deviceSub] is active.
  static DeviceOrientation _held = DeviceOrientation.portraitUp;
  static bool _heldKnown = false;

  /// The owner whose mode is applied, or null when the app default is in force.
  static Object? get topOwner => _stack.isEmpty ? null : _stack.last.owner;

  /// The mode of [topOwner], or [OrientationMode.appDefault] when nobody owns the orientation.
  static OrientationMode get topMode => _stack.isEmpty ? OrientationMode.appDefault : _stack.last.mode;

  /// Number of owners currently stacked.
  static int get depth => _stack.length;

  static bool get _supported =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android);

  static bool get _isPhone {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    return (view.physicalSize / view.devicePixelRatio).shortestSide < 600;
  }

  /// On iPhone the player and the editor follow how the phone is held, one orientation at a time.
  static bool get _followsDevice => defaultTargetPlatform == TargetPlatform.iOS && _isPhone;

  static bool _isLandscape(DeviceOrientation o) =>
      o == DeviceOrientation.landscapeLeft || o == DeviceOrientation.landscapeRight;

  /// Phones keep the library upright; tablets rotate freely.
  static Future<void> applyAppDefault() {
    if (!_supported) return Future<void>.value();
    return SystemChrome.setPreferredOrientations(_isPhone ? const [DeviceOrientation.portraitUp] : const []);
  }

  /// Makes [owner] the top of the stack with [mode] and applies it. An owner that is already
  /// stacked is moved to the top with a fresh state.
  static Future<void> enter(Object owner, OrientationMode mode) {
    _stack.removeWhere((e) => identical(e.owner, owner));
    _stack.add(_OrientationEntry(owner, mode));
    return _applyTop();
  }

  /// Removes [owner] wherever it is in the stack. Re-applies the new top (or the app default)
  /// only when [owner] was the top; does nothing when it is not stacked, so a screen that is
  /// still closing can never undo the orientation of one opened after it.
  static Future<void> release(Object owner) {
    final index = _stack.indexWhere((e) => identical(e.owner, owner));
    if (index < 0) return Future<void>.value();
    final wasTop = index == _stack.length - 1;
    _stack.removeAt(index);
    return wasTop ? _applyTop() : Future<void>.value();
  }

  /// The rotate button: flips [owner] between portrait and landscape and holds it there regardless
  /// of how the device is held, until the phone is turned to match (iPhone). Applied at once when
  /// [owner] is the top; otherwise remembered for when it is again.
  static Future<void> toggle(Object owner, Orientation current) {
    final index = _stack.indexWhere((e) => identical(e.owner, owner));
    if (index < 0) return Future<void>.value();
    final entry = _stack[index];
    entry.forced = (entry.forced ?? current) == Orientation.landscape ? Orientation.portrait : Orientation.landscape;
    if (index != _stack.length - 1 || !_supported || entry.mode == OrientationMode.appDefault) {
      return Future<void>.value();
    }
    return _applyForced(entry.forced!);
  }

  /// Drops every owner and the device subscription without touching the platform. Tests only.
  @visibleForTesting
  static void resetForTesting() {
    _stack.clear();
    _stopFollowing();
  }

  static Future<void> _applyTop() {
    if (!_supported) return Future<void>.value();
    if (_stack.isEmpty || _stack.last.mode == OrientationMode.appDefault) {
      _stopFollowing();
      return applyAppDefault();
    }
    final entry = _stack.last;
    final forced = entry.forced;
    if (_followsDevice) {
      // Stays as it is until the stream reports the phone is held otherwise.
      _deviceSub ??= PlatformBridge.deviceOrientations.listen(_onDeviceOrientation, onError: (Object _) {});
      if (forced != null) return _applyForced(forced);
      return _heldKnown ? SystemChrome.setPreferredOrientations([_held]) : Future<void>.value();
    }
    _stopFollowing();
    if (forced != null) return _applyForced(forced);
    return SystemChrome.setPreferredOrientations(const []);
  }

  static Future<void> _applyForced(Orientation forced) {
    if (forced == Orientation.portrait) {
      return SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    }
    return SystemChrome.setPreferredOrientations(
      _followsDevice
          ? [_isLandscape(_held) ? _held : DeviceOrientation.landscapeLeft]
          : const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight],
    );
  }

  static void _onDeviceOrientation(DeviceOrientation held) {
    // iPhones never show the interface upside down.
    if (held == DeviceOrientation.portraitDown || _stack.isEmpty) return;
    final entry = _stack.last;
    if (entry.mode == OrientationMode.appDefault) return;
    _held = held;
    _heldKnown = true;
    final forced = entry.forced;
    if (forced != null) {
      // The rotate button's choice holds until the phone is turned to match it.
      if (_isLandscape(held) != (forced == Orientation.landscape)) return;
      entry.forced = null;
    }
    SystemChrome.setPreferredOrientations([held]);
  }

  static void _stopFollowing() {
    _deviceSub?.cancel();
    _deviceSub = null;
    _heldKnown = false;
    _held = DeviceOrientation.portraitUp;
  }
}

class _OrientationEntry {
  _OrientationEntry(this.owner, this.mode);

  final Object owner;
  final OrientationMode mode;

  /// Orientation pinned by the rotate button; null while following the device.
  Orientation? forced;
}
