// OWNER: UX-01
//
// Rebuild counters (ux.md §16.6, §21.2; QA-04 "playback rebuild counts"). Widgets on the
// performance contract call `EditorRebuildCounters.count('<WidgetName>')` from `build`; tests and
// the profile-mode perf suite enable counting, run a scenario and compare counts. Available in debug
// and profile builds; a no-op in release builds.

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Named rebuild counters.
///
/// See ARCH §17.3 ("nothing in EditorState changes per playback frame"), BUILD_PLAN QA-04.
abstract final class EditorRebuildCounters {
  /// Whether counting can happen in this build mode (debug and profile).
  static const bool available = !kReleaseMode;

  /// Whether counting is on (off by default so normal runs pay one branch per build).
  static bool enabled = false;

  static final Map<String, int> _counts = <String, int>{};

  /// Counts one rebuild of [name] when [enabled].
  static void count(String name) {
    if (!available || !enabled) return;
    _counts[name] = (_counts[name] ?? 0) + 1;
  }

  /// Rebuilds of [name] since the last [reset].
  static int of(String name) => _counts[name] ?? 0;

  /// All counts.
  static Map<String, int> snapshot() => Map.unmodifiable(_counts);

  /// Counts accumulated since [before] (a previous [snapshot]); names without new rebuilds are
  /// omitted.
  static Map<String, int> since(Map<String, int> before) {
    final out = <String, int>{};
    _counts.forEach((name, n) {
      final d = n - (before[name] ?? 0);
      if (d > 0) out[name] = d;
    });
    return out;
  }

  /// Clears every count.
  static void reset() => _counts.clear();

  /// Enables counting from zero, runs [body], restores the previous state and returns the counts
  /// recorded during [body].
  static Future<Map<String, int>> record(Future<void> Function() body) async {
    final wasEnabled = enabled;
    final before = snapshot();
    enabled = true;
    try {
      await body();
    } finally {
      enabled = wasEnabled;
    }
    return since(before);
  }
}

/// Counts the rebuilds of its parent's `build` under [name] (for widgets that cannot call
/// [EditorRebuildCounters.count] themselves, e.g. a builder callback). Renders [child] unchanged.
///
/// See ux.md §16.6.
class EditorRebuildProbe extends StatelessWidget {
  /// Creates the probe.
  const EditorRebuildProbe({super.key, required this.name, required this.child});

  /// Counter name.
  final String name;

  /// The content.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    EditorRebuildCounters.count(name);
    return child;
  }
}
