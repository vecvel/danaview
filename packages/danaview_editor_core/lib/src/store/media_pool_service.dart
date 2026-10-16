// OWNER: CORE-27
//
// The media pool service (ARCH §9.1-9.3, D-13). The contract types are shared with CORE-28.
// [FileMediaPoolService] implements `import` (probe, fingerprint via `MediaAccessPort.quickHash`,
// dedupe by quickHash within the project, routing by `ImportPolicy`, managed copies through
// `ManagedStore`, sticky `AddAssets` pool changes, optional timeline placement). Availability,
// relink, "Relink several" and same-folder search are delegated to a [MediaRelinkDelegate], which
// CORE-28 implements (availability.dart, relink.dart).
//
// Originals are never written: the service reads picked files (hash, probe, LUT text) and writes
// only inside the editor roots through `ManagedStore` / `OwnedFileDeleter`.

import 'dart:async';
import 'dart:convert' show Base64Codec;
import 'dart:io' show Platform;

import 'package:meta/meta.dart';

import '../formats/cube_lut.dart';
import '../formats/vlut.dart';
import '../ids/ids.dart';
import '../model/pool/fingerprint.dart';
import '../model/pool/media_access_port.dart';
import '../model/pool/media_asset.dart';
import '../model/pool/media_locator.dart';
import '../model/pool/media_pool.dart';
import '../model/pool/media_probe.dart';
import '../model/pool/picked_media.dart';
import '../model/pool/resolved_media.dart';
import '../model/track.dart';
import '../ops/edit_command.dart';
import '../ops/outcome.dart';
import '../session/session.dart';
import 'import_policy.dart';
import 'managed_store.dart';
import 'owned_file_deleter.dart';
import 'store_fs.dart';
import 'store_roots.dart';

/// Where imported media should land on the timeline (null = bin only).
@immutable
final class ImportTarget {
  /// Creates a target.
  const ImportTarget({this.track, this.atUs, this.asOverlay = false});

  /// Preferred track, or null for the default lane of the media kind.
  final TrackId? track;

  /// Timeline time (on the grid), or null for the playhead.
  final int? atUs;

  /// Add as a picture-in-picture overlay instead of the main lane.
  final bool asOverlay;
}

/// Result of importing one picked item.
@immutable
sealed class ImportOutcome {
  const ImportOutcome(this.picked);

  /// The item this outcome is about.
  final PickedMedia picked;
}

/// Imported (or reused: re-picking the same file reuses the same `MediaId`).
final class ImportedMedia extends ImportOutcome {
  /// Creates the outcome.
  const ImportedMedia(super.picked, this.asset, {this.reused = false});

  /// The pool asset.
  final MediaAsset asset;

  /// Whether an existing asset was reused.
  final bool reused;

  @override
  String toString() => 'ImportedMedia(${asset.id}${reused ? ', reused' : ''})';
}

/// Not imported.
final class ImportRejected extends ImportOutcome {
  /// Creates the outcome.
  const ImportRejected(super.picked, this.reason);

  /// Stable reason code: `unsupported` (probe failed or the file is not editable), an issue code
  /// of the probe in lowerCamel (`containerUnsupportedIos`, `protected`, …), `empty`, `notFound`,
  /// `accessDenied`, `notPersistable` (a URI that needs a platform copy and none is available),
  /// `diskFull`, `lutInvalid`, `cancelled` or `io`.
  final String reason;

  @override
  String toString() => 'ImportRejected(${picked.displayName}: $reason)';
}

/// Availability of one asset (ARCH §9.3).
enum MediaAvailability {
  /// Readable and matching its fingerprint.
  available,

  /// Not found.
  missing,

  /// Grant revoked or bookmark unresolvable.
  accessLost,

  /// Found but the hash differs ("Use updated file" or Relink).
  changed,

  /// A rendition, still or proxy is gone (requeued silently).
  derivedMissing,
}

