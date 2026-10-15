// OWNER: UX-44
//
// The render-preview action binding (merged by wiring/action_bindings.dart, ARCH §17.6, D-45):
//
// * `renderPreview` renders the selection's span when items are selected, else the loop range when
//   one is set, else the whole timeline (the ranges that need it). It is available on every tier
//   (`RenderPolicy.manualRenderAllowed`); it is disabled while the preview has no plan, the timeline
//   is empty, an export runs, or the device cannot render (with the reason as the disabled
//   explanation).
// * Shortcut: ⌘R (Command on Apple platforms, Ctrl elsewhere), [renderPreviewMeta]; R alone stays
//   "Ripple editing".
//
// The action id and its registry entry belong to UX-01 (`EditorActionId.renderPreview`) and UX-15
// (label, icon, [renderPreviewMeta]'s combo). Until that id exists the binding list is empty, so
// this file never binds an id it does not own; [renderPreviewActionId] finds it by name.

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:danaview_editor_core/model.dart' show TimeRange, TimeUs;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../../app/editor_providers.dart';
import '../../../app/strings/render_preview_strings.dart';
import '../../contracts/action_binding.dart';
import '../../contracts/action_ids.dart';
import '../../state/editor_state.dart' show EditorSelection;
import '../../state/render_preview_controller.dart';
import '../../timeline/render_marker_strip.dart' show blockedMessage;
import '../editor_action_registry.dart' show EditorActionMeta, EditorKeyCombo;

/// The `renderPreview` action id, once UX-01 adds it to [EditorActionId] (null before).
EditorActionId? get renderPreviewActionId {
  for (final id in EditorActionId.values) {
    if (id.name == 'renderPreview') return id;
  }
  return null;
}

/// ⌘R.
const EditorKeyCombo renderPreviewCombo = EditorKeyCombo(LogicalKeyboardKey.keyR, command: true);

/// Label, icon and shortcut of the action (the registry entry UX-15 lists for it).
const EditorActionMeta renderPreviewMeta = EditorActionMeta(
  RenderPreviewStrings.action,
  Icons.movie_filter_rounded,
  combos: [renderPreviewCombo],
);

/// What the action renders for [selection] (the selected items' span), [loop] and the timeline.
RenderTarget renderTargetFor({TimeRange? selection, TimeRange? loop}) {
  if (selection != null && !selection.isEmpty) return RenderTarget.selection(selection);
  if (loop != null && !loop.isEmpty) return RenderTarget.loop(loop);
  return const RenderTarget.timeline();
}

/// The span covering every selected item of [selection] in [ctx]'s committed project, or null.
TimeRange? selectionSpan(EditorActionContext ctx, EditorSelection selection) {
  if (selection.items.isEmpty) return null;
  final project = ctx.read(editorSessionProvider(ctx.projectId)).committedProject;
  if (project == null) return null;
  TimeUs? start;
  TimeUs? end;
  for (final track in project.timeline.tracks) {
    for (final item in track.items) {
      if (!selection.items.contains(item.id)) continue;
      if (start == null || item.start < start) start = item.start;
      if (end == null || item.end > end) end = item.end;
    }
  }
  return start == null || end == null || end <= start ? null : TimeRange(start, end);
}

RenderPreviewController _controller(EditorActionContext ctx) => ctx.read(renderPreviewControllerProvider(ctx.projectId));

bool _isEnabled(EditorActionContext ctx) {
  if (!ctx.read(editorControllerProvider(ctx.projectId)).isReady) return false;
  return _controller(ctx).blockedReason == null;
}

String? _disabledReason(EditorActionContext ctx) {
  if (!ctx.read(editorControllerProvider(ctx.projectId)).isReady) return RenderPreviewStrings.notReady;
  final blocked = _controller(ctx).blockedReason;
  return blocked == null ? null : blockedMessage(blocked);
}

Future<void> _render(EditorActionContext ctx) async {
  final controller = _controller(ctx);
  final selection = ctx.read(editorControllerProvider(ctx.projectId)).selection;
  final loop = ctx.read(transportProvider(ctx.projectId)).loop.value;
  final target = renderTargetFor(selection: selectionSpan(ctx, selection), loop: loop);
  final outcome = await controller.render(target);
  final context = ctx.context;
  if (!context.mounted) return;
  final message = switch (outcome) {
    RenderRequestOutcome.started => RenderPreviewStrings.started(controller.value.queued.length + (controller.value.active == null ? 0 : 1)),
    _ => blockedMessage(outcome),
  };
  DanaviewToast.show(context, message, icon: Icons.movie_filter_rounded);
}

/// The render-preview actions bound by UX-44 (ARCH §17.6). Empty until UX-01 adds
/// `EditorActionId.renderPreview`. The same instances on every read.
List<EditorActionBinding> get renderPreviewBindings => _bindings ??= List.unmodifiable(<EditorActionBinding>[
      if (renderPreviewActionId case final id?)
        EditorActionBinding(id: id, handler: _render, isEnabled: _isEnabled, disabledReason: _disabledReason),
    ]);

List<EditorActionBinding>? _bindings;
