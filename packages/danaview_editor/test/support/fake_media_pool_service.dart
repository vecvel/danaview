// OWNER: UX-01
//
// FakeMediaPoolService for danaview_editor widget tests: scriptable results and a call log. CORE-27
// and CORE-28 implement the real service; `EditOutcome` is still CORE-09's placeholder, so
// [FakeMediaPoolService.onRelink] must be scripted before `relink` is called.

import 'dart:async';

import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show EditOutcome, EditSession;
import 'package:danaview_editor_core/store.dart';

/// A scriptable [MediaPoolService].
class FakeMediaPoolService implements MediaPoolService {
  /// Every call by method name.
  final List<String> calls = <String>[];

  /// Import results; the default rejects every pick with `notScripted`.
  Future<List<ImportOutcome>> Function(List<PickedMedia> picked, ImportTarget? target)? onImport;

  /// Relink check; the default is an exact match.
  RelinkCheck Function(MediaId id, PickedMedia candidate)? onCheckRelink;

  /// "Relink several" proposals; the default leaves every pick unassigned.
  List<RelinkProposal> Function(List<PickedMedia> picks)? onAutoMatch;

  /// Relink result (must be scripted; `EditOutcome` is defined by CORE-09).
  Future<EditOutcome> Function(Map<MediaId, PickedMedia> picks)? onRelink;

  /// Candidates of `findInSameFolder`; the default is none.
  List<RelinkCandidate> Function(PickedMedia anchor)? onFindInSameFolder;

  /// The availability reported first by [watchAvailability].
  Map<MediaId, MediaAvailability> availability = <MediaId, MediaAvailability>{};

  final StreamController<MediaAvailabilityReport> _availability = StreamController<MediaAvailabilityReport>.broadcast();

  /// Pushes a new availability report to watchers.
  void emitAvailability(Map<MediaId, MediaAvailability> next) {
    availability = Map.of(next);
    _availability.add(MediaAvailabilityReport(availability));
  }

  /// Closes the availability stream.
  Future<void> dispose() => _availability.close();

  @override
  Future<List<ImportOutcome>> import(EditSession session, List<PickedMedia> picked, {ImportTarget? target}) async {
    calls.add('import');
    final script = onImport;
    if (script != null) return script(picked, target);
    return [for (final p in picked) ImportRejected(p, 'notScripted')];
  }

  @override
  Stream<MediaAvailabilityReport> watchAvailability(EditSession session) async* {
    calls.add('watchAvailability');
    yield MediaAvailabilityReport(availability);
    yield* _availability.stream;
  }

  @override
  Future<RelinkCheck> checkRelink(EditSession session, MediaId id, PickedMedia candidate) async {
    calls.add('checkRelink');
    return onCheckRelink?.call(id, candidate) ?? const RelinkMatch(exactFingerprint: true);
  }

  @override
  Future<List<RelinkProposal>> autoMatch(EditSession session, List<PickedMedia> picks) async {
    calls.add('autoMatch');
    return onAutoMatch?.call(picks) ??
        [for (final p in picks) RelinkProposal(pick: p, media: null, check: const RelinkUnsupported('unassigned'))];
  }

  @override
  Future<EditOutcome> relink(EditSession session, Map<MediaId, PickedMedia> picks) {
    calls.add('relink');
    final script = onRelink;
    if (script == null) throw StateError('FakeMediaPoolService.onRelink is not scripted');
    return script(picks);
  }

  @override
  Future<List<RelinkCandidate>> findInSameFolder(EditSession session, PickedMedia anchor) async {
    calls.add('findInSameFolder');
    return onFindInSameFolder?.call(anchor) ?? const <RelinkCandidate>[];
  }
}
