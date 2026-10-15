// OWNER: API-01
//
// Reusable engine contract kit (ARCH §12.2 normative semantics, §12.3, §12.4). Framework-free:
// returns the list of violations so `flutter_test`, `integration_test` (ENG-09 example host) and
// QA suites can all run it against any [EditorEngine] (the fake, a mocked-channel MobileEditorEngine
// or the real plugin on a simulator / emulator).
//
// The kit checks, in this order: capabilities caching; plan and patch revision semantics;
// transients never touching the plan revision; clock `seq` rules; exact-seek acks on the frame
// grid; scrub acks; job cancel semantics; export reattach (when an output path is supplied) and
// one-shot export records; and, when a [RenderPreviewContractProbe] is supplied (D-45, INT-06),
// the render-preview job (renders to its output, cancel deletes the output, refusals are
// `EngineFailure`s) and rendered ranges (a patch touching a range drops it, an untouched one
// stays, `setPlan` drops all, an invalid list is `planInvalid`).

import 'dart:async';

import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/plan.dart';

import '../engine.dart';
import '../export.dart';
import '../failures.dart';
import '../media_services.dart';
import '../platform_services.dart';
import '../preview.dart';

/// Frame grid of every plan built by [contractKitPlan].
const FrameRate contractKitGrid = FrameRate.fps30;

/// Item id of the solid layer in [contractKitPlan].
const String contractKitItem = 'it_kit00000001';

/// A minimal valid 30 fps preview plan of one solid layer, used by the kit.
RenderPlan contractKitPlan({int rev = 1}) {
  final dur = contractKitGrid.timeOfFrame(90);
  return RenderPlan(
    rev: rev,
    target: PlanTarget.preview,
    canvas: const PlanCanvas(w: 64, h: 36, fps: 30),
    durUs: dur,
    layers: [PlanLayer(id: '$contractKitItem#tx0', z: 15, t0: 0, t1: dur, kind: PlanLayerKind.solid, color: 0xFF336699)],
  );
}

/// A patch from [from] to [from] + 1 that adds one more solid layer (a structural change).
RenderPlanPatch contractKitPatch(int from) {
  final dur = contractKitGrid.timeOfFrame(90);
  return RenderPlanPatch(
    from: from,
    to: from + 1,
    layers: PatchSet<PlanLayer>(
      upsert: [PlanLayer(id: 'it_kit00000002#tx0', z: 16, t0: 0, t1: dur, kind: PlanLayerKind.solid, color: 0xFFCC3366)],
    ),
  );
}

/// A patch from [from] to [from] + 1 that adds a solid layer over frames 0..10 only, so it touches
/// a rendered range starting at frame 0 and no range starting at frame 30 or later.
RenderPlanPatch contractKitShortPatch(int from) => RenderPlanPatch(
      from: from,
      to: from + 1,
      layers: PatchSet<PlanLayer>(
        upsert: [
          PlanLayer(id: 'it_kit00000003#tx0', z: 17, t0: 0, t1: contractKitGrid.timeOfFrame(10), kind: PlanLayerKind.solid, color: 0xFF22AA44),
        ],
      ),
    );

/// What [checkEngineContract] needs to check the D-45 render-preview contract on an engine that
/// implements it (the fake; IOS-19 / AND-18 engines on a simulator or emulator).
///
/// See ARCH §12.2, §12.3, D-45.
final class RenderPreviewContractProbe {
  /// Creates the probe.
  const RenderPreviewContractProbe({required this.rendersDirectory, required this.fileExists, required this.activeRanges});

  /// Absolute path of the engine's `<cache>/danaview/editor/renders` directory (the kit writes
  /// `kit-*.mp4` files there).
  final String rendersDirectory;

  /// Whether a file exists at an absolute path.
  final FutureOr<bool> Function(String path) fileExists;

  /// The rendered ranges [session] currently plays from files (a test hook of the engine).
  final FutureOr<List<RenderedRange>> Function(PreviewSession session) activeRanges;
}

