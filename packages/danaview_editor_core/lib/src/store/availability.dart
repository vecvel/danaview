// OWNER: CORE-28
//
// Media availability (ARCH §9.3). For every pool asset:
//
// * `available`      the file is readable and matches its fingerprint;
// * `missing`        not found (or a placeholder asset that `repair()` made for a dangling clip);
// * `accessLost`     the grant was revoked or the bookmark cannot be resolved;
// * `changed`        found, but the size or `quickHash` differs ("Use updated file" or Relink);
// * `derivedMissing` a rendition, still or LUT companion is gone and will be requeued silently.
//
// A file whose size and modification time equal the fingerprint's is `available` without hashing;
// otherwise the `quickHash` (64 KiB head + tail) decides. Checks only read: nothing is written,
// moved or deleted. [AvailabilityMonitor] re-checks a session on open (first listen), on app
// resume ([AvailabilityMonitor.refresh]) and after a relink.

import 'dart:async';

import 'package:meta/meta.dart';

import '../ids/ids.dart';
import '../model/pool/media_access_port.dart';
import '../model/pool/media_asset.dart';
import '../model/pool/media_locator.dart';
import '../model/pool/media_pool.dart';
import '../model/pool/media_probe.dart';
import '../model/pool/picked_media.dart';
import '../session/session.dart';
import 'managed_store.dart';
import 'media_pool_service.dart';

/// Status reason `repair()` gives placeholder assets of dangling clips (`FailedStatus`).
const String missingPlaceholderReason = 'missing';

/// Checks assets against the platform port.
final class MediaAvailabilityChecker {
  /// Creates a checker over [access].
  const MediaAvailabilityChecker(this.access);

  /// The platform port (stat, quickHash).
  final MediaAccessPort access;

  /// The availability of [asset].
  Future<MediaAvailability> check(MediaAsset asset) async {
    final status = asset.status;
    if (status is FailedStatus && status.reason == missingPlaceholderReason) return MediaAvailability.missing;
    final derived = asset.derived != null || asset.origin == MediaOrigin.derived;
    if (status is PendingStatus) return MediaAvailability.derivedMissing;
    final MediaStat? stat;
    try {
      stat = await access.stat(asset.locator);
    } on MediaAccessFailure catch (e) {
      return switch (e.kind) {
        MediaAccessFailureKind.notFound => derived ? MediaAvailability.derivedMissing : MediaAvailability.missing,
        MediaAccessFailureKind.accessLost || MediaAccessFailureKind.permissionDenied => MediaAvailability.accessLost,
        MediaAccessFailureKind.outsideEditorRoots || MediaAccessFailureKind.io => MediaAvailability.accessLost,
      };
    }
    if (stat == null) return derived ? MediaAvailability.derivedMissing : MediaAvailability.missing;
    if (asset.kind == MediaKind.lut) {
      // The .cube is the user's data; the .vlut is regenerated from it.
      final locator = asset.locator;
      if (locator is AppRelativeLocator) {
        try {
          if (await access.stat(ManagedStore.vlutOf(locator)) == null) return MediaAvailability.derivedMissing;
        } on MediaAccessFailure {
          return MediaAvailability.derivedMissing;
        }
      }
    }
    if (derived) return MediaAvailability.available; // regenerable; content is ours
    final fp = asset.fingerprint;
    if (fp.sizeBytes > 0 && stat.sizeBytes != fp.sizeBytes) return MediaAvailability.changed;
    if (fp.modifiedMs != null && stat.modifiedMs == fp.modifiedMs) return MediaAvailability.available;
    if (fp.quickHash.isEmpty) return MediaAvailability.available;
    try {
      final hash = await access.quickHash(asset.locator);
      return hash == fp.quickHash ? MediaAvailability.available : MediaAvailability.changed;
    } on MediaAccessFailure catch (e) {
      return e.kind == MediaAccessFailureKind.notFound ? MediaAvailability.missing : MediaAvailability.accessLost;
    }
  }

  /// The availability of every asset of [pool].
  Future<MediaAvailabilityReport> checkPool(MediaPool pool) async {
    final out = <MediaId, MediaAvailability>{};
    for (final a in pool.assets.values) {
      out[a.id] = await check(a);
    }
    return MediaAvailabilityReport(out);
  }
}

/// Availability reports of one session, re-checked on demand.
final class AvailabilityMonitor {
  /// Creates a monitor of [session].
  AvailabilityMonitor(this.session, this.checker);

  /// The session.
  final EditSession session;

  /// The checker.
  final MediaAvailabilityChecker checker;

  final List<StreamController<MediaAvailabilityReport>> _listeners = [];
  MediaAvailabilityReport? _last;
  Future<MediaAvailabilityReport>? _checking;
  bool _again = false;

  /// The latest report, if any.
  MediaAvailabilityReport? get last => _last;

  /// Reports: the current state on listen, then one per [refresh].
  Stream<MediaAvailabilityReport> watch() {
    late final StreamController<MediaAvailabilityReport> c;
    c = StreamController<MediaAvailabilityReport>(
      onListen: () {
        _listeners.add(c);
        unawaited(refresh());
      },
      onCancel: () {
        _listeners.remove(c);
      },
    );
    return c.stream;
  }

  /// Re-checks the session's pool (app resume, after relink) and emits the report. Concurrent
  /// calls share a check (and run one more when the pool changed meanwhile).
  Future<MediaAvailabilityReport> refresh() {
    final running = _checking;
    if (running != null) {
      _again = true;
      return running;
    }
    return _checking = _run().whenComplete(() => _checking = null);
  }

  Future<MediaAvailabilityReport> _run() async {
    MediaAvailabilityReport r;
    do {
      _again = false;
      r = await checker.checkPool(session.project.pool);
    } while (_again);
    _last = r;
    for (final c in [..._listeners]) {
      if (!c.isClosed) c.add(r);
    }
    return r;
  }

  /// Closes every listener.
  Future<void> dispose() async {
    for (final c in [..._listeners]) {
      await c.close();
    }
    _listeners.clear();
  }
}

/// Counts of a report for summaries (`ProjectSummary.missingMediaCount`).
@immutable
final class AvailabilityCounts {
  /// Counts [report].
  factory AvailabilityCounts.of(MediaAvailabilityReport report) {
    var missing = 0, lost = 0, changed = 0, derived = 0;
    for (final v in report.byMedia.values) {
      switch (v) {
        case MediaAvailability.missing:
          missing++;
        case MediaAvailability.accessLost:
          lost++;
        case MediaAvailability.changed:
          changed++;
        case MediaAvailability.derivedMissing:
          derived++;
        case MediaAvailability.available:
          break;
      }
    }
    return AvailabilityCounts._(missing, lost, changed, derived);
  }

  const AvailabilityCounts._(this.missing, this.accessLost, this.changed, this.derivedMissing);

  /// Missing assets.
  final int missing;

  /// Assets whose access was lost.
  final int accessLost;

  /// Changed assets.
  final int changed;

  /// Regenerable derived files that are gone.
  final int derivedMissing;

  /// Assets that block export (the Projects list's "missing media" count).
  int get blocking => missing + accessLost + changed;
}
