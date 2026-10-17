// OWNER: AI-13
//
// The resource governor (ARCH §16.5, ai.md §6): thread policy, thermal and low-power reaction,
// memory and disk preflight, export interplay and app lifecycle. It holds no job; the pipeline
// asks it what to do ([threads], [chunkCooldown], [pauseReason]) and listens to [changes].
//
// Policy:
//   base threads = clamp(perf cores, 2, 4)
//   thermal serious  -> max(2, base ~/ 2) and a 2 s cooldown between chunks
//   thermal critical -> paused (at the next chunk boundary); resumes after <= serious for 10 s
//   low power        -> max(2, threads - 1)
//   export running   -> generation waits, or pauses at the next chunk boundary
//   iOS background   -> pause at once (the running chunk is aborted and redone, V-A3)
//   Android          -> keeps running in the background under a BackgroundLeaseProvider lease
//
// Signals come from the danaview_whisper device channel (thermal, low power, lifecycle, memory
// warnings) and from an [ExportActivity] port that INT-04 binds to the engine's export state.

import 'dart:async';

import 'package:meta/meta.dart';
import 'package:danaview_whisper/danaview_whisper.dart';

import '../catalog/speech_model_catalog.dart';
import '../catalog/tuning.dart';
import '../contracts/failures.dart';
import '../contracts/transcription_service.dart' show PauseReason;

/// Device facts and signals the governor reads (the plugin's device channel in production).
abstract interface class DeviceResources {
  /// The device snapshot ([WhisperDeviceProfile.unknown] when the plugin is unavailable).
  Future<WhisperDeviceProfile> profile();

  /// Memory the app may still allocate, or null when unknown.
  Future<int?> availableMemory();

  /// Free bytes on the volume holding [path], or null when unknown.
  Future<int?> freeDiskBytes(String path);

  /// Thermal, low-power, lifecycle and memory-warning events.
  Stream<WhisperDeviceEvent> get events;
}

/// [DeviceResources] over the `danaview_whisper/device` channel (AI-06).
final class WhisperDeviceResources implements DeviceResources {
  /// Creates the adapter over [channel].
  WhisperDeviceResources(this.channel);

  /// The channel.
  final WhisperDeviceChannel channel;

  @override
  Future<WhisperDeviceProfile> profile() => channel.deviceProfile();

  @override
  Future<int?> availableMemory() => channel.availableMemory();

  @override
  Future<int?> freeDiskBytes(String path) => channel.freeDiskBytes(path);

  @override
  Stream<WhisperDeviceEvent> get events => channel.events;
}

/// Whether an export is running (INT-04 binds it to the engine's export signal).
abstract interface class ExportActivity {
  /// Whether an export runs now.
  bool get isActive;

  /// Emits the new state on every change.
  Stream<bool> get changes;
}

/// An [ExportActivity] that never reports an export (tests, desktop).
final class NoExportActivity implements ExportActivity {
  /// Creates the port.
  const NoExportActivity();

  @override
  bool get isActive => false;

  @override
  Stream<bool> get changes => const Stream<bool>.empty();
}

/// The platform family whose background rules apply.
enum SpeechPlatform {
  /// iOS: pause in the background (abort the running chunk).
  ios,

  /// Android: keep running under a foreground-service lease.
  android,

  /// Anything else (desktop, tests): no lifecycle reaction.
  other,
}

/// Starts a timer (tests pass a manual one).
typedef GovernorTimerFactory = Timer Function(Duration duration, void Function() callback);

/// Thread, thermal, memory, export and lifecycle policy for Auto captions.
final class ResourceGovernor {
  /// Creates a governor. [platform] defaults to the profile's OS. [timer] starts the critical
  /// recovery timer.
  ResourceGovernor({
    required DeviceResources device,
    ExportActivity exports = const NoExportActivity(),
    SpeechPlatform? platform,
    this.thermalCooldown = const Duration(seconds: 2),
    this.criticalRecovery = const Duration(seconds: 10),
    GovernorTimerFactory? timer,
  })  : _device = device,
        _exports = exports,
        _platformOverride = platform,
        _timer = timer ?? Timer.new;

