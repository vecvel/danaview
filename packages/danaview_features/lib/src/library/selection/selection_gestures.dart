// OWNER: HOM-12
//
// The gestures and marks a tab uses to take part in the Home's selection (BUILD_PLAN HOM-12):
//
// * [SelectionDragRegion] wraps a grid or list: a long press on an item starts selection mode on
//   it and, without lifting the finger, dragging over neighbours extends the range
//   ([DragSelectSession]). The tab supplies `indexAt` (its own layout answers which item is under
//   a point), so the region works with HOM-10's masonry grid and HOM-18's rows alike. Inside a
//   region, cells leave their own `onLongPress` unset (the region's recognizer handles it).
// * [selectionAwareTap]: while something is selected a tap toggles the item, otherwise it opens it.
// * [SelectionCheckMark]: the check (with the pick number) drawn on a selected cell.
// * [SelectAllInGroupButton]: "Select all" / "Deselect all" on a date group or section header.

import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'selection_model.dart';

/// Returns the index into the region's items of the item at [localPosition], or null.
typedef SelectionIndexAt = int? Function(Offset localPosition);

/// Long press and drag over [child] to select a range of [items].
class SelectionDragRegion extends ConsumerStatefulWidget {
  /// A region over [items] (display order); [indexAt] maps a point in [child] to an item.
  const SelectionDragRegion({super.key, required this.items, required this.indexAt, required this.child, this.enabled = true});

  /// The items in display order.
  final List<MediaItem> items;

  /// Which item is under a local point.
  final SelectionIndexAt indexAt;

  /// The grid or list.
  final Widget child;

  /// False disables the gesture (e.g. while a pinch is in progress).
  final bool enabled;

  @override
  ConsumerState<SelectionDragRegion> createState() => _SelectionDragRegionState();
}

class _SelectionDragRegionState extends ConsumerState<SelectionDragRegion> {
  DragSelectSession? _session;
  int? _last;

  void _start(LongPressStartDetails details) {
    final index = widget.indexAt(details.localPosition);
    if (index == null || index < 0 || index >= widget.items.length) return;
    final controller = ref.read(homeSelectionProvider.notifier);
    final session = DragSelectSession(base: ref.read(homeSelectionProvider), items: widget.items, anchor: index);
    _session = session;
    _last = index;
    controller.replace(session.update(index));
    HapticFeedback.selectionClick();
  }

  void _move(LongPressMoveUpdateDetails details) {
    final session = _session;
    if (session == null) return;
    final index = widget.indexAt(details.localPosition);
    if (index == null || index == _last) return;
    _last = index;
    ref.read(homeSelectionProvider.notifier).replace(session.update(index));
  }

  void _end() {
    _session = null;
    _last = null;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onLongPressStart: _start,
      onLongPressMoveUpdate: _move,
      onLongPressEnd: (_) => _end(),
      onLongPressCancel: _end,
      child: widget.child,
    );
  }
}

/// The tap handler of a selectable cell: toggles [item] while the Home is in selection mode,
/// otherwise calls [open].
VoidCallback selectionAwareTap(WidgetRef ref, MediaItem item, VoidCallback? open) => () {
      final controller = ref.read(homeSelectionProvider.notifier);
      if (ref.read(homeSelectionProvider).isActive) {
        controller.toggle(item);
      } else {
        open?.call();
      }
    };

/// The mark on a selected cell: a filled circle with the pick number, or an empty ring while the
/// Home is in selection mode and the cell isn't selected.
class SelectionCheckMark extends StatelessWidget {
  /// The mark; [order] is the 1-based pick number, null when the cell isn't selected.
  const SelectionCheckMark({super.key, required this.order, this.size = 24});

  /// The pick number, or null.
  final int? order;

  /// The circle diameter.
  final double size;

  @override
  Widget build(BuildContext context) {
    final selected = order != null;
    final fg = DanaviewColors.foregroundOn(DanaviewColors.primary);
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: selected ? DanaviewColors.primary : DanaviewColors.scrim,
          border: Border.all(color: DanaviewColors.textPrimary, width: 1.5),
        ),
        child: selected
            ? FittedBox(
                child: Padding(
                  padding: const EdgeInsets.all(3),
                  child: Text(
                    '$order',
                    textScaler: TextScaler.noScaling,
                    style: DanaviewTextStyles.micro.copyWith(color: fg, fontWeight: FontWeight.w700),
                  ),
                ),
              )
            : null,
      ),
    );
  }
}

/// The semantics a selectable cell adds to its own label while the Home is in selection mode.
String selectionCellLabel(String label, int? order) => order == null ? '$label, not selected' : '$label, selected, $order';

/// "Select all" / "Deselect all" for one group of items (a date group, a folder, a section).
class SelectAllInGroupButton extends ConsumerWidget {
  /// The button for [items]; [groupLabel] names the group for screen readers.
  const SelectAllInGroupButton({super.key, required this.items, required this.groupLabel});

  /// The group's items in display order.
  final List<MediaItem> items;

  /// The group's title (e.g. "Today").
  final String groupLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final all = ref.watch(homeSelectionProvider.select((s) => s.containsAll(items)));
    final onPressed = items.isEmpty ? null : () => ref.read(homeSelectionProvider.notifier).toggleAll(items);
    // The spoken label names the group; the kit button would read its text as well.
    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: all ? 'Deselect all in $groupLabel' : 'Select all in $groupLabel',
      onTap: onPressed,
      excludeSemantics: true,
      child: DanaviewButton.ghost(
        label: all ? 'Deselect all' : 'Select all',
        size: DanaviewButtonSize.sm,
        onPressed: onPressed,
      ),
    );
  }
}
