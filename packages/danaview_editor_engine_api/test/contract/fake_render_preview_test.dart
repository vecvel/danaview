// OWNER: INT-06
//
// The D-45 render-preview additions of the engine contract on FakeEditorEngine (BUILD_PLAN
// INT-06): the contract kit's render-preview cases pass; renders write a stub file and cancel
// deletes it; failures are EngineFailures; rendered ranges are dropped by touching patches and by
// setPlan; the power state is scripted.


import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/plan.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';
import 'package:danaview_editor_engine_api/testing.dart';

const _renders = '/fake/cache/danaview/editor/renders';

RenderPreviewContractProbe _probe(FakeEditorEngine e) => RenderPreviewContractProbe(
      rendersDirectory: _renders,
      fileExists: e.jobs.files.contains,
      activeRanges: (s) => (s as FakePreviewSession).renderedRanges,
    );

Matcher _failure(EngineErrorCode code) => isA<EngineFailure>().having((f) => f.code, 'code', code);

RenderedRange _range(int f0, int f1, String hash) => RenderedRange(
      range: TimeRange(contractKitGrid.timeOfFrame(f0), contractKitGrid.timeOfFrame(f1)),
      uri: 'file://$_renders/$hash.mp4',
      hash: hash,
    );

Future<FakePreviewSession> _open(FakeEditorEngine e) async {
  final s = await e.openPreview(const PreviewConfig(canvasWidth: 64, canvasHeight: 36, fps: 30)) as FakePreviewSession;
  await s.setPlan(contractKitPlan());
  return s;
}

