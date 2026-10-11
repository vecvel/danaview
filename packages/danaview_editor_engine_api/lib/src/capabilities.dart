// OWNER: API-01
//
// Device capabilities (ARCH §12.5, D-14, D-22, D-40). Cached by the engine after the first call.

import 'dart:ui' show Size;

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

/// Device tier (ARCH §12.5): minimal < 3 GB RAM (D-40), low 3–4 GB, mid 4–6 GB, high ≥ 8 GB or
/// iOS A15+ with 6 GB.
enum DeviceTier {
  /// iOS A9–A11 2 GB, Android < 3 GB or `isLowRamDevice`: proxies forced, 2 video layers,
  /// 3 visual sequences, preview ≤ 640 px, export ≤ 1080p H.264, Fast captions only.
  minimal,

  /// iPhone X/SE 2, Android ≤ 4 GB.
  low,

  /// 4–6 GB.
  mid,

  /// ≥ 8 GB, or iOS A15+ with 6 GB.
  high,
}

/// What happens to an export when the app goes to the background (D-22).
///
/// See ARCH §12.5, D-22.
enum BackgroundExportKind {
  /// Exports stop and fail when backgrounded.
  none,

  /// iPhone: stops at background, resumes from the last complete segment on return.
  paused,

  /// iPad on iOS 26+ with background GPU: `BGContinuedProcessingTask`.
  continued,

  /// Android: foreground service (`mediaProcessing` API 35+, `dataSync` 29–34).
  foregroundService,
}

/// Reasons `EditorCapabilities.unsupportedReason` may carry.
///
/// See ARCH §12.5, D-17.
abstract final class UnsupportedReasons {
  /// Android below API 29.
  static const String androidTooOld = 'android_too_old';

  /// No GLES 3.0 context.
  static const String gles3Missing = 'gles3_missing';

  /// Less than 2 GB RAM.
  static const String insufficientMemory = 'insufficient_memory';

  /// No Metal device.
  static const String metalMissing = 'metal_missing';

  /// Desktop or another platform without an engine (D-17).
  static const String platform = 'platform';

  /// The native engine is not built in this app version (scaffold placeholder).
  static const String engineNotAvailable = 'engine_not_available';
}

/// What this device's engine can do.
///
/// See ARCH §12.5.
@immutable
final class EditorCapabilities {
  /// Creates capabilities.
  const EditorCapabilities({
    required this.supported,
    this.unsupportedReason,
    this.tier = DeviceTier.low,
    this.lowMemoryDevice = false,
    this.h264Encode = true,
    this.hevcEncode = false,
    this.hardwareH264 = true,
    this.hardwareHevc = false,
    this.movContainer = false,
    this.maxExportSize = const Size(1920, 1080),
    this.maxFpsByHeight = const {1080: 60, 2160: 30},
    this.maxConcurrentVideoLayers = 3,
    this.maxVisualSequences = 4,
    this.maxTextureSize = 4096,
    this.maxPreviewLongSide = 960,
    this.backgroundKind = BackgroundExportKind.none,
    this.backgroundGpu = false,
    this.voiceRecording = true,
    this.proxiesRecommended = false,
    this.holdFrame = true,
    this.fpsUpconversion = true,
    this.externalDrop = false,
    this.minSpeed = 0.1,
    this.maxSpeed = 10,
    this.maxAudioSpeed = 4,
    this.maxLutSize = 65,
    this.planVersions = const [1],
  });

  /// Capabilities of a device or platform that cannot edit.
  factory EditorCapabilities.unsupported(String reason) => EditorCapabilities(
        supported: false,
        unsupportedReason: reason,
        tier: DeviceTier.minimal,
        h264Encode: false,
        hardwareH264: false,
        maxExportSize: Size.zero,
        maxFpsByHeight: const {},
        maxConcurrentVideoLayers: 0,
        maxVisualSequences: 0,
        voiceRecording: false,
        planVersions: const [],
      );