/// Availability of every asset of a project.
@immutable
final class MediaAvailabilityReport {
  /// Creates a report.
  MediaAvailabilityReport(Map<MediaId, MediaAvailability> byMedia) : byMedia = Map.unmodifiable(byMedia);

  /// State per asset.
  final Map<MediaId, MediaAvailability> byMedia;

  /// Assets that block export (missing, access lost, changed).
  Iterable<MediaId> get blocking => byMedia.entries
      .where((e) => e.value == MediaAvailability.missing || e.value == MediaAvailability.accessLost || e.value == MediaAvailability.changed)
      .map((e) => e.key);
}

/// Whether a candidate can replace a missing asset.
@immutable
sealed class RelinkCheck {
  const RelinkCheck();
}

/// Fingerprint equal, or duration ±100 ms with equal kind and dimensions.
final class RelinkMatch extends RelinkCheck {
  /// Creates the result.
  const RelinkMatch({required this.exactFingerprint});

  /// Whether the quickHash matched exactly.
  final bool exactFingerprint;
}

/// Durations differ; accepting clamps clips (with a notice).
final class RelinkDurationMismatch extends RelinkCheck {
  /// Creates the result.
  const RelinkDurationMismatch({required this.expectedUs, required this.actualUs});

  /// Expected duration.
  final int expectedUs;

  /// Candidate duration.
  final int actualUs;
}

/// A different media kind (refused).
final class RelinkDifferentKind extends RelinkCheck {
  /// Creates the result.
  const RelinkDifferentKind();
}

/// Not usable (reason code).
final class RelinkUnsupported extends RelinkCheck {
  /// Creates the result.
  const RelinkUnsupported(this.reason);

  /// Reason code.
  final String reason;
}

/// "Relink several": one pick proposed for one missing asset.
@immutable
final class RelinkProposal {
  /// Creates a proposal; [media] is null when the pick could not be assigned (ties are left
  /// unassigned).
  const RelinkProposal({required this.pick, required this.media, required this.check});

  /// The picked file.
  final PickedMedia pick;

  /// The missing asset it would replace, or null.
  final MediaId? media;

  /// Why.
  final RelinkCheck check;
}

/// A same-folder candidate (path locators only).
@immutable
final class RelinkCandidate {
  /// Creates a candidate.
  const RelinkCandidate({required this.media, required this.pick, required this.check});

  /// Missing asset.
  final MediaId media;

  /// File found next to the anchor.
  final PickedMedia pick;

  /// Check result.
  final RelinkCheck check;
}

/// Imports, availability and relink for one session's pool (ARCH §9.2).
abstract interface class MediaPoolService {
  /// Imports picked media following the import policy (ARCH §9.1); sticky pool changes.
  Future<List<ImportOutcome>> import(EditSession session, List<PickedMedia> picked, {ImportTarget? target});

  /// Availability on open, on resume and after relink.
  Stream<MediaAvailabilityReport> watchAvailability(EditSession session);

  /// Checks one candidate for one missing asset.
  Future<RelinkCheck> checkRelink(EditSession session, MediaId id, PickedMedia candidate);

  /// "Relink several": pairs each pick with the best missing asset (fingerprint first, then
  /// duration ±100 ms with equal kind and dimensions; ties unassigned).
  Future<List<RelinkProposal>> autoMatch(EditSession session, List<PickedMedia> picks);

  /// Applies relinks as one undoable "Relink media" entry.
  Future<EditOutcome> relink(EditSession session, Map<MediaId, PickedMedia> picks);

  /// Files next to [anchor] that match other missing assets (readable folders only).
  Future<List<RelinkCandidate>> findInSameFolder(EditSession session, PickedMedia anchor);
}

// ============================================================================================
// CORE-27 implementation
// ============================================================================================