void main() {
  group('contract kit', () {
    test('FakeEditorEngine passes the render-preview cases', () async {
      final e = FakeEditorEngine();
      expect(await checkEngineContract(e, renderPreview: _probe(e)), isEmpty);
    });

    test('without plan validation too', () async {
      final e = FakeEditorEngine(validatePlans: false);
      expect(await checkEngineContract(e, renderPreview: _probe(e)), isEmpty);
    });
  });

  group('renderPreview', () {
    test('renders instantly to a stub file at the output path', () async {
      final e = FakeEditorEngine();
      final job = e.jobs.renderPreview(contractKitPlan(), outputPath: '$_renders/a.mp4');
      expect((job as FakeMediaJob<Object?>).priority, JobPriority.background);
      final progress = <double>[];
      job.progress.listen(progress.add);
      final asset = await job.result;
      expect(asset.path, '$_renders/a.mp4');
      expect(asset.duration, contractKitPlan().durUs);
      expect(e.jobs.files, {'$_renders/a.mp4'});
      expect(progress.last, 1);
      expect(e.jobs.renderRequests.single.$2, '$_renders/a.mp4');
      expect(e.calls, contains('jobs.renderPreview'));
    });

    test('cancel before the render finishes deletes the output and fails with EngineCancelled', () async {
      final e = FakeEditorEngine()..jobs.holdRenders = true;
      final job = e.jobs.renderPreview(contractKitPlan(), outputPath: '$_renders/b.mp4') as FakeMediaJob<GeneratedAsset>;
      job.complete(GeneratedAsset(path: '$_renders/b.mp4', sizeBytes: 1));
      expect(e.jobs.files, contains('$_renders/b.mp4'));

      final held = e.jobs.renderPreview(contractKitPlan(), outputPath: '$_renders/c.mp4');
      final result = held.result;
      held.cancel();
      await expectLater(result, throwsA(isA<EngineCancelled>()));
      expect(e.jobs.files, isNot(contains('$_renders/c.mp4')));
    });

    test('cancel after completion keeps the file', () async {
      final e = FakeEditorEngine();
      final job = e.jobs.renderPreview(contractKitPlan(), outputPath: '$_renders/d.mp4');
      await job.result;
      job.cancel();
      expect(e.jobs.files, contains('$_renders/d.mp4'));
    });

    test('refusals and injected failures are EngineFailures', () async {
      final e = FakeEditorEngine();
      await expectLater(
        e.jobs.renderPreview(contractKitPlan().copyWith(target: PlanTarget.export), outputPath: '$_renders/x.mp4').result,
        throwsA(_failure(EngineErrorCode.planInvalid)),
      );
      await expectLater(
        e.jobs.renderPreview(contractKitPlan(), outputPath: '/fake/cache/danaview/editor/work/x.mp4').result,
        throwsA(_failure(EngineErrorCode.permissionDenied)),
      );
      e.failNext['jobs.renderPreview'] = EngineFailure.of(EngineErrorCode.diskFull);
      await expectLater(
        e.jobs.renderPreview(contractKitPlan(), outputPath: '$_renders/y.mp4').result,
        throwsA(_failure(EngineErrorCode.diskFull)),
      );
      expect(e.jobs.files, isEmpty);
    });
  });

  group('rendered ranges', () {
    test('a patch drops exactly the ranges it touches, until the next setRenderedRanges', () async {
      final e = FakeEditorEngine();
      final s = await _open(e);
      final head = _range(0, 30, 'head');
      final mid = _range(30, 60, 'mid');
      final tail = _range(60, 90, 'tail');
      await s.setRenderedRanges([head, mid, tail]);
      expect(s.renderedRanges, [head, mid, tail]);

      await s.applyPatch(contractKitShortPatch(1)); // frames 0..10
      expect(s.renderedRanges, [mid, tail]);
      expect(s.droppedRanges, [head]);

      await s.applyPatch(contractKitPatch(2)); // whole timeline
      expect(s.renderedRanges, isEmpty);

      await s.setRenderedRanges([head, tail]);
      expect(s.renderedRanges, [head, tail]);
      expect(s.droppedRanges, isEmpty);
    });

    test('setPlan drops every range', () async {
      final e = FakeEditorEngine();
      final s = await _open(e);
      await s.setRenderedRanges([_range(0, 30, 'a')]);
      await s.setPlan(contractKitPlan(rev: 5));
      expect(s.renderedRanges, isEmpty);
      expect(s.droppedRanges.single.hash, 'a');
    });

    test('invalid lists are refused with planInvalid and leave the set unchanged', () async {
      final e = FakeEditorEngine();
      final s = await _open(e);
      final a = _range(0, 30, 'a');
      await s.setRenderedRanges([a]);
      for (final bad in [
        [_range(30, 60, 'b'), _range(0, 30, 'c')], // not sorted
        [_range(0, 30, 'b'), _range(20, 40, 'c')], // overlap
        [_range(10, 10, 'b')], // empty
        [RenderedRange(range: const TimeRange(0, 10), uri: '/no/scheme.mp4', hash: 'b')],
        [RenderedRange(range: const TimeRange(0, 10), uri: 'file:///r/b.mp4', hash: '')],
      ]) {
        await expectLater(s.setRenderedRanges(bad), throwsA(_failure(EngineErrorCode.planInvalid)));
      }
      expect(s.renderedRanges, [a]);
    });

    test('patchTouchesRange: layers, canvas, duration and assets', () {
      final plan = contractKitPlan();
      final dur = plan.durUs;
      final r0 = TimeRange(0, contractKitGrid.timeOfFrame(30));
      final r1 = TimeRange(contractKitGrid.timeOfFrame(60), dur);
      expect(patchTouchesRange(plan, contractKitShortPatch(1), r0), isTrue);
      expect(patchTouchesRange(plan, contractKitShortPatch(1), r1), isFalse);
      // Removing the kit layer (spanning everything) touches both.
      final remove = RenderPlanPatch(from: 1, to: 2, layers: PatchSet<PlanLayer>(remove: ['$contractKitItem#tx0']));
      expect(patchTouchesRange(plan, remove, r1), isTrue);
      // Moving a layer touches its old span as well as its new one.
      final moved = PlanLayer(
          id: '$contractKitItem#tx0', z: 15, t0: contractKitGrid.timeOfFrame(70), t1: dur, kind: PlanLayerKind.solid, color: 0xFF336699);
      final move = RenderPlanPatch(from: 1, to: 2, layers: PatchSet<PlanLayer>(upsert: [moved]));
      expect(patchTouchesRange(plan, move, r0), isTrue);
      // Canvas changes touch every range; a longer duration only ranges past the old end.
      expect(patchTouchesRange(plan, RenderPlanPatch(from: 1, to: 2, canvas: plan.canvas.copyWith(bg: 0xFF000000)), r0), isTrue);
      final longer = RenderPlanPatch(from: 1, to: 2, durUs: dur * 2);
      expect(patchTouchesRange(plan, longer, r0), isFalse);
      expect(patchTouchesRange(plan, longer, TimeRange(dur, dur * 2)), isTrue);
      final shorter = RenderPlanPatch(from: 1, to: 2, durUs: contractKitGrid.timeOfFrame(65));
      expect(patchTouchesRange(plan, shorter, r1), isTrue);
      expect(patchTouchesRange(plan, shorter, r0), isFalse);
      // An empty patch touches nothing.
      expect(patchTouchesRange(plan, RenderPlanPatch(from: 1, to: 2), r0), isFalse);
    });
  });

  group('power state', () {
    test('is scripted and changes are emitted once', () async {
      final e = FakeEditorEngine();
      expect(await e.background.powerState(), const PowerState(charging: false, lowPowerMode: false));
      final changes = <PowerState>[];
      final sub = e.background.powerStateChanged.listen(changes.add);
      e.background.setPowerState(const PowerState(charging: true, lowPowerMode: false));
      e.background.setPowerState(const PowerState(charging: true, lowPowerMode: false));
      e.background.setPowerState(const PowerState(charging: true, lowPowerMode: true));
      await Future<void>.delayed(Duration.zero);
      expect(changes, const [PowerState(charging: true, lowPowerMode: false), PowerState(charging: true, lowPowerMode: true)]);
      expect(await e.background.powerState(), const PowerState(charging: true, lowPowerMode: true));
      expect(e.calls.where((c) => c == 'background.powerState'), hasLength(2));
      await sub.cancel();
    });

    test('failures can be injected', () async {
      final e = FakeEditorEngine();
      e.failNext['background.powerState'] = EngineFailure.of(EngineErrorCode.notSupportedOnDevice);
      await expectLater(e.background.powerState(), throwsA(_failure(EngineErrorCode.notSupportedOnDevice)));
      expect(await e.background.powerState(), isA<PowerState>());
    });
  });
}
