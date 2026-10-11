// OWNER: UX-01
//
// Editor preferences (ARCH §17.10, ux.md §4.8): SharedPreferences keys prefixed `editor.`.
//
// Typed accessors cover every setting known in this release (Editor settings screen UX-04,
// splitter UX-07, Projects sort UX-05, export notices UX-39, captions defaults UX-38). Later
// tickets that need another key use the generic `read*`/`write*` methods with an [EditorPrefKeys]
// style `editor.<feature>.<name>` key instead of editing this file. Nothing here stores media
// paths or user content.

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Proxy media setting (ARCH §9.5, §17.10).
///
/// See ARCH §17.10.
enum ProxyMediaMode {
  /// Proxies when the device tier or the source needs them (recommended).
  auto,

  /// Always edit with proxies.
  always,

  /// Never create proxies.
  off,
}

/// Default preview quality for new editor sessions (ARCH §17.10; UX-18 adds per-session choices).
///
/// See ARCH §17.10.
enum PreviewQualityPreference {
  /// Engine decides by tier and thermal state.
  auto,

  /// Full preview resolution.
  full,

  /// Half preview resolution.
  half,
}

/// Default aspect of new projects (ARCH §17.10, ux.md §5.3).
///
/// See ARCH §17.10.
enum NewProjectAspect {
  /// Match the first video (default).
  matchFirstClip,

  /// 16:9.
  landscape16x9,

  /// 9:16.
  portrait9x16,

  /// 1:1.
  square,

  /// 4:5.
  portrait4x5,
}

/// Projects screen sort order (ux.md §5.4).
///
/// See BUILD_PLAN UX-05.
enum ProjectSortPreference {
  /// Most recently updated first.
  recent,

  /// By name.
  name,
}

/// The `editor.` keys used by the typed accessors of [EditorPrefs].
///
/// See ARCH §17.10.
abstract final class EditorPrefKeys {
  /// Every editor key starts with this prefix.
  static const String prefix = 'editor.';

  /// [ProxyMediaMode] name.
  static const String proxyMedia = 'editor.proxyMedia';

  /// [PreviewQualityPreference] name.
  static const String previewQuality = 'editor.previewQuality';

  /// Centre-locked playhead on touch (bool).
  static const String centerPlayheadOnTouch = 'editor.centerPlayheadOnTouch';

  /// Haptic tick when snapping engages (bool).
  static const String snappingHaptics = 'editor.snappingHaptics';

  /// [NewProjectAspect] name.
  static const String newProjectAspect = 'editor.newProjectAspect';

  /// [ProjectSortPreference] name.
  static const String projectsSort = 'editor.projects.sort';

  /// Splitter ratio per layout kind: `editor.layout.splitRatio.<kind>` (double).
  static String splitRatio(String layoutKind) => 'editor.layout.splitRatio.$layoutKind';

  /// The first-export background notice was shown (bool).
  static const String exportBackgroundNoticeShown = 'editor.export.backgroundNoticeShown';

  /// The in-context notification permission request was made (Android 13+; bool).
  static const String exportNotificationPermissionAsked = 'editor.export.notificationPermissionAsked';

  /// Default caption segmentation preset (`SegmentationPreset` name).
  static const String captionsDefaultPreset = 'editor.captions.defaultPreset';

  /// Whether [key] is an editor key.
  static bool isEditorKey(String key) => key.startsWith(prefix) && key.length > prefix.length;
}

/// Storage behind [EditorPrefs]: SharedPreferences in the app, memory in tests and on platforms
/// without the editor.
///
/// See ARCH §17.10.
abstract interface class EditorPrefsBackend {
  /// The stored value (String, bool, int or double), or null.
  Object? read(String key);

  /// Stores [value] (String, bool, int or double); null removes the key.
  Future<void> write(String key, Object? value);

  /// Every stored key (editor and non-editor).
  Set<String> get keys;
}

/// [EditorPrefsBackend] over `SharedPreferences`.
///
/// See ARCH §17.10.
final class SharedPreferencesEditorBackend implements EditorPrefsBackend {
  /// Wraps [prefs].
  SharedPreferencesEditorBackend(this.prefs);

  /// The plugin instance.
  final SharedPreferences prefs;

  @override
  Object? read(String key) => prefs.get(key);

