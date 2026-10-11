// OWNER: UX-16
//
// InspectorHeader (ux.md §9.3): back (returns to the tool list), the panel title (one line,
// ellipsis), reset (asks first only when keyframes would be removed), the keyframe-all toggle (when
// the panel has keyframable rows) and done.
//
// Panels own their reset and keyframe-all behaviour and publish it to the header the host draws:
//
//   InspectorHeaderActions.publish(
//     actions: InspectorHeaderActions(onReset: _reset, resetRemovesKeyframes: _hasKeys,
//         keyframeAll: status, onKeyframeAll: _toggleAll),
//     child: body,
//   )
//
// (`InspectorHeaderActionsPublisher` writes them into the host's `InspectorHeaderSlot` after the
// frame and clears them when the panel goes away.)

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:vwish_ui_kit/vwish_ui_kit.dart';

import 'keyframe_toggle.dart';

/// Copy of the inspector host and header.
abstract final class InspectorStrings {
  /// Back.
  static const String back = 'Back to tools';

  /// Reset.
  static const String reset = 'Reset';

  /// Done.
  static const String done = 'Done';

  /// Keyframe every property of the panel.
  static const String keyframeAll = 'Keyframe all';

  /// Remove the keys of every property at the playhead.
  static const String removeAllKeys = 'Remove keyframes here';

  /// Semantics label of the inspector region.
  static const String region = 'Inspector';

  /// Reset confirmation title ("Reset Adjust?").
  static String resetTitle(String panel) => 'Reset $panel?';

  /// Reset confirmation message.
  static const String resetMessage = 'This also removes the keyframes of these settings.';

  /// Panel titles.
  static const String media = 'Media';

  /// Voiceover.
  static const String voiceover = 'Voiceover';

  /// Overlay.
  static const String overlay = 'Overlay';

  /// Canvas.
  static const String format = 'Format';

  /// Transform.
  static const String transform = 'Transform';

  /// Crop.
  static const String crop = 'Crop';

  /// Mask.
  static const String mask = 'Mask';

  /// Speed.
  static const String speed = 'Speed';

  /// Audio, volume focus.
  static const String volume = 'Volume';

  /// Audio, fades focus.
  static const String fades = 'Fades';

  /// Adjust.
  static const String adjust = 'Adjust';

  /// Filters.
  static const String filters = 'Filters';

  /// Chroma key.
  static const String chroma = 'Chroma key';

  /// Keyframes.
  static const String keyframes = 'Keyframes';

  /// Text.
  static const String text = 'Text';

  /// Clip info.
  static const String clipInfo = 'Clip info';

  /// Subtitles.
  static const String captions = 'Captions';

  /// Transition.
  static const String transition = 'Transition';
}

/// What a panel adds to the header.
@immutable
final class InspectorHeaderActions {
  /// Creates the actions.
  const InspectorHeaderActions({this.onReset, this.resetRemovesKeyframes = false, this.keyframeAll, this.onKeyframeAll});

  /// No actions.
  static const InspectorHeaderActions none = InspectorHeaderActions();

  /// Resets the panel's settings (null hides reset).
  final VoidCallback? onReset;

  /// Whether reset removes keyframes (it asks first then).
  final bool resetRemovesKeyframes;

  /// The keyframe-all state (null hides the toggle).
  final KeyframeStatus? keyframeAll;

  /// Toggles keyframes of every keyframable row at the playhead.
  final VoidCallback? onKeyframeAll;

  /// Publishes [actions] to the header of the nearest inspector host while [child] is shown.
  static Widget publish({Key? key, required InspectorHeaderActions actions, required Widget child}) =>
      InspectorHeaderActionsPublisher(key: key, actions: actions, child: child);

  @override
  bool operator ==(Object other) =>
      other is InspectorHeaderActions &&
      other.onReset == onReset &&
      other.resetRemovesKeyframes == resetRemovesKeyframes &&
      other.keyframeAll == keyframeAll &&
      other.onKeyframeAll == onKeyframeAll;

  @override
  int get hashCode => Object.hash(onReset, resetRemovesKeyframes, keyframeAll, onKeyframeAll);
}

