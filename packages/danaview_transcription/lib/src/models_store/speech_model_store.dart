// OWNER: AI-09
//
// The speech model store (ARCH §16.2-16.3, ai.md §5.2-5.6): verified model files under
// `<support>/danaview/speech/models/` with an atomic `manifest.json`, `.part` + sidecar partials,
// states (absent, downloading, verifying, ready, corrupt), delete (blocked while a job runs) and
// the consent-gated download. Pure Dart: device services come in through [ModelStorePlatform] and
// [DownloadWakelock].

library;

import 'dart:async';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../catalog/speech_model_catalog.dart';
import '../contracts/consent.dart';
import '../contracts/failures.dart';
import '../contracts/transcription_service.dart';
import 'model_downloader.dart';
import 'model_file_checks.dart';
import 'model_manifest.dart';
import 'model_store_ports.dart';

/// Installed model files, for the runtime (AI-13) to load.
@immutable
final class SpeechModelFiles {
  /// Creates the pair.
  const SpeechModelFiles({required this.model, required this.modelPath, required this.vadPath});

  /// The model.
  final InstalledSpeechModel model;

  /// Absolute path of the model file.
  final String modelPath;

  /// Absolute path of the VAD model file.
  final String vadPath;
}

/// One partial download on disk.
@immutable
final class PartialDownload {
  /// Creates the record.
  const PartialDownload({required this.modelId, required this.bytes, required this.expectedBytes});

  /// Catalog id.
  final String modelId;

  /// Bytes on disk.
  final int bytes;

  /// Bytes when complete.
  final int expectedBytes;
}

/// What the store holds right now.
@immutable
final class SpeechModelInventory {
  /// Creates an inventory.
  const SpeechModelInventory({this.installed = const [], this.partials = const [], this.corruptIds = const {}, this.totalBytes = 0});

  /// Verified installed files (models and the VAD).
  final List<InstalledSpeechModel> installed;

  /// Partial downloads.
  final List<PartialDownload> partials;

  /// Ids whose file failed verification (download again).
  final Set<String> corruptIds;

  /// Bytes used by the models folder.
  final int totalBytes;

  /// Whether the model [id] is installed (VAD included in the inventory).
  bool has(String id) => installed.any((m) => m.spec.id == id);
}

/// Disk use of the models folder (Settings › Storage "Speech model").
@immutable
final class FolderUsage {
  /// Creates the record.
  const FolderUsage({required this.bytes, required this.files, this.partialBytes = 0});

  /// Nothing stored.
  static const FolderUsage none = FolderUsage(bytes: 0, files: 0);

  /// Total bytes.
  final int bytes;

  /// File count.
  final int files;

  /// Bytes of `.part` files within [bytes].
  final int partialBytes;
}

/// The speech model store (ai.md §5.3).
abstract interface class SpeechModelStore {
  /// Installed files, partials and corrupt ids.
  Future<SpeechModelInventory> inventory();

  /// Inventories after every change.
  Stream<SpeechModelInventory> watch();

  /// The installed model [modelId] when its file and the VAD file pass the load-time checks
  /// (size, ggml magic, manifest), else null.
  Future<InstalledSpeechModel?> installed(String modelId);

  /// Model and VAD paths for loading, or null when [modelId] is not ready.
  Future<SpeechModelFiles?> filesFor(String modelId);

  /// absent / downloading (also verifying) / ready / corrupt.
  Future<SpeechModelStatus> statusOf(String modelId);

  /// Downloads the model named by [consent] (and the VAD when the disclosure includes it). One at
  /// a time: the same model returns the running download, another model throws [StateError].
  /// A consent that does not equal the catalog fails with `consentMismatch` before any request.
  ModelDownload download(UserConsent consent);

  /// The running download, if any.
  ModelDownload? get activeDownload;

  /// Deletes [modelId] (the VAD with the last model); throws [StateError] while a job uses models.
  Future<void> delete(String modelId);

  /// Deletes models, the VAD and partials; throws [StateError] while a job uses models.
  Future<void> deleteAll();

  /// Marks the file of [modelId] damaged (a native load failed): deletes it and reports
  /// [SpeechModelCorrupt] until it is downloaded again.
  Future<void> markCorrupt(String modelId);

