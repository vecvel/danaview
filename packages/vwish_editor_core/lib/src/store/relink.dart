// OWNER: CORE-28
//
// Relink (ARCH §9.2-9.3): [MediaRelinkService] is the `MediaRelinkDelegate` that
// `FileMediaPoolService` (CORE-27) forwards availability and relink calls to.
//
// * `checkRelink(asset, candidate)`:
//     match            the candidate's quickHash equals the fingerprint, or its duration is within
//                      ±100 ms with an equal kind and equal dimensions;
//     durationMismatch same kind, durations differ by more than 100 ms (accepting clamps clips);
//     differentKind    video vs image vs audio vs LUT;
//     unsupported      unreadable, not editable, or same kind and duration with other dimensions
//                      (`dimensionsDiffer`).
// * `relink(session, picks)` persists each pick the way an import would (managed copy, bookmark,
//   persisted grant, Documents reference; ImportPolicy) and applies ONE undoable
//   `RelinkAssets` pool edit ("Relink media") that keeps every MediaId; clips beyond the end of a
//   shorter replacement are trimmed (or removed when they start beyond it) in the same entry.
// * `autoMatch(session, picks)` ("Relink several"): each pick is paired with a blocking asset
//   (missing, access lost, changed): exact fingerprint first, then duration ±100 ms with equal
//   kind and dimensions; a pick with several candidates, or a candidate wanted by several picks,
//   is left unassigned.
// * `findInSameFolder(session, anchor)`: files named like other missing assets in the anchor's
//   folder, only where that folder is readable (the app's Documents, desktop paths).
//
// Original files are only read (stat, hash, probe); copies are made by `ManagedStore`.

import 'dart:async';
import 'dart:convert' show base64;

import 'package:path/path.dart' as p;

import '../eval/clip_time_map.dart';
import '../ids/ids.dart';
import '../model/items.dart';
import '../model/pool/fingerprint.dart';
import '../model/pool/media_access_port.dart';
import '../model/pool/media_asset.dart';
import '../model/pool/media_locator.dart';
import '../model/pool/media_pool.dart';
import '../model/pool/media_probe.dart';
import '../model/pool/picked_media.dart';
import '../ops/edit_command.dart';
import '../ops/outcome.dart';
import '../ops/rejections.dart';
import '../session/session.dart';
import '../time/time.dart';
import 'availability.dart';
import 'import_policy.dart';
import 'managed_store.dart';
import 'media_pool_service.dart';
import 'owned_file_deleter.dart';
import 'store_fs.dart';
import 'store_roots.dart';

/// Durations within this tolerance count as equal (±100 ms).
const int relinkDurationToleranceUs = 100000;

/// Availability, relink, "Relink several" and same-folder search (see the file header).
final class MediaRelinkService implements MediaRelinkDelegate {
  /// Creates the service. [store] defaults to a `ManagedStore` over [roots] and [fs] (with
  /// [deleter], which must share [fs]); [platform] to the host's. [materialize] copies URIs Dart
  /// cannot read (as for imports).
  MediaRelinkService({
    required this.access,
    required this.probe,
    required this.roots,
    StoreFs fs = const LocalStoreFs(),
    ImportPlatform? platform,
    ManagedStore? store,
    OwnedFileDeleter? deleter,
    this.materialize,
    DateTime Function()? clock,
  })  : _fs = fs,
        policy = ImportPolicy(platform: platform ?? FileMediaPoolService.hostImportPlatform(), roots: roots),
        store = store ?? ManagedStore(roots, fs: fs, deleter: deleter ?? OwnedFileDeleter(roots, fs: fs), access: access),
        checker = MediaAvailabilityChecker(access),
        _clock = clock ?? _utcNow;

  static DateTime _utcNow() => DateTime.now().toUtc();

  /// The platform port.
  final MediaAccessPort access;

  /// Engine probe.
  final MediaProber probe;

  /// App roots.
  final StoreRoots roots;

  /// Routing of relinked picks (same as imports).
  final ImportPolicy policy;

  /// Managed copies.
  final ManagedStore store;

  /// Availability checks.
  final MediaAvailabilityChecker checker;

  /// Copier for picks Dart cannot read.
  final PickMaterializer? materialize;

  final StoreFs _fs;
  final DateTime Function() _clock;
  final Expando<AvailabilityMonitor> _monitors = Expando('availability monitor');
  final List<WeakReference<EditSession>> _watched = [];

  // ------------------------------------------------------------------------------------------
  // Availability
  // ------------------------------------------------------------------------------------------

