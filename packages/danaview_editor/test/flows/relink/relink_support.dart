// OWNER: UX-40
//
// Support for the UX-40 tests: a project with missing media, a scripted pool that behaves like the
// real relink service (it applies ONE `RelinkAssets` pool edit, with the clamps of a shorter file,
// to the session it is given), and a rig that opens the editor controller over the harness.

import 'dart:async';

import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor/src/editor/state/editor_controller.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart' show EditorPhase;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' hide MediaUnavailable;
import 'package:danaview_editor_core/store.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' show MediaPickRequest, MediaPickSource;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../support/support.dart';

/// A ready video asset [id] of [seconds] (1920x1080), originally a Photos copy that is gone.
MediaAsset videoAsset(
  String id, {
  int seconds = 5,
  String? name,
  MediaLocator? locator,
  MediaKind kind = MediaKind.video,
  MediaOrigin origin = MediaOrigin.photos,
  int size = 4000000,
}) =>
    MediaAsset(
      id: MediaId(id),
      kind: kind,
      displayName: name ?? '$id.mov',
      locator: locator ?? AppRelativeLocator(AppRoot.support, 'danaview/editor/media/${id.substring(id.length - 2)}/$id/${name ?? '$id.mov'}'),
      ownership: MediaOwnership.managedCopy,
      fingerprint: MediaFingerprint(sizeBytes: size, quickHash: 'hash-$id', duration: seconds * microsPerSecond),
      probe: MediaProbe(
        kind: kind,
        duration: kind == MediaKind.image ? 0 : seconds * microsPerSecond,
        hasVideo: kind == MediaKind.video || kind == MediaKind.image,
        hasAudio: kind == MediaKind.audio,
        width: kind == MediaKind.audio ? null : 1920,
        height: kind == MediaKind.audio ? null : 1080,
        nominalFps: kind == MediaKind.video ? 30 : null,
      ),
      origin: origin,
      addedAt: DateTime.utc(2026, 10, 1),
    );

/// Seeds [repo] with a project whose main lane holds one clip per asset (back to back) and returns
/// it. Assets of kind audio go on an audio lane.
EditProject projectWithMedia(FakeProjectRepository repo, List<MediaAsset> assets, {String name = 'Goa trip', Map<String, int> extraUses = const {}}) {
  final empty = repo.seedEmpty(name);
  final session = EditSession(empty, ids: SeededIdGenerator(21));
  session.applyPoolChange(AddAssets(assets));
  final visual = [for (final a in assets) if (a.kind != MediaKind.audio) a.id];
  final audio = [for (final a in assets) if (a.kind == MediaKind.audio) a.id];
  if (visual.isNotEmpty) {
    final out = session.apply(InsertMedia(visual, 0));
    if (out.rejection != null) throw StateError('seed: ${out.rejection}');
  }
  if (audio.isNotEmpty) {
    final out = session.apply(InsertMedia(audio, 0));
    if (out.rejection != null) throw StateError('seed audio: ${out.rejection}');
  }
  for (final e in extraUses.entries) {
    for (var n = 0; n < e.value; n++) {
      final out = session.apply(InsertMedia([MediaId(e.key)], session.committedProject.duration));
      if (out.rejection != null) throw StateError('seed extra: ${out.rejection}');
    }
  }
  repo.seed(session.committedProject);
  return session.committedProject;
}

/// A [MediaPoolService] over the harness fake that applies relinks like the real one.
class ScriptedRelinkPool extends FakeMediaPoolService {
  /// Checks by pick display name; the default is a match by duration.
  final Map<String, RelinkCheck> checks = {};

  /// Pick display names whose check throws a store failure.
  final Set<String> throwingChecks = {};

  /// Seconds of the new file by pick display name (a shorter one clamps clips); default: unchanged.
  final Map<String, int> newSeconds = {};

  /// Sessions `relink` was called with (the scratch sessions).
  final List<EditSession> relinkSessions = [];

  /// Picks of the last `relink` call.
  Map<MediaId, PickedMedia>? lastRelink;

  /// Made `relink` reject.
  bool rejectRelink = false;

  /// Assets `import` adds by pick display name (like the real service: a sticky pool change).
  final Map<String, MediaAsset> importAssets = {};

  /// Rejection reasons of `import` by pick display name.
  final Map<String, String> importRejections = {};

