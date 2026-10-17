// OWNER: ENG-04
//
// A simulated native `ExportHostApi` over MockEngineHost (ENG-01): an `ActiveExportStore` of job
// records, `start` / `resume` / `cancel` / `activeJobs` / `consumeJobRecord` handlers, and
// helpers that build export events. Lets the ENG-04 tests drive MobileExportService over the real
// Pigeon codec and event channel.

import 'package:flutter/services.dart' show PlatformException;
import 'package:danaview_editor_engine/src/pigeon/engine_api.g.dart';

import '../../services/support/services_harness.dart';

export '../../services/support/services_harness.dart';

/// Native export side kept by the tests.
final class NativeExport {
  /// Installs the export handlers on [host]. [onStart] runs inside the `start` handler before the
  /// reply (to emit events that race it).
  NativeExport(this.host, {this.idPrefix = 'exp'}) {
    host
      ..on('ExportHostApi', 'preflight', (_) => preflightReply)
      ..on('ExportHostApi', 'start', (args) async {
        final id = '$idPrefix-${_n++}';
        records[id] = ExportJobRecordMsg(jobId: id, state: ExportJobStateKindMsg.running, savedToGallery: false);
        await onStart?.call(id);
        return id;
      })
      ..on('ExportHostApi', 'resume', (args) {
        final id = args[0]! as String;
        final r = records[id];
        if (r == null || r.state != ExportJobStateKindMsg.resumable) {
          throw PlatformException(code: 'notSupportedOnDevice', message: 'not resumable');
        }
        records[id] = ExportJobRecordMsg(jobId: id, state: ExportJobStateKindMsg.running, savedToGallery: false);
        return id;
      })
      ..on('ExportHostApi', 'cancel', (args) {
        if (cancelFails) throw PlatformException(code: 'io', message: 'cancel failed');
        if (!keepCancelledRecords) records.remove(args[0]! as String);
        return null;
      })
      ..on('ExportHostApi', 'activeJobs', (_) => [...records.values, ...extraRecords])
      ..on('ExportHostApi', 'consumeJobRecord', (args) {
        if (!keepConsumedRecords) records.remove(args[0]! as String);
        return null;
      });
  }

  /// The mock host.
  final MockEngineHost host;

  /// Prefix of the ids [start] hands out.
  final String idPrefix;

  int _n = 0;

  /// The native store, by job id.
  final Map<String, ExportJobRecordMsg> records = {};

  /// Records appended to every `activeJobs` reply (duplicates, stale entries).
  final List<ExportJobRecordMsg> extraRecords = [];

  /// The `preflight` reply.
  ExportPreflightMsg preflightReply = ExportPreflightMsg(ok: true, warnings: []);

  /// Runs inside `start` before the reply.
  Future<void> Function(String jobId)? onStart;

  /// `cancel` answers a native error.
  bool cancelFails = false;

  /// `cancel` leaves the job listed as running (the store lags).
  bool keepCancelledRecords = false;

  /// `consumeJobRecord` leaves the record in the store.
  bool keepConsumedRecords = false;
}

/// An `exportProgress` event for [jobId].
EngineEventMsg exportProgressEvent(
  String jobId, {
  ExportPhaseMsg phase = ExportPhaseMsg.rendering,
  double fraction = 0,
  int framesDone = 0,
  int framesTotal = 0,
  bool backgrounded = false,
  bool pausedInBackground = false,
  List<ExportWarningMsg> warnings = const [],
}) =>
    EngineEventMsg(
      kind: EngineEventKindMsg.exportProgress,
      jobId: jobId,
      exportProgress: ExportProgressMsg(
        phase: phase,
        fraction: fraction,
        framesDone: framesDone,
        framesTotal: framesTotal,
        backgrounded: backgrounded,
        pausedInBackground: pausedInBackground,
        warnings: warnings,
      ),
    );

/// A native export result.
ExportResultMsg exportResultMsg(String jobId) => ExportResultMsg(
      path: '/c/danaview/editor/work/export-$jobId.mp4',
      bytes: 4242,
      durationUs: 3000000,
      videoEncoderName: 'com.apple.videotoolbox.h264',
      hardwareEncoder: true,
    );

/// The terminal `jobDone` event of export [jobId].
EngineEventMsg exportDoneEvent(String jobId) =>
    doneEvent(jobId, JobResultMsg(kind: JobKindMsg.export, exportResult: exportResultMsg(jobId)));
