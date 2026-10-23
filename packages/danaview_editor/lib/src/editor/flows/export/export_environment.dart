// OWNER: UX-39
//
// What the export flow needs from the app besides the open editor session (ARCH §14.1, §4.1):
//
// * [ExportEnvironment]: the storage roots, the file system, `DocumentsExportWriter` (the only code
//   writing into `Documents`, D-44), `OwnedFileDeleter` (the only delete path, D-44), the sprite
//   pre-pass runner (API-04 `SpritePrepass`), the resolver of ORIGINAL media for `compileExport`,
//   the clock, the platform and the screen wakelock. `exportEnvironmentProvider` builds it from the
//   wired `EditorRuntime` (INT-02) so the app needs no extra wiring; tests override the provider.
// * [ExportHost]: optional navigation callbacks the router supplies (INT-04): Play in Danaview, Free up
//   space and Open Settings. A missing callback hides its button; the message still says what to do.
// * [exportCapabilitiesOf]: engine `EditorCapabilities` -> core `ExportCapabilities`.

import 'dart:async';
import 'dart:isolate';
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/eval.dart' show TextMetricsProvider;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/plan.dart';
import 'package:danaview_editor_core/store.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart'
    show EditorCapabilities, FontResolver, SpritePrepass, TextLayoutEngine, TextSpriteRasterizer;
import 'package:danaview_platform/danaview_platform.dart' show PlatformBridge;

import '../../../app/editor_bootstrap.dart' show editorRuntimeProvider;
import '../../../app/editor_providers.dart' show EditorNotConfiguredError;
import '../../../app/export_output_sweeper.dart' show ExportOutputLeases;
import '../../state/default_plan_compiler.dart' show DefaultSessionPlanCompiler;
import '../../state/editor_session.dart';
import '../../state/plan_compiler_port.dart' show ResolvingSessionPlanCompiler;
import '../../text/font_catalog.dart' show FontCatalog, fontCatalogProvider;

/// Core export capabilities of a device (ARCH §12.5 -> core `ExportCapabilities`).
ExportCapabilities exportCapabilitiesOf(EditorCapabilities c) {
  final Size size = c.maxExportSize;
  final long = size.width > size.height ? size.width : size.height;
  final short = size.width > size.height ? size.height : size.width;
  return ExportCapabilities(
    h264Encode: c.h264Encode,
    hevcEncode: c.hevcEncode,
    movContainer: c.movContainer,
    maxExportLongSide: long.round(),
    maxExportShortSide: short.round(),
    maxFpsByHeight: c.maxFpsByHeight,
    maxTextureSize: c.maxTextureSize,
    maxAudioSpeed: c.maxAudioSpeed,
    holdFrame: c.holdFrame,
  );
}

/// Runs the sprite pre-pass (API-04) for the export and measures text with the same layout engine.
abstract interface class ExportSpriteRunner {
  /// The metrics provider to pass to `exportSpriteRequests`, or null (estimates are used).
  TextMetricsProvider? get metrics;

  /// Rasterizes the missing sprites of [requests] into [cacheDir] and returns the manifest.
  /// Throws `SpritePrepassCancelled` when [isCancelled] turns true.
  Future<SpriteManifest> run(
    List<SpriteRequest> requests, {
    required String cacheDir,
    void Function(double fraction)? onProgress,
    bool Function()? isCancelled,
  });
}

/// [ExportSpriteRunner] over API-04's [SpritePrepass].
final class PrepassSpriteRunner implements ExportSpriteRunner {
  /// Wraps [prepass].
  PrepassSpriteRunner(this.prepass);

  /// The pre-pass.
  final SpritePrepass prepass;

  @override
  TextMetricsProvider get metrics => prepass.rasterizer.engine;

  @override
  Future<SpriteManifest> run(
    List<SpriteRequest> requests, {
    required String cacheDir,
    void Function(double fraction)? onProgress,
    bool Function()? isCancelled,
  }) =>
      prepass.run(requests, cacheDir: cacheDir, onProgress: onProgress, isCancelled: isCancelled);
}

/// Everything one `compileExport` call needs (sent to an isolate for large projects).
@immutable
final class ExportCompileInput {
  /// Creates the input.
  const ExportCompileInput({
    required this.project,
    required this.settings,
    required this.manifest,
    required this.resolver,
    required this.capabilities,
    required this.spriteRequests,
  });

