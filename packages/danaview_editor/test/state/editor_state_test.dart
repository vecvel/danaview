// OWNER: UX-08
//
// EditorState value semantics (ux.md §16.2): copyWith clears nullable fields only when asked,
// selection pruning, preview/save status values.

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_metrics.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/store.dart' show StoreFailureKind;
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' show PreviewQuality;

void main() {
  test('the opening state', () {
    const s = EditorState.opening();
    expect(s.phase, EditorPhase.opening);
    expect(s.project, isNull);
    expect(s.history, HistoryStatus.empty);
    expect(s.save, SaveStatus.clean);
    expect(s.selection.isEmpty, isTrue);
    expect(s.preview, PreviewStatus.starting);
    expect(s.media.isOk, isTrue);
    expect(s.isReady, isFalse);
  });

  test('copyWith keeps nullable fields unless null is passed explicitly', () {
    final s = const EditorState.opening().copyWith(
      phase: EditorPhase.ready,
      tool: ToolId.text,
      inspector: const CanvasInspector(),
      failure: const UnknownFailure(),
    );
    expect(s.copyWith(phase: EditorPhase.closing).tool, ToolId.text);
    expect(s.copyWith(phase: EditorPhase.closing).inspector, const CanvasInspector());
    final cleared = s.copyWith(tool: null, inspector: null, failure: null);
    expect(cleared.tool, isNull);
    expect(cleared.inspector, isNull);
    expect(cleared.failure, isNull);
    expect(s, s.copyWith());
    expect(s == cleared, isFalse);
  });

  test('selection pruning keeps the primary when possible', () {
    const a = ItemId('it_a'), b = ItemId('it_b');
    final sel = EditorSelection(items: {a, b}, primary: a, keyframe: const KeyframeRef(a, 'transform.position', 0));
    expect(identical(sel.retainItems((_) => true), sel), isTrue);
    final pruned = sel.retainItems((id) => id == b);
    expect(pruned.items, {b});
    expect(pruned.primary, b);
    expect(pruned.keyframe, isNull);
    expect(sel.retainItems((_) => false).isEmpty, isTrue);
    expect(EditorSelection(items: {a}, primary: a), EditorSelection(items: {a}, primary: a));
  });

  test('modes, preview and save values', () {
    const m = EditModes();
    expect(m.ripple && m.snapping && m.centerPlayhead, isTrue);
    expect(m.copyWith(laneHeight: LaneHeightPreset.large).laneHeight, LaneHeightPreset.large);
    final failed = PreviewStatus.starting.copyWith(phase: PreviewPhase.failed, failure: const PreviewFailed());
    expect(failed.failure, const PreviewFailed());
    expect(failed.copyWith(phase: PreviewPhase.ready).failure, isNull);
    expect(failed.copyWith(quality: PreviewQuality.half).quality, PreviewQuality.half);
    expect(SaveStatus.failed(const SaveFailed(StoreFailureKind.diskFull)).phase, SavePhase.failed);
    expect(SaveStatus.saved(DateTime.utc(2026)).at, DateTime.utc(2026));
  });
}