/// Where the inspector host collects the header actions of its panel.
class InspectorHeaderSlot extends InheritedWidget {
  /// Creates the slot.
  const InspectorHeaderSlot({super.key, required this.actions, required super.child});

  /// The current actions.
  final ValueNotifier<InspectorHeaderActions> actions;

  /// The slot of the nearest host, or null.
  static ValueNotifier<InspectorHeaderActions>? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<InspectorHeaderSlot>()?.actions;

  @override
  bool updateShouldNotify(InspectorHeaderSlot oldWidget) => !identical(oldWidget.actions, actions);
}

/// Writes its [actions] into the nearest [InspectorHeaderSlot] (after the frame) and clears them
/// when it goes away.
class InspectorHeaderActionsPublisher extends StatefulWidget {
  /// Creates the publisher.
  const InspectorHeaderActionsPublisher({super.key, required this.actions, required this.child});

  /// The actions.
  final InspectorHeaderActions actions;

  /// The panel body.
  final Widget child;

  @override
  State<InspectorHeaderActionsPublisher> createState() => _InspectorHeaderActionsPublisherState();
}

class _InspectorHeaderActionsPublisherState extends State<InspectorHeaderActionsPublisher> {
  ValueNotifier<InspectorHeaderActions>? _slot;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _slot = InspectorHeaderSlot.maybeOf(context);
    _schedule();
  }

  @override
  void didUpdateWidget(InspectorHeaderActionsPublisher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.actions != widget.actions) _schedule();
  }

  void _schedule() {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted) _slot?.value = widget.actions;
    });
  }

  @override
  void dispose() {
    final slot = _slot;
    if (slot != null) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        try {
          slot.value = InspectorHeaderActions.none;
        } on FlutterError {
          // The host went away with the panel.
        }
      });
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Back, title, reset, keyframe-all and done (ux.md §9.3).
class InspectorHeader extends StatelessWidget {
  /// Creates the header.
  const InspectorHeader({super.key, required this.title, this.onBack, this.onDone, this.actions = InspectorHeaderActions.none});

  /// Panel title.
  final String title;

  /// Back to the tool list.
  final VoidCallback? onBack;

  /// Done.
  final VoidCallback? onDone;

  /// The panel's reset and keyframe-all.
  final InspectorHeaderActions actions;

  /// Height of the header row.
  static const double height = 48;

  Future<void> _reset(BuildContext context) async {
    final reset = actions.onReset;
    if (reset == null) return;
    if (actions.resetRemovesKeyframes) {
      final ok = await showVwishConfirm(
        context,
        title: InspectorStrings.resetTitle(title),
        message: InspectorStrings.resetMessage,
        confirmLabel: InspectorStrings.reset,
        destructive: true,
      );
      if (!ok) return;
    }
    reset();
  }

  @override
  Widget build(BuildContext context) {
    final kf = actions.keyframeAll;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: height),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: VwishSpacing.xs),
        child: Row(
          children: [
            if (onBack != null)
              VwishIconButton(
                icon: Icons.arrow_back_ios_new_rounded,
                iconSize: 18,
                size: 36,
                tooltip: InspectorStrings.back,
                onPressed: onBack,
              ),
            const SizedBox(width: VwishSpacing.xs),
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: VwishTextStyles.headline.copyWith(fontFamily: VwishFonts.family),
                ),
              ),
            ),
            if (actions.onReset != null)
              VwishIconButton(
                icon: Icons.settings_backup_restore_rounded,
                iconSize: 20,
                size: 36,
                tooltip: InspectorStrings.reset,
                onPressed: () => _reset(context),
              ),
            if (kf != null)
              KeyframeToggle(
                status: kf,
                property: InspectorStrings.keyframeAll,
                showJumps: false,
                size: 36,
                onToggle: actions.onKeyframeAll,
              ),
            if (onDone != null)
              VwishIconButton(
                icon: Icons.check_rounded,
                iconSize: 20,
                size: 36,
                variant: VwishIconButtonVariant.tonal,
                tooltip: InspectorStrings.done,
                onPressed: onDone,
              ),
          ],
        ),
      ),
    );
  }
}