  /// The monitor of [session] (created on first use).
  AvailabilityMonitor monitorOf(EditSession session) {
    final existing = _monitors[session];
    if (existing != null) return existing;
    _watched.add(WeakReference(session));
    return _monitors[session] = AvailabilityMonitor(session, checker);
  }

  @override
  Stream<MediaAvailabilityReport> watchAvailability(EditSession session) => monitorOf(session).watch();

  /// Re-checks every watched session (call on app resume).
  Future<void> resumed() async {
    _watched.removeWhere((w) => w.target == null);
    for (final w in [..._watched]) {
      final s = w.target;
      if (s != null) await monitorOf(s).refresh();
    }
  }

  /// Blocking assets of [session] right now (missing, access lost, changed).
  Future<List<MediaAsset>> blockingAssets(EditSession session) async {
    final report = await monitorOf(session).refresh();
    final pool = session.project.pool;
    return [
      for (final id in report.blocking)
        if (pool[id] case final a?) a,
    ];
  }

  // ------------------------------------------------------------------------------------------
  // Checks
  // ------------------------------------------------------------------------------------------

  @override
  Future<RelinkCheck> checkRelink(EditSession session, MediaId id, PickedMedia candidate) async {
    final asset = session.project.pool[id];
    if (asset == null) return const RelinkUnsupported('unknownMedia');
    return _checkAgainst(asset, await _inspect(candidate));
  }

  Future<_Inspected> _inspect(PickedMedia pick) async {
    final decision = policy.decide(pick);
    final MediaLocator locator;
    final bookmark = pick.bookmark;
    if (bookmark != null) {
      locator = BookmarkLocator(base64.encode(bookmark), lastKnownPath: decision.sourcePath ?? '');
    } else if (decision.contentUri != null) {
      locator = ContentUriLocator(decision.contentUri!);
    } else if (decision.sourcePath != null) {
      locator = FileLocator(decision.sourcePath!);
    } else {
      return _Inspected.failed(pick, decision, 'unsupported');
    }
    try {
      final stat = await access.stat(locator);
      if (stat == null) return _Inspected.failed(pick, decision, 'notFound');
      if (stat.sizeBytes == 0) return _Inspected.failed(pick, decision, 'empty');
      final hash = await access.quickHash(locator);
      return _Inspected(pick, decision, locator, stat, hash);
    } on MediaAccessFailure catch (e) {
      if (e.kind == MediaAccessFailureKind.outsideEditorRoots) rethrow;
      return _Inspected.failed(pick, decision, e.kind == MediaAccessFailureKind.notFound ? 'notFound' : 'accessDenied');
    }
  }

  /// The probe of [c] (once), or null when it cannot be probed; sets [_Inspected.failure].
  Future<MediaProbe?> _probeOf(_Inspected c) async {
    if (c.probed) return c.probe;
    c.probed = true;
    if (c.failure != null) return null;
    if (ImportPolicy.isLut(c.pick)) {
      c.probe = MediaProbe(kind: MediaKind.lut, sizeBytes: c.stat!.sizeBytes);
      return c.probe;
    }
    try {
      final pr = await probe(await access.resolve(c.locator!));
      if (!pr.editable) {
        c.failure = pr.issues.isEmpty ? 'unsupported' : _lowerCamel(pr.issues.first);
        return null;
      }
      return c.probe = pr;
    } on MediaAccessFailure catch (e) {
      if (e.kind == MediaAccessFailureKind.outsideEditorRoots) rethrow;
      c.failure = 'accessDenied';
      return null;
    } on Object catch (e) {
      if (e is Error) rethrow;
      c.failure = 'unsupported';
      return null;
    }
  }

  Future<RelinkCheck> _checkAgainst(MediaAsset asset, _Inspected c) async {
    final failure = c.failure;
    if (failure != null) return RelinkUnsupported(failure);
    if (asset.fingerprint.quickHash.isNotEmpty && c.hash == asset.fingerprint.quickHash) {
      return const RelinkMatch(exactFingerprint: true);
    }
    final pr = await _probeOf(c);
    if (pr == null) return RelinkUnsupported(c.failure ?? 'unsupported');
    return compareForRelink(asset, pr);
  }

  // ------------------------------------------------------------------------------------------
  // Relink
  // ------------------------------------------------------------------------------------------

