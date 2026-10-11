// OWNER: ENG-04
//
// The contract kit (API-01, `checkEngineContract`) export section against MobileExportService
// over mocked channels: start → activeJobs reports ExportRunning with the same job (reattach),
// cancel → EngineCancelled and off the running list, resume of an unknown job → EngineFailure,
// and one-shot records not returned after consumeJobRecord. Preview and media jobs are delegated
// to the fake engine (ENG-02 / ENG-03 run the kit against their own services).

import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor_engine/src/pigeon/engine_api.g.dart';
import 'package:vwish_editor_engine/vwish_editor_engine.dart';
import 'package:vwish_editor_engine_api/testing.dart';
import 'package:vwish_editor_engine_api/vwish_editor_engine_api.dart';

import 'support/native_export.dart';

/// The fake engine with the mobile export service.
final class _Eng04Engine implements EditorEngine {
  _Eng04Engine(this.mobile, this.fake);

  final MobileEditorEngine mobile;
  final FakeEditorEngine fake;

  @override
  Future<EditorCapabilities> capabilities() => fake.capabilities();
  @override
  Future<EditCompatibility> compatibility(String pathOrUri) => fake.compatibility(pathOrUri);
  @override
  Future<MediaProbe> probe(EngineMedia media) => fake.probe(media);
  @override
  Future<PreviewSession> openPreview(PreviewConfig config) => fake.openPreview(config);
  @override
  ThumbnailSource get thumbnails => fake.thumbnails;
  @override
  WaveformSource get waveforms => fake.waveforms;
  @override
  MediaJobs get jobs => fake.jobs;
  @override
  ExportService get exporter => mobile.exporter;
  @override
  VoiceRecorder? get voiceRecorder => fake.voiceRecorder;
  @override
  MediaPicker get picker => fake.picker;
  @override
  FileHandoff get files => fake.files;
  @override
  MediaAccess get access => fake.access;
  @override
  BackgroundWorkGuard get background => fake.background;
  @override
  ExternalDropTarget get drops => fake.drops;
  @override
  Future<int> freeBytes(String path) => fake.freeBytes(path);
  @override
  Stream<EngineSignal> get signals => fake.signals;
  @override
  Future<void> trimCaches(CacheTrimLevel level) => fake.trimCaches(level);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockEngineHost host;
  late NativeExport native;
  setUp(() {
    host = MockEngineHost()..acceptInitialize();
    host.installEvents();
    native = NativeExport(host);
  });
  tearDown(() => host.dispose());

  test('checkEngineContract export section passes with MobileExportService', () async {
    native.records
      ..['exp-int'] = ExportJobRecordMsg(jobId: 'exp-int', state: ExportJobStateKindMsg.interrupted, savedToGallery: false)
      ..['exp-det'] = ExportJobRecordMsg(
        jobId: 'exp-det',
        state: ExportJobStateKindMsg.completedWhileDetached,
        result: exportResultMsg('exp-det'),
        savedToGallery: true,
      );
    final mobile = MobileEditorEngine(config: servicesConfig, limits: noRateLimits);
    final violations = await checkEngineContract(
      _Eng04Engine(mobile, FakeEditorEngine()),
      exportOutputPath: '/c/vwish/editor/work/export-kit.mp4',
    );
    expect(violations, isEmpty);
    expect(host.count('ExportHostApi', 'start'), 1);
    expect(host.argsOf('ExportHostApi', 'cancel'), [
      ['exp-0']
    ]);
    expect(host.args['ExportHostApi.consumeJobRecord'], [
      ['exp-int'],
      ['exp-det'],
    ]);
    expect(native.records, isEmpty);
  });

  test('the kit still passes when the native store keeps cancelled and consumed records', () async {
    native
      ..keepCancelledRecords = true
      ..keepConsumedRecords = true;
    native.records['exp-int'] = ExportJobRecordMsg(jobId: 'exp-int', state: ExportJobStateKindMsg.interrupted, savedToGallery: false);
    final mobile = MobileEditorEngine(config: servicesConfig, limits: noRateLimits);
    final violations = await checkEngineContract(
      _Eng04Engine(mobile, FakeEditorEngine()),
      exportOutputPath: '/c/vwish/editor/work/export-kit.mp4',
    );
    expect(violations, isEmpty);
  });
}

extension on MockEngineHost {
  List<List<Object?>> argsOf(String api, String method) => args['$api.$method'] ?? const [];
}
