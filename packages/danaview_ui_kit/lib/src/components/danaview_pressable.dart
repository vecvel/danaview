import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/danaview_theme.dart';
import '../theme/danaview_tokens.dart';

@immutable
class DanaviewPressState {
  const DanaviewPressState({
    required this.pressed,
    required this.hovered,
    required this.focused,
    required this.enabled,
  });

  final bool pressed;
  final bool hovered;
  final bool focused;
  final bool enabled;
}

typedef DanaviewPressableBuilder = Widget Function(BuildContext context, DanaviewPressState state);

class DanaviewPressable extends StatefulWidget {
  const DanaviewPressable({
    super.key,
    required Widget this.child,
    this.onTap,
    this.onLongPress,
    this.enabled = true,
    this.semanticLabel,
    this.tooltip,
    this.pressedScale = 0.97,
    this.pressedOpacity = 0.85,
    this.hoverColor = DanaviewColors.hover,
    this.borderRadius,
    this.circle = false,
    this.focusNode,
    this.autofocus = false,
    this.isButton = true,
    this.selected,
    this.toggled,
    this.behavior = HitTestBehavior.opaque,
  }) : builder = null;

  const DanaviewPressable.builder({
    super.key,
    required DanaviewPressableBuilder this.builder,
    this.onTap,
    this.onLongPress,
    this.enabled = true,
    this.semanticLabel,
    this.tooltip,
    this.pressedScale = 0.97,
    this.pressedOpacity = 1.0,
    this.focusNode,
    this.autofocus = false,
    this.isButton = true,
    this.selected,
    this.toggled,
    this.behavior = HitTestBehavior.opaque,
  })  : child = null,
        hoverColor = DanaviewColors.hover,
        borderRadius = null,
        circle = false;

  final Widget? child;
  final DanaviewPressableBuilder? builder;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool enabled;
  final String? semanticLabel;
  final String? tooltip;
  final double pressedScale;
  final double pressedOpacity;
  final Color hoverColor;
  final BorderRadius? borderRadius;
  final bool circle;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool isButton;
  final bool? selected;
  final bool? toggled;
  final HitTestBehavior behavior;

  @override
  State<DanaviewPressable> createState() => _DanaviewPressableState();
}

class _DanaviewPressableState extends State<DanaviewPressable> {
  static const Map<ShortcutActivator, Intent> _shortcuts = <ShortcutActivator, Intent>{
    SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
  };

  bool _pressed = false;
  bool _hovered = false;
  bool _focused = false;

  bool get _active => widget.enabled && (widget.onTap != null || widget.onLongPress != null);

  // Pointer-hover tooltip (QA-01 step 4). Material's Tooltip shows on hover only from the mouse
  // tracker's enter/exit callbacks; on the iPad (pointer or trackpad) those did not show it, while
  // the hover events themselves arrive (the timeline's hover pill, which uses them, works). So the
  // pressable also shows its tooltip from the hit-tested hover events after the theme's wait, and
  // hides it when a hover leaves its box, a pointer goes down or the pointer is removed. Touch never
  // hovers, so taps and long presses behave as before. No hover highlight is added.
  final GlobalKey<TooltipState> _tooltipKey = GlobalKey<TooltipState>();
  Timer? _hoverTimer;
  int? _hoverDevice;
  bool _hoverShown = false;

