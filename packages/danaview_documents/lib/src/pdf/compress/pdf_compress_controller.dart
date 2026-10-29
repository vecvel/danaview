// OWNER: HOM-31
//
// The state of the compress sheet (HOM plan §8.5, D-98j, G-H6): the file's size now, each preset's
// estimated or actual size, one cancelable run into an app-owned temporary file, then either a
// NEW file saved through [PdfCompressSave] as "<name> (compressed).pdf" (the original is never
// touched) or, when the result isn't smaller, nothing saved and the temporary file deleted.
// Nothing here logs a path, a name or a password (rule 30).

import 'dart:async';
import 'dart:io';

import 'package:danaview_pdf/danaview_pdf.dart';
import 'package:flutter/foundation.dart';

/// Saves the compressed file at [tempPath] as a new file named [fileName]; resolves to the name
/// it got (a clash may add " (2)"). It may move or delete [tempPath].
typedef PdfCompressSave = Future<String> Function(String tempPath, String fileName);

/// Where the sheet is.
enum PdfCompressPhase {
  /// Choosing a preset (estimates may still be loading).
  idle,

  /// A preset runs ([PdfCompressController.progress]).
  running,

  /// Saved as a new file ([PdfCompressController.savedName]).
  done,

  /// The result was not smaller; nothing was saved.
  notSmaller,

  /// The run or the save failed ([PdfCompressController.error]).
  error,
}

/// The name of the compressed copy of [name]: "Report.pdf" → "Report (compressed).pdf".
String compressedPdfName(String name) {
  final trimmed = name.trim();
  final base = trimmed.toLowerCase().endsWith('.pdf') ? trimmed.substring(0, trimmed.length - 4) : trimmed;
  return '${base.isEmpty ? 'Document' : base} (compressed).pdf';
}

/// The user-facing sentence of a failed run.
String compressErrorMessage(Object error) {
  if (error is PdfException) {
    return switch (error.code) {
      PdfErrorCode.passwordRequired => 'This PDF is protected. Open it with its password, then compress it.',
      PdfErrorCode.noSpace => 'There isn’t enough space on this device.',
      PdfErrorCode.damaged || PdfErrorCode.unsupported => 'Danaview couldn’t read this PDF.',
      PdfErrorCode.notSupportedOnDevice => 'Compress isn’t available on this device.',
      PdfErrorCode.notFound => 'The file is no longer there.',
      _ => 'That didn’t work. Try again.',
    };
  }
  return 'That didn’t work. Try again.';
}

int _jobCounter = 0;

/// The compress sheet's state over [engine].
class PdfCompressController extends ChangeNotifier {
  /// A controller for the PDF at [path] shown as [displayName].
  PdfCompressController({
    required this.engine,
    required this.path,
    required this.displayName,
    required this.save,
    this.password,
    String? tempDirectory,
    PdfCompressPreset initialPreset = PdfCompressPreset.medium,
  })  : _tempDirectory = tempDirectory,
        _preset = initialPreset;

  /// The engine (PlatformPdfCompressEngine in the app).
  final PdfCompressEngine engine;

  /// The source (read only).
  final String path;

  /// Its name as shown.
  final String displayName;

  /// Its password, when it is encrypted (never logged).
  final String? password;

  /// Saves the result.
  final PdfCompressSave save;

  final String? _tempDirectory;
  PdfCompressPreset _preset;
  PdfCompressPhase _phase = PdfCompressPhase.idle;
  int? _beforeBytes;
  PdfCompressEstimate? _estimate;
  bool _estimating = false;
  final Map<PdfCompressPreset, int> _actual = {};
  double _progress = 0;
  int? _afterBytes;
  String? _savedName;
  String? _error;
  String? _notice;
  String? _jobId;
  String? _tempPath;
  bool _cancelRequested = false;
  bool _disposed = false;

  /// The chosen preset.
  PdfCompressPreset get preset => _preset;

  /// Where the sheet is.
  PdfCompressPhase get phase => _phase;

  /// The file's size now (null until read).
  int? get beforeBytes => _beforeBytes;

  /// Estimates are loading.
  bool get estimating => _estimating;

  /// The size of [preset] after a run of it, else its estimate, else null.
  int? sizeOf(PdfCompressPreset preset) => _actual[preset] ?? _estimate?.bytes[preset];

  /// True when [sizeOf] is a measured size, not an estimate.
  bool isActual(PdfCompressPreset preset) => _actual.containsKey(preset);

  /// Progress of the running preset (0…1).
  double get progress => _progress;

  /// The result's size (done, notSmaller).
  int? get afterBytes => _afterBytes;

  /// The saved file's name (done).
  String? get savedName => _savedName;

  /// What went wrong (error).
  String? get error => _error;

  /// A one-line note on the idle sheet ("Cancelled. Nothing was saved.").
  String? get notice => _notice;