/// Availability, relink and same-folder search: implemented by CORE-28 and plugged into
/// [FileMediaPoolService]; the signatures mirror [MediaPoolService].
abstract interface class MediaRelinkDelegate {
  /// See [MediaPoolService.watchAvailability].
  Stream<MediaAvailabilityReport> watchAvailability(EditSession session);

  /// See [MediaPoolService.checkRelink].
  Future<RelinkCheck> checkRelink(EditSession session, MediaId id, PickedMedia candidate);

  /// See [MediaPoolService.autoMatch].
  Future<List<RelinkProposal>> autoMatch(EditSession session, List<PickedMedia> picks);

  /// See [MediaPoolService.relink].
  Future<EditOutcome> relink(EditSession session, Map<MediaId, PickedMedia> picks);

  /// See [MediaPoolService.findInSameFolder].
  Future<List<RelinkCandidate>> findInSameFolder(EditSession session, PickedMedia anchor);
}

/// Probes a resolved media file through the engine (`EditorEngine.probe`).
typedef MediaProber = Future<MediaProbe> Function(ResolvedMedia media);

/// Free bytes on the volume of [directory], or null when unknown (no preflight then).
typedef FreeSpaceProbe = Future<int?> Function(String directory);

/// Called after each picked item with the number done and the total.
typedef ImportProgress = void Function(int done, int total);

/// Copies a pick Dart cannot read (an Android `content://` URI whose grant cannot be persisted,
/// or a dropped URI with a temporary grant) into an app-owned temporary file under [intoDir]
/// (`<cache>/danaview/editor/work/picks/`) and returns its absolute path. Implemented natively
/// (AND-14 `ContentResolver` copy) and wired by INT-02.
typedef PickMaterializer = Future<String> Function(PickedMedia picked, String intoDir);

/// The production [MediaPoolService] (see the file header).
final class FileMediaPoolService implements MediaPoolService {
  /// Creates the service.
  ///
  /// [access] is the engine's `MediaAccess` (or [DartIoMediaAccess] for plain paths), [probe]
  /// the engine probe, [ids] mints `MediaId`s, [clock] stamps `addedAt` (UTC). [platform]
  /// defaults to the host. [store] defaults to a [ManagedStore] over [roots] and [fs] that excludes
  /// `media/` and `derived/` from backups through [access]. [materialize] copies non-persistable
  /// URIs; without it such picks are rejected (`notPersistable`). [freeSpace] enables the
  /// size + 64 MB preflight before copies. [relinker] is CORE-28's delegate.
  FileMediaPoolService({
    required this.access,
    required this.probe,
    required this.roots,
    StoreFs fs = const LocalStoreFs(),
    ImportPlatform? platform,
    ManagedStore? store,
    OwnedFileDeleter? deleter,
    IdGenerator? ids,
    DateTime Function()? clock,
    this.materialize,
    this.freeSpace,
    this.relinker,
  })  : _fs = fs,
        policy = ImportPolicy(platform: platform ?? hostImportPlatform(), roots: roots),
        store = store ?? ManagedStore(roots, fs: fs, deleter: deleter ?? OwnedFileDeleter(roots, fs: fs), access: access),
        _ids = ids ?? SecureIdGenerator(),
        _clock = clock ?? _utcNow;

  static DateTime _utcNow() => DateTime.now().toUtc();

  /// The platform's media access port.
  final MediaAccessPort access;

  /// Engine probe.
  final MediaProber probe;

  /// App roots.
  final StoreRoots roots;

  /// Routing rules (ARCH §9.1).
  final ImportPolicy policy;

  /// Managed copies and project-owned files.
  final ManagedStore store;

  /// Copier for URIs Dart cannot read (null: such picks are rejected).
  final PickMaterializer? materialize;

  /// Free-space preflight (null: none).
  final FreeSpaceProbe? freeSpace;

  /// CORE-28's availability/relink implementation.
  final MediaRelinkDelegate? relinker;

