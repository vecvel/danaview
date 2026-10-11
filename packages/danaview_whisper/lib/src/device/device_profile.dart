// OWNER: AI-06
//
// Device facts the speech pipeline needs (ai.md §4.8, §6): RAM, performance cores, CPU features,
// Apple GPU family, thermal and power state. Everything here is parsed defensively from the map the
// native plugin returns: a missing key, a wrong type or an unknown value never throws, it falls
// back to a conservative default (ARCH §16.5: threads, tiers and preflight must still work).

import 'package:meta/meta.dart';

/// Thermal pressure, mapped natively (iOS `ProcessInfo.ThermalState`, Android
/// `PowerManager.THERMAL_STATUS_*`).
enum ThermalLevel {
  /// Nominal (Android NONE/LIGHT).
  nominal,

  /// Fair (Android MODERATE).
  fair,

  /// Serious (Android SEVERE): halve the threads, cool down between chunks.
  serious,

  /// Critical (Android CRITICAL, EMERGENCY, SHUTDOWN): pause at the next chunk boundary.
  critical;

  /// The level named [name], or null for anything else (case-sensitive, native strings).
  static ThermalLevel? tryParse(Object? name) {
    if (name is! String) return null;
    for (final l in values) {
      if (l.name == name) return l;
    }
    return null;
  }

  /// Whether this level is `serious` or worse.
  bool get isHot => index >= ThermalLevel.serious.index;
}

/// CPU features that select kernels and shims (ai.md §4.3).
enum CpuFeature {
  /// Armv8.2 dot product (`asimddp` / `FEAT_DotProd`).
  dotprod,

  /// Armv8.2 half-precision vector arithmetic (`asimdhp` / `FEAT_FP16`).
  fp16,

  /// Int8 matrix multiply (`i8mm`).
  i8mm,

  /// bfloat16 (`bf16`).
  bf16;

  /// The feature named [name], or null.
  static CpuFeature? tryParse(Object? name) {
    if (name is! String) return null;
    for (final f in values) {
      if (f.name == name) return f;
    }
    return null;
  }
}

/// A snapshot of the device (see `deviceProfile` in ai.md §4.8).
@immutable
final class WhisperDeviceProfile {
  /// Creates a profile.
  const WhisperDeviceProfile({
    this.os = 'unknown',
    this.osVersion = '',
    this.model = '',
    this.physicalRamBytes = 0,
    this.isLowRam = false,
    this.perfCores = 0,
    this.efficiencyCores = 0,
    this.totalCores = 0,
    this.is64Bit = true,
    this.cpuFeatures = const {},
    this.gpuFamily = 0,
    this.isSimulator = false,
    this.lowPowerMode = false,
    this.thermal = ThermalLevel.nominal,
    this.apiLevel = 0,
  });

  /// Parses the native map. Never throws.
  factory WhisperDeviceProfile.fromMap(Object? raw) {
    if (raw is! Map<Object?, Object?>) return WhisperDeviceProfile.unknown;
    final perf = _nonNegativeInt(raw['perfCores']);
    final total = _nonNegativeInt(raw['totalCores']);
    var efficiency = _nonNegativeInt(raw['efficiencyCores']);
    if (efficiency == 0 && total > perf && perf > 0) efficiency = total - perf;
    final features = <CpuFeature>{};
    final rawFeatures = raw['cpuFeatures'];
    if (rawFeatures is List<Object?>) {
      for (final f in rawFeatures) {
        final parsed = CpuFeature.tryParse(f);
        if (parsed != null) features.add(parsed);
      }
    }
    return WhisperDeviceProfile(
      os: _string(raw['os']) ?? 'unknown',
      osVersion: _string(raw['osVersion']) ?? '',
      model: _string(raw['model']) ?? '',
      physicalRamBytes: _nonNegativeInt(raw['physicalRam']),
      isLowRam: raw['isLowRam'] == true,
      perfCores: perf,
      efficiencyCores: efficiency,
      totalCores: total,
      is64Bit: raw['is64Bit'] is bool ? raw['is64Bit'] as bool : true,
      cpuFeatures: Set<CpuFeature>.unmodifiable(features),
      gpuFamily: _nonNegativeInt(raw['gpuFamily']),
      isSimulator: raw['isSimulator'] == true,
      lowPowerMode: raw['lowPowerMode'] == true,
      thermal: ThermalLevel.tryParse(raw['thermal']) ?? ThermalLevel.nominal,
      apiLevel: _nonNegativeInt(raw['apiLevel']),
    );
  }

