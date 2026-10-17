// OWNER: UX-01
//
// Editor availability (ARCH §3.3, §17.1, D-17, D-31).
//
// * The platform gate is synchronous and platform-only, so the router and the Home header decide
//   without awaiting: supported on iOS/Android when the compile-time `DANAVIEW_EDITOR` define is true,
//   hidden everywhere else. Desktop is always hidden; there is no "coming soon" teaser (D-17).
// * The device gate is asynchronous ([editorDeviceSupportProvider], from
//   `EditorEngine.capabilities()`): checked when the Projects screen or the editor opens. Entry
//   points stay visible on unsupported devices so the explanation is reachable.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';

import 'editor_providers.dart';

/// Compile-time feature flags of the editor (D-31). Both default to false; release builds pass
/// `--dart-define=DANAVIEW_EDITOR=true --dart-define=DANAVIEW_AUTO_CAPTIONS=true` (INT-05).
///
/// See ARCH §3.3, D-31.
abstract final class EditorFlags {
  /// `DANAVIEW_EDITOR`: editor entry points and routes.
  static const bool editor = bool.fromEnvironment('DANAVIEW_EDITOR');

  /// `DANAVIEW_AUTO_CAPTIONS`: the Auto captions UI (UX-37 also requires a non-empty `offers()`).
  static const bool autoCaptions = bool.fromEnvironment('DANAVIEW_AUTO_CAPTIONS');

  /// Test-only override of [editor]; null uses the compile-time value.
  @visibleForTesting
  static bool? debugEditorOverride;

  /// Test-only override of [autoCaptions]; null uses the compile-time value.
  @visibleForTesting
  static bool? debugAutoCaptionsOverride;

  /// The effective `DANAVIEW_EDITOR` value.
  static bool get editorEnabled => debugEditorOverride ?? editor;

  /// The effective `DANAVIEW_AUTO_CAPTIONS` value.
  static bool get autoCaptionsEnabled => debugAutoCaptionsOverride ?? autoCaptions;
}

/// Why the editor is hidden (no entry points, routes redirect to `/`).
///
/// See ARCH §3.3, D-17.
enum EditorHiddenReason {
  /// Desktop, web or any platform without an editor engine (D-17).
  platform,

  /// iOS/Android with `DANAVIEW_EDITOR=false` (development default, D-31).
  flagOff,
}

/// Whether the editor can be used, at the platform level ([EditorAvailability.platform]) or at
/// the device level ([editorDeviceSupportProvider]).
///
/// See ARCH §3.3, §17.1.
@immutable
sealed class EditorSupport {
  const EditorSupport();

  /// Whether the Home edit button, the player Edit action and the Settings row are shown.
  bool get showsEntryPoints;
}

/// The editor is available.
///
/// See ARCH §3.3.
final class EditorSupported extends EditorSupport {
  /// Creates the value.
  const EditorSupported();

  @override
  bool get showsEntryPoints => true;

  @override
  bool operator ==(Object other) => other is EditorSupported;

  @override
  int get hashCode => (EditorSupported).hashCode;

  @override
  String toString() => 'EditorSupported()';
}

/// The editor is hidden on this platform or build (D-17, D-31). No teaser state exists.
///
/// See ARCH §3.3, D-17.
final class EditorHidden extends EditorSupport {
  /// Creates the value.
  const EditorHidden(this.reason);

  /// Why it is hidden.
  final EditorHiddenReason reason;

  @override
  bool get showsEntryPoints => false;

  @override
  bool operator ==(Object other) => other is EditorHidden && other.reason == reason;

  @override
  int get hashCode => Object.hash(EditorHidden, reason);

  @override
  String toString() => 'EditorHidden(${reason.name})';
}

/// The platform supports the editor but this device does not pass the device gate (ARCH §3.2:
/// `android_too_old`, `gles3_missing`, `insufficient_memory`, `metal_missing`, …). Entry points stay
/// visible so the explanation is reachable (UX-05 unsupported state, UX-41 explain on tap).
///
/// See ARCH §3.2, §12.5.
final class EditorUnsupported extends EditorSupport {
  /// Creates the value.
  const EditorUnsupported(this.reason);

  /// One of `UnsupportedReasons` (engine API).
  final String reason;

  @override
  bool get showsEntryPoints => true;

  @override
  bool operator ==(Object other) => other is EditorUnsupported && other.reason == reason;

  @override
  int get hashCode => Object.hash(EditorUnsupported, reason);

  @override
  String toString() => 'EditorUnsupported($reason)';
}

/// The synchronous platform gate (ARCH §3.3).
///
/// See ARCH §3.3, §17.1, D-17.
abstract final class EditorAvailability {
  /// Platforms that have an editor engine in this release.
  static const Set<TargetPlatform> enginePlatforms = {TargetPlatform.iOS, TargetPlatform.android};

  /// Pure decision used by [platform]: supported only on iOS/Android (not web) with the editor
  /// flag on; hidden everywhere else.
  static EditorSupport resolve({required TargetPlatform platform, required bool editorFlag, bool isWeb = false}) {
    if (isWeb || !enginePlatforms.contains(platform)) return const EditorHidden(EditorHiddenReason.platform);
    if (!editorFlag) return const EditorHidden(EditorHiddenReason.flagOff);
    return const EditorSupported();
  }

  /// The platform gate for this process: [resolve] with `defaultTargetPlatform` (overridable in
  /// tests through `debugDefaultTargetPlatformOverride`), [EditorFlags.editorEnabled] and `kIsWeb`.
  static EditorSupport get platform => resolve(platform: defaultTargetPlatform, editorFlag: EditorFlags.editorEnabled, isWeb: kIsWeb);

  /// Whether the Home edit button, the player Edit action, the Settings "Video editor" row and the
  /// editor storage contributors exist (the router passes callbacks only when true).
  static bool get showsEntryPoints => platform.showsEntryPoints;

  /// Maps engine capabilities to a device-level [EditorSupport].
  static EditorSupport fromCapabilities(EditorCapabilities caps) =>
      caps.supported ? const EditorSupported() : EditorUnsupported(caps.unsupportedReason ?? UnsupportedReasons.engineNotAvailable);
}

/// The asynchronous device gate (ARCH §3.3): the platform gate first (hidden platforms never touch
/// the engine), then `EditorEngine.capabilities()`. An engine that is missing or fails reports
/// `EditorUnsupported(engine_not_available)`; it never throws.
///
/// See ARCH §3.3, §12.5.
final editorDeviceSupportProvider = FutureProvider<EditorSupport>((ref) async {
  final platform = EditorAvailability.platform;
  if (platform is! EditorSupported) return platform;
  try {
    final caps = await ref.watch(editorCapabilitiesProvider.future);
    return EditorAvailability.fromCapabilities(caps);
  } on Object {
    return const EditorUnsupported(UnsupportedReasons.engineNotAvailable);
  }
});