  /// Records a use (LRU hint in the manifest).
  Future<void> markUsed(String modelId);

  /// Disk use of the models folder.
  Future<FolderUsage> measure();
}

/// File-backed [SpeechModelStore].
final class FileSpeechModelStore implements SpeechModelStore, ModelDownloadHost {
  /// Creates a store under `<supportDirectory>/danaview/speech/models/`.
  ///
  /// [isModelInUse] reports a running transcription job (delete is blocked then). [models],
  /// [vadSpec] and [config] default to the pinned catalog and production settings; tests pass
  /// small specs and a loopback server through them.
  FileSpeechModelStore({
    required String supportDirectory,
    required ModelStorePlatform platform,
    DownloadWakelock wakelock = const NoDownloadWakelock(),
    bool Function()? isModelInUse,
    ModelDownloaderConfig config = const ModelDownloaderConfig(),
    List<SpeechModelSpec>? models,
    SpeechModelSpec? vadSpec,
    DateTime Function()? clock,
    Set<String> legacySha256 = SpeechModelCatalog.acceptedLegacySha256,
  })  : layout = ModelStoreLayout(supportDirectory),
        _platform = platform,
        _wakelock = wakelock,
        _isModelInUse = isModelInUse ?? (() => false),
        _config = config,
        _models = models ?? SpeechModelCatalog.models,
        _vad = vadSpec ?? SpeechModelCatalog.vad,
        _clock = clock ?? DateTime.now,
        _legacySha256 = legacySha256;

  /// File layout.
  final ModelStoreLayout layout;

  final ModelStorePlatform _platform;
  final DownloadWakelock _wakelock;
  final bool Function() _isModelInUse;
  final ModelDownloaderConfig _config;
  final List<SpeechModelSpec> _models;
  final SpeechModelSpec _vad;
  final DateTime Function() _clock;
  final Set<String> _legacySha256;

  final _Mutex _mutex = _Mutex();
  final Set<String> _corrupt = {};
  final StreamController<SpeechModelInventory> _changes = StreamController<SpeechModelInventory>.broadcast();
  ModelDownloadTask? _active;
  ModelDownloadProgress? _activeProgress;
  Future<void>? _prepared;

  // ------------------------------------------------------------------------------------------
  // Consent and download
  // ------------------------------------------------------------------------------------------

  /// Whether [d] is exactly what the catalog (this store's specs) would disclose for [spec]:
  /// the same fields [ConsentDisclosure.of] fills, compared one by one. With the production
  /// catalog this equals [ConsentDisclosure.matchesCatalog].
  bool _matches(ConsentDisclosure d, SpeechModelSpec spec) =>
      d.fileName == spec.fileName &&
      d.host == spec.host &&
      d.cdnHost == SpeechModelCatalog.cdnHost &&
      d.sha256 == spec.sha256 &&
      d.totalBytes == spec.bytes + (d.includesVad ? _vad.bytes : 0);

  @override
  ModelDownload? get activeDownload => _active;