  /// Pause between chunks while the device is at thermal `serious`.
  final Duration thermalCooldown;

  /// Time at `serious` or cooler before a thermal pause ends.
  final Duration criticalRecovery;

  /// Required available memory as a multiple of a tier's peak budget.
  static const double memoryHeadroom = SpeechTuning.preflightMemoryFactor;

  final DeviceResources _device;
  final ExportActivity _exports;
  final SpeechPlatform? _platformOverride;
  final GovernorTimerFactory _timer;

  final StreamController<void> _changes = StreamController<void>.broadcast(sync: true);
  final StreamController<void> _memoryWarnings = StreamController<void>.broadcast(sync: true);
  final List<StreamSubscription<Object?>> _subs = [];
  Future<void>? _started;
  Timer? _recovery;

  WhisperDeviceProfile _profile = WhisperDeviceProfile.unknown;
  ThermalLevel _thermal = ThermalLevel.nominal;
  bool _lowPower = false;
  bool _background = false;
  bool _thermalPaused = false;
  bool _exportActive = false;

  /// Loads the profile and subscribes to the signals. Idempotent.
  Future<void> start() => _started ??= _start();

  Future<void> _start() async {
    try {
      _profile = await _device.profile();
    } on Object {
      _profile = WhisperDeviceProfile.unknown;
    }
    _thermal = _profile.thermal;
    _lowPower = _profile.lowPowerMode;
    _thermalPaused = _thermal == ThermalLevel.critical;
    _exportActive = _exports.isActive;
    _subs
      ..add(_device.events.listen(_onDeviceEvent, onError: (Object _) {}))
      ..add(_exports.changes.listen(_onExport, onError: (Object _) {}));
  }

  /// Stops listening.
  Future<void> dispose() async {
    _recovery?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _changes.close();
    await _memoryWarnings.close();
  }

  // -------------------------------------------------------------------------------------------
  // State
  // -------------------------------------------------------------------------------------------

  /// The device profile ([WhisperDeviceProfile.unknown] before [start]).
  WhisperDeviceProfile get profile => _profile;

  /// The platform whose background rules apply.
  SpeechPlatform get platform =>
      _platformOverride ??
      switch (_profile.os) {
        'ios' => SpeechPlatform.ios,
        'android' => SpeechPlatform.android,
        _ => SpeechPlatform.other,
      };

  /// Current thermal level.
  ThermalLevel get thermal => _thermal;

  /// Low Power Mode / Battery Saver.
  bool get lowPower => _lowPower;

  /// The app is in the background.
  bool get inBackground => _background;

  /// An export is running.
  bool get exportActive => _exportActive;

  /// Thread count for the next chunk.
  int get threads => threadsFor(perfCores: _profile.effectivePerfCores, thermal: _thermal, lowPower: _lowPower);

  /// Pause inserted between chunks (thermal `serious`).
  Duration get chunkCooldown => _thermal == ThermalLevel.serious ? thermalCooldown : Duration.zero;

  /// Why generation must not run now, or null. iOS background wins over thermal over export.
  /// The pipeline reports an export as [PauseReason.waitingForExport] before transcription has
  /// begun and as [PauseReason.exportRunning] after.
  PauseReason? get pauseReason {
    if (_background && platform == SpeechPlatform.ios) return PauseReason.background;
    if (_thermalPaused) return PauseReason.thermal;
    if (_exportActive) return PauseReason.exportRunning;
    return null;
  }

  /// Emits after every change of [threads], [chunkCooldown] or [pauseReason].
  Stream<void> get changes => _changes.stream;