  /// A cancel was requested and the job is ending.
  bool get cancelling => _cancelRequested && _phase == PdfCompressPhase.running;

  /// The saving in percent (done).
  int? get savingPercent {
    final before = _beforeBytes, after = _afterBytes;
    if (before == null || after == null || before <= 0) return null;
    return ((before - after) * 100 / before).round().clamp(0, 100);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Reads the size now and asks for estimates (never throws).
  Future<void> load() async {
    // A stat and the temporary file's create and delete are quick: sync IO keeps every state
    // change in one frame.
    try {
      _beforeBytes = File(path).lengthSync();
    } on Object {
      _beforeBytes = null;
    }
    _estimating = true;
    _notify();
    try {
      _estimate = await engine.estimate(path, password: password);
      if (_estimate != null && _beforeBytes == null) _beforeBytes = _estimate!.sourceBytes;
    } on Object {
      _estimate = null; // the sizes show once a preset has run
    }
    _estimating = false;
    _notify();
  }

  /// Picks [preset] (idle only).
  void select(PdfCompressPreset preset) {
    if (_phase != PdfCompressPhase.idle || preset == _preset) return;
    _preset = preset;
    _notify();
  }

  /// Back to choosing a preset after a result.
  void reset() {
    if (_phase == PdfCompressPhase.running) return;
    _phase = PdfCompressPhase.idle;
    _error = null;
    _afterBytes = null;
    _notice = null;
    _notify();
  }

  /// Runs the chosen preset and saves a smaller result as a new file.
  Future<void> run() async {
    if (_phase == PdfCompressPhase.running) return;
    final jobId = 'compress-${DateTime.now().microsecondsSinceEpoch}-${_jobCounter++}';
    final dir = _tempDirectory ?? Directory.systemTemp.path;
    final temp = '$dir${Platform.pathSeparator}dv_compress_$jobId.pdf';
    final preset = _preset;
    _jobId = jobId;
    _tempPath = temp;
    _cancelRequested = false;
    _phase = PdfCompressPhase.running;
    _progress = 0;
    _error = null;
    _notice = null;
    _afterBytes = null;
    _notify();
    try {
      Directory(dir).createSync(recursive: true);
      final out = await engine.compress(
        jobId: jobId,
        path: path,
        preset: preset,
        outPath: temp,
        password: password,
        onProgress: (f) {
          if (_phase == PdfCompressPhase.running && !_cancelRequested) {
            _progress = f;
            _notify();
          }
        },
      );
      if (_disposed) return;
      if (_cancelRequested) throw const PdfException(PdfErrorCode.cancelled, 'cancelled');
      _actual[preset] = out.sizeBytes;
      _afterBytes = out.sizeBytes;
      final before = _beforeBytes;
      if (before != null && out.sizeBytes >= before) {
        _phase = PdfCompressPhase.notSmaller;
        return;
      }
      _progress = 1;
      _notify();
      try {
        _savedName = await save(temp, compressedPdfName(displayName));
      } on Object {
        if (_disposed) return;
        _phase = PdfCompressPhase.error;
        _error = 'The compressed copy couldn’t be saved.';
        return;
      }
      if (_disposed) return;
      _phase = PdfCompressPhase.done;
    } on PdfException catch (e) {
      if (_disposed) return;
      if (e.code == PdfErrorCode.cancelled) {
        _phase = PdfCompressPhase.idle;
        _notice = 'Cancelled. Nothing was saved.';
      } else {
        _phase = PdfCompressPhase.error;
        _error = compressErrorMessage(e);
      }
    } on Object catch (e) {
      if (_disposed) return;
      _phase = PdfCompressPhase.error;
      _error = compressErrorMessage(e);
    } finally {
      _jobId = null;
      _cancelRequested = false;
      _deleteTemp(temp);
      _notify();
    }
  }

  /// Cancels the running preset; the run ends as idle with nothing saved.
  Future<void> cancel() async {
    final job = _jobId;
    if (job == null || _phase != PdfCompressPhase.running || _cancelRequested) return;
    _cancelRequested = true;
    _notify();
    try {
      await engine.cancel(job);
    } on Object {
      // The job ends on its own; its result is dropped (`_cancelRequested`).
    }
  }

  void _deleteTemp(String temp) {
    try {
      final f = File(temp);
      if (f.existsSync()) f.deleteSync();
    } on Object {
      // A leftover in the temporary directory is purged by the system.
    }
    if (_tempPath == temp) _tempPath = null;
  }

  @override
  void dispose() {
    // Closing the sheet mid-run cancels the job; its temporary file is deleted when it ends.
    final job = _jobId;
    if (job != null) unawaited(engine.cancel(job).catchError((Object _) {}));
    _disposed = true;
    super.dispose();
  }
}