  @override
  Future<EditOutcome> relink(EditSession session, Map<MediaId, PickedMedia> picks) async {
    final base = session.project;
    if (picks.isEmpty) return EditOutcome(project: base, noop: true);
    final replacements = <MediaId, MediaAsset>{};
    final shorter = <MediaId, int>{};
    for (final e in picks.entries) {
      final asset = base.pool[e.key];
      if (asset == null) return EditOutcome.rejected(base, MediaUnavailable(e.key));
      final c = await _inspect(e.value);
      final check = await _checkAgainst(asset, c);
      if (check is RelinkDifferentKind || check is RelinkUnsupported) {
        return EditOutcome.rejected(base, const InvalidValue('relink'));
      }
      final probe = check is RelinkMatch && check.exactFingerprint ? asset.probe : (await _probeOf(c))!;
      final stored = await _persist(session, asset, c);
      if (stored == null) return EditOutcome.rejected(base, const InvalidValue('relink'));
      final (locator, ownership) = stored;
      replacements[e.key] = asset.copyWith(
        displayName: e.value.displayName,
        locator: locator,
        ownership: ownership,
        fingerprint: MediaFingerprint(
          sizeBytes: c.stat!.sizeBytes,
          quickHash: c.hash!,
          modifiedMs: c.stat!.modifiedMs,
          duration: probe.duration,
        ),
        probe: probe.sizeBytes == 0 ? probe.copyWith(sizeBytes: c.stat!.sizeBytes) : probe,
        origin: e.value.origin,
        status: AssetStatus.ready,
      );
      if (check is RelinkDurationMismatch && check.actualUs < check.expectedUs) shorter[e.key] = check.actualUs;
    }
    final adjust = _clampsFor(session, shorter);
    final outcome = session.applyPoolEdit(RelinkAssets(replacements), adjust: adjust);
    unawaited(monitorOf(session).refresh());
    return outcome;
  }

  /// Trims (or removes) clips that run past the end of a shorter replacement: a forward clip loses
  /// its tail, a reversed clip its head (where the late source plays), keeping the speed; a clip
  /// that starts beyond the new end is removed.
  EditCommand? _clampsFor(EditSession session, Map<MediaId, int> shorter) {
    if (shorter.isEmpty) return null;
    final rate = session.project.settings.frameRate;
    final trims = <EditCommand>[];
    final drop = <ItemId>{};
    for (final t in session.project.tracks) {
      for (final i in t.items) {
        if (i is! MediaClip) continue;
        final limit = shorter[i.media];
        if (limit == null) continue;
        if (i.sourceIn + ClipTimeMap.sourceLengthOf(i.duration, i.speed) <= limit) continue;
        if (i.sourceIn >= limit) {
          drop.add(i.id);
          continue;
        }
        // The longest whole-frame duration whose source stays within the new file.
        final k0 = rate.frameIndexOf(i.start), k1 = rate.frameIndexOf(i.end);
        TimeUs lengthOf(int frames) => i.reversed
            ? i.end - rate.timeOfFrame(k1 - frames)
            : rate.timeOfFrame(k0 + frames) - i.start;
        final estimate = rate.frameIndexOf(ClipTimeMap.durationFor(TimeRange(i.sourceIn, limit), i.speed, rate)) + 2;
        var frames = estimate < k1 - k0 ? estimate : k1 - k0;
        while (frames > 0 && i.sourceIn + ClipTimeMap.sourceLengthOf(lengthOf(frames), i.speed) > limit) {
          frames--;
        }
        if (frames < 1) {
          drop.add(i.id);
        } else if (i.reversed) {
          trims.add(TrimItem(i.id, TrimEdge.start, rate.timeOfFrame(k1 - frames), clamp: true));
        } else {
          trims.add(TrimItem(i.id, TrimEdge.end, rate.timeOfFrame(k0 + frames), clamp: true));
        }
      }
    }
    final commands = [if (drop.isNotEmpty) DeleteItems(drop), ...trims];
    if (commands.isEmpty) return null;
    return CompositeCommand('Relink media', commands);
  }