  /// Emits on every system memory warning (the service then releases idle models).
  Stream<void> get memoryWarnings => _memoryWarnings.stream;

  /// The thread policy (ai.md §6.2).
  static int threadsFor({required int perfCores, ThermalLevel thermal = ThermalLevel.nominal, bool lowPower = false}) {
    var n = perfCores.clamp(2, 4);
    if (thermal.isHot) n = n ~/ 2 < 2 ? 2 : n ~/ 2;
    if (lowPower) n = n - 1 < 2 ? 2 : n - 1;
    return n;
  }

  // -------------------------------------------------------------------------------------------
  // Preflight
  // -------------------------------------------------------------------------------------------

  /// Memory needed to run [spec]: [memoryHeadroom] × its peak budget.
  static int requiredMemory(SpeechModelSpec spec) => (spec.peakMemoryBudgetBytes * memoryHeadroom).ceil();

  /// Null when [spec] fits in the memory available now (or that is unknown); otherwise an
  /// [InsufficientMemoryFailure] suggesting the largest smaller tier among [available] that fits.
  Future<InsufficientMemoryFailure?> checkMemory(SpeechModelSpec spec, {required List<SpeechModelTier> available}) async {
    int? avail;
    try {
      avail = await _device.availableMemory();
    } on Object {
      avail = null;
    }
    if (avail == null || avail >= requiredMemory(spec)) return null;
    return InsufficientMemoryFailure(suggestedTier: suggestSmallerTier(spec.tier, available: available, availableMemory: avail));
  }

  /// The largest tier below [tier] among [available] that fits [availableMemory] (any smaller
  /// one when the memory is unknown), or null.
  static SpeechModelTier? suggestSmallerTier(SpeechModelTier tier, {required List<SpeechModelTier> available, int? availableMemory}) {
    for (var i = tier.index - 1; i >= 0; i--) {
      final t = SpeechModelTier.values[i];
      if (!available.contains(t)) continue;
      if (availableMemory == null || availableMemory >= requiredMemory(SpeechModelCatalog.specOf(t))) return t;
    }
    return null;
  }

  /// Whether [bytes] fit on the volume holding [path] (true when unknown).
  Future<bool> hasDisk(String path, int bytes) async {
    int? free;
    try {
      free = await _device.freeDiskBytes(path);
    } on Object {
      free = null;
    }
    return free == null || free >= bytes;
  }

  // -------------------------------------------------------------------------------------------
  // Signals
  // -------------------------------------------------------------------------------------------

  void _onDeviceEvent(WhisperDeviceEvent e) {
    switch (e) {
      case ThermalChanged(:final level):
        _setThermal(level);
      case LowPowerChanged(:final enabled):
        if (enabled == _lowPower) return;
        _lowPower = enabled;
        _notify();
      case AppStateChanged(:final state):
        final bg = state == WhisperAppState.background;
        if (bg == _background) return;
        _background = bg;
        _notify();
      case MemoryWarning():
        if (!_memoryWarnings.isClosed) _memoryWarnings.add(null);
      case BackgroundTaskExpiring():
        break;
    }
  }

  void _setThermal(ThermalLevel level) {
    if (level == _thermal) return;
    _thermal = level;
    if (level == ThermalLevel.critical) {
      _recovery?.cancel();
      _recovery = null;
      _thermalPaused = true;
    } else if (_thermalPaused && _recovery == null) {
      _recovery = _timer(criticalRecovery, () {
        _recovery = null;
        if (_thermal != ThermalLevel.critical && _thermalPaused) {
          _thermalPaused = false;
          _notify();
        }
      });
    }
    _notify();
  }

  void _onExport(bool active) {
    if (active == _exportActive) return;
    _exportActive = active;
    _notify();
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  /// Feeds a device event as if the channel sent it (tests).
  @visibleForTesting
  void debugDeviceEvent(WhisperDeviceEvent e) => _onDeviceEvent(e);
}