  /// The committed project.
  final EditProject project;

  /// User-level settings.
  final ExportSettings settings;

  /// Sprites from the pre-pass.
  final SpriteManifest manifest;

  /// Original-media resolver.
  final PlanAssetResolver resolver;

  /// Device capabilities.
  final ExportCapabilities capabilities;

  /// The requests the pre-pass handled (the same list).
  final List<SpriteRequest> spriteRequests;
}

/// Compiles the export plan (CORE-33).
typedef ExportCompile = Future<ExportCompileResult> Function(ExportCompileInput input);

/// Items above which the compile runs in an isolate (ARCH §18.1, like the preview compiler).
const int exportIsolateItemThreshold = 300;

/// The default [ExportCompile]: inline, or `Isolate.run` for large projects (falling back inline
/// when the inputs cannot be sent).
Future<ExportCompileResult> defaultExportCompile(ExportCompileInput input) async {
  ExportCompileResult run() => compileExport(
        input.project,
        input.settings,
        input.manifest,
        resolver: input.resolver,
        capabilities: input.capabilities,
        spriteRequests: input.spriteRequests,
      );
  final items = input.project.timeline.tracks.fold<int>(0, (n, t) => n + t.items.length);
  if (items <= exportIsolateItemThreshold) return run();
  try {
    return await Isolate.run(run);
  } on Object catch (e) {
    debugPrint('[Export] Compile isolate failed (${e.runtimeType}); compiling inline');
    return run();
  }
}

/// Resolves the ORIGINAL media of the session's project for an export (never proxies).
typedef ExportAssetResolver = Future<PlanAssetResolver> Function(EditorSession session, EditProject project);

/// The default [ExportAssetResolver]: refreshes the session's resolver (INT-02's
/// `DefaultSessionPlanCompiler`) or reads the resolving compiler's; nothing resolves otherwise.
Future<PlanAssetResolver> defaultExportAssetResolver(EditorSession session, EditProject project) async {
  final compiler = session.compiler;
  if (compiler is DefaultSessionPlanCompiler) return compiler.assets.refresh(project);
  if (compiler is ResolvingSessionPlanCompiler) return compiler.resolver(project);
  return MapPlanAssetResolver.empty;
}

/// Holds or releases the screen wakelock (ux.md §11.4: held while an export runs).
typedef ExportWakelock = void Function(bool on);

/// The collaborators of the export flow.
final class ExportEnvironment {
  /// Creates an environment.
  const ExportEnvironment({
    required this.roots,
    required this.fs,
    required this.documentsWriter,
    required this.deleter,
    required this.spriteRunner,
    this.resolveAssets = defaultExportAssetResolver,
    this.compile = defaultExportCompile,
    this.platform,
    this.now = DateTime.now,
    this.wakelock = _defaultWakelock,
    this.newToken = _defaultToken,
    this.notificationPermissionTimeout = defaultNotificationPermissionTimeout,
    this.outputLeases,
    this.onJobEnded,
  });

  /// The default of [notificationPermissionTimeout].
  static const Duration defaultNotificationPermissionTimeout = Duration(seconds: 10);

  /// The environment over the app's storage roots and the local file system. Export sprites lay
  /// text out with [fontResolver] (default: UX-30's `FontCatalog.instance`), the resolver of the
  /// preview overlay, so the exported text uses the chosen content font (FIX-FONTS).
  factory ExportEnvironment.local(
    StoreRoots roots, {
    StoreFs fs = const LocalStoreFs(),
    FontResolver? fontResolver,
    ExportAssetResolver resolveAssets = defaultExportAssetResolver,
    ExportCompile compile = defaultExportCompile,
    ExportWakelock wakelock = _defaultWakelock,
    ExportOutputLeases? outputLeases,
    void Function()? onJobEnded,
  }) =>
      ExportEnvironment(
        roots: roots,
        fs: fs,
        documentsWriter: DocumentsExportWriter(roots, fs: fs),
        deleter: OwnedFileDeleter(roots, fs: fs),
        spriteRunner: (caps) => PrepassSpriteRunner(
          SpritePrepass(
            rasterizer: TextSpriteRasterizer(engine: TextLayoutEngine(fontResolver: fontResolver ?? FontCatalog.instance.resolve)),
            maxTextureSize: caps.maxTextureSize,
            fs: fs,
          ),
        ),
        resolveAssets: resolveAssets,
        compile: compile,
        wakelock: wakelock,
        outputLeases: outputLeases,
        onJobEnded: onJobEnded,
      );