/// Runs the preview, job and export contract against [engine] and returns violations (empty =
/// pass).
///
/// * [settle] is how long to wait for asynchronous clock samples after a command (zero is enough
///   for in-process engines; use ~100 ms on a real device).
/// * [exportOutputPath]: when set, the kit starts an export of [contractKitPlan] to this path,
///   checks that [ExportService.activeJobs] reports it as [ExportRunning] (reattach), cancels it and
///   checks `EngineCancelled` and that the job left the running list. Real engines need a plan
///   with real media, so the default is off.
/// * [checkExportRecords]: consumes one-shot records and checks they do not come back.
/// * [renderPreview]: when set, also checks the D-45 render-preview job, rendered ranges and the
///   power state (engines that still answer `notSupportedOnDevice` leave it null).
Future<List<String>> checkEngineContract(
  EditorEngine engine, {
  Duration settle = Duration.zero,
  String? exportOutputPath,
  bool checkExportRecords = true,
  RenderPreviewContractProbe? renderPreview,
}) async {
  final v = <String>[];
  final caps = await engine.capabilities();
  if (!caps.supported) {
    return ['engine reports unsupported: ${caps.unsupportedReason}'];
  }
  final caps2 = await engine.capabilities();
  if (caps2 != caps) {
    v.add('capabilities() must return the same value on every call (cached)');
  }
  if (!caps.planVersions.contains(1)) {
    v.add('capabilities.planVersions must contain 1');
  }

  await _checkPreview(engine, v, settle);
  await _checkJobs(engine, v);
  await _checkExport(engine, v, exportOutputPath, checkExportRecords);
  if (renderPreview != null) {
    await _checkRenderJobs(engine, v, renderPreview, settle);
    await _checkRenderedRanges(engine, v, renderPreview, settle);
    await _checkPowerState(engine, v);
  }
  return v;
}

Future<void> _checkRenderJobs(EditorEngine engine, List<String> v, RenderPreviewContractProbe probe, Duration settle) async {
  final dir = probe.rendersDirectory.endsWith('/') ? probe.rendersDirectory.substring(0, probe.rendersDirectory.length - 1) : probe.rendersDirectory;

  // A render writes its output.
  final donePath = '$dir/kit-render.mp4';
  final job = engine.jobs.renderPreview(contractKitPlan(), outputPath: donePath);
  if (job.id.isEmpty) v.add('a render-preview job must have a non-empty id');
  try {
    final asset = await job.result;
    if (asset.path != donePath) v.add('renderPreview result path ${asset.path} is not the requested output');
    if (!await probe.fileExists(donePath)) v.add('a finished render preview must leave its output file');
  } on Object catch (e) {
    v.add('renderPreview of a valid range plan failed: $e');
  }

  // Cancel deletes the output.
  final cancelPath = '$dir/kit-cancel.mp4';
  final cancelled = engine.jobs.renderPreview(contractKitPlan(), outputPath: cancelPath);
  final cancelledResult = cancelled.result;
  cancelled.cancel();
  cancelled.cancel(); // idempotent
  try {
    await cancelledResult;
    v.add('a cancelled render preview must complete with EngineCancelled');
  } on EngineCancelled {
    // expected
  } on Object catch (e) {
    v.add('cancelled render preview threw ${e.runtimeType} instead of EngineCancelled');
  }
  await _pump(settle);
  if (await probe.fileExists(cancelPath)) v.add('a cancelled render preview must delete its output');

  // Refusals are typed failures.
  final exportPlan = contractKitPlan().copyWith(target: PlanTarget.export);
  await _expectFailure(
    v,
    'renderPreview of an export-target plan',
    EngineErrorCode.planInvalid,
    () => engine.jobs.renderPreview(exportPlan, outputPath: '$dir/kit-refused.mp4').result,
  );
}

