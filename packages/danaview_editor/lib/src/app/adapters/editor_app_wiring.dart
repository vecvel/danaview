// OWNER: INT-04
//
// App wiring v2 (ARCH §4.1, §16, §17.1, §17.10; D-28): what the app root adds on top of INT-02's
// `EditorBootstrap.overridesFor`.
//
// * [EditorAppWiring.transcriptionService] builds the real `TranscriptionServiceImpl`: the model
//   store and speech folders under `<support>/danaview/speech`, the engine adapters
//   ([EngineSpeechAudioExtractor], [EngineBackgroundLeaseProvider]) and a `ResourceGovernor` over
//   the device signals the app root supplies (the danaview_whisper device channel merged with
//   `engine.signals`; danaview_editor never imports danaview_whisper, ARCH §4.2 rule 7) and the
//   engine's export state ([EngineExportActivity]).
// * [EditorAppWiring.overrides] returns the overrides the app appends AFTER
//   `EditorBootstrap.overridesFor` (a later override of the same provider wins): the
//   transcription service, the Auto captions host (privacy link), the export host (Play in
//   Danaview, Free up space) and the Settings › Storage contributors, which now pass the service to
//   the cache-in-use check and add the "Speech model" row (SpeechStorageContributor, UX-38).
//
// Desktop never reaches this file: `EditorBootstrap.unavailable()` keeps every contributor and the
// service away (D-17).

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';
import 'package:danaview_features/storage.dart' show StorageContributor, storageContributorsProvider;
import 'package:danaview_transcription/danaview_transcription.dart';

import '../../editor/flows/captions/auto_captions_controller.dart' show AutoCaptionsHost, autoCaptionsHostProvider;
import '../../editor/flows/export/export_environment.dart' show ExportHost, exportHostProvider;
import '../editor_availability.dart' show EditorFlags;
import '../editor_bootstrap.dart';
import '../editor_providers.dart' show transcriptionServiceProvider;
import '../editor_storage_contributor.dart';
import '../speech_storage_contributor.dart';
import 'engine_background_lease_provider.dart';
import 'engine_export_activity.dart';
import 'engine_speech_audio_extractor.dart';

export '../../editor/flows/captions/auto_captions_controller.dart' show AutoCaptionsHost, autoCaptionsHostProvider;
export '../../editor/flows/export/export_environment.dart' show ExportHost, exportHostProvider;

/// Builds the service from the parts [EditorAppWiring.transcriptionService] wired (a test seam).
typedef AutoCaptionsServiceFactory = TranscriptionServiceImpl Function({
  required SpeechModelStore store,
  required SpeechAudioExtractor extractor,
  required ResourceGovernor governor,
  required BackgroundLeaseProvider leases,
});

/// The Auto captions service and its parts, as built by [EditorAppWiring.transcriptionService].
final class AutoCaptionsRuntime {
  AutoCaptionsRuntime._({required this.service, required this.store, required this.governor, required this.exports});

  /// The service the editor flows use.
  final TranscriptionServiceImpl service;

  /// The model store under `<support>/danaview/speech/models`.
  final FileSpeechModelStore store;

  /// Thread, thermal, memory, export and lifecycle policy.
  final ResourceGovernor governor;

  /// The engine's export state, as the governor sees it.
  final EngineExportActivity exports;

  /// Cancels a running job and stops every listener.
  Future<void> dispose() async {
    await service.dispose();
    await governor.dispose();
    await exports.dispose();
  }
}

/// The app root's editor wiring beyond INT-02 (see the file header).
abstract final class EditorAppWiring {
  /// Whether Auto captions are wired in this build (`DANAVIEW_AUTO_CAPTIONS`, D-31).
  static bool get autoCaptionsEnabled => EditorFlags.autoCaptionsEnabled;

