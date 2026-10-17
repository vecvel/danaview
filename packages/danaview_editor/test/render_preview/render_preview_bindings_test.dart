// OWNER: UX-44
//
// The render-preview action binding (ARCH §17.6): the target it picks (selection span, else loop
// range, else whole timeline), its ⌘R shortcut (R alone stays Ripple editing), and that it binds
// `EditorActionId.renderPreview` exactly when UX-01 has added that id.

import 'package:danaview_editor/src/app/strings/render_preview_strings.dart';
import 'package:danaview_editor/src/editor/actions/bindings/render_preview_bindings.dart';
import 'package:danaview_editor/src/editor/contracts/action_ids.dart';
import 'package:danaview_editor/src/editor/state/render_preview_controller.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('target: selection, else loop, else the whole timeline', () {
    const sel = TimeRange(1000000, 2000000);
    const loop = TimeRange(3000000, 4000000);
    expect(renderTargetFor(selection: sel, loop: loop), const RenderTarget.selection(sel));
    expect(renderTargetFor(loop: loop), const RenderTarget.loop(loop));
    expect(renderTargetFor(selection: const TimeRange(5, 5), loop: loop), const RenderTarget.loop(loop));
    expect(renderTargetFor(), const RenderTarget.timeline());
    expect(renderTargetFor().kind, RenderTargetKind.timeline);
  });

  test('label, icon and ⌘R shortcut', () {
    expect(renderPreviewMeta.label, RenderPreviewStrings.action);
    expect(renderPreviewMeta.combos.single.key, LogicalKeyboardKey.keyR);
    expect(renderPreviewMeta.combos.single.command, isTrue);
  });

  test('binds renderPreview once the id exists, the same instances on every read', () {
    final id = renderPreviewActionId;
    expect(identical(renderPreviewBindings, renderPreviewBindings), isTrue);
    if (id == null) {
      expect(renderPreviewBindings, isEmpty);
    } else {
      expect(renderPreviewBindings.map((b) => b.id), [id]);
    }
    expect(EditorActionId.values.where((e) => e.name == 'renderPreview').firstOrNull, id);
  });
}