  @override
  Future<void> write(String key, Object? value) async {
    switch (value) {
      case null:
        await prefs.remove(key);
      case final String v:
        await prefs.setString(key, v);
      case final bool v:
        await prefs.setBool(key, v);
      case final int v:
        await prefs.setInt(key, v);
      case final double v:
        await prefs.setDouble(key, v);
      default:
        throw ArgumentError.value(value, 'value', 'only String, bool, int and double are stored');
    }
  }

  @override
  Set<String> get keys => prefs.getKeys();
}

/// In-memory [EditorPrefsBackend].
///
/// See ARCH §17.10.
final class MemoryEditorPrefsBackend implements EditorPrefsBackend {
  /// Creates the backend with [initial] values.
  MemoryEditorPrefsBackend([Map<String, Object> initial = const {}]) : values = Map.of(initial);

  /// Stored values.
  final Map<String, Object> values;

  @override
  Object? read(String key) => values[key];

  @override
  Future<void> write(String key, Object? value) async {
    if (value == null) {
      values.remove(key);
    } else if (value is String || value is bool || value is int || value is double) {
      values[key] = value;
    } else {
      throw ArgumentError.value(value, 'value', 'only String, bool, int and double are stored');
    }
  }

  @override
  Set<String> get keys => values.keys.toSet();
}

/// Typed access to the `editor.` preferences. Notifies listeners after every change.
///
/// Reads are synchronous; writes update the in-memory state immediately and return when the
/// backend has persisted the value.
///
/// See ARCH §17.10.
class EditorPrefs extends ChangeNotifier {
  /// Creates prefs over [backend].
  EditorPrefs(this.backend);

  /// Prefs held in memory only (tests; desktop where the editor is hidden).
  factory EditorPrefs.memory([Map<String, Object> initial = const {}]) => EditorPrefs(MemoryEditorPrefsBackend(initial));

  /// Prefs over the app's SharedPreferences.
  static Future<EditorPrefs> load() async => EditorPrefs(SharedPreferencesEditorBackend(await SharedPreferences.getInstance()));

  /// The storage.
  final EditorPrefsBackend backend;

  // ---- Editor settings screen (UX-04) -------------------------------------------------------

  /// Proxy media (default [ProxyMediaMode.auto]).
  ProxyMediaMode get proxyMedia => _enum(EditorPrefKeys.proxyMedia, ProxyMediaMode.values, ProxyMediaMode.auto);

  /// Sets [proxyMedia].
  Future<void> setProxyMedia(ProxyMediaMode value) => _write(EditorPrefKeys.proxyMedia, value.name);

  /// Default preview quality (default [PreviewQualityPreference.auto]).
  PreviewQualityPreference get previewQuality =>
      _enum(EditorPrefKeys.previewQuality, PreviewQualityPreference.values, PreviewQualityPreference.auto);

  /// Sets [previewQuality].
  Future<void> setPreviewQuality(PreviewQualityPreference value) => _write(EditorPrefKeys.previewQuality, value.name);

  /// Centre-locked playhead on touch (default true; ARCH §17.4).
  bool get centerPlayheadOnTouch => readBool(EditorPrefKeys.centerPlayheadOnTouch) ?? true;

  /// Sets [centerPlayheadOnTouch].
  Future<void> setCenterPlayheadOnTouch(bool value) => _write(EditorPrefKeys.centerPlayheadOnTouch, value);

  /// Haptic tick when snapping engages (default true).
  bool get snappingHaptics => readBool(EditorPrefKeys.snappingHaptics) ?? true;

  /// Sets [snappingHaptics].
  Future<void> setSnappingHaptics(bool value) => _write(EditorPrefKeys.snappingHaptics, value);

  /// Default aspect of new projects (default [NewProjectAspect.matchFirstClip]).
  NewProjectAspect get newProjectAspect => _enum(EditorPrefKeys.newProjectAspect, NewProjectAspect.values, NewProjectAspect.matchFirstClip);

  /// Sets [newProjectAspect].
  Future<void> setNewProjectAspect(NewProjectAspect value) => _write(EditorPrefKeys.newProjectAspect, value.name);

  // ---- Projects (UX-05), layout (UX-07), export (UX-39), captions (UX-38) ------------------

  /// Projects sort (default [ProjectSortPreference.recent]).
  ProjectSortPreference get projectsSort => _enum(EditorPrefKeys.projectsSort, ProjectSortPreference.values, ProjectSortPreference.recent);