Future<void> _checkRenderedRanges(EditorEngine engine, List<String> v, RenderPreviewContractProbe probe, Duration settle) async {
  const grid = contractKitGrid;
  final session = await engine.openPreview(const PreviewConfig(canvasWidth: 64, canvasHeight: 36, fps: 30));
  try {
    final dir = probe.rendersDirectory.endsWith('/') ? probe.rendersDirectory.substring(0, probe.rendersDirectory.length - 1) : probe.rendersDirectory;
    final head = RenderedRange(range: TimeRange(0, grid.timeOfFrame(30)), uri: Uri.file('$dir/kit-head.mp4').toString(), hash: 'kit-head');
    final tail = RenderedRange(range: TimeRange(grid.timeOfFrame(60), grid.timeOfFrame(90)), uri: Uri.file('$dir/kit-tail.mp4').toString(), hash: 'kit-tail');
    final plan = contractKitPlan();
    await session.setPlan(plan);
    await session.setRenderedRanges([head, tail]);
    await _pump(settle);
    var active = await probe.activeRanges(session);
    if (active.length != 2 || active.first != head || active.last != tail) {
      v.add('setRenderedRanges must make every given range active (got ${active.length})');
    }

    // A patch touching the head range drops it; the tail range stays.
    await session.applyPatch(contractKitShortPatch(plan.rev));
    await _pump(settle);
    active = await probe.activeRanges(session);
    if (active.contains(head)) v.add('a patch touching a rendered range must drop it');
    if (!active.contains(tail)) v.add('a patch must not drop a rendered range it does not touch');

    // The next call restores the set; setPlan drops every range.
    await session.setRenderedRanges([head, tail]);
    await _pump(settle);
    if ((await probe.activeRanges(session)).length != 2) v.add('setRenderedRanges after a drop must restore the given ranges');
    await session.setPlan(contractKitPlan(rev: 20));
    await _pump(settle);
    if ((await probe.activeRanges(session)).isNotEmpty) v.add('setPlan must drop every rendered range');

    // Invalid lists are refused.
    await _expectFailure(
      v,
      'setRenderedRanges with overlapping ranges',
      EngineErrorCode.planInvalid,
      () => session.setRenderedRanges([head, RenderedRange(range: TimeRange(grid.timeOfFrame(20), grid.timeOfFrame(40)), uri: head.uri, hash: 'kit-overlap')]),
    );
  } finally {
    await session.dispose();
  }
}

Future<void> _checkPowerState(EditorEngine engine, List<String> v) async {
  try {
    final PowerState state = await engine.background.powerState();
    if (state != await engine.background.powerState()) v.add('powerState() must be stable while nothing changes');
  } on Object catch (e) {
    v.add('powerState() failed: $e');
  }
}

Future<void> _pump(Duration settle) async {
  await Future<void>.delayed(settle);
  await Future<void>.delayed(Duration.zero);
}

Future<void> _expectFailure(List<String> v, String what, EngineErrorCode code, Future<Object?> Function() body) async {
  try {
    await body();
    v.add('$what must throw EngineFailure(${code.name})');
  } on EngineFailure catch (e) {
    if (e.code != code) {
      v.add('$what threw ${e.code.name}, expected ${code.name}');
    }
  } on Object catch (e) {
    v.add('$what threw a non-EngineFailure: ${e.runtimeType}');
  }
}