  /// What the pipeline assumes when the plugin is unavailable (desktop, tests, a channel error):
  /// no RAM information, one-core defaults, no features.
  static const WhisperDeviceProfile unknown = WhisperDeviceProfile();

  /// `ios`, `android` or `unknown`.
  final String os;

  /// OS version string (`18.2`, `14`).
  final String osVersion;

  /// Hardware model (`iPhone15,2`, `Pixel 7a`).
  final String model;

  /// Physical RAM in bytes (0 = unknown).
  final int physicalRamBytes;

  /// Android `isLowRamDevice` (always false on iOS).
  final bool isLowRam;

  /// Performance ("big") cores, 0 = unknown.
  final int perfCores;

  /// Efficiency cores, 0 = unknown.
  final int efficiencyCores;

  /// Logical cores, 0 = unknown.
  final int totalCores;

  /// 64-bit process (always true on supported iOS and arm64-v8a/x86_64 Android).
  final bool is64Bit;

  /// Detected CPU features.
  final Set<CpuFeature> cpuFeatures;

  /// Apple GPU family number (`MTLGPUFamilyApple<N>`), 0 when unknown or not Apple.
  final int gpuFamily;

  /// Running in a simulator.
  final bool isSimulator;

  /// iOS Low Power Mode or Android Battery Saver.
  final bool lowPowerMode;

  /// Thermal level at the time of the snapshot.
  final ThermalLevel thermal;

  /// Android API level (0 on iOS).
  final int apiLevel;

  /// Performance cores for the thread policy `clamp(perf, 2, 4)` (ai.md §6.2); half the logical
  /// cores when the platform could not tell (never below 1).
  int get effectivePerfCores {
    if (perfCores > 0) return perfCores;
    if (totalCores > 1) return totalCores ~/ 2;
    return 1;
  }

  /// Whether the Armv8.2 dot-product and fp16 shim variant can run.
  bool get supportsV82 => cpuFeatures.contains(CpuFeature.dotprod) && cpuFeatures.contains(CpuFeature.fp16);

  /// Whether whisper's Metal backend is allowed here: a real iOS device on iOS >= 16.4 with Apple
  /// GPU family >= 6 (A13 or newer), ARCH §3.1. The shim applies the same policy; this getter lets
  /// the Dart side predict it (tier advice, diagnostics).
  bool get metalAllowed => os == 'ios' && !isSimulator && gpuFamily >= 6 && _atLeast(osVersion, 16, 4);

  @override
  bool operator ==(Object other) =>
      other is WhisperDeviceProfile &&
      other.os == os &&
      other.osVersion == osVersion &&
      other.model == model &&
      other.physicalRamBytes == physicalRamBytes &&
      other.isLowRam == isLowRam &&
      other.perfCores == perfCores &&
      other.efficiencyCores == efficiencyCores &&
      other.totalCores == totalCores &&
      other.is64Bit == is64Bit &&
      _setEquals(other.cpuFeatures, cpuFeatures) &&
      other.gpuFamily == gpuFamily &&
      other.isSimulator == isSimulator &&
      other.lowPowerMode == lowPowerMode &&
      other.thermal == thermal &&
      other.apiLevel == apiLevel;

  @override
  int get hashCode => Object.hash(os, osVersion, model, physicalRamBytes, isLowRam, perfCores, efficiencyCores, totalCores,
      is64Bit, Object.hashAllUnordered(cpuFeatures), gpuFamily, isSimulator, lowPowerMode, thermal, apiLevel);

  @override
  String toString() =>
      'WhisperDeviceProfile($os $osVersion, $model, ram=${physicalRamBytes ~/ (1024 * 1024)} MiB, perf=$perfCores/$totalCores, '
      'features=${cpuFeatures.map((f) => f.name).join('+')}, gpu=$gpuFamily, thermal=${thermal.name})';
}

bool _setEquals<T>(Set<T> a, Set<T> b) => a.length == b.length && a.containsAll(b);

String? _string(Object? v) => v is String ? v : null;

/// A non-negative integer from a number the platform may encode as int or double; anything else is 0.
int _nonNegativeInt(Object? v) {
  if (v is int) return v < 0 ? 0 : v;
  if (v is double && v.isFinite) return v < 0 ? 0 : v.toInt();
  return 0;
}

bool _atLeast(String version, int major, int minor) {
  final parts = version.split('.');
  final a = int.tryParse(parts.isNotEmpty ? parts[0] : '') ?? 0;
  final b = int.tryParse(parts.length > 1 ? parts[1] : '') ?? 0;
  return a > major || (a == major && b >= minor);
}
