// OWNER: UX-08
//
// The port between the editor and the RenderPlan compiler (ARCH §11.7, §11.8, ux.md §16.5).
//
// * `PlanCompilerPort.forSession` is called once per opened project; the returned
//   `SessionPlanCompiler` feeds `PlanSync` (`compile`), builds gesture transients
//   (`transientFor`), resolves media for poster thumbnails (`resolve`) and drops its memo on
//   memory pressure (`trim`).
// * INT-02's `DefaultPlanCompiler` implements the port with an asset resolver over the session
//   pool, proxies and availability, and overrides [planCompilerPortProvider] in EditorBootstrap.
//   [ResolvingPlanCompilerPort] is the ready-made implementation over API-02's
//   `PreviewPlanCompiler` and core `transientFor`: INT-02 only has to supply the resolver.
// * Without an override the provider compiles with [MapPlanAssetResolver.empty] (every media
//   offline): the editor still opens and edits in tests and on the harness, it just shows
//   offline placeholders.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show EditSession;
import 'package:danaview_editor_core/plan.dart' as plan show CompileOptions, PlanTarget, standardLoweringStages, transientFor;
import 'package:danaview_editor_core/plan.dart' show MapPlanAssetResolver, PlanAssetResolver, defaultMaxAudioSpeed;
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart'
    show EditorCapabilities, EngineMedia, PlanTransient, PreviewPlanCompiler, RenderPlan;

/// Compiles projects into RenderPlans for PlanSync (ARCH §11.7). One per opened project.
abstract interface class PlanCompilerPort {
  /// The compiler for [session] on a device with [capabilities].
  SessionPlanCompiler forSession(EditSession session, EditorCapabilities capabilities);
}

/// The compiler of one editing session (ARCH §11.7, §11.8).
abstract interface class SessionPlanCompiler {
  /// The preview plan of [project] (`PlanSync.compile`; may run in an isolate above 300 items).
  Future<RenderPlan> compile(EditProject project);

  /// The param-only transient of [item] in the gesture's [working] project, or null when the
  /// item has no preview layers (core `transientFor`, ARCH §11.2 Transient).
  PlanTransient? transientFor(EditProject working, ItemId item);

  /// The file the engine opens for [media] in [project] (poster and thumbnail requests), or null
  /// when it is offline.
  EngineMedia? resolve(EditProject project, MediaId media);

  /// Drops caches (memory pressure); the next compile is cold.
  void trim();
}

/// A [PlanCompilerPort] from an asset-resolver factory (API-02 `PreviewPlanCompiler` + core
/// `transientFor`).
final class ResolvingPlanCompilerPort implements PlanCompilerPort {
  /// Creates the port; [resolverFor] resolves the assets of a project of [EditSession].
  const ResolvingPlanCompilerPort(this.resolverFor, {this.isolateThreshold = 300});

  /// Every asset offline (the default when the app did not wire a resolver).
  static final ResolvingPlanCompilerPort offline = ResolvingPlanCompilerPort((_, __) => MapPlanAssetResolver.empty);

  /// Resolver for a project of a session.
  final PlanAssetResolver Function(EditSession session, EditProject project) resolverFor;

  /// Item count above which a cold compile runs in an isolate.
  final int isolateThreshold;

  @override
  SessionPlanCompiler forSession(EditSession session, EditorCapabilities capabilities) => ResolvingSessionPlanCompiler(
        (project) => resolverFor(session, project),
        holdFrame: capabilities.holdFrame,
        maxAudioSpeed: capabilities.maxAudioSpeed,
        isolateThreshold: isolateThreshold,
      );
}

/// [SessionPlanCompiler] over `PreviewPlanCompiler` (memo per session, isolate when cold and large)
/// and core `transientFor`.
final class ResolvingSessionPlanCompiler implements SessionPlanCompiler {
  /// Creates the compiler.
  ResolvingSessionPlanCompiler(
    this.resolver, {
    this.holdFrame = true,
    this.maxAudioSpeed = defaultMaxAudioSpeed,
    int isolateThreshold = 300,
  }) : _compiler =
            PreviewPlanCompiler(resolver: resolver, holdFrame: holdFrame, maxAudioSpeed: maxAudioSpeed, isolateThreshold: isolateThreshold);

  /// Resolver for a project.
  final PlanAssetResolver Function(EditProject project) resolver;

  /// `capabilities.holdFrame`.
  final bool holdFrame;

  /// `capabilities.maxAudioSpeed`.
  final double maxAudioSpeed;

  final PreviewPlanCompiler _compiler;

  /// Compiles so far.
  int compiles = 0;

  @override
  Future<RenderPlan> compile(EditProject project) {
    compiles++;
    return _compiler.call(project);
  }

  @override
  PlanTransient? transientFor(EditProject working, ItemId item) => plan.transientFor(
        working,
        item,
        resolver(working),
        options: plan.CompileOptions(holdFrame: holdFrame, stages: plan.standardLoweringStages(maxAudioSpeed: maxAudioSpeed)),
        target: plan.PlanTarget.preview,
      );

  @override
  EngineMedia? resolve(EditProject project, MediaId media) => resolver(project).original(media);

  @override
  void trim() => _compiler.reset();
}

/// The app's plan compiler port. Overridden by EditorBootstrap (INT-02) with
/// `DefaultPlanCompiler`; defaults to [ResolvingPlanCompilerPort.offline].
final planCompilerPortProvider = Provider<PlanCompilerPort>((ref) => ResolvingPlanCompilerPort.offline, name: 'planCompilerPortProvider');