Future<void> _checkPreview(EditorEngine engine, List<String> v, Duration settle) async {
  const grid = contractKitGrid;
  final session = await engine.openPreview(const PreviewConfig(canvasWidth: 64, canvasHeight: 36, fps: 30));
  final clock = <PreviewClock>[];
  final sub = session.clock.listen(clock.add);
  try {
    // --- Plan and patch revision semantics.
    final plan = contractKitPlan();
    final ack = await session.setPlan(plan);
    if (ack.rev != plan.rev) {
      v.add('setPlan ack rev ${ack.rev} != ${plan.rev}');
    }

    await _expectFailure(
      v,
      'applyPatch with a stale `from`',
      EngineErrorCode.planOutOfSync,
      () => session.applyPatch(RenderPlanPatch(from: plan.rev + 5, to: plan.rev + 6)),
    );

    // A rejected patch leaves the engine at the old revision: the right patch still applies.
    // Transients never touch the revision, so they must not make the patch fail either.
    session.setTransient(
      const ItemId(contractKitItem),
      PlanTransient(item: contractKitItem, layers: const [TransientLayer(id: '$contractKitItem#tx0', xf: PlanTransform(op: 0.5))]),
    );
    final patched = await session.applyPatch(contractKitPatch(plan.rev));
    if (patched.rev != plan.rev + 1) {
      v.add('patch ack rev ${patched.rev} != ${plan.rev + 1}');
    }
    session.clearTransient(const ItemId(contractKitItem));
    session.clearTransient(const ItemId(contractKitItem)); // idempotent

    // The same patch again is stale now.
    await _expectFailure(
      v,
      'replaying an applied patch',
      EngineErrorCode.planOutOfSync,
      () => session.applyPatch(contractKitPatch(plan.rev)),
    );

    // The recovery path of PlanSync: setPlan(full) resets the revision and patches continue.
    final resent = await session.setPlan(contractKitPlan(rev: 10));
    if (resent.rev != 10) {
      v.add('setPlan(rev 10) ack rev ${resent.rev}');
    }
    final after = await session.applyPatch(contractKitPatch(10));
    if (after.rev != 11) {
      v.add('patch after a full resend ack rev ${after.rev} != 11');
    }

    // --- Clock seq rules: seq increases with every seek, play and pause; each clock sample
    // carries the seq of the last command it reflects.
    clock.clear();
    final s0 = (await session.seek(0)).seq;
    await session.play();
    await _pump(settle);
    final playSeq = clock.isEmpty ? -1 : clock.last.seq;
    if (clock.isEmpty || !clock.last.playing) {
      v.add('after play() the last clock sample must report playing');
    }
    if (playSeq <= s0) {
      v.add('play must increase seq (seek $s0, play sample $playSeq)');
    }
    await session.pause();
    await _pump(settle);
    if (clock.isEmpty || clock.last.playing) {
      v.add('after pause() the last clock sample must report paused');
    }
    if (clock.isNotEmpty && clock.last.seq <= playSeq) {
      v.add('pause must increase seq (play $playSeq, pause sample ${clock.last.seq})');
    }
    var previous = -1;
    for (final c in clock) {
      if (c.seq < previous) {
        v.add('clock seq went backwards ($previous -> ${c.seq})');
        break;
      }
      previous = c.seq;
    }
    for (final c in clock) {
      if (c.time != grid.timeOfFrame(grid.frameIndexNearest(c.time))) {
        v.add('clock time ${c.time} is not on the frame grid');
        break;
      }
    }

    // --- Exact seek acks on the frame grid.
    clock.clear();
    final t = grid.timeOfFrame(31) + 10;
    final a1 = await session.seek(t);
    if (a1.displayedFrame != grid.frameIndexOf(t)) {
      v.add('exact seek displayed ${a1.displayedFrame}, expected ${grid.frameIndexOf(t)}');
    }
    if (a1.displayedFrameTime != grid.timeOfFrame(a1.displayedFrame)) {
      v.add('displayedFrameTime is not timeOfFrame(displayedFrame)');
    }
    if (a1.requested != t) {
      v.add('SeekAck.requested ${a1.requested} != $t');
    }
    final a2 = await session.seek(grid.timeOfFrame(32));
    if (a2.seq <= a1.seq) {
      v.add('seq must increase with every seek');
    }
    if (a2.displayedFrame != 32) {
      v.add('exact seek to timeOfFrame(32) displayed frame ${a2.displayedFrame}');
    }
    final a3 = await session.seek(grid.timeOfFrame(33) - 1);
    if (a3.displayedFrame != 32) {
      v.add('exact seek one µs before frame 33 displayed ${a3.displayedFrame}, expected 32 (frameIndexOf)');
    }
    await _pump(settle);
    if (clock.isEmpty || clock.last.seq != a3.seq) {
      v.add('the clock sample after a seek must carry the seek seq (${clock.isEmpty ? 'none' : clock.last.seq} vs ${a3.seq})');
    }
    if (clock.isNotEmpty && clock.last.time != a3.displayedFrameTime) {
      v.add('the clock sample after a seek must report the displayed frame time');
    }

    // --- Scrub acks still name the displayed frame on the grid.
    final sc = await session.seek(grid.timeOfFrame(50), kind: SeekKind.scrub);
    if (sc.displayedFrameTime != grid.timeOfFrame(sc.displayedFrame)) {
      v.add('scrub ack displayedFrameTime is not timeOfFrame(displayedFrame)');
    }
    if (sc.seq <= a3.seq) {
      v.add('scrub seek must increase seq');
    }
  } finally {
    await sub.cancel();
    await session.dispose();
  }
}

