// OWNER: QA-00
//
// The real `MobileEditorEngine` with two seams for the system UI an integration test cannot drive:
//
// * the system pickers (PHPicker / document picker / Photo Picker / SAF): [E2ePicker] returns the
//   fixtures the scenario queued, as `PickedMedia` of the Files origin pointing at the sandbox copies
//   (ARCH §9.1: a file under `Documents` is a `documentsReference`, so relink scenarios can make it
//   go missing). A request with nothing queued is a cancel, exactly as the real picker reports it;
// * the export handoff (Photos add-only, Files, share sheet): [E2eHandoff] copies the file into
//   `E2eConfig.outDir` (callers delete their temporary folders right after the handoff) and reports
//   `done`; `saveToPhotos` additionally calls the real `saveToPhotos` when [E2eHandoff.realPhotos] is
//   set (Android FGS / Gallery checks, where the add-only permission is pre-granted by the host).
//
// Everything else (preview, probe, export, jobs, recorder, access, background, drops, signals) is the
// production engine. Cross-app drags from Files/Photos stay manual checklist items (docs/v1.1/editor/
// qa/README.md).

import 'dart:async';
import 'dart:io';

import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';

import 'e2e_config.dart';

/// Scripted picker: the next [queue]d batch answers the next pick.
final class E2ePicker implements MediaPicker {
  final List<List<PickedMedia>> _queue = [];

  /// Every request the app made (for assertions on kinds and sources).
  final List<MediaPickRequest> requests = [];

  /// Queues [paths] (absolute) as the answer to the next pick.
  void queue(List<String> paths) => _queue.add([for (final p in paths) pickOf(p)]);

  /// Whether a queued answer is still waiting for a pick.
  bool get hasQueued => _queue.isNotEmpty;

  /// The `PickedMedia` the Files picker reports for [path].
  static PickedMedia pickOf(String path) => PickedMedia(
        uri: Uri.file(path).toString(),
        displayName: path.split('/').last,
        origin: MediaOrigin.files,
        sizeBytes: File(path).existsSync() ? File(path).lengthSync() : null,
      );

  @override
  Future<List<PickedMedia>> pick(MediaPickRequest request) async {
    requests.add(request);
    if (_queue.isEmpty) return const [];
    final batch = _queue.removeAt(0);
    return request.multiple ? batch : batch.take(1).toList();
  }
}

/// One handoff the app made.
final class E2eHandoffRecord {
  /// Creates a record.
  const E2eHandoffRecord(this.kind, this.sourcePath, this.copyPath, {this.suggestedName});

  /// `photos`, `files` or `share`.
  final String kind;

  /// The path the app handed over.
  final String sourcePath;

  /// The suite's copy in `E2eConfig.outDir`.
  final String copyPath;

  /// The suggested name (Files).
  final String? suggestedName;

  @override
  String toString() => 'E2eHandoffRecord($kind, $copyPath)';
}

/// Handoff that keeps a copy of everything the app delivers.
final class E2eHandoff implements FileHandoff {
  /// Wraps [real].
  E2eHandoff(this.real);

  /// The engine's handoff.
  final FileHandoff real;

  /// Whether `saveToPhotos` also adds the file to the real Photos library / Gallery.
  bool realPhotos = false;

  /// Every handoff, in order.
  final List<E2eHandoffRecord> records = [];

  final StreamController<E2eHandoffRecord> _added = StreamController<E2eHandoffRecord>.broadcast();

  /// Handoffs as they happen.
  Stream<E2eHandoffRecord> get added => _added.stream;

  Future<E2eHandoffRecord> _keep(String kind, String path, {String? name}) async {
    final out = Directory(E2eConfig.outDir)..createSync(recursive: true);
    final base = name ?? path.split('/').last;
    final copy = '${out.path}/${DateTime.now().microsecondsSinceEpoch}-$base';
    await File(path).copy(copy);
    final r = E2eHandoffRecord(kind, path, copy, suggestedName: name);
    records.add(r);
    _added.add(r);
    return r;
  }

  @override
  Future<FileHandoffResult> saveToPhotos(String path) async {
    final r = await _keep('photos', path);
    if (realPhotos) return real.saveToPhotos(path);
    return FileHandoffResult(FileHandoffOutcome.done, savedUri: Uri.file(r.copyPath).toString());
  }

  @override
  Future<FileHandoffResult> saveToFiles(String path, String suggestedName) async {
    final r = await _keep('files', path, name: suggestedName);
    return FileHandoffResult(FileHandoffOutcome.done, savedUri: Uri.file(r.copyPath).toString());
  }

  @override
  Future<FileHandoffResult> share(String path) async {
    await _keep('share', path);
    return const FileHandoffResult(FileHandoffOutcome.done);
  }
}

/// The production engine with the picker and handoff seams (see the file header).
final class E2eEditorEngine implements EditorEngine {
  /// Wraps [inner].
  E2eEditorEngine(this.inner) : files = E2eHandoff(inner.files);

  /// The production engine.
  final EditorEngine inner;

  @override
  final E2ePicker picker = E2ePicker();

  @override
  final E2eHandoff files;

  @override
  Future<EditorCapabilities> capabilities() => inner.capabilities();

  @override
  Future<EditCompatibility> compatibility(String pathOrUri) => inner.compatibility(pathOrUri);

  @override
  Future<MediaProbe> probe(EngineMedia media) => inner.probe(media);

  @override
  Future<PreviewSession> openPreview(PreviewConfig config) => inner.openPreview(config);

  @override
  ThumbnailSource get thumbnails => inner.thumbnails;

  @override
  WaveformSource get waveforms => inner.waveforms;

  @override
  MediaJobs get jobs => inner.jobs;

  @override
  ExportService get exporter => inner.exporter;

  @override
  VoiceRecorder? get voiceRecorder => inner.voiceRecorder;

  @override
  MediaAccess get access => inner.access;

  @override
  BackgroundWorkGuard get background => inner.background;

  @override
  ExternalDropTarget get drops => inner.drops;

  @override
  Future<int> freeBytes(String path) => inner.freeBytes(path);

  @override
  Stream<EngineSignal> get signals => inner.signals;

  @override
  Future<void> trimCaches(CacheTrimLevel level) => inner.trimCaches(level);
}