  final StoreFs _fs;
  final IdGenerator _ids;
  final DateTime Function() _clock;
  final Expando<Future<void>> _queues = Expando('import queue');
  final Set<String> _inFlight = {};

  /// Content hashes being imported right now (GC marks their managed folders, CORE-28).
  Set<String> get inFlightQuickHashes => Set.unmodifiable(_inFlight);

  /// The platform of the host process.
  static ImportPlatform hostImportPlatform() {
    if (Platform.isIOS) return ImportPlatform.ios;
    if (Platform.isAndroid) return ImportPlatform.android;
    return ImportPlatform.desktop;
  }

  // ------------------------------------------------------------------------------------------
  // Import
  // ------------------------------------------------------------------------------------------

  /// Imports [picked] in order (imports into one session run one batch at a time). Each imported
  /// item is added to the pool at once as a sticky `AddAssets` (undo never empties the bin);
  /// re-picking content already in the pool returns the existing asset (`reused`). With [target]
  /// the imported media (LUTs excluded) are then placed on the timeline ([place]). [onProgress]
  /// is told after each item; when [isCancelled] turns true the remaining items are rejected
  /// (`cancelled`).
  @override
  Future<List<ImportOutcome>> import(
    EditSession session,
    List<PickedMedia> picked, {
    ImportTarget? target,
    ImportProgress? onProgress,
    bool Function()? isCancelled,
  }) {
    final previous = _queues[session] ?? Future<void>.value();
    final done = Completer<void>();
    _queues[session] = done.future;
    return previous.then((_) async {
      try {
        final outcomes = <ImportOutcome>[];
        for (var i = 0; i < picked.length; i++) {
          if (isCancelled?.call() ?? false) {
            outcomes.add(ImportRejected(picked[i], 'cancelled'));
          } else {
            outcomes.add(await _importOne(session, picked[i]));
          }
          onProgress?.call(i + 1, picked.length);
        }
        if (target != null) place(session, outcomes, target);
        return outcomes;
      } finally {
        done.complete();
      }
    });
  }

  /// Places the imported media of [outcomes] (in order, each asset once, LUTs skipped) at
  /// [target] as one `InsertMedia` entry. `asOverlay` uses the first unlocked overlay lane and
  /// creates one (its own "Add track" entry) when there is none. Returns null when nothing is
  /// placeable.
  EditOutcome? place(EditSession session, List<ImportOutcome> outcomes, ImportTarget target) {
    final ids = <MediaId>[];
    for (final o in outcomes) {
      if (o is ImportedMedia && o.asset.kind != MediaKind.lut && !ids.contains(o.asset.id)) ids.add(o.asset.id);
    }
    if (ids.isEmpty) return null;
    var track = target.track;
    if (track == null && target.asOverlay) {
      for (final t in session.project.timeline.tracks) {
        if (t.kind == TrackKind.overlay && !t.locked) {
          track = t.id;
          break;
        }
      }
      if (track == null) {
        final added = session.apply(const AddTrack(TrackKind.overlay));
        if (added.rejection != null || added.createdTracks.isEmpty) return added;
        track = added.createdTracks.first;
      }
    }
    final at = target.atUs ?? session.project.view.playhead;
    return session.apply(InsertMedia(ids, at, track: track));
  }