Future<void> _checkJobs(EditorEngine engine, List<String> v) async {
  const media = ResolvedMedia(uri: 'file:///kit.mp4', fingerprint: 'kit');
  final job = engine.jobs.freezeFrame(media, 0, outputPath: '/kit.png');
  if (job.id.isEmpty) {
    v.add('a job must have a non-empty id');
  }
  // Silence the unhandled-error report of an already-failed future while we await it below.
  final result = job.result;
  job.setPriority(JobPriority.interactive);
  job.cancel();
  job.cancel(); // idempotent
  try {
    await result;
    v.add('a cancelled job must complete with EngineCancelled');
  } on EngineCancelled {
    // expected
  } on Object catch (e) {
    v.add('cancelled job threw ${e.runtimeType} instead of EngineCancelled');
  }
}

Future<void> _checkExport(EditorEngine engine, List<String> v, String? outputPath, bool checkRecords) async {
  final exporter = engine.exporter;
  if (outputPath != null) {
    final settings = const EncodeSettings(width: 64, height: 36, fps: 30, videoBitrate: 1000000);
    final job = await exporter.start(contractKitPlan(), settings, outputPath: outputPath, title: 'Contract kit');
    final result = job.result;
    final running = await exporter.activeJobs();
    final state = running.where((s) => s.jobId == job.id).toList();
    if (state.length != 1 || state.single is! ExportRunning) {
      v.add('a started export must be reported by activeJobs() as ExportRunning (reattach)');
    } else if ((state.single as ExportRunning).job.id != job.id) {
      v.add('ExportRunning.job must be the running job');
    }
    await job.cancel();
    try {
      await result;
      v.add('a cancelled export must complete with EngineCancelled');
    } on EngineCancelled {
      // expected
    } on Object catch (e) {
      v.add('cancelled export threw ${e.runtimeType} instead of EngineCancelled');
    }
    if ((await exporter.activeJobs()).any((s) => s.jobId == job.id && s is ExportRunning)) {
      v.add('a cancelled export must leave the running list');
    }
    try {
      await exporter.resume('kit-unknown-job');
      v.add('resume of an unknown job must throw an EngineFailure');
    } on EngineFailure {
      // expected (notSupportedOnDevice on Android, a job error on iOS)
    } on Object catch (e) {
      v.add('resume of an unknown job threw ${e.runtimeType}, expected EngineFailure');
    }
  }

  if (checkRecords) {
    for (final r in await exporter.activeJobs()) {
      if (r is ExportInterrupted || r is ExportCompletedWhileDetached) {
        await exporter.consumeJobRecord(r.jobId);
        final again = await exporter.activeJobs();
        if (again.any((x) => x.jobId == r.jobId)) {
          v.add('consumed record ${r.jobId} was returned again');
        }
      }
    }
  }
}