  /// Persists [c] for [asset] the way an import would; null when it cannot be read.
  Future<(MediaLocator, MediaOwnership)?> _persist(EditSession session, MediaAsset asset, _Inspected c) async {
    final d = c.decision;
    final pick = c.pick;
    switch (d.route) {
      case ImportRoute.managedCopy:
        return _managed(c);
      case ImportRoute.persistedGrant:
        if (!ImportPolicy.grantBudgetExhausted(await access.remainingGrantBudget())) {
          try {
            final l = await access.persist(pick);
            if (l is ContentUriLocator) return (l, MediaOwnership.external);
          } on MediaAccessFailure catch (e) {
            if (e.kind == MediaAccessFailureKind.outsideEditorRoots) rethrow;
          }
        }
        return _managed(c);
      case ImportRoute.bookmark:
        final l = await access.persist(pick);
        final portable = l is FileLocator ? (roots.relativize(l.path) ?? l) : l;
        return (portable, MediaOwnership.external);
      case ImportRoute.documentsReference:
        final rel = roots.relativize(d.sourcePath!);
        if (rel == null || rel.root != AppRoot.documents) return null;
        return (rel, MediaOwnership.external);
      case ImportRoute.fileReference:
        return (FileLocator(d.sourcePath!), MediaOwnership.external);
      case ImportRoute.projectLut:
      case ImportRoute.projectRecording:
      case ImportRoute.projectStill:
        final source = await _readable(c);
        if (source == null) return null;
        final folder = switch (asset.kind) {
          MediaKind.lut => 'luts',
          MediaKind.recording => 'recordings',
          _ => 'stills',
        };
        var ext = p.extension(pick.displayName).toLowerCase();
        if (!RegExp(r'^\.[a-z0-9]{1,8}$').hasMatch(ext)) ext = p.extension(source.path).toLowerCase();
        final stamp = _clock().microsecondsSinceEpoch.toRadixString(36);
        final rel = ManagedStore.projectAssetRelPath(session.project.id, folder, '${asset.id}-r$stamp$ext');
        final stored = await store.storeProjectFile(source.path, rel, temporary: source.temporary);
        return (stored.locator, MediaOwnership.projectOwned);
    }
  }

  Future<(MediaLocator, MediaOwnership)?> _managed(_Inspected c) async {
    final known = await store.findManaged(c.hash!);
    if (known != null) {
      final d = c.decision;
      if (d.temporary && d.sourcePath != null) await store.discardTemporary(d.sourcePath!);
      return (known.locator, MediaOwnership.managedCopy);
    }
    final source = await _readable(c);
    if (source == null) return null;
    final stored = await store.adopt(source.path, quickHash: c.hash!, displayName: c.pick.displayName, temporary: source.temporary);
    return (stored.locator, MediaOwnership.managedCopy);
  }

  Future<({String path, bool temporary})?> _readable(_Inspected c) async {
    final path = c.decision.sourcePath;
    if (path != null) return (path: path, temporary: c.decision.temporary);
    final copier = materialize;
    if (copier == null) return null;
    return (path: await copier(c.pick, roots.picksDir), temporary: true);
  }

  // ------------------------------------------------------------------------------------------
  // Relink several
  // ------------------------------------------------------------------------------------------

  @override
  Future<List<RelinkProposal>> autoMatch(EditSession session, List<PickedMedia> picks) async {
    final targets = await blockingAssets(session);
    final inspected = [for (final pick in picks) await _inspect(pick)];
    final assigned = <int, MediaId>{};
    final checks = <int, RelinkCheck>{};
    final taken = <MediaId>{};

    // 1. Exact fingerprints.
    for (var i = 0; i < inspected.length; i++) {
      final c = inspected[i];
      if (c.failure != null) continue;
      for (final a in targets) {
        if (taken.contains(a.id) || a.fingerprint.quickHash.isEmpty || a.fingerprint.quickHash != c.hash) continue;
        assigned[i] = a.id;
        checks[i] = const RelinkMatch(exactFingerprint: true);
        taken.add(a.id);
        break;
      }
    }

    // 2. Duration ±100 ms with equal kind and dimensions; only one-to-one pairs.
    final candidates = <int, List<MediaId>>{};
    final wanted = <MediaId, List<int>>{};
    for (var i = 0; i < inspected.length; i++) {
      if (assigned.containsKey(i)) continue;
      final c = inspected[i];
      final pr = await _probeOf(c);
      if (pr == null) {
        checks[i] = RelinkUnsupported(c.failure ?? 'unsupported');
        continue;
      }
      for (final a in targets) {
        if (taken.contains(a.id)) continue;
        final r = compareForRelink(a, pr);
        if (r is RelinkMatch) {
          (candidates[i] ??= []).add(a.id);
          (wanted[a.id] ??= []).add(i);
        }
      }
    }
    for (final e in candidates.entries) {
      if (e.value.length == 1 && wanted[e.value.single]!.length == 1) {
        assigned[e.key] = e.value.single;
        checks[e.key] = const RelinkMatch(exactFingerprint: false);
      } else {
        checks[e.key] = const RelinkUnsupported('ambiguous');
      }
    }
    return [
      for (var i = 0; i < picks.length; i++)
        RelinkProposal(pick: picks[i], media: assigned[i], check: checks[i] ?? const RelinkUnsupported('noMatch')),
    ];
  }