  /// App roots.
  final StoreRoots roots;

  /// File access for caption side files.
  final StoreFs fs;

  /// The only writer into `Documents` (D-44).
  final DocumentsExportWriter documentsWriter;

  /// The only delete path (D-44).
  final OwnedFileDeleter deleter;

  /// The sprite pre-pass for a device.
  final ExportSpriteRunner Function(EditorCapabilities caps) spriteRunner;

  /// Original-media resolver.
  final ExportAssetResolver resolveAssets;

  /// Plan compile.
  final ExportCompile compile;

  /// The platform for iOS-specific estimates; null reads `defaultTargetPlatform`.
  final TargetPlatform? platform;

  /// The clock.
  final DateTime Function() now;

  /// The wakelock.
  final ExportWakelock wakelock;

  /// A unique token for output names (`export-<token>.mp4`).
  final String Function() newToken;

  /// How long the start waits for the notification permission dialog (Android) before it goes on
  /// without notifications (UX-39): an unanswered dialog must not hold the export at "Preparing".
  final Duration notificationPermissionTimeout;

  /// Where the controller registers the export files it uses, so the export sweep keeps them
  /// (FIX-QA05-D8-2); null registers nothing.
  final ExportOutputLeases? outputLeases;

  /// Called when an export job reaches a terminal state (the runtime's export sweep, FIX-QA05-D8-2).
  final void Function()? onJobEnded;

  /// The platform in effect.
  TargetPlatform get targetPlatform => platform ?? defaultTargetPlatform;

  /// `<support>/danaview/editor/exports` (export outputs and their caption side files). Not the
  /// purgeable cache: the system emptied that mid-export under low storage (QA-05 D8).
  String get workDir => roots.exportsDir;

  /// Creates [workDir] when it is missing (first use, or removed behind the app's back). Never
  /// throws: a directory that cannot be made fails the job that needs it with a proper error.
  Future<void> ensureWorkDir() async {
    try {
      await fs.createDirectory(workDir);
    } on Object catch (e) {
      debugPrint('[Export] Could not create the exports folder: ${e.runtimeType}');
    }
  }

  /// `<cache>/danaview/editor/sprites`.
  String get spritesDir => SpritePrepass.spritesDirOf(roots.editorCache);

  static void _defaultWakelock(bool on) => unawaited(PlatformBridge.setSleepInhibited(on));

  static int _tokenCounter = 0;

  static String _defaultToken() => '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${(_tokenCounter++).toRadixString(36)}';
}

/// The environment built from the wired editor runtime; unconfigured without one.
final exportEnvironmentProvider = Provider<ExportEnvironment>((ref) {
  final runtime = ref.watch(editorRuntimeProvider);
  if (runtime == null) throw EditorNotConfiguredError('exportEnvironmentProvider');
  return ExportEnvironment.local(
    runtime.roots,
    fontResolver: ref.watch(fontCatalogProvider).resolve,
    outputLeases: runtime.exportLeases,
    onJobEnded: runtime.exportSweeper.sweepSoon,
  );
}, name: 'exportEnvironmentProvider');

/// Navigation the router supplies for the export flow (INT-04). Every callback is optional.
@immutable
final class ExportHost {
  /// Creates the host.
  const ExportHost({this.onPlay, this.onFreeUpSpace, this.onOpenSettings});

  /// Plays the exported file in the player (the kept copy in `Documents/Exports`, else the export).
  final FutureOr<void> Function(String path)? onPlay;

  /// Opens Settings › Storage.
  final FutureOr<void> Function()? onFreeUpSpace;

  /// Opens the system settings of the app (permissions).
  final FutureOr<void> Function()? onOpenSettings;
}

/// The router's [ExportHost]; no callbacks by default.
final exportHostProvider = Provider<ExportHost>((ref) => const ExportHost(), name: 'exportHostProvider');
