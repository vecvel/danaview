// OWNER: UX-06
//
// Fakes for the import flow tests: a scripted media pool that behaves like the real service (each
// imported asset is added to the session's pool as a sticky `AddAssets`) and simulates copies in a
// `MemoryStoreFs` (`.part` file, progress, abort on cancel with the partial file deleted), plus
// pick and asset builders.

import 'dart:async';

import 'package:vwish_editor/src/editor/flows/import_media_sheet.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/ops.dart' show EditSession;
import 'package:vwish_editor_core/store.dart';
import 'package:vwish_editor_core/testing.dart';

import '../../support/support.dart';

/// A picked item.
PickedMedia pickOf(String name, {MediaOrigin origin = MediaOrigin.files, int? size, bool temporary = false}) => PickedMedia(
      uri: 'file:///picked/$name',
      displayName: name,
      origin: origin,
      isTemporaryCopy: temporary,
      sizeBytes: size,
    );

var _assetCounter = 0;

/// A pool asset for [picked].
MediaAsset assetFor(
  PickedMedia picked, {
  MediaKind kind = MediaKind.video,
  int width = 1920,
  int height = 1080,
  double fps = 30,
  TimeUs duration = 4000000,
}) {
  final n = ++_assetCounter;
  return MediaAsset(
    id: MediaId('md_test$n'),
    kind: kind,
    displayName: picked.displayName,
    locator: AppRelativeLocator(AppRoot.support, 'vwish/editor/media/aa/hash$n/${picked.displayName}'),
    ownership: MediaOwnership.managedCopy,
    fingerprint: MediaFingerprint(sizeBytes: picked.sizeBytes ?? 1000, quickHash: 'hash$n', duration: duration),
    probe: MediaProbe(
      kind: kind,
      duration: kind == MediaKind.image ? 0 : duration,
      hasVideo: kind == MediaKind.video,
      hasAudio: kind != MediaKind.image,
      width: kind == MediaKind.audio ? null : width,
      height: kind == MediaKind.audio ? null : height,
      nominalFps: kind == MediaKind.video ? fps : null,
    ),
    origin: picked.origin,
    addedAt: DateTime.utc(2026, 10, 8),
  );
}

/// What the scripted pool does with one pick.
sealed class PoolStep {
  const PoolStep();
}

/// Imports the pick as an asset of [kind].
final class AddStep extends PoolStep {
  /// Creates the step.
  const AddStep({this.kind = MediaKind.video, this.width = 1920, this.height = 1080, this.fps = 30});

  /// Kind.
  final MediaKind kind;

  /// Width.
  final int width;

  /// Height.
  final int height;

  /// Frame rate.
  final double fps;
}

/// Rejects the pick with [reason].
final class RejectStep extends PoolStep {
  /// Creates the step.
  const RejectStep(this.reason);

  /// Reason code.
  final String reason;
}

/// Copies the pick: writes a `.part` file, reports [fraction], then waits for [gate]. Cancelled
/// meanwhile, it deletes the partial file and reports `cancelled`; else it renames the file into
/// place and imports the asset.
final class CopyStep extends PoolStep {
  /// Creates the step.
  CopyStep({this.fraction = 0.4});

  /// Progress reported before waiting.
  final double fraction;

  /// Released by the test.
  final Completer<void> gate = Completer<void>();

  /// Completes when the copy has started.
  final Completer<void> started = Completer<void>();
}

/// A media pool with scripted steps per display name (default: add a video).
class ScriptedPool extends FakeMediaPoolService implements CancellableMediaImport {
  /// Creates the pool; partial copies go to [fs] under [mediaDir].
  ScriptedPool({MemoryStoreFs? fs, this.mediaDir = '/app/support/vwish/editor/media'}) : fs = fs ?? MemoryStoreFs();

  /// Steps by display name.
  final Map<String, PoolStep> steps = {};

  /// Where copies are written.
  final MemoryStoreFs fs;

  /// Managed media folder.
  final String mediaDir;

  /// Display names imported, in order.
  final List<String> imported = [];

  /// Whether the cancellation-aware path was used.
  int cancellableCalls = 0;

  @override
  Future<List<ImportOutcome>> import(EditSession session, List<PickedMedia> picked, {ImportTarget? target}) async {
    calls.add('import');
    return [for (final p in picked) await _one(session, p, null, null)];
  }

  @override
  Future<List<ImportOutcome>> importWithCancel(
    EditSession session,
    List<PickedMedia> picked, {
    required ImportCancellation cancellation,
    void Function(double fraction)? onCopyProgress,
  }) async {
    cancellableCalls++;
    calls.add('import');
    return [for (final p in picked) await _one(session, p, cancellation, onCopyProgress)];
  }

  Future<ImportOutcome> _one(
    EditSession session,
    PickedMedia picked,
    ImportCancellation? cancellation,
    void Function(double fraction)? onCopyProgress,
  ) async {
    imported.add(picked.displayName);
    final step = steps[picked.displayName] ?? const AddStep();
    switch (step) {
      case RejectStep(:final reason):
        return ImportRejected(picked, reason);
      case AddStep():
        return _add(session, picked, step);
      case CopyStep():
        final part = '$mediaDir/aa/${picked.displayName}.part-1';
        final dest = '$mediaDir/aa/${picked.displayName}';
        fs.putFile(part, List<int>.filled(64, 1));
        onCopyProgress?.call(step.fraction);
        step.started.complete();
        await Future.any([step.gate.future, if (cancellation != null) cancellation.whenCancelled]);
        if (cancellation?.isCancelled ?? false) {
          await fs.delete(part);
          return ImportRejected(picked, 'cancelled');
        }
        await fs.rename(part, dest);
        return _add(session, picked, const AddStep());
    }
  }

  ImportOutcome _add(EditSession session, PickedMedia picked, AddStep step) {
    final asset = assetFor(picked, kind: step.kind, width: step.width, height: step.height, fps: step.fps);
    session.applyPoolChange(AddAssets([asset]));
    return ImportedMedia(picked, asset);
  }
}

/// A pool that is not cancellation-aware (only the plain `import`), scripted like [ScriptedPool].
class PlainScriptedPool extends FakeMediaPoolService {
  /// Steps by display name.
  final Map<String, PoolStep> steps = {};

  @override
  Future<List<ImportOutcome>> import(EditSession session, List<PickedMedia> picked, {ImportTarget? target}) async {
    calls.add('import');
    return [
      for (final p in picked)
        switch (steps[p.displayName] ?? const AddStep()) {
          RejectStep(:final reason) => ImportRejected(p, reason),
          _ => () {
              final asset = assetFor(p);
              session.applyPoolChange(AddAssets([asset]));
              return ImportedMedia(p, asset);
            }(),
        },
    ];
  }
}
