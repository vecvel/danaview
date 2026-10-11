// OWNER: UX-15
//
// The keyboard shortcuts sheet (ARCH §17.6, ux.md §15.2): generated from the action registry, so
// it lists exactly the actions that have a shortcut on this platform, grouped as the registry
// groups them, with `⌘` or `Ctrl` glyphs for the platform. iPadOS shows no system shortcut overlay
// for Flutter apps (Flutter registers no `UIKeyCommand`s), so this sheet fills that gap. An action
// that can't run now stays listed, dimmed, with the reason under its label.
//
// Opened by the `showShortcuts` action (⌘/ or ?), the Project sheet's "Keyboard shortcuts" row
// and the more-menu of the transport bar: `ShortcutsSheet.show(context)`.

import 'package:flutter/material.dart' show Theme;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/model.dart' show ProjectId;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../contracts/contracts.dart';
import '../editor_scope.dart';
import 'editor_action_registry.dart';

/// Every action with its shortcut, generated from the registry (ARCH §17.6).
class ShortcutsSheet extends ConsumerWidget {
  /// Creates the sheet content. [projectId] lets it show which actions are available right now;
  /// without it every bound action reads as available.
  const ShortcutsSheet({super.key, this.projectId});

  /// The open project, or null.
  final ProjectId? projectId;

  /// Below this width a row puts the shortcuts under the label.
  static const double stackBelow = 340;

  /// Shows the sheet above the editor of [context].
  static Future<void> show(BuildContext context, {ProjectId? projectId}) {
    final id = projectId ?? EditorScope.maybeIdOf(context);
    return showDanaviewSheet<void>(
      context,
      title: EditorActionStrings.sheetTitle,
      builder: (context) => ShortcutsSheet(projectId: id),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final registry = ref.watch(editorActionRegistryProvider).forPlatformOf(Theme.of(context).platform);
    final id = projectId;
    final ctx = id == null ? null : WidgetActionContext(projectId: id, context: context, ref: ref, source: EditorActionSource.shortcutsSheet);
    final children = <Widget>[];
    for (final group in EditorActionGroup.values) {
      final specs = registry.shortcutSpecs.where((s) => s.id.group == group).toList();
      if (specs.isEmpty) continue;
      children.add(DanaviewSectionHeader(EditorActionStrings.group(group), padding: const EdgeInsets.fromLTRB(4, 12, 4, 4)));
      for (final spec in specs) {
        final reason = ctx == null ? (spec.isBound ? null : spec.disabledReason(_NoContext.instance)) : spec.disabledReason(ctx);
        children.add(ShortcutRow(spec: spec, disabledReason: reason));
      }
    }
    children
      ..add(const SizedBox(height: DanaviewSpacing.md))
      ..add(Text(
        EditorActionStrings.sheetNote,
        style: DanaviewTextStyles.caption.copyWith(fontFamily: DanaviewFonts.family),
      ));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: children);
  }
}

/// A context for specs whose reason doesn't depend on providers (unbound actions).
final class _NoContext implements EditorActionContext {
  const _NoContext();

  static const _NoContext instance = _NoContext();

  @override
  BuildContext get context => throw UnimplementedError('no context');

  @override
  ProjectId get projectId => throw UnimplementedError('no project');

  @override
  T read<T>(ProviderListenable<T> provider) => throw UnimplementedError('no providers');

  @override
  EditorActionSource get source => EditorActionSource.shortcutsSheet;
}

/// One row of the sheet: the action's icon and label (with the reason when it can't run now) and
/// its shortcuts as key caps.
class ShortcutRow extends StatelessWidget {
  /// Creates the row for [spec].
  const ShortcutRow({super.key, required this.spec, this.disabledReason});

  /// The action.
  final EditorActionSpec spec;

  /// Why the action can't run now, or null.
  final String? disabledReason;

  @override
  Widget build(BuildContext context) {
    final reason = disabledReason;
    final dim = reason != null;
    final labelStyle = DanaviewTextStyles.body.copyWith(
      fontFamily: DanaviewFonts.family,
      color: dim ? DanaviewColors.textSecondary : DanaviewColors.textPrimary,
    );
    final label = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(spec.label, style: labelStyle),
        if (reason != null) Text(reason, style: DanaviewTextStyles.caption.copyWith(fontFamily: DanaviewFonts.family)),
      ],
    );
    final keys = _KeyCaps(labels: spec.shortcutLabels);
    return Semantics(
      container: true,
      label: EditorActionStrings.rowSemantics(spec.label, spec.shortcutLabels, reason),
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: DanaviewSpacing.xs + 2),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final icon = Padding(
              padding: const EdgeInsets.only(right: DanaviewSpacing.md),
              child: Icon(spec.icon, size: 18, color: dim ? DanaviewColors.textMuted : DanaviewColors.textSecondary),
            );
            if (constraints.maxWidth < ShortcutsSheet.stackBelow) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [icon, Expanded(child: label)]),
                  const SizedBox(height: DanaviewSpacing.xs),
                  Padding(padding: const EdgeInsets.only(left: 18 + DanaviewSpacing.md), child: keys),
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                icon,
                Expanded(child: label),
                const SizedBox(width: DanaviewSpacing.md),
                Flexible(child: Align(alignment: Alignment.topRight, child: keys)),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _KeyCaps extends StatelessWidget {
  const _KeyCaps({required this.labels});

  final List<String> labels;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: DanaviewSpacing.xs + 2,
      runSpacing: DanaviewSpacing.xs + 2,
      alignment: WrapAlignment.end,
      children: [
        for (final label in labels)
          DecoratedBox(
            decoration: BoxDecoration(
              color: DanaviewColors.surfaceElevatedHigher,
              borderRadius: DanaviewRadius.xsAll,
              border: DanaviewBorders.all,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: DanaviewSpacing.sm, vertical: 3),
              child: Text(
                label,
                style: DanaviewTextStyles.label.copyWith(fontFamily: DanaviewFonts.family, fontSize: 12),
              ),
            ),
          ),
      ],
    );
  }
}
