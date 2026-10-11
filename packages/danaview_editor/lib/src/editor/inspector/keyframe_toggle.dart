// OWNER: UX-16
//
// KeyframeToggle (ux.md §9.4): the diamond next to a keyframable inspector row.
//
//   state       icon                          meaning                         tap
//   none        diamond_outlined, muted       property is static              add a key at the playhead
//   animated    diamond_outlined, primaryLight keys elsewhere                 add a key at the playhead
//   atPlayhead  diamond_rounded, primaryLight  a key exists at this frame     remove it (the last remove
//                                                                             leaves the property static)
//
// * `KeyframeStateListenable(item, key, playhead)` computes the status and notifies only when it
//   changes (state, previous/next key, playhead inside the item), never per playback frame
//   otherwise.
// * ‹ › appear next to the diamond when the property has keys and jump to the previous or next key
//   (`PlayheadController.seekExact`).
// * `PropertyKeyframeToggle` wires the toggle to the editor: AddKeyframe / RemoveKeyframe (CORE-13)
//   at the item-local playhead through `EditorController.apply`. Outside the item the toggle is
//   disabled (a key can't be written there).

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show AddKeyframe, RemoveKeyframe;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../app/editor_providers.dart';
import '../editor_scope.dart';
import '../state/editor_controller.dart';
import '../state/playhead_controller.dart';

/// The three states of ux.md §9.4.
enum KeyframeToggleState {
  /// The property is static.
  none,

  /// The property has keys, none at the playhead.
  animated,

  /// A key exists at the playhead.
  atPlayhead,
}

/// What a keyframe toggle shows.
@immutable
final class KeyframeStatus {
  /// Creates a status.
  const KeyframeStatus(this.state, {this.previous, this.next, this.enabled = true});

  /// A static property with the playhead inside the item.
  static const KeyframeStatus none = KeyframeStatus(KeyframeToggleState.none);

  /// State.
  final KeyframeToggleState state;

  /// Absolute time of the previous key, or null.
  final TimeUs? previous;

  /// Absolute time of the next key, or null.
  final TimeUs? next;

  /// Whether a key can be added or removed now (the playhead is inside the item).
  final bool enabled;

  /// Whether the property has keys.
  bool get animated => state != KeyframeToggleState.none;

  /// The status of [key] on [item] at absolute [playhead].
  static KeyframeStatus of(TimelineItem item, PropertyKey<Object?> key, TimeUs playhead) {
    if (!key.keyframable) return const KeyframeStatus(KeyframeToggleState.none, enabled: false);
    final local = playhead - item.start;
    final inside = local >= 0 && local < item.duration;
    final times = KeyframeOps.keyTimes(keyframesOf(item), key).where((t) => t >= 0 && t < item.duration).toList();
    if (times.isEmpty) return KeyframeStatus(KeyframeToggleState.none, enabled: inside);
    TimeUs? previous;
    TimeUs? next;
    var at = false;
    for (final t in times) {
      if (t < local) {
        previous = t;
      } else if (t == local) {
        at = true;
      } else {
        next ??= t;
      }
    }
    return KeyframeStatus(
      at && inside ? KeyframeToggleState.atPlayhead : KeyframeToggleState.animated,
      previous: previous == null ? null : item.start + previous,
      next: next == null ? null : item.start + next,
      enabled: inside,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is KeyframeStatus && other.state == state && other.previous == previous && other.next == next && other.enabled == enabled;

  @override
  int get hashCode => Object.hash(state, previous, next, enabled);

  @override
  String toString() => 'KeyframeStatus(${state.name}, prev: $previous, next: $next, enabled: $enabled)';
}

/// The keyframe status of one property of one item at the playhead; notifies only on change.
class KeyframeStateListenable extends ChangeNotifier implements ValueListenable<KeyframeStatus> {
  /// Creates the listenable for [key] on [item], following [playhead].
  KeyframeStateListenable({required TimelineItem item, required this.key, required this.playhead})
      : _item = item,
        _value = KeyframeStatus.of(item, key, playhead.value) {
    playhead.addListener(_recompute);
  }

  /// The property.
  final PropertyKey<Object?> key;

  /// The playhead (absolute time).
  final ValueListenable<TimeUs> playhead;

  TimelineItem _item;
  KeyframeStatus _value;

  /// The item (replace it when the project changes).
  TimelineItem get item => _item;
  set item(TimelineItem item) {
    if (identical(item, _item)) return;
    _item = item;
    _recompute();
  }

  @override
  KeyframeStatus get value => _value;

  void _recompute() {
    final next = KeyframeStatus.of(_item, key, playhead.value);
    if (next == _value) return;
    _value = next;
    notifyListeners();
  }

  @override
  void dispose() {
    playhead.removeListener(_recompute);
    super.dispose();
  }
}

/// Copy of the keyframe toggle.
abstract final class KeyframeToggleStrings {
  /// Tooltip when a tap adds a key.
  static const String add = 'Add keyframe';

  /// Tooltip when a tap removes the key.
  static const String remove = 'Remove keyframe';

  /// Tooltip when the playhead is outside the item.
  static const String outside = 'Move the playhead over the clip to add keyframes';

  /// Previous key.
  static const String previous = 'Previous keyframe';

  /// Next key.
  static const String next = 'Next keyframe';

  /// Semantics label ("Opacity keyframe").
  static String label(String property) => '$property keyframe';

  /// Semantics value of a state.
  static String state(KeyframeToggleState s) => switch (s) {
        KeyframeToggleState.none => 'Not animated',
        KeyframeToggleState.animated => 'Animated, no keyframe here',
        KeyframeToggleState.atPlayhead => 'Keyframe here',
      };
}

/// The diamond button of ux.md §9.4 (presentational).
class KeyframeToggle extends StatelessWidget {
  /// Creates the toggle for [status]; [property] names the row for semantics.
  const KeyframeToggle({
    super.key,
    required this.status,
    required this.onToggle,
    this.onPrevious,
    this.onNext,
    this.property = '',
    this.showJumps = true,
    this.size = 32,
  });

  /// What it shows.
  final KeyframeStatus status;

  /// Adds or removes the key (null disables it).
  final VoidCallback? onToggle;

  /// Jumps to the previous key.
  final VoidCallback? onPrevious;

  /// Jumps to the next key.
  final VoidCallback? onNext;

  /// Property name.
  final String property;

  /// Shows ‹ › when the property has keys.
  final bool showJumps;

  /// Diameter of the diamond button.
  final double size;

  /// The icon of [state].
  static IconData iconOf(KeyframeToggleState state) =>
      state == KeyframeToggleState.atPlayhead ? Icons.diamond_rounded : Icons.diamond_outlined;

  /// The colour of [state].
  static Color colorOf(KeyframeToggleState state) => state == KeyframeToggleState.none ? DanaviewColors.textMuted : DanaviewColors.primaryLight;

  @override
  Widget build(BuildContext context) {
    final state = status.state;
    final enabled = status.enabled && onToggle != null;
    final tooltip = !status.enabled
        ? KeyframeToggleStrings.outside
        : state == KeyframeToggleState.atPlayhead
            ? KeyframeToggleStrings.remove
            : KeyframeToggleStrings.add;
    final diamond = Semantics(
      value: KeyframeToggleStrings.state(state),
      child: DanaviewIconButton(
        icon: iconOf(state),
        color: enabled ? colorOf(state) : DanaviewColors.disabled(colorOf(state)),
        size: size,
        iconSize: 18,
        tooltip: tooltip,
        semanticLabel: '${KeyframeToggleStrings.label(property)}, $tooltip',
        onPressed: enabled ? onToggle : null,
      ),
    );
    if (!showJumps || !status.animated) return diamond;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        DanaviewIconButton(
          icon: Icons.chevron_left_rounded,
          size: 24,
          iconSize: 18,
          color: DanaviewColors.textSecondary,
          tooltip: KeyframeToggleStrings.previous,
          onPressed: status.previous == null ? null : onPrevious,
        ),
        diamond,
        DanaviewIconButton(
          icon: Icons.chevron_right_rounded,
          size: 24,
          iconSize: 18,
          color: DanaviewColors.textSecondary,
          tooltip: KeyframeToggleStrings.next,
          onPressed: status.next == null ? null : onNext,
        ),
      ],
    );
  }
}

