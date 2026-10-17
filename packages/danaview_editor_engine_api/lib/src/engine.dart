// OWNER: API-01
//
// The engine root (ARCH §12.1). Implemented by `MobileEditorEngine` (danaview_editor_engine,
// iOS + Android) and by `FakeEditorEngine` (tests). A later desktop engine implements the same
// interface (ARCH §25, G7). Only the app root constructs implementations (ARCH §4.1).

import 'package:meta/meta.dart';
import 'package:danaview_editor_core/model.dart';

import 'capabilities.dart';
import 'export.dart';
import 'media_services.dart';
import 'platform_services.dart';
import 'preview.dart';
import 'recorder.dart';

/// Media resolved for the engine (D-27: one type, defined in core).
///
/// See ARCH §12.1, D-27.
typedef EngineMedia = ResolvedMedia;

/// Whether a file can be edited on this device (≤ 300 ms).
///
/// See ARCH §12.1.
@immutable
sealed class EditCompatibility {
  const EditCompatibility();
}

/// The file can be edited.
///
/// See ARCH §12.1.
final class Editable extends EditCompatibility {
  /// Creates the result.
  const Editable();
}

/// The file cannot be edited here; [code] selects platform-specific copy (UX-41).
///
/// See ARCH §12.1.
final class NotEditable extends EditCompatibility {
  /// Creates the result.
  const NotEditable(this.code, [this.message = '']);

  /// `container_unsupported_ios`, `codec_unsupported`, `protected_content`, `not_found`, …
  final String code;

  /// Diagnostic detail (no paths).
  final String message;
}

/// How much cached data to drop.
///
/// See ARCH §12.1, §18.3.
enum CacheTrimLevel {
  /// Memory pressure: shrink in-memory caches to 25%.
  memoryPressure,

  /// App backgrounded: release GPU intermediates.
  background,

  /// "Clear editor cache": delete regenerable disk caches not pinned by a session.
  clearAll,
}

/// Thermal state reported by the OS.
///
/// See ARCH §12.1, §18.2.
enum ThermalLevel {
  /// Normal.
  nominal,

  /// Slightly elevated.
  fair,

  /// Serious: preview forced to ≤ half quality.
  serious,

  /// Critical: export pumps pause.
  critical,
}

/// Engine-wide signals.
///
/// See ARCH §12.1.
@immutable
sealed class EngineSignal {
  const EngineSignal();
}

/// The OS reported memory pressure.
///
/// See ARCH §12.1.
final class MemoryWarningSignal extends EngineSignal {
  /// Creates the signal.
  const MemoryWarningSignal();
}

/// The thermal state changed.
///
/// See ARCH §12.1.
final class ThermalSignal extends EngineSignal {
  /// Creates the signal.
  const ThermalSignal(this.level);

  /// New level.
  final ThermalLevel level;
}

/// The editor's rendering engine.
///
/// See ARCH §12.1.
abstract interface class EditorEngine {
  /// Device capabilities (cached after the first call).
  Future<EditorCapabilities> capabilities();

  /// Whether [pathOrUri] can be edited here (≤ 300 ms).
  Future<EditCompatibility> compatibility(String pathOrUri);

  /// Probes one media file.
  Future<MediaProbe> probe(EngineMedia media);

  /// Opens a live preview bound to a new texture.
  Future<PreviewSession> openPreview(PreviewConfig config);

  /// Thumbnail strips.
  ThumbnailSource get thumbnails;

  /// Waveforms.
  WaveformSource get waveforms;

  /// Proxies, reverse renditions, freeze stills, speech audio.
  MediaJobs get jobs;

  /// Export.
  ExportService get exporter;

  /// Voice recorder; null when `!capabilities.voiceRecording`.
  VoiceRecorder? get voiceRecorder;

  /// System pickers.
  MediaPicker get picker;

  /// Export handoff.
  FileHandoff get files;

  /// Media access (implements core `MediaAccessPort`).
  MediaAccess get access;

  /// Background leases.
  BackgroundWorkGuard get background;

  /// External drops.
  ExternalDropTarget get drops;

  /// Free bytes on the volume of [path].
  Future<int> freeBytes(String path);

  /// Memory and thermal signals.
  Stream<EngineSignal> get signals;

  /// Drops cached data.
  Future<void> trimCaches(CacheTrimLevel level);
}