  /// Whether the editor can run (Android API 29 + GLES 3 + 2 GB; iOS Metal).
  final bool supported;

  /// Why not (see [UnsupportedReasons]).
  final String? unsupportedReason;

  /// Device tier.
  final DeviceTier tier;

  /// The player is released while editing (minimal tier and 3 GB devices).
  final bool lowMemoryDevice;

  /// H.264 encode available.
  final bool h264Encode;

  /// HEVC encode available (hardware only, D-23).
  final bool hevcEncode;

  /// H.264 encoder is hardware.
  final bool hardwareH264;

  /// HEVC encoder is hardware.
  final bool hardwareHevc;

  /// MOV container (iOS only).
  final bool movContainer;

  /// Largest export size.
  final Size maxExportSize;

  /// Highest export fps by output short side.
  final Map<int, int> maxFpsByHeight;

  /// Cap 1 (D-14): concurrent decoder-backed video layers at any instant (2/3/4/6).
  final int maxConcurrentVideoLayers;

  /// Cap 2 (D-14): visual sequences after packing (Android 3/4/6/8 from AND-01; iOS 16).
  final int maxVisualSequences;

  /// `GL_MAX_TEXTURE_SIZE` on Android, 16384 on iOS Metal (sprite raster clamp, ARCH §10.3).
  final int maxTextureSize;

  /// Preview render cap on the long side (640/960/1280/1920).
  final int maxPreviewLongSide;

  /// Background export behaviour (honest per device, D-22).
  final BackgroundExportKind backgroundKind;

  /// Background GPU available (iPad iOS 26+ with the entitlement).
  final bool backgroundGpu;

  /// Microphone recording available.
  final bool voiceRecording;

  /// Proxies recommended by default.
  final bool proxiesRecommended;

  /// `hold: true` media layers supported (pending freeze stills).
  final bool holdFrame;

  /// Export fps above the source rate honoured (AND-01).
  final bool fpsUpconversion;

  /// External drag and drop available (D-18).
  final bool externalDrop;

  /// Lowest clip speed.
  final double minSpeed;

  /// Highest clip speed.
  final double maxSpeed;

  /// Above this, audio is muted for the span (D-15).
  final double maxAudioSpeed;

  /// Largest `.vlut` N.
  final int maxLutSize;

  /// RenderPlan versions the engine decodes.
  final List<int> planVersions;

  /// A copy with the given fields replaced (tests and fakes). Pass `unsupportedReason: null`
  /// explicitly to clear the reason.
  EditorCapabilities copyWith({
    bool? supported,
    Object? unsupportedReason = _keep,
    DeviceTier? tier,
    bool? lowMemoryDevice,
    bool? h264Encode,
    bool? hevcEncode,
    bool? hardwareH264,
    bool? hardwareHevc,
    bool? movContainer,
    Size? maxExportSize,
    Map<int, int>? maxFpsByHeight,
    int? maxConcurrentVideoLayers,
    int? maxVisualSequences,
    int? maxTextureSize,
    int? maxPreviewLongSide,
    BackgroundExportKind? backgroundKind,
    bool? backgroundGpu,
    bool? voiceRecording,
    bool? proxiesRecommended,
    bool? holdFrame,
    bool? fpsUpconversion,
    bool? externalDrop,
    double? minSpeed,
    double? maxSpeed,
    double? maxAudioSpeed,
    int? maxLutSize,
    List<int>? planVersions,
  }) =>
      EditorCapabilities(
        supported: supported ?? this.supported,
        unsupportedReason: identical(unsupportedReason, _keep) ? this.unsupportedReason : unsupportedReason as String?,
        tier: tier ?? this.tier,
        lowMemoryDevice: lowMemoryDevice ?? this.lowMemoryDevice,
        h264Encode: h264Encode ?? this.h264Encode,
        hevcEncode: hevcEncode ?? this.hevcEncode,
        hardwareH264: hardwareH264 ?? this.hardwareH264,
        hardwareHevc: hardwareHevc ?? this.hardwareHevc,
        movContainer: movContainer ?? this.movContainer,
        maxExportSize: maxExportSize ?? this.maxExportSize,
        maxFpsByHeight: maxFpsByHeight ?? this.maxFpsByHeight,
        maxConcurrentVideoLayers: maxConcurrentVideoLayers ?? this.maxConcurrentVideoLayers,
        maxVisualSequences: maxVisualSequences ?? this.maxVisualSequences,
        maxTextureSize: maxTextureSize ?? this.maxTextureSize,
        maxPreviewLongSide: maxPreviewLongSide ?? this.maxPreviewLongSide,
        backgroundKind: backgroundKind ?? this.backgroundKind,
        backgroundGpu: backgroundGpu ?? this.backgroundGpu,
        voiceRecording: voiceRecording ?? this.voiceRecording,
        proxiesRecommended: proxiesRecommended ?? this.proxiesRecommended,
        holdFrame: holdFrame ?? this.holdFrame,
        fpsUpconversion: fpsUpconversion ?? this.fpsUpconversion,
        externalDrop: externalDrop ?? this.externalDrop,
        minSpeed: minSpeed ?? this.minSpeed,
        maxSpeed: maxSpeed ?? this.maxSpeed,
        maxAudioSpeed: maxAudioSpeed ?? this.maxAudioSpeed,
        maxLutSize: maxLutSize ?? this.maxLutSize,
        planVersions: planVersions ?? this.planVersions,
      );