  @override
  ModelDownload download(UserConsent consent) {
    final d = consent.disclosure;
    final spec = _lookup(d.modelId);
    // The consent must equal today's catalog entry; nothing is requested otherwise (no consent
    // memory: every download needs its own consent).
    if (spec == null || spec.id == _vad.id || !_matches(d, spec)) {
      return FailedModelDownload(ModelDownloadFailureKind.consentMismatch);
    }
    final running = _active;
    if (running != null) {
      if (running.model.id == spec.id) return running;
      throw StateError('Another model is downloading (${running.model.id}).');
    }
    final task = ModelDownloadTask(
      model: spec,
      vad: d.includesVad ? _vad : null,
      totalBytes: d.totalBytes,
      layout: layout,
      platform: _platform,
      wakelock: _wakelock,
      config: _config,
      host: this,
    );
    _active = task;
    _activeProgress = null;
    unawaited(task.done.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
      if (identical(_active, task)) {
        _active = null;
        _activeProgress = null;
      }
      unawaited(_notify());
    }));
    unawaited(_notify());
    return task;
  }

  @override
  void reportProgress(String modelId, ModelDownloadProgress progress) {
    _activeProgress = progress;
  }

  @override
  void reportCorrupt(String modelId) {
    _corrupt.add(modelId);
  }

  @override
  Future<InstalledSpeechModel?> installedOf(SpeechModelSpec spec) async {
    await _prepare();
    final entry = (await _loadManifest()).entryOf(spec.id);
    if (entry == null) return null;
    return await _checkEntry(spec, entry) ? _recordOf(spec, entry) : null;
  }

  @override
  Future<InstalledSpeechModel> commit(SpeechModelSpec spec) async {
    final from = layout.partOf(spec);
    final to = layout.fileOf(spec);
    // Atomic: the final name only ever holds a verified file.
    await File(from).rename(to);
    try {
      await File(layout.sidecarOf(spec)).delete();
    } on FileSystemException {
      // No sidecar left.
    }
    await _platform.excludeFromBackup(to);
    final now = _clock().toUtc();
    final entry = ManifestEntry(
      id: spec.id,
      file: spec.fileName,
      sha256: spec.sha256.toLowerCase(),
      bytes: spec.bytes,
      installedAt: now,
      verifiedAt: now,
    );
    await _mutateManifest((m) => m.upsert(entry));
    _corrupt.remove(spec.id);
    return _recordOf(spec, entry);
  }

  // ------------------------------------------------------------------------------------------
  // Reading
  // ------------------------------------------------------------------------------------------

  @override
  Future<InstalledSpeechModel?> installed(String modelId) async {
    final spec = _lookup(modelId);
    if (spec == null) return null;
    final model = await installedOf(spec);
    if (model == null) return null;
    if (spec.id != _vad.id && await installedOf(_vad) == null) return null;
    return model;
  }

  @override
  Future<SpeechModelFiles?> filesFor(String modelId) async {
    final spec = _lookup(modelId);
    final model = await installed(modelId);
    if (spec == null || model == null) return null;
    return SpeechModelFiles(model: model, modelPath: layout.fileOf(spec), vadPath: layout.fileOf(_vad));
  }

  @override
  Future<SpeechModelStatus> statusOf(String modelId) async {
    final running = _active;
    if (running != null && (running.model.id == modelId || running.vad?.id == modelId)) {
      return SpeechModelDownloading(_activeProgress ?? running.latest);
    }
    await _prepare();
    final spec = _lookup(modelId);
    if (spec == null) return const SpeechModelMissing();
    if (_corrupt.contains(modelId)) return const SpeechModelCorrupt();
    final entry = (await _loadManifest()).entryOf(modelId);
    if (entry == null) return const SpeechModelMissing();
    if (!await _checkEntry(spec, entry)) return const SpeechModelCorrupt();
    if (spec.id != _vad.id) {
      final vadEntry = (await _loadManifest()).entryOf(_vad.id);
      if (vadEntry == null || !await _checkEntry(_vad, vadEntry)) return const SpeechModelMissing();
    }
    return SpeechModelReady(_recordOf(spec, entry));
  }

  @override
  Future<SpeechModelInventory> inventory() async {
    await _prepare();
    final manifest = await _loadManifest();
    final installed = <InstalledSpeechModel>[];
    final corrupt = <String>{..._corrupt};
    for (final e in manifest.installed) {
      final spec = _lookup(e.id);
      if (spec == null) continue;
      if (await _checkEntry(spec, e)) {
        installed.add(_recordOf(spec, e));
      } else {
        corrupt.add(e.id);
      }
    }
    final partials = <PartialDownload>[];
    for (final spec in _allSpecs()) {
      final part = File(layout.partOf(spec));
      if (await part.exists()) {
        partials.add(PartialDownload(modelId: spec.id, bytes: await part.length(), expectedBytes: spec.bytes));
      }
    }
    final usage = await measure();
    return SpeechModelInventory(installed: installed, partials: partials, corruptIds: corrupt, totalBytes: usage.bytes);
  }

  @override
  Stream<SpeechModelInventory> watch() => _changes.stream;

  Future<void> _notify() async {
    if (!_changes.hasListener || _changes.isClosed) return;
    try {
      _changes.add(await inventory());
    } on Object {
      // A change notification never throws.
    }
  }

  @override
  Future<FolderUsage> measure() async {
    final dir = Directory(layout.dir);
    if (!await dir.exists()) return FolderUsage.none;
    var bytes = 0;
    var files = 0;
    var partial = 0;
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final n = await e.length();
      bytes += n;
      files++;
      if (e.path.endsWith('.part')) partial += n;
    }
    return FolderUsage(bytes: bytes, files: files, partialBytes: partial);
  }

  // ------------------------------------------------------------------------------------------
  // Writing
  // ------------------------------------------------------------------------------------------

  @override
  Future<void> delete(String modelId) async {
    _guardNotInUse();
    final spec = _lookup(modelId);
    if (spec == null) return;
    await _cancelDownloadOf(modelId);
    await _prepare();
    await _removeFiles(spec);
    _corrupt.remove(modelId);
    // The VAD only exists for the models: the last model takes it along.
    if (spec.id != _vad.id) {
      final manifest = await _loadManifest();
      final remaining = manifest.installed.where((e) => e.id != _vad.id && _lookup(e.id) != null);
      if (remaining.isEmpty) {
        await _cancelDownloadOf(_vad.id);
        await _removeFiles(_vad);
      }
    }
    unawaited(_notify());
  }

  @override
  Future<void> deleteAll() async {
    _guardNotInUse();
    final running = _active;
    if (running != null) {
      running.cancel(keepPartial: false);
      try {
        await running.done;
      } on Object {
        // Cancelled on purpose.
      }
    }
    await _prepare();
    await _mutex.run(() async {
      final dir = Directory(layout.dir);
      if (await dir.exists()) {
        await for (final e in dir.list(followLinks: false)) {
          try {
            if (e is File) await e.delete();
            if (e is Directory) await e.delete(recursive: true);
          } on FileSystemException {
            // Best effort; the rest is still removed.
          }
        }
      }
    });
    _corrupt.clear();
    unawaited(_notify());
  }

  @override
  Future<void> markCorrupt(String modelId) async {
    final spec = _lookup(modelId);
    if (spec == null) return;
    await _prepare();
    await _removeFiles(spec);
    _corrupt.add(modelId);
    unawaited(_notify());
  }

  @override
  Future<void> markUsed(String modelId) async {
    await _prepare();
    await _mutateManifest((m) {
      final e = m.entryOf(modelId);
      return e == null ? m : m.upsert(e.usedAt(_clock().toUtc()));
    });
  }

  /// Installs [path] as [spec] without any network (CI and QA fixtures). Verifies size, SHA-256
  /// and the ggml magic; throws `ModelDownloadFailure` on a mismatch and [UnsupportedError] in
  /// release builds, where this seam does not exist.
  @visibleForTesting
  Future<InstalledSpeechModel> installFromFile(SpeechModelSpec spec, String path) async {
    if (const bool.fromEnvironment('dart.vm.product')) {
      throw UnsupportedError('installFromFile is available in debug and profile builds only.');
    }
    await _prepare();
    await Directory(layout.dir).create(recursive: true);
    final source = File(path);
    if (await source.length() != spec.bytes) throw const ModelDownloadFailure(ModelDownloadFailureKind.sizeMismatch);
    final part = layout.partOf(spec);
    await source.copy(part);
    if (await sha256OfFile(part) != spec.sha256.toLowerCase() || !await hasGgmlMagic(part)) {
      await File(part).delete();
      _corrupt.add(spec.id);
      throw const ModelDownloadFailure(ModelDownloadFailureKind.checksumMismatch);
    }
    final installed = await commit(spec);
    unawaited(_notify());
    return installed;
  }

  // ------------------------------------------------------------------------------------------
  // Internals
  // ------------------------------------------------------------------------------------------

  Iterable<SpeechModelSpec> _allSpecs() => [..._models, _vad];

  SpeechModelSpec? _lookup(String id) {
    for (final s in _allSpecs()) {
      if (s.id == id) return s;
    }
    return null;
  }

  void _guardNotInUse() {
    if (_isModelInUse()) throw StateError('In use by auto captions');
  }

  Future<void> _cancelDownloadOf(String modelId) async {
    final running = _active;
    if (running == null) return;
    if (running.model.id != modelId && running.vad?.id != modelId) return;
    running.cancel(keepPartial: false);
    try {
      await running.done;
    } on Object {
      // Cancelled on purpose.
    }
  }

  Future<void> _removeFiles(SpeechModelSpec spec) async {
    for (final path in [layout.fileOf(spec), layout.partOf(spec), layout.sidecarOf(spec)]) {
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } on FileSystemException {
        // Gone is gone.
      }
    }
    await _mutateManifest((m) => m.without(spec.id));
  }

  InstalledSpeechModel _recordOf(SpeechModelSpec spec, ManifestEntry e) =>
      InstalledSpeechModel(spec: spec, installedAt: e.installedAt, lastUsedAt: e.lastUsedAt);

  /// Load-time integrity (ai.md §5.3): size equals the manifest, the magic is right and the
  /// manifest hash is the catalog's (or an accepted legacy one). No re-hash here: a full re-hash
  /// runs only when the manifest was lost ([_prepare]).
  Future<bool> _checkEntry(SpeechModelSpec spec, ManifestEntry e) async {
    if (e.sha256 != spec.sha256.toLowerCase() && !_legacySha256.contains(e.sha256)) return false;
    final file = File(p.join(layout.dir, e.file));
    try {
      if (!await file.exists() || await file.length() != e.bytes) return false;
    } on FileSystemException {
      return false;
    }
    return hasGgmlMagic(file.path);
  }

  Future<SpeechModelManifest> _loadManifest() async {
    try {
      final text = await File(layout.manifest).readAsString();
      return SpeechModelManifest.tryDecode(text) ?? SpeechModelManifest.empty;
    } on FileSystemException {
      return SpeechModelManifest.empty;
    }
  }

  Future<void> _mutateManifest(SpeechModelManifest Function(SpeechModelManifest) change) => _mutex.run(() async {
        final next = change(await _loadManifest());
        await Directory(layout.dir).create(recursive: true);
        await writeStringAtomic(layout.manifest, next.encode());
      });

  /// First-use housekeeping: create the folder (backup-excluded), sweep stale partials, and
  /// rebuild a lost manifest by hashing files whose size matches the catalog.
  Future<void> _prepare() => _prepared ??= _doPrepare();

  Future<void> _doPrepare() async {
    final dir = Directory(layout.dir);
    final existed = await dir.exists();
    if (!existed) await dir.create(recursive: true);
    await _platform.excludeFromBackup(layout.dir);

    final manifestFile = File(layout.manifest);
    final lost = !await manifestFile.exists() || SpeechModelManifest.tryDecode(await manifestFile.readAsString()) == null;
    final now = _clock().toUtc();
    final specs = <SpeechModelSpec>[..._allSpecs()];

    for (final spec in specs) {
      final part = File(layout.partOf(spec));
      if (await part.exists() && now.difference((await part.lastModified()).toUtc()) > _config.staleAfter) {
        await _removePart(spec);
      }
    }
    if (lost) {
      var manifest = SpeechModelManifest.empty;
      for (final spec in specs) {
        final file = File(layout.fileOf(spec));
        if (!await file.exists()) continue;
        if (await file.length() == spec.bytes && await hasGgmlMagic(file.path) && await sha256OfFile(file.path) == spec.sha256.toLowerCase()) {
          manifest = manifest.upsert(ManifestEntry(
            id: spec.id,
            file: spec.fileName,
            sha256: spec.sha256.toLowerCase(),
            bytes: spec.bytes,
            installedAt: now,
            verifiedAt: now,
          ));
        } else {
          await file.delete();
        }
      }
      if (manifest.installed.isNotEmpty || await manifestFile.exists()) {
        await writeStringAtomic(layout.manifest, manifest.encode());
      }
    }
  }

  Future<void> _removePart(SpeechModelSpec spec) async {
    for (final path in [layout.partOf(spec), layout.sidecarOf(spec)]) {
      try {
        await File(path).delete();
      } on FileSystemException {
        // Already gone.
      }
    }
  }
}

/// Runs async sections one after another.
final class _Mutex {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() section) {
    final gate = Completer<void>();
    final previous = _tail;
    _tail = gate.future;
    return previous.then((_) => section()).whenComplete(gate.complete);
  }
}