  // ------------------------------------------------------------------------------------------
  // Same folder
  // ------------------------------------------------------------------------------------------

  @override
  Future<List<RelinkCandidate>> findInSameFolder(EditSession session, PickedMedia anchor) async {
    if (anchor.bookmark != null || anchor.uri.startsWith('content://')) return const [];
    final path = ImportPolicy.pathOf(anchor.uri);
    if (path == null) return const [];
    final readable = policy.platform == ImportPlatform.desktop || p.isWithin(p.normalize(roots.documents), path);
    if (!readable) return const [];
    final dir = p.dirname(path);
    final List<StoreEntry> entries;
    try {
      if ((await _fs.stat(dir)).type != StoreEntityType.directory) return const [];
      entries = await _fs.list(dir);
    } on StoreFailure {
      return const [];
    }
    final byName = <String, String>{};
    for (final e in entries) {
      if (e.type != StoreEntityType.file || p.equals(e.path, path)) continue;
      byName.putIfAbsent(p.basename(e.path).toLowerCase(), () => e.path);
    }
    final out = <RelinkCandidate>[];
    for (final a in await blockingAssets(session)) {
      final names = {a.displayName.toLowerCase(), _locatorName(a.locator)?.toLowerCase()};
      String? found;
      for (final n in names) {
        if (n != null && byName[n] != null) {
          found = byName[n];
          break;
        }
      }
      if (found == null) continue;
      final pick = PickedMedia(uri: found, displayName: p.basename(found), origin: anchor.origin);
      final check = await _checkAgainst(a, await _inspect(pick));
      if (check is RelinkMatch || check is RelinkDurationMismatch) out.add(RelinkCandidate(media: a.id, pick: pick, check: check));
    }
    return out;
  }

  static String? _locatorName(MediaLocator l) => switch (l) {
        AppRelativeLocator(:final relPath) => p.posix.basename(relPath),
        FileLocator(:final path) => p.basename(path),
        BookmarkLocator(:final lastKnownPath) when lastKnownPath.isNotEmpty => p.basename(lastKnownPath),
        _ => null,
      };

  static String _lowerCamel(String code) {
    final parts = code.split(RegExp('[_-]')).where((s) => s.isNotEmpty).toList();
    if (parts.isEmpty) return 'unsupported';
    return [parts.first, for (final s in parts.skip(1)) s[0].toUpperCase() + s.substring(1)].join();
  }
}

/// Compares a candidate's probe with [asset] (no fingerprint match): see the file header.
RelinkCheck compareForRelink(MediaAsset asset, MediaProbe candidate) {
  final want = _family(asset.kind);
  if (want != _family(candidate.kind)) return const RelinkDifferentKind();
  if (want == _Family.lut) return const RelinkUnsupported('lutContentDiffers');
  final expected = asset.probe.duration > 0 ? asset.probe.duration : asset.fingerprint.duration;
  final timed = want == _Family.video || want == _Family.audio;
  if (timed && (candidate.duration - expected).abs() > relinkDurationToleranceUs) {
    return RelinkDurationMismatch(expectedUs: expected, actualUs: candidate.duration);
  }
  if (want == _Family.video || want == _Family.image) {
    final (w0, h0) = _dims(asset.probe);
    final (w1, h1) = _dims(candidate);
    if (w0 != null && h0 != null && (w0 != w1 || h0 != h1)) return const RelinkUnsupported('dimensionsDiffer');
  }
  return const RelinkMatch(exactFingerprint: false);
}

enum _Family { video, image, audio, lut }

_Family _family(MediaKind k) => switch (k) {
      MediaKind.video => _Family.video,
      MediaKind.image || MediaKind.still => _Family.image,
      MediaKind.audio || MediaKind.recording => _Family.audio,
      MediaKind.lut => _Family.lut,
    };

/// Display dimensions (rotation applied).
(int?, int?) _dims(MediaProbe pr) {
  final w = pr.width, h = pr.height;
  if (pr.rotation % 180 != 0) return (h, w);
  return (w, h);
}

/// One inspected pick (stat + hash once; probe on demand).
final class _Inspected {
  _Inspected(this.pick, this.decision, this.locator, this.stat, this.hash);

  _Inspected.failed(this.pick, this.decision, this.failure)
      : locator = null,
        stat = null,
        hash = null;

  final PickedMedia pick;
  final ImportDecision decision;
  final MediaLocator? locator;
  final MediaStat? stat;
  final String? hash;
  String? failure;
  bool probed = false;
  MediaProbe? probe;
}
