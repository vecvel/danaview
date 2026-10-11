// OWNER: API-01

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor_engine_api/testing.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';

void main() {
  test('FakeEditorEngine passes the contract kit', () async {
    final engine = FakeEditorEngine();
    engine.exporter.records
      ..add(const ExportInterrupted('job-a'))
      ..add(const ExportCompletedWhileDetached('job-b', savedToGallery: true));
    expect(await checkEngineContract(engine, exportOutputPath: '/fake/cache/danaview/editor/work/export-kit.mp4'), isEmpty);
    expect(await engine.exporter.activeJobs(), isEmpty);
  });

  test('the kit passes without the export reattach check too', () async {
    expect(await checkEngineContract(FakeEditorEngine()), isEmpty);
  });

  test('FakeEditorEngine without plan validation passes the kit', () async {
    expect(await checkEngineContract(FakeEditorEngine(validatePlans: false)), isEmpty);
  });

  test('unsupported capabilities short-circuit the kit', () async {
    final engine = FakeEditorEngine(caps: EditorCapabilities.unsupported(UnsupportedReasons.platform));
    expect(await checkEngineContract(engine), ['engine reports unsupported: platform']);
  });

  test('error codes round-trip by name; unknown names map to internal', () {
    for (final c in EngineErrorCode.values) {
      expect(EngineErrorCode.fromName(c.name), c);
    }
    expect(EngineErrorCode.fromName('nope'), EngineErrorCode.internal);
    expect(EngineErrorCode.fromName(null), EngineErrorCode.internal);
    expect(EngineFailure.of(EngineErrorCode.cancelled), isA<EngineCancelled>());
    expect(EngineFailure.of(EngineErrorCode.diskFull), isA<EngineError>());
  });

  test('excludeFromBackup refuses paths outside the editor roots (D-44)', () async {
    final engine = FakeEditorEngine();
    await engine.access.excludeFromBackup('/fake/support/danaview/editor/media');
    expect(
      () => engine.access.excludeFromBackup('/fake/documents'),
      throwsA(isA<MediaAccessFailure>().having((f) => f.kind, 'kind', MediaAccessFailureKind.outsideEditorRoots)),
    );
  });

  test('export start records whenDetached and resumable jobs resume', () async {
    final engine = FakeEditorEngine();
    final plan = contractKitPlan();
    await engine.exporter.start(
      plan,
      const EncodeSettings(width: 1280, height: 720, fps: 30, videoBitrate: 5000000),
      outputPath: '/fake/cache/danaview/editor/work/export-1.mp4',
      title: 'Trip',
      whenDetached: ExportDetachedHandoff.keepForLater,
    );
    expect(engine.exporter.lastWhenDetached, ExportDetachedHandoff.keepForLater);
    engine.exporter.records.add(const ExportResumable('job-r', doneFraction: 0.4));
    final job = await engine.exporter.resume('job-r');
    expect(job.id, 'job-r');
  });
}