  Future<ImportOutcome> _importOne(EditSession session, PickedMedia picked) async {
    final decision = policy.decide(picked);
    String? hash;
    try {
      final pickLocator = _pickLocator(picked, decision);
      final stat = await access.stat(pickLocator);
      if (stat == null) return ImportRejected(picked, 'notFound');
      hash = await access.quickHash(pickLocator);
      if (hash.isEmpty || stat.sizeBytes == 0) return ImportRejected(picked, 'empty');

      // Dedupe within the project: same content → same MediaId.
      final existing = _findByHash(session.committedProject.pool, hash);
      if (existing != null) {
        if (decision.temporary && decision.sourcePath != null) await store.discardTemporary(decision.sourcePath!);
        return ImportedMedia(picked, existing, reused: true);
      }
      _inFlight.add(hash);

      final id = _ids.mediaId();
      final MediaProbe probed;
      if (decision.route == ImportRoute.projectLut) {
        probed = MediaProbe(kind: MediaKind.lut, sizeBytes: stat.sizeBytes);
      } else {
        final p0 = await _probe(pickLocator);
        if (p0 == null) return ImportRejected(picked, 'unsupported');
        if (!p0.editable) return ImportRejected(picked, _issueReason(p0));
        probed = switch (decision.route) {
          ImportRoute.projectRecording => p0.copyWith(kind: MediaKind.recording),
          ImportRoute.projectStill => p0.copyWith(kind: MediaKind.still),
          _ => p0,
        };
      }

      final placed = await _store(session, picked, decision, id, hash, stat);
      if (placed is ImportRejected) return placed;
      final (locator, ownership) = placed as (MediaLocator, MediaOwnership);

      final asset = MediaAsset(
        id: id,
        kind: probed.kind,
        displayName: picked.displayName,
        locator: locator,
        ownership: ownership,
        fingerprint: MediaFingerprint(
          sizeBytes: stat.sizeBytes,
          quickHash: hash,
          modifiedMs: stat.modifiedMs,
          duration: probed.duration,
        ),
        probe: probed.sizeBytes == 0 ? probed.copyWith(sizeBytes: stat.sizeBytes) : probed,
        origin: picked.origin,
        addedAt: _clock(),
      );
      session.applyPoolChange(AddAssets([asset]));
      return ImportedMedia(picked, asset);
    } on MediaAccessFailure catch (e) {
      if (e.kind == MediaAccessFailureKind.outsideEditorRoots) rethrow; // a bug
      return ImportRejected(picked, switch (e.kind) {
        MediaAccessFailureKind.notFound => 'notFound',
        MediaAccessFailureKind.accessLost || MediaAccessFailureKind.permissionDenied => 'accessDenied',
        _ => 'io',
      });
    } on StoreFailure catch (e) {
      return ImportRejected(picked, switch (e.kind) {
        StoreFailureKind.diskFull => 'diskFull',
        StoreFailureKind.permissionDenied => 'accessDenied',
        StoreFailureKind.notFound => 'notFound',
        _ => 'io',
      });
    } on LutFormatException {
      return ImportRejected(picked, 'lutInvalid');
    } finally {
      if (hash != null) _inFlight.remove(hash);
    }
  }