  @override
  Future<List<ImportOutcome>> import(EditSession session, List<PickedMedia> picked, {ImportTarget? target}) async {
    calls.add('import');
    final out = <ImportOutcome>[];
    for (final p in picked) {
      final reason = importRejections[p.displayName];
      final asset = importAssets[p.displayName];
      if (reason != null || asset == null) {
        out.add(ImportRejected(p, reason ?? 'unsupported'));
        continue;
      }
      session.applyPoolChange(AddAssets([asset]));
      out.add(ImportedMedia(p, asset));
    }
    return out;
  }

  @override
  Future<RelinkCheck> checkRelink(EditSession session, MediaId id, PickedMedia candidate) async {
    calls.add('checkRelink');
    if (throwingChecks.contains(candidate.displayName)) throw const StoreFailure(StoreFailureKind.io);
    return checks[candidate.displayName] ?? const RelinkMatch(exactFingerprint: false);
  }

  @override
  Future<EditOutcome> relink(EditSession session, Map<MediaId, PickedMedia> picks) async {
    calls.add('relink');
    relinkSessions.add(session);
    lastRelink = Map.of(picks);
    if (rejectRelink) return EditOutcome.rejected(session.project, const InvalidValue('relink'));
    final base = session.committedProject;
    final replacements = <MediaId, MediaAsset>{};
    final shorter = <MediaId, TimeUs>{};
    for (final e in picks.entries) {
      final asset = base.pool[e.key]!;
      final seconds = newSeconds[e.value.displayName];
      final duration = seconds == null ? asset.probe.duration : seconds * microsPerSecond;
      replacements[e.key] = asset.copyWith(
        displayName: e.value.displayName,
        locator: FileLocator('/restored/${e.value.displayName}'),
        ownership: MediaOwnership.external,
        fingerprint: MediaFingerprint(sizeBytes: asset.fingerprint.sizeBytes, quickHash: 'new-${e.key.value}', duration: duration),
        probe: asset.probe.copyWith(duration: duration),
      );
      if (duration < asset.probe.duration) shorter[e.key] = duration;
    }
    final trims = <EditCommand>[];
    for (final t in base.tracks) {
      for (final i in t.items) {
        if (i is MediaClip && shorter.containsKey(i.media) && i.sourceIn + i.duration > shorter[i.media]!) {
          trims.add(TrimItem(i.id, TrimEdge.end, i.start + shorter[i.media]! - i.sourceIn, clamp: true));
        }
      }
    }
    return session.applyPoolEdit(RelinkAssets(replacements), adjust: trims.isEmpty ? null : CompositeCommand('Relink media', trims));
  }
}

/// The editor controller of a project with missing media, opened over the harness.
class RelinkRig {
  /// Creates the rig; [assets] are the pool (one clip each).
  RelinkRig(this.assets, {ScriptedRelinkPool? pool, FakeProjectRepository? repository, Map<String, int> extraUses = const {}, List<Override> overrides = const []})
      : pool = pool ?? ScriptedRelinkPool(),
        repo = repository ?? FakeProjectRepository() {
    harness = EditorTestHarness(mediaPool: this.pool, repository: repo, overrides: overrides);
    project = projectWithMedia(repo, assets, extraUses: extraUses);
    id = project.id;
  }

  /// The pool assets.
  final List<MediaAsset> assets;

  /// The scripted pool.
  final ScriptedRelinkPool pool;

  /// The project store.
  final FakeProjectRepository repo;

  /// The harness.
  late final EditorTestHarness harness;

  /// The seeded project.
  late final EditProject project;

  /// Its id.
  late final ProjectId id;

  /// The container of a unit test (see [useContainer]).
  late ProviderContainer container;

  /// Uses [c] as the container.
  void useContainer(ProviderContainer c) => container = c;

  /// The editor controller.
  EditorController get editor => container.read(editorControllerProvider(id).notifier);

  /// Opens the editor.
  Future<void> open() async {
    await editor.open();
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    if (editor.state.phase != EditorPhase.ready) throw StateError('editor did not open: ${editor.state.failure}');
  }

  /// Marks [offline] assets with their availability and lets listeners run.
  Future<void> report(Map<String, MediaAvailability> offline) async {
    pool.emitAvailability({
      for (final a in assets) a.id: offline[a.id.value] ?? MediaAvailability.available,
    });
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }
}

/// The pick requests the fake picker saw.
List<MediaPickRequest> pickRequests(EditorTestHarness h) => h.engine.picker.requests;

/// Sources of the pick requests.
List<MediaPickSource> pickSources(EditorTestHarness h) => [for (final r in pickRequests(h)) r.source];

/// A repository for tests that need a project without the rest of the rig.
abstract final class FakeProjectRepositoryHolder {
  /// A new empty fake repository.
  static FakeProjectRepository make() => FakeProjectRepository();
}
