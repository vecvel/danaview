// OWNER: INT-06
//
// The D-45 engine interface additions over mocked Pigeon channels (BUILD_PLAN INT-06): the
// render-preview job (start, cancel, progress, done, failed), `setRenderedRanges` and
// `powerState` / `powerStateChanged`; and, with the INT-06 native placeholders (a host error
// `notSupportedOnDevice`, or no host API at all), every new call fails with
// `EngineFailure(notSupportedOnDevice)`.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor_core/model.dart' show TimeRange;
import 'package:danaview_editor_engine/danaview_editor_engine.dart';
import 'package:danaview_editor_engine/src/pigeon/conversions.dart';
import 'package:danaview_editor_engine/src/pigeon/engine_api.g.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';
import 'package:danaview_editor_engine_api/testing.dart';

import 'support/mock_engine_host.dart';

const _config = EditorEngineConfig(cacheRoot: '/c/danaview/editor', supportRoot: '/s/danaview/editor');
const _renders = '/c/danaview/editor/renders';

Matcher _failure(EngineErrorCode code) => isA<EngineFailure>().having((f) => f.code, 'code', code);

RenderedRange _range(int f0, int f1, String hash) => RenderedRange(
      range: TimeRange(contractKitGrid.timeOfFrame(f0), contractKitGrid.timeOfFrame(f1)),
      uri: 'file://$_renders/$hash.mp4',
      hash: hash,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockEngineHost host;
  late StreamController<Object?> events;

  setUp(() {
    host = MockEngineHost();
    events = host.installEvents();
  });
  tearDown(() => host.dispose());

  group('with a native engine', () {
    setUp(() => host.acceptInitialize());

    group('renderPreview job', () {
      test('starts through startJob with the encoded range plan, reports progress and completes', () async {
        host.on('JobsHostApi', 'startJob', (_) => 'rp-1');
        final engine = MobileEditorEngine(config: _config);
        final plan = contractKitPlan();
        final job = engine.jobs.renderPreview(plan, outputPath: '$_renders/h1.mp4');
        final progress = <double>[];
        job.progress.listen(progress.add);
        await pumpEventQueue();

        final request = host.args['JobsHostApi.startJob']!.single.single! as JobRequestMsg;
        expect(request.kind, JobKindMsg.renderPreview);
        expect(request.outputPath, '$_renders/h1.mp4');
        expect(request.priority, JobPriorityMsg.background);
        expect(request.media.uri, Uri.file('$_renders/h1.mp4').toString());
        expect(utf8.decode(request.plan!), utf8.decode(await PlanTransport.encodePlan(plan)));

        events
          ..add(EngineEventMsg(kind: EngineEventKindMsg.progress, jobId: 'rp-1', progress: 0.5))
          ..add(EngineEventMsg(
              kind: EngineEventKindMsg.jobDone,
              jobId: 'rp-1',
              jobDone: JobResultMsg(
                  kind: JobKindMsg.renderPreview,
                  asset: GeneratedAssetMsg(path: '$_renders/h1.mp4', sizeBytes: 4096, durationUs: plan.durUs))));
        final asset = await job.result;
        expect((asset.path, asset.sizeBytes, asset.duration), ('$_renders/h1.mp4', 4096, plan.durUs));
        expect(progress, [0.5, 1]);
      });

      test('cancel sends cancelJob and completes with EngineCancelled', () async {
        host
          ..on('JobsHostApi', 'startJob', (_) => 'rp-2')
          ..on('JobsHostApi', 'cancelJob', (_) => null);
        final engine = MobileEditorEngine(config: _config);
        final job = engine.jobs.renderPreview(contractKitPlan(), outputPath: '$_renders/h2.mp4');
        await pumpEventQueue();
        final result = job.result;
        job.cancel();
        await expectLater(result, throwsA(isA<EngineCancelled>()));
        await pumpEventQueue();
        expect(host.args['JobsHostApi.cancelJob']!.single.single, 'rp-2');
      });

      test('a cancel before the plan is encoded never reaches native', () async {
        host.on('JobsHostApi', 'startJob', (_) => 'rp-3');
        final engine = MobileEditorEngine(config: _config);
        final job = engine.jobs.renderPreview(contractKitPlan(), outputPath: '$_renders/h3.mp4');
        final result = job.result;
        job.cancel();
        await expectLater(result, throwsA(isA<EngineCancelled>()));
        await pumpEventQueue();
        expect(host.count('JobsHostApi', 'startJob'), 0);
      });

      test('setPriority before the start is sent is used for the start', () async {
        host.on('JobsHostApi', 'startJob', (_) => 'rp-4');
        final engine = MobileEditorEngine(config: _config);
        final job = engine.jobs.renderPreview(contractKitPlan(), outputPath: '$_renders/h4.mp4');
        job.setPriority(JobPriority.interactive);
        await pumpEventQueue();
        expect((host.args['JobsHostApi.startJob']!.single.single! as JobRequestMsg).priority, JobPriorityMsg.interactive);
        expect(host.count('JobsHostApi', 'setJobPriority'), 0);
      });

      test('failure events and start errors map to EngineFailure', () async {
        host.on('JobsHostApi', 'startJob', (_) => 'rp-5');
        final engine = MobileEditorEngine(config: _config);
        final job = engine.jobs.renderPreview(contractKitPlan(), outputPath: '$_renders/h5.mp4');
        await pumpEventQueue();
        events.add(EngineEventMsg(
            kind: EngineEventKindMsg.failure, jobId: 'rp-5', failure: FailureMsg(code: 'diskFull', message: 'no space', retryable: false)));
        await expectLater(job.result, throwsA(_failure(EngineErrorCode.diskFull)));

        host.fail('JobsHostApi', 'startJob', 'planInvalid', details: {'retryable': false});
        await expectLater(
          engine.jobs.renderPreview(contractKitPlan(), outputPath: '$_renders/h6.mp4').result,
          throwsA(_failure(EngineErrorCode.planInvalid)),
        );
      });

      test('a done event of another kind is an internal failure', () async {
        host.on('JobsHostApi', 'startJob', (_) => 'rp-7');
        final engine = MobileEditorEngine(config: _config);
        final job = engine.jobs.renderPreview(contractKitPlan(), outputPath: '$_renders/h7.mp4');
        await pumpEventQueue();
        events.add(EngineEventMsg(
            kind: EngineEventKindMsg.jobDone,
            jobId: 'rp-7',
            jobDone: JobResultMsg(kind: JobKindMsg.proxy, asset: GeneratedAssetMsg(path: '/p.mp4', sizeBytes: 1))));
        await expectLater(job.result, throwsA(_failure(EngineErrorCode.internal)));
      });
    });

    group('setRenderedRanges', () {
      Future<PreviewSession> open(MobileEditorEngine engine) async {
        host
          ..on('PreviewHostApi', 'open', (_) => PreviewOpenedMsg(sessionId: 's1', textureId: 3))
          ..on('PreviewHostApi', 'setPlan', (a) => PlanAckMsg(rev: 1, structural: true, applyMs: 1));
        return engine.openPreview(const PreviewConfig(canvasWidth: 64, canvasHeight: 36, fps: 30));
      }

      test('sends every range to native for the session', () async {
        host.on('PreviewHostApi', 'setRenderedRanges', (_) => null);
        final engine = MobileEditorEngine(config: _config);
        final session = await open(engine);
        await session.setRenderedRanges([_range(0, 30, 'a'), _range(60, 90, 'b')]);
        final args = host.args['PreviewHostApi.setRenderedRanges']!.single;
        expect(args[0], 's1');
        final sent = (args[1]! as List<Object?>).cast<RenderedRangeMsg>();
        expect([for (final r in sent) (r.startUs, r.endUs, r.uri, r.hash)], [
          (0, contractKitGrid.timeOfFrame(30), 'file://$_renders/a.mp4', 'a'),
          (contractKitGrid.timeOfFrame(60), contractKitGrid.timeOfFrame(90), 'file://$_renders/b.mp4', 'b'),
        ]);
        await session.setRenderedRanges(const []);
        expect((host.args['PreviewHostApi.setRenderedRanges']!.last[1]! as List<Object?>), isEmpty);
      });

      test('is sent after a plan that was sent before it', () async {
        final order = <String>[];
        final gate = Completer<void>();
        host
          ..on('PreviewHostApi', 'open', (_) => PreviewOpenedMsg(sessionId: 's1', textureId: 3))
          ..on('PreviewHostApi', 'setPlan', (a) async {
            order.add('setPlan');
            await gate.future;
            return PlanAckMsg(rev: 1, structural: true, applyMs: 1);
          })
          ..on('PreviewHostApi', 'setRenderedRanges', (_) {
            order.add('setRenderedRanges');
            return null;
          });
        final engine = MobileEditorEngine(config: _config);
        final session = await engine.openPreview(const PreviewConfig(canvasWidth: 64, canvasHeight: 36, fps: 30));
        final planDone = session.setPlan(contractKitPlan());
        final rangesDone = session.setRenderedRanges([_range(0, 30, 'a')]);
        await pumpEventQueue();
        expect(order, ['setPlan']);
        gate.complete();
        await planDone;
        await rangesDone;
        expect(order, ['setPlan', 'setRenderedRanges']);
      });

      test('an invalid list fails with planInvalid without reaching native', () async {
        host.on('PreviewHostApi', 'setRenderedRanges', (_) => null);
        final engine = MobileEditorEngine(config: _config);
        final session = await open(engine);
        await expectLater(
          session.setRenderedRanges([_range(0, 30, 'a'), _range(20, 40, 'b')]),
          throwsA(_failure(EngineErrorCode.planInvalid)),
        );
        expect(host.count('PreviewHostApi', 'setRenderedRanges'), 0);
      });

      test('native errors are typed; calls after dispose fail with EngineCancelled', () async {
        host
          ..fail('PreviewHostApi', 'setRenderedRanges', 'planInvalid')
          ..on('PreviewHostApi', 'dispose', (_) => null);
        final engine = MobileEditorEngine(config: _config);
        final session = await open(engine);
        await expectLater(session.setRenderedRanges([_range(0, 30, 'a')]), throwsA(_failure(EngineErrorCode.planInvalid)));
        await session.dispose();
        await expectLater(session.setRenderedRanges(const []), throwsA(isA<EngineCancelled>()));
      });
    });

    group('power state', () {
      test('powerState maps the native reply', () async {
        host.on('PlatformHostApi', 'powerState', (_) => PowerStateMsg(charging: true, lowPowerMode: false));
        final engine = MobileEditorEngine(config: _config);
        expect(await engine.background.powerState(), const PowerState(charging: true, lowPowerMode: false));
        expect(host.count('PlatformHostApi', 'powerState'), 1);
      });

      test('powerStateChanged signals reach powerStateChanged and never EditorEngine.signals', () async {
        final engine = MobileEditorEngine(config: _config);
        final power = <PowerState>[];
        final signals = <EngineSignal>[];
        engine.background.powerStateChanged.listen(power.add);
        engine.signals.listen(signals.add);
        await engine.channels.ensureInitialized();
        events
          ..add(EngineEventMsg(
              kind: EngineEventKindMsg.signal,
              signal: SignalMsg(kind: SignalKindMsg.powerStateChanged, powerState: PowerStateMsg(charging: true, lowPowerMode: false))))
          ..add(EngineEventMsg(kind: EngineEventKindMsg.signal, signal: SignalMsg(kind: SignalKindMsg.powerStateChanged)))
          ..add(EngineEventMsg(kind: EngineEventKindMsg.signal, signal: SignalMsg(kind: SignalKindMsg.memoryWarning)))
          ..add(EngineEventMsg(
              kind: EngineEventKindMsg.signal,
              signal: SignalMsg(kind: SignalKindMsg.powerStateChanged, powerState: PowerStateMsg(charging: false, lowPowerMode: true))));
        await pumpEventQueue();
        expect(power, const [PowerState(charging: true, lowPowerMode: false), PowerState(charging: false, lowPowerMode: true)]);
        expect(signals, [isA<MemoryWarningSignal>()]);
      });

      test('native errors are typed', () async {
        host.fail('PlatformHostApi', 'powerState', 'internal');
        final engine = MobileEditorEngine(config: _config);
        await expectLater(engine.background.powerState(), throwsA(_failure(EngineErrorCode.internal)));
      });
    });

    test('the INT-06 native placeholders answer notSupportedOnDevice for every new call', () async {
      for (final (api, method) in [
        ('JobsHostApi', 'startJob'),
        ('PreviewHostApi', 'setRenderedRanges'),
        ('PlatformHostApi', 'powerState'),
      ]) {
        host.fail(api, method, 'notSupportedOnDevice', message: 'render preview lands with IOS-19 / AND-18');
      }
      host.on('PreviewHostApi', 'open', (_) => PreviewOpenedMsg(sessionId: 's1', textureId: 3));
      final engine = MobileEditorEngine(config: _config);
      await expectLater(
        engine.jobs.renderPreview(contractKitPlan(), outputPath: '$_renders/n.mp4').result,
        throwsA(_failure(EngineErrorCode.notSupportedOnDevice)),
      );
      final session = await engine.openPreview(const PreviewConfig(canvasWidth: 64, canvasHeight: 36, fps: 30));
      await expectLater(session.setRenderedRanges([_range(0, 30, 'a')]), throwsA(_failure(EngineErrorCode.notSupportedOnDevice)));
      await expectLater(engine.background.powerState(), throwsA(_failure(EngineErrorCode.notSupportedOnDevice)));
    });
  });

  test('without a native engine (no host API) the new calls fail with notSupportedOnDevice, never PlatformException', () async {
    final engine = MobileEditorEngine(config: _config);
    await expectLater(
      engine.jobs.renderPreview(contractKitPlan(), outputPath: '$_renders/m.mp4').result,
      throwsA(_failure(EngineErrorCode.notSupportedOnDevice)),
    );
    await expectLater(engine.background.powerState(), throwsA(_failure(EngineErrorCode.notSupportedOnDevice)));
    await expectLater(engine.background.powerState(), throwsA(isNot(isA<PlatformException>())));
  });

  test('conversions: rendered ranges, power state and signals', () {
    final msg = renderedRangeToMsg(const RenderedRange(range: TimeRange(10, 20), uri: 'file:///r/a.mp4', hash: 'h'));
    expect((msg.startUs, msg.endUs, msg.uri, msg.hash), (10, 20, 'file:///r/a.mp4', 'h'));
    expect(powerStateFromMsg(PowerStateMsg(charging: false, lowPowerMode: true)), const PowerState(charging: false, lowPowerMode: true));
    expect(signalFromMsg(SignalMsg(kind: SignalKindMsg.powerStateChanged, powerState: PowerStateMsg(charging: true, lowPowerMode: true))),
        isNull);
    expect(powerStateOfSignal(SignalMsg(kind: SignalKindMsg.thermal, thermalLevel: ThermalLevelMsg.fair)), isNull);
    expect(JobKindMsg.values.last, JobKindMsg.renderPreview);
    expect(SignalKindMsg.values.last, SignalKindMsg.powerStateChanged);
  });
}