  /// Carries out [decision]; returns `(locator, ownership)` or an [ImportRejected].
  Future<Object> _store(
    EditSession session,
    PickedMedia picked,
    ImportDecision decision,
    MediaId id,
    String hash,
    MediaStat stat,
  ) async {
    switch (decision.route) {
      case ImportRoute.managedCopy:
        return _managed(picked, decision, hash, stat);

      case ImportRoute.persistedGrant:
        final budget = await access.remainingGrantBudget();
        if (!ImportPolicy.grantBudgetExhausted(budget)) {
          try {
            final l = await access.persist(picked);
            if (l is ContentUriLocator) return (l as MediaLocator, MediaOwnership.external);
            if (l is AppRelativeLocator && l.root == AppRoot.documents) return (l as MediaLocator, MediaOwnership.external);
          } on MediaAccessFailure catch (e) {
            if (e.kind == MediaAccessFailureKind.outsideEditorRoots) rethrow;
            // Not persistable: fall back to a managed copy.
          }
        }
        return _managed(picked, decision, hash, stat);

      case ImportRoute.bookmark:
        final l = await access.persist(picked);
        return (_portable(l), MediaOwnership.external);

      case ImportRoute.documentsReference:
        final rel = roots.relativize(decision.sourcePath!);
        if (rel == null || rel.root != AppRoot.documents) return ImportRejected(picked, 'io');
        return (rel as MediaLocator, MediaOwnership.external);

      case ImportRoute.fileReference:
        return (FileLocator(decision.sourcePath!) as MediaLocator, MediaOwnership.external);

      case ImportRoute.projectLut:
        final source = await _readablePath(picked, decision, stat.sizeBytes);
        if (source == null) return ImportRejected(picked, 'notPersistable');
        final bytes = await _fs.readBytes(source.path);
        final lut = CubeLut.parse(bytes);
        final pid = session.committedProject.id;
        final cubeRel = ManagedStore.projectAssetRelPath(pid, 'luts', '$id.cube');
        final cube = await store.writeProjectBytes(cubeRel, bytes);
        await store.writeProjectBytes(ManagedStore.vlutOf(cube.locator).relPath, writeVlutFromCube(lut));
        if (source.temporary) await store.discardTemporary(source.path);
        return (cube.locator as MediaLocator, MediaOwnership.projectOwned);

      case ImportRoute.projectRecording:
      case ImportRoute.projectStill:
        final source = await _readablePath(picked, decision, stat.sizeBytes);
        if (source == null) return ImportRejected(picked, 'notPersistable');
        final pid = session.committedProject.id;
        final inBundle = roots.relativize(source.path);
        final bundleRel = '${roots.relativize(roots.projectDir(pid))?.relPath}/';
        if (inBundle != null && inBundle.root == AppRoot.support && inBundle.relPath.startsWith(bundleRel)) {
          return (inBundle as MediaLocator, MediaOwnership.projectOwned);
        }
        final recording = decision.route == ImportRoute.projectRecording;
        var ext = _extensionOf(picked.displayName).isNotEmpty ? _extensionOf(picked.displayName) : _extensionOf(source.path);
        if (ext.isEmpty) ext = recording ? '.wav' : '.png';
        final rel = ManagedStore.projectAssetRelPath(pid, recording ? 'recordings' : 'stills', '$id$ext');
        await _preflight(stat.sizeBytes, moving: source.temporary);
        final stored = await store.storeProjectFile(source.path, rel, temporary: source.temporary);
        return (stored.locator as MediaLocator, MediaOwnership.projectOwned);
    }
  }

  Future<Object> _managed(PickedMedia picked, ImportDecision decision, String hash, MediaStat stat) async {
    final known = await store.findManaged(hash);
    if (known != null) {
      if (decision.temporary && decision.sourcePath != null) await store.discardTemporary(decision.sourcePath!);
      return (known.locator as MediaLocator, MediaOwnership.managedCopy);
    }
    final source = await _readablePath(picked, decision, stat.sizeBytes);
    if (source == null) return ImportRejected(picked, 'notPersistable');
    await _preflight(stat.sizeBytes, moving: source.temporary && await store.deleter.canConsume(source.path));
    final stored = await store.adopt(source.path, quickHash: hash, displayName: picked.displayName, temporary: source.temporary);
    return (stored.locator as MediaLocator, MediaOwnership.managedCopy);
  }

  /// A plain path Dart can read for [picked]: the pick itself, or a platform copy of a URI.
  ///
  /// The platform copy lands in `work/picks` under the editor roots, so its free space is checked
  /// against the source size ([sizeBytes] plus the margin) before anything is copied (QA-02 M-17):
  /// the later preflight treats the copy as a move and skips, so this is the only check it gets.
  Future<({String path, bool temporary})?> _readablePath(PickedMedia picked, ImportDecision decision, int sizeBytes) async {
    final path = decision.sourcePath;
    if (path != null) return (path: path, temporary: decision.temporary);
    final copier = materialize;
    if (copier == null) return null;
    await _preflight(sizeBytes, moving: false, stage: 'materialize');
    final copied = await copier(picked, roots.picksDir);
    return (path: copied, temporary: true);
  }