  /// Sets [projectsSort].
  Future<void> setProjectsSort(ProjectSortPreference value) => _write(EditorPrefKeys.projectsSort, value.name);

  /// The user's splitter ratio for a layout kind (`EditorLayoutKind.name`), or null for the
  /// layout default. Values outside (0, 1) read as null.
  double? splitRatio(String layoutKind) {
    final v = readDouble(EditorPrefKeys.splitRatio(layoutKind));
    return v != null && v.isFinite && v > 0 && v < 1 ? v : null;
  }

  /// Stores the splitter ratio for [layoutKind]; null resets it.
  Future<void> setSplitRatio(String layoutKind, double? ratio) {
    if (ratio != null && !(ratio.isFinite && ratio > 0 && ratio < 1)) {
      throw ArgumentError.value(ratio, 'ratio', 'must be in (0, 1)');
    }
    return _write(EditorPrefKeys.splitRatio(layoutKind), ratio);
  }

  /// Whether the first-export background notice was shown (ux.md §11.1).
  bool get exportBackgroundNoticeShown => readBool(EditorPrefKeys.exportBackgroundNoticeShown) ?? false;

  /// Records that the background notice was shown.
  Future<void> markExportBackgroundNoticeShown() => _write(EditorPrefKeys.exportBackgroundNoticeShown, true);

  /// Whether the in-context notification permission request was made (Android 13+).
  bool get exportNotificationPermissionAsked => readBool(EditorPrefKeys.exportNotificationPermissionAsked) ?? false;

  /// Records that the notification permission request was made.
  Future<void> markExportNotificationPermissionAsked() => _write(EditorPrefKeys.exportNotificationPermissionAsked, true);

  /// Default caption segmentation preset name (core `SegmentationPreset.name`), or null.
  String? get captionsDefaultPreset => readString(EditorPrefKeys.captionsDefaultPreset);

  /// Sets [captionsDefaultPreset]; null resets it.
  Future<void> setCaptionsDefaultPreset(String? presetName) => _write(EditorPrefKeys.captionsDefaultPreset, presetName);

  // ---- Generic access for later tickets ------------------------------------------------------

  /// A String value of an `editor.` key (null when absent or of another type).
  String? readString(String key) => _read<String>(key);

  /// A bool value of an `editor.` key.
  bool? readBool(String key) => _read<bool>(key);

  /// An int value of an `editor.` key.
  int? readInt(String key) => _read<int>(key);

  /// A double value of an `editor.` key (ints are widened).
  double? readDouble(String key) {
    final v = backend.read(_checked(key));
    return switch (v) {
      final double d => d,
      final int i => i.toDouble(),
      _ => null,
    };
  }

  /// Stores a String under an `editor.` key; null removes it.
  Future<void> writeString(String key, String? value) => _write(key, value);

  /// Stores a bool under an `editor.` key; null removes it.
  Future<void> writeBool(String key, bool? value) => _write(key, value);

  /// Stores an int under an `editor.` key; null removes it.
  Future<void> writeInt(String key, int? value) => _write(key, value);

  /// Stores a double under an `editor.` key; null removes it.
  Future<void> writeDouble(String key, double? value) => _write(key, value);

  /// Removes an `editor.` key.
  Future<void> remove(String key) => _write(key, null);

  /// Every stored `editor.` key.
  Set<String> get editorKeys => backend.keys.where(EditorPrefKeys.isEditorKey).toSet();

  /// Removes every `editor.` key (other app preferences are untouched).
  Future<void> clearEditorKeys() async {
    final keys = editorKeys;
    if (keys.isEmpty) return;
    for (final k in keys) {
      await backend.write(k, null);
    }
    notifyListeners();
  }

  T? _read<T extends Object>(String key) {
    final v = backend.read(_checked(key));
    return v is T ? v : null;
  }

  E _enum<E extends Enum>(String key, List<E> values, E fallback) {
    final name = readString(key);
    for (final v in values) {
      if (v.name == name) return v;
    }
    return fallback;
  }

  Future<void> _write(String key, Object? value) async {
    final checked = _checked(key);
    if (backend.read(checked) == value) return;
    final pending = backend.write(checked, value);
    notifyListeners();
    await pending;
  }

  static String _checked(String key) {
    if (!EditorPrefKeys.isEditorKey(key)) {
      throw ArgumentError.value(key, 'key', 'editor preferences use keys prefixed "${EditorPrefKeys.prefix}"');
    }
    return key;
  }
}