/// A [KeyframeToggle] for [property] of the item [item] of the open editor.
class PropertyKeyframeToggle extends ConsumerStatefulWidget {
  /// Creates the toggle.
  const PropertyKeyframeToggle({super.key, required this.item, required this.property, this.label, this.showJumps = true});

  /// The item.
  final ItemId item;

  /// The property (keyframable).
  final PropertyKey<Object?> property;

  /// Row label for semantics (default: the property's display name).
  final String? label;

  /// Shows ‹ ›.
  final bool showJumps;

  @override
  ConsumerState<PropertyKeyframeToggle> createState() => _PropertyKeyframeToggleState();
}

class _PropertyKeyframeToggleState extends ConsumerState<PropertyKeyframeToggle> {
  KeyframeStateListenable? _status;
  PlayheadController? _playhead;
  bool _building = false;

  void _changed() {
    if (!_building && mounted) setState(() {});
  }

  @override
  void dispose() {
    _status?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final id = EditorScope.idOf(context);
    final item = ref.watch(editorControllerProvider(id).select((s) => s.project?.index.item(widget.item)));
    final playhead = ref.watch(playheadProvider(id));
    if (item == null || !widget.property.appliesToItem(item)) {
      _status?.dispose();
      _status = null;
      return const SizedBox.shrink();
    }
    _building = true;
    var status = _status;
    if (status == null || !identical(_playhead, playhead) || status.key != widget.property) {
      status?.dispose();
      status = _status = KeyframeStateListenable(item: item, key: widget.property, playhead: playhead)..addListener(_changed);
      _playhead = playhead;
    } else {
      status.item = item;
    }
    _building = false;
    final editor = ref.read(editorControllerProvider(id).notifier);
    final value = status.value;
    return KeyframeToggle(
      status: value,
      property: widget.label ?? widget.property.displayName,
      showJumps: widget.showJumps,
      onToggle: () => toggle(editor, item, widget.property, playhead.value, value.state),
      onPrevious: value.previous == null ? null : () => playhead.seekExact(value.previous!),
      onNext: value.next == null ? null : () => playhead.seekExact(value.next!),
    );
  }

  /// Adds or removes the key of [property] on [item] at absolute [playhead].
  static void toggle(
      EditorController editor, TimelineItem item, PropertyKey<Object?> property, TimeUs playhead, KeyframeToggleState state) {
    final ref = KeyframeRef(item.id, property.id, playhead - item.start);
    editor.apply(state == KeyframeToggleState.atPlayhead ? RemoveKeyframe(ref) : AddKeyframe(ref));
  }
}