  /// Refuses a copy of [sizeBytes] when the editor volume has less than that plus
  /// [ImportPolicy.freeSpaceMarginBytes] free; a move needs no new space. Throws a
  /// [StoreFailureKind.diskFull] [StoreFailure], which `import` reports as `diskFull`.
  Future<void> _preflight(int sizeBytes, {required bool moving, String stage = 'copy'}) async {
    final probeFree = freeSpace;
    if (probeFree == null || moving) return;
    final free = await probeFree(roots.editorSupport);
    final needed = (sizeBytes < 0 ? 0 : sizeBytes) + ImportPolicy.freeSpaceMarginBytes;
    if (free != null && free < needed) {
      throw StoreFailure(StoreFailureKind.diskFull, 'preflight $stage: needs $needed bytes, $free free');
    }
  }

  Future<MediaProbe?> _probe(MediaLocator locator) async {
    try {
      return await probe(await access.resolve(locator));
    } on MediaAccessFailure {
      rethrow;
    } on Object catch (e) {
      if (e is Error) rethrow;
      return null;
    }
  }

  MediaLocator _pickLocator(PickedMedia picked, ImportDecision decision) {
    final bookmark = picked.bookmark;
    if (decision.route == ImportRoute.bookmark && bookmark != null) {
      return BookmarkLocator(_base64Of(bookmark), lastKnownPath: decision.sourcePath ?? '');
    }
    if (decision.contentUri != null) return ContentUriLocator(decision.contentUri!);
    return FileLocator(decision.sourcePath!);
  }

  /// Never persist an absolute app-container path (ARCH §8.2).
  MediaLocator _portable(MediaLocator l) => switch (l) {
        FileLocator(:final path) => roots.relativize(path) ?? l,
        _ => l,
      };

  static MediaAsset? _findByHash(MediaPool pool, String hash) {
    for (final a in pool.assets.values) {
      if (a.derived == null && a.fingerprint.quickHash == hash) return a;
    }
    return null;
  }

  static String _issueReason(MediaProbe probe) {
    if (probe.issues.isEmpty) return 'unsupported';
    final parts = probe.issues.first.split(RegExp('[_-]')).where((s) => s.isNotEmpty).toList();
    if (parts.isEmpty) return 'unsupported';
    return [parts.first, for (final s in parts.skip(1)) s[0].toUpperCase() + s.substring(1)].join();
  }

  static String _extensionOf(String name) {
    final slash = name.lastIndexOf('/');
    final base = slash < 0 ? name : name.substring(slash + 1);
    final dot = base.lastIndexOf('.');
    if (dot <= 0) return '';
    final ext = base.substring(dot).toLowerCase();
    return RegExp(r'^\.[a-z0-9]{1,8}$').hasMatch(ext) ? ext : '';
  }

  // ------------------------------------------------------------------------------------------
  // Delegated to CORE-28
  // ------------------------------------------------------------------------------------------

  MediaRelinkDelegate get _relinker =>
      relinker ?? (throw UnsupportedError('availability and relink are provided by CORE-28 (MediaRelinkDelegate)'));

  @override
  Stream<MediaAvailabilityReport> watchAvailability(EditSession session) => _relinker.watchAvailability(session);

  @override
  Future<RelinkCheck> checkRelink(EditSession session, MediaId id, PickedMedia candidate) =>
      _relinker.checkRelink(session, id, candidate);

  @override
  Future<List<RelinkProposal>> autoMatch(EditSession session, List<PickedMedia> picks) => _relinker.autoMatch(session, picks);

  @override
  Future<EditOutcome> relink(EditSession session, Map<MediaId, PickedMedia> picks) => _relinker.relink(session, picks);

  @override
  Future<List<RelinkCandidate>> findInSameFolder(EditSession session, PickedMedia anchor) =>
      _relinker.findInSameFolder(session, anchor);
}

/// Base64 of bookmark bytes (the persisted form of `BookmarkLocator.bookmarkB64`).
String _base64Of(List<int> bytes) => const Base64Codec().encode(bytes);
