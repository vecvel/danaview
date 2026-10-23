// OWNER: ST-03
//
// The speed test's skip memory (V2-403, D-ST3): a provider that failed with a rate limit, a refusal,
// a connection failure or a stall is skipped for 10 minutes. The skip is kept in memory and in
// SharedPreferences (`speed.skip.<provider id>`, ARCH §5 "Speed-test prefs"), so it survives the
// screen closing and the app restarting. Clock and prefs are injectable for tests.

import 'package:shared_preferences/shared_preferences.dart';

class ProviderHealthStore {
  /// [prefs] null keeps the skip memory in memory only (tests, or prefs unavailable).
  ProviderHealthStore({
    SharedPreferences? prefs,
    DateTime Function()? now,
    this.skipFor = defaultSkipFor,
  })  : _prefs = prefs,
        _now = now ?? DateTime.now;

  /// A store backed by the app's SharedPreferences; memory only when they can't be opened.
  static Future<ProviderHealthStore> load({DateTime Function()? now, Duration skipFor = defaultSkipFor}) async {
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {
      prefs = null;
    }
    return ProviderHealthStore(prefs: prefs, now: now, skipFor: skipFor);
  }

  /// D-ST3: a failed provider is skipped for 10 minutes.
  static const Duration defaultSkipFor = Duration(minutes: 10);

  /// The prefs key for [providerId]'s skip; the value is the end of the skip, in ms since the epoch.
  static String prefsKey(String providerId) => 'speed.skip.$providerId';

  final SharedPreferences? _prefs;
  final DateTime Function() _now;
  final Duration skipFor;

  /// End of each provider's skip, as written by this store.
  final Map<String, DateTime> _memory = {};

  /// When [providerId]'s skip ends, or null when it is not skipped.
  ///
  /// A skip that ends more than [skipFor] from now was written before the clock moved back; it is
  /// treated as ending [skipFor] after now at most, so a changed clock can't skip a provider for good.
  DateTime? skippedUntil(String providerId) {
    final until = _memory[providerId] ?? _readPrefs(providerId);
    if (until == null) return null;
    final now = _now();
    if (!until.isAfter(now)) return null;
    final latest = now.add(skipFor);
    return until.isAfter(latest) ? latest : until;
  }

  bool isSkipped(String providerId) => skippedUntil(providerId) != null;

  /// [providerId] failed now: skip it for [skipFor].
  Future<void> markFailed(String providerId) async {
    final until = _now().add(skipFor);
    _memory[providerId] = until;
    await _writePrefs(providerId, until);
  }

  /// [providerId] answered: stop skipping it.
  Future<void> clear(String providerId) async {
    final hadSkip = _memory.remove(providerId) != null || _readPrefs(providerId) != null;
    if (!hadSkip) return;
    try {
      await _prefs?.remove(prefsKey(providerId));
    } catch (_) {
      // The memory copy is already clear.
    }
  }

  DateTime? _readPrefs(String providerId) {
    try {
      final ms = _prefs?.getInt(prefsKey(providerId));
      return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
    } catch (_) {
      // A value of another type under the key reads as no skip.
      return null;
    }
  }

  Future<void> _writePrefs(String providerId, DateTime until) async {
    try {
      await _prefs?.setInt(prefsKey(providerId), until.millisecondsSinceEpoch);
    } catch (_) {
      // The memory copy still skips the provider for this session.
    }
  }
}