  void _onPointerHover(PointerHoverEvent event) {
    if (_hoverDevice == event.device) return;
    _endHover();
    _hoverDevice = event.device;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onGlobalPointer);
    final wait = TooltipTheme.of(context).waitDuration ?? Duration.zero;
    _hoverTimer = Timer(wait, () {
      _hoverTimer = null;
      if (!mounted || _hoverDevice == null) return;
      _hoverShown = _tooltipKey.currentState?.ensureTooltipVisible() ?? false;
    });
  }

  void _onGlobalPointer(PointerEvent event) {
    if (event is PointerDownEvent) {
      // A press hides the tooltip; it shows again only after the pointer has left and come back.
      _hideHoverTooltip();
      return;
    }
    if (event.device != _hoverDevice) return;
    if (event is PointerRemovedEvent) {
      _endHover();
      return;
    }
    if (event is PointerHoverEvent) {
      final box = context.findRenderObject();
      final inside = box is RenderBox && box.attached && box.hasSize && (Offset.zero & box.size).contains(box.globalToLocal(event.position));
      if (!inside) _endHover();
    }
  }

  void _hideHoverTooltip() {
    _hoverTimer?.cancel();
    _hoverTimer = null;
    if (_hoverShown) {
      _hoverShown = false;
      Tooltip.dismissAllToolTips();
    }
  }

  void _endHover() {
    _hideHoverTooltip();
    if (_hoverDevice != null) {
      GestureBinding.instance.pointerRouter.removeGlobalRoute(_onGlobalPointer);
      _hoverDevice = null;
    }
  }

  @override
  void dispose() {
    _hoverTimer?.cancel();
    if (_hoverDevice != null) GestureBinding.instance.pointerRouter.removeGlobalRoute(_onGlobalPointer);
    super.dispose();
  }

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  void didUpdateWidget(DanaviewPressable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_active) _pressed = false;
  }

  Widget _decorate(Widget child, DanaviewPressState state) {
    final overlay = state.focused
        ? DanaviewColors.primarySoft
        : state.hovered
            ? widget.hoverColor
            : widget.hoverColor.withValues(alpha: 0);
    return AnimatedContainer(
      duration: DanaviewMotion.fast,
      curve: DanaviewMotion.curve,
      foregroundDecoration: BoxDecoration(
        color: overlay,
        shape: widget.circle ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: widget.circle ? null : widget.borderRadius,
        border: Border.fromBorderSide(
          state.focused ? DanaviewBorders.focus : DanaviewBorders.focus.copyWith(color: Colors.transparent),
        ),
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final active = _active;
    final state = DanaviewPressState(
      pressed: _pressed && active,
      hovered: _hovered && active,
      focused: _focused && active,
      enabled: active,
    );

    Widget content = widget.builder?.call(context, state) ?? _decorate(widget.child!, state);

    content = AnimatedOpacity(
      opacity: state.pressed ? widget.pressedOpacity : 1.0,
      duration: DanaviewMotion.press,
      curve: DanaviewMotion.curve,
      child: content,
    );
    content = AnimatedScale(
      scale: state.pressed ? widget.pressedScale : 1.0,
      duration: DanaviewMotion.press,
      curve: DanaviewMotion.curve,
      child: content,
    );

    content = GestureDetector(
      behavior: widget.behavior,
      onTapDown: active ? (_) => _setPressed(true) : null,
      onTapUp: active ? (_) => _setPressed(false) : null,
      onTapCancel: active ? () => _setPressed(false) : null,
      onTap: active ? widget.onTap : null,
      onLongPress: active ? widget.onLongPress : null,
      child: content,
    );

    content = FocusableActionDetector(
      enabled: active,
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      mouseCursor: active ? SystemMouseCursors.click : MouseCursor.defer,
      shortcuts: _shortcuts,
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            (widget.onTap ?? widget.onLongPress)?.call();
            return null;
          },
        ),
      },
      onShowHoverHighlight: (value) {
        if (_hovered != value) setState(() => _hovered = value);
      },
      onShowFocusHighlight: (value) {
        if (_focused != value) setState(() => _focused = value);
      },
      child: content,
    );

    content = Semantics(
      container: true,
      button: widget.isButton ? true : null,
      enabled: widget.isButton || !widget.enabled ? active : null,
      selected: widget.selected,
      toggled: widget.toggled,
      label: widget.semanticLabel,
      child: content,
    );

    final tooltip = widget.tooltip;
    if (tooltip != null && tooltip.isNotEmpty) {
      content = Tooltip(
        key: _tooltipKey,
        message: tooltip,
        excludeFromSemantics: widget.semanticLabel != null,
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerHover: _onPointerHover,
          child: content,
        ),
      );
    }
    return content;
  }
}
