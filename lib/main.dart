import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:danaview_data/danaview_data.dart';
import 'package:danaview_editor/danaview_editor.dart';
import 'package:danaview_editor_engine/danaview_editor_engine.dart';
import 'package:danaview_engine/danaview_engine.dart';
import 'package:danaview_features/danaview_features.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart'
    show EditorEngine, EngineSignal, MemoryWarningSignal, ThermalSignal;
import 'package:danaview_platform/danaview_platform.dart';
import 'package:danaview_transcription/danaview_transcription.dart'
    show DeviceResources, ModelDownloaderConfig, ModelStorePlatform, TranscriptionService, WhisperDeviceModelStorePlatform, WhisperDeviceResources;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:danaview_whisper/danaview_whisper.dart';
import 'app.dart';
import 'router/app_router.dart' show appExportHost, openPrivacyPolicy, openProjects;

Future<void> main([List<String> args = const []]) async {
  WidgetsFlutterBinding.ensureInitialized();

  IncomingMediaBridge.setLaunchArgs(args);
  await PlatformBridge.initializeWindow();
  if (PlatformBridge.isMobile) await PlayerOrientation.applyAppDefault();

  // The app is dark everywhere; without an AppBar nothing else sets light status bar icons.
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Color(0x00000000),
    statusBarBrightness: Brightness.dark,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: DanaviewColors.background,
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  final prefs = await SharedPreferences.getInstance();
  final sessionRepo = SessionRepository(prefs);
  final libraryRepo = LibraryRepository(prefs);
  await sessionRepo.migrateMediaIds(libraryRepo.resolveStoredPath);

  final engine = MpvPlaybackEngine(subtitleFontAssets: DanaviewFonts.files);
  await engine.initialize();

  final editorOverrides = await _editorOverrides();

  runApp(
    ProviderScope(
      overrides: [
        playbackEngineProvider.overrideWithValue(engine),
        sessionRepositoryProvider.overrideWithValue(sessionRepo),
        libraryRepositoryProvider.overrideWithValue(libraryRepo),
        ...editorOverrides,
      ],
      child: const DanaviewApp(),
    ),
  );
}

/// The video editor's overrides (ARCH §4.1): on iOS/Android with `DANAVIEW_EDITOR` the app constructs
/// the platform engine, `EditorBootstrap` wires the store, pool, GC and plan compiler, and
/// [editorAppOverrides] adds Auto captions, the flows' hosts and the storage rows (INT-04);
/// everywhere else (desktop, flag off) the editor stays hidden (D-17, D-31).
Future<List<Override>> _editorOverrides() async {
  if (EditorAvailability.platform is! EditorSupported) return EditorBootstrap.unavailable();
  try {
    final roots = await EditorBootstrap.defaultRoots();
    final editorEngine = MobileEditorEngine(config: EditorBootstrap.engineConfigOf(roots));
    final runtime = await EditorBootstrap.createRuntime(engine: editorEngine, roots: roots, prefs: await EditorPrefs.load());
    final captions = EditorAppWiring.autoCaptionsEnabled ? createAutoCaptions(engine: editorEngine, supportDirectory: roots.support) : null;
    if (captions != null) unawaited(captions.service.initialize());
    return editorAppOverrides(runtime, transcription: captions?.service);
  } catch (e) {
    debugPrint('[main] Video editor unavailable: $e');
    return EditorBootstrap.unavailable();
  }
}

/// Every editor override of a wired [runtime]: INT-02's `EditorBootstrap.overridesFor`, then (later
/// overrides win) the Auto captions service [transcription] (null when Auto captions are off), the consent view's privacy link, the export host and
/// the Settings › Storage rows including "Speech model" (ARCH §17.10).
List<Override> editorAppOverrides(EditorRuntime runtime, {TranscriptionService? transcription}) => [
      ...EditorBootstrap.overridesFor(runtime, onOpenProjects: openProjects),
      ...EditorAppWiring.overrides(
        runtime: runtime,
        transcription: transcription,
        onOpenProjects: openProjects,
        onOpenPrivacyPolicy: openPrivacyPolicy,
        exportHost: appExportHost,
      ),
    ];

/// The Auto captions service of the app (ARCH §16): speech folders under
/// `<supportDirectory>/danaview/speech`, the engine adapters (D-28), and a governor fed by the
/// danaview_whisper device channel and the engine's memory and thermal signals. [channel],
/// [storePlatform], [createService] and [downloaderConfig] are test seams.
AutoCaptionsRuntime createAutoCaptions({
  required EditorEngine engine,
  required String supportDirectory,
  WhisperDeviceChannel? channel,
  ModelStorePlatform? storePlatform,
  AutoCaptionsServiceFactory? createService,
  ModelDownloaderConfig? downloaderConfig,
}) {
  final device = channel ?? WhisperDeviceChannel();
  return EditorAppWiring.transcriptionService(
    engine: engine,
    supportDirectory: supportDirectory,
    device: EngineSignalDeviceResources(WhisperDeviceResources(device), engine.signals),
    storePlatform: storePlatform ?? WhisperDeviceModelStorePlatform(device),
    appVersion: danaviewAppVersion,
    createService: createService,
    downloaderConfig: downloaderConfig,
  );
}

/// The governor's [DeviceResources]: [device] (the danaview_whisper channel) with the engine's
/// [signals] merged into its events, so a memory warning or thermal change the engine sees (for
/// example during preview or export) also reaches Auto captions.
final class EngineSignalDeviceResources implements DeviceResources {
  /// Creates the adapter.
  EngineSignalDeviceResources(this.device, this.signals);

  /// The plugin's device facts and events.
  final DeviceResources device;

  /// `EditorEngine.signals`.
  final Stream<EngineSignal> signals;

  Stream<WhisperDeviceEvent>? _events;

  /// The whisper event for an engine signal.
  static WhisperDeviceEvent eventOf(EngineSignal signal) => switch (signal) {
        MemoryWarningSignal() => const MemoryWarning(),
        ThermalSignal(:final level) => ThermalChanged(ThermalLevel.values.byName(level.name)),
      };

  @override
  Future<WhisperDeviceProfile> profile() => device.profile();

  @override
  Future<int?> availableMemory() => device.availableMemory();

  @override
  Future<int?> freeDiskBytes(String path) => device.freeDiskBytes(path);

  @override
  Stream<WhisperDeviceEvent> get events => _events ??= _merge();

  Stream<WhisperDeviceEvent> _merge() {
    late final StreamController<WhisperDeviceEvent> out;
    final subs = <StreamSubscription<Object?>>[];
    out = StreamController<WhisperDeviceEvent>.broadcast(
      onListen: () {
        subs
          ..add(device.events.listen(out.add, onError: (Object _) {}))
          ..add(signals.listen((s) => out.add(eventOf(s)), onError: (Object _) {}));
      },
      onCancel: () async {
        for (final sub in subs) {
          await sub.cancel();
        }
        subs.clear();
      },
    );
    return out.stream;
  }
}