  static const Object _keep = Object();

  @override
  bool operator ==(Object other) =>
      other is EditorCapabilities &&
      other.supported == supported &&
      other.unsupportedReason == unsupportedReason &&
      other.tier == tier &&
      other.lowMemoryDevice == lowMemoryDevice &&
      other.h264Encode == h264Encode &&
      other.hevcEncode == hevcEncode &&
      other.hardwareH264 == hardwareH264 &&
      other.hardwareHevc == hardwareHevc &&
      other.movContainer == movContainer &&
      other.maxExportSize == maxExportSize &&
      const MapEquality<int, int>().equals(other.maxFpsByHeight, maxFpsByHeight) &&
      other.maxConcurrentVideoLayers == maxConcurrentVideoLayers &&
      other.maxVisualSequences == maxVisualSequences &&
      other.maxTextureSize == maxTextureSize &&
      other.maxPreviewLongSide == maxPreviewLongSide &&
      other.backgroundKind == backgroundKind &&
      other.backgroundGpu == backgroundGpu &&
      other.voiceRecording == voiceRecording &&
      other.proxiesRecommended == proxiesRecommended &&
      other.holdFrame == holdFrame &&
      other.fpsUpconversion == fpsUpconversion &&
      other.externalDrop == externalDrop &&
      other.minSpeed == minSpeed &&
      other.maxSpeed == maxSpeed &&
      other.maxAudioSpeed == maxAudioSpeed &&
      other.maxLutSize == maxLutSize &&
      const ListEquality<int>().equals(other.planVersions, planVersions);

  @override
  int get hashCode => Object.hashAll([
        supported,
        unsupportedReason,
        tier,
        lowMemoryDevice,
        h264Encode,
        hevcEncode,
        hardwareH264,
        hardwareHevc,
        movContainer,
        maxExportSize,
        maxFpsByHeight.entries.fold<int>(0, (acc, e) => acc ^ Object.hash(e.key, e.value)),
        maxConcurrentVideoLayers,
        maxVisualSequences,
        maxTextureSize,
        maxPreviewLongSide,
        backgroundKind,
        backgroundGpu,
        voiceRecording,
        proxiesRecommended,
        holdFrame,
        fpsUpconversion,
        externalDrop,
        minSpeed,
        maxSpeed,
        maxAudioSpeed,
        maxLutSize,
        Object.hashAll(planVersions),
      ]);
}