  /// Builds the Auto captions service for [engine] with its folders under [supportDirectory] (the
  /// app support directory; `StoreRoots.support`).
  ///
  /// [device] supplies the device profile and the thermal, low-power, lifecycle and memory signals
  /// (production: the danaview_whisper device channel merged with `engine.signals`), and
  /// [storePlatform] the free space, backup exclusion and iOS background tasks of the downloader.
  /// [appVersion] goes into the download's `User-Agent` (no identifiers, ARCH §16.3). The other
  /// parameters are test seams: [createService] builds the service from the wired parts (tests
  /// inject a whisper runtime there, which danaview_editor cannot name), [downloaderConfig]
  /// replaces the production downloader settings.
  static AutoCaptionsRuntime transcriptionService({
    required EditorEngine engine,
    required String supportDirectory,
    required DeviceResources device,
    required ModelStorePlatform storePlatform,
    String appVersion = '0',
    SpeechPlatform? platform,
    ModelDownloaderConfig? downloaderConfig,
    AutoCaptionsServiceFactory? createService,
    EngineExportActivity? exports,
  }) {
    final exportActivity = exports ?? EngineExportActivity(engine.exporter);
    final governor = ResourceGovernor(device: device, exports: exportActivity, platform: platform);
    late final TranscriptionServiceImpl service;
    final store = FileSpeechModelStore(
      supportDirectory: supportDirectory,
      platform: storePlatform,
      // The Auto captions flow holds the screen wakelock through download and job (AutoCaptionsHost);
      // the store's own wakelock would release it between the two, so it stays a no-op here.
      isModelInUse: () => service.activeJob != null,
      config: downloaderConfig ?? ModelDownloaderConfig(appVersion: appVersion),
    );
    final extractor = EngineSpeechAudioExtractor(engine);
    final leases = EngineBackgroundLeaseProvider(engine);
    service = createService != null
        ? createService(store: store, extractor: extractor, governor: governor, leases: leases)
        : TranscriptionServiceImpl(
            supportDirectory: supportDirectory,
            store: store,
            extractor: extractor,
            governor: governor,
            leases: leases,
          );
    return AutoCaptionsRuntime._(service: service, store: store, governor: governor, exports: exportActivity);
  }

  /// The overrides the app appends after `EditorBootstrap.overridesFor(runtime, …)`.
  ///
  /// [transcription] is the Auto captions service (null when Auto captions are off: no service, no
  /// "Speech model" row). [onOpenProjects] is the router's navigation to Projects; without it no
  /// storage contributor is listed (as in INT-02). [onOpenPrivacyPolicy] opens Settings › Privacy
  /// from the consent view; [exportHost] supplies the export flow's navigation.
  static List<Override> overrides({
    required EditorRuntime runtime,
    TranscriptionService? transcription,
    void Function(BuildContext context)? onOpenProjects,
    VoidCallback? onOpenPrivacyPolicy,
    ExportHost exportHost = const ExportHost(),
  }) =>
      [
        if (transcription != null) transcriptionServiceProvider.overrideWithValue(transcription),
        autoCaptionsHostProvider.overrideWithValue(AutoCaptionsHost(onOpenPrivacyPolicy: onOpenPrivacyPolicy)),
        exportHostProvider.overrideWithValue(exportHost),
        storageContributorsProvider.overrideWithValue(
          storageContributors(runtime: runtime, transcription: transcription, onOpenProjects: onOpenProjects),
        ),
      ];

  /// Settings › Storage rows of the editor: projects, cache (in use while a captions job runs) and,
  /// with [transcription], the speech model (ARCH §17.10). Empty without [onOpenProjects].
  static List<StorageContributor> storageContributors({
    required EditorRuntime runtime,
    TranscriptionService? transcription,
    void Function(BuildContext context)? onOpenProjects,
  }) {
    if (onOpenProjects == null) return const <StorageContributor>[];
    final engine = runtime.engine;
    final repository = runtime.repository;
    return [
      ...EditorStorageContributor.all(
        repository: repository,
        cache: EditorCacheCleaner(roots: runtime.roots, trimEngine: () => engine.trimCaches(CacheTrimLevel.clearAll)),
        cacheUse: editorCacheUseOf(openProjects: () => repository.openIds, exporter: engine.exporter, transcription: transcription),
        onOpenProjects: onOpenProjects,
      ),
      if (transcription != null) SpeechStorageContributor(service: transcription),
    ];
  }
}
