import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../foundation/danaview_internal.dart';
import '../theme/danaview_theme.dart';
import '../theme/danaview_tokens.dart';
import 'danaview_glyph.dart';
import 'danaview_icon_button.dart';
import 'danaview_pressable.dart';
import 'danaview_surface.dart';

enum DanaviewMenuAlignment { start, center, end }

sealed class DanaviewMenuEntry {
  const DanaviewMenuEntry();
}

final class DanaviewMenuItem extends DanaviewMenuEntry {
  const DanaviewMenuItem({
    required this.label,
    this.icon,
    this.glyph,
    this.subtitle,
    this.trailing,
    this.selected = false,
    this.destructive = false,
    this.enabled = true,
    this.onTap,
  });

  final String label;
  final IconData? icon;

  /// Drawn instead of [icon] when set.
  final DanaviewGlyphKind? glyph;
  final String? subtitle;
  final Widget? trailing;
  final bool selected;
  final bool destructive;
  final bool enabled;
  final VoidCallback? onTap;
}

final class DanaviewMenuDivider extends DanaviewMenuEntry {
  const DanaviewMenuDivider();
}

final class DanaviewMenuHeader extends DanaviewMenuEntry {
  const DanaviewMenuHeader(this.label);

  final String label;
}

@immutable
class DanaviewOption<T> {
  const DanaviewOption({
    required this.value,
    required this.label,
    this.icon,
    this.subtitle,
    this.enabled = true,
  });

  final T value;
  final String label;
  final IconData? icon;
  final String? subtitle;
  final bool enabled;
}

typedef DanaviewMenuAnchorBuilder = Widget Function(BuildContext context, VoidCallback open, bool isOpen);

class DanaviewMenuAnchor extends StatefulWidget {
  const DanaviewMenuAnchor({
    super.key,
    required this.builder,
    required this.entries,
    this.width = 220,
    this.matchAnchorWidth = false,
    this.alignment = DanaviewMenuAlignment.start,
    this.maxHeight = 420,
    this.onOpen,
    this.onClose,
  });

  /// `open` toggles: calling it while the menu is open closes it.
  final DanaviewMenuAnchorBuilder builder;
  final List<DanaviewMenuEntry> entries;

  /// Menu width; with [matchAnchorWidth] it is the minimum width.
  final double width;
  final bool matchAnchorWidth;
  final DanaviewMenuAlignment alignment;
  final double maxHeight;
  final VoidCallback? onOpen;
  final VoidCallback? onClose;

  /// Whether any menu is open (opening or shown, not closing). Keyboard scopes that handle Esc
  /// themselves (the editor's shortcuts) leave the key alone while this is true, since Esc closes
  /// the menu first.
  static bool get anyOpen => _DanaviewMenuAnchorState._open.isNotEmpty;

  @override
  State<DanaviewMenuAnchor> createState() => _DanaviewMenuAnchorState();
}

class _DanaviewMenuAnchorState extends State<DanaviewMenuAnchor> with SingleTickerProviderStateMixin {
  /// Open menus, newest last. Esc closes the newest one through an early key handler, so it works
  /// wherever keyboard focus is: the menu's focus scope may not hold focus (the menu was opened
  /// from a post-frame callback, a platform moved focus back, or focus was elsewhere), and Esc
  /// would then reach the screen behind it instead (FIX-QA02-M2-2).
  static final List<_DanaviewMenuAnchorState> _open = [];

  static KeyEventResult _onEarlyKey(KeyEvent event) {
    if (_open.isEmpty || event.logicalKey != LogicalKeyboardKey.escape) return KeyEventResult.ignored;
    // Repeats and the key up are swallowed while the menu is open, so nothing behind sees them.
    if (event is KeyDownEvent) _open.last._close();
    return KeyEventResult.handled;
  }

  void _register() {
    if (_open.contains(this)) return;
    if (_open.isEmpty) FocusManager.instance.addEarlyKeyEventHandler(_onEarlyKey);
    _open.add(this);
  }

  void _unregister() {
    if (!_open.remove(this)) return;
    if (_open.isEmpty) FocusManager.instance.removeEarlyKeyEventHandler(_onEarlyKey);
  }

  final OverlayPortalController _portal = OverlayPortalController();
  final GlobalKey _anchorKey = GlobalKey();
  final FocusScopeNode _menuScope = FocusScopeNode(debugLabel: 'DanaviewMenu');
  late final AnimationController _animation;
  late final CurvedAnimation _curved;

  @override
  void initState() {
    super.initState();
    _animation = AnimationController(
      vsync: this,
      duration: DanaviewMotion.fast,
      reverseDuration: DanaviewMotion.press,
    )..addStatusListener(_onStatus);
    _curved = CurvedAnimation(parent: _animation, curve: DanaviewMotion.curve);
  }

  bool get _isOpen => _portal.isShowing && _animation.status != AnimationStatus.reverse;

  FocusNode? _focusBeforeOpen;

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.dismissed || !_portal.isShowing) return;
    final restore = _menuScope.hasFocus ? _focusBeforeOpen : null;
    _focusBeforeOpen = null;
    _portal.hide();
    if (restore != null && restore.context != null) restore.requestFocus();
  }

  void _toggle() {
    if (_isOpen) {
      _close();
      return;
    }
    _focusBeforeOpen = FocusManager.instance.primaryFocus;
    _portal.show();
    _animation.forward();
    _register();
    setState(() {});
    widget.onOpen?.call();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _isOpen) _menuScope.requestFocus();
    });
  }

  void _close() {
    if (!_isOpen) return;
    _unregister();
    _animation.reverse();
    setState(() {});
    widget.onClose?.call();
  }

  @override
  void dispose() {
    _unregister();
    _curved.dispose();
    _animation.dispose();
    _menuScope.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: _buildOverlay,
      child: KeyedSubtree(
        key: _anchorKey,
        child: widget.builder(context, _toggle, _isOpen),
      ),
    );
  }

  Widget _buildOverlay(BuildContext context) {
    final anchorBox = _anchorKey.currentContext?.findRenderObject() as RenderBox?;
    final overlayBox = Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (anchorBox == null || overlayBox == null || !anchorBox.hasSize) {
      return const SizedBox.shrink();
    }
    final anchorRect = MatrixUtils.transformRect(
      anchorBox.getTransformTo(overlayBox),
      Offset.zero & anchorBox.size,
    );
    final media = MediaQuery.of(context);
    final safe = EdgeInsets.fromLTRB(
      media.padding.left + 8,
      media.padding.top + 8,
      media.padding.right + 8,
      math.max(media.padding.bottom, media.viewInsets.bottom) + 8,
    );
    final baseWidth = widget.matchAnchorWidth ? math.max(widget.width, anchorRect.width) : widget.width;
    // Larger text gets a wider menu so labels don't truncate; the layout clamps it to the screen.
    final width = baseWidth * math.max(1.0, media.textScaler.scale(14) / 14);
    final textDirection = Directionality.of(context);
    final touch = context.isTouchPlatform;
    final estimate = _estimateHeight(widget.entries, touch, media.textScaler.scale(1));
    final layout = _DanaviewMenuLayout(
      anchor: anchorRect,
      safe: safe,
      width: width,
      maxHeight: widget.maxHeight,
      alignment: widget.alignment,
      textDirection: textDirection,
      estimate: estimate,
    );
    final below = layout.placeBelow(overlayBox.size, math.min(estimate, widget.maxHeight));
    final alignX = switch (widget.alignment) {
      DanaviewMenuAlignment.start => textDirection == TextDirection.ltr ? -1.0 : 1.0,
      DanaviewMenuAlignment.center => 0.0,
      DanaviewMenuAlignment.end => textDirection == TextDirection.ltr ? 1.0 : -1.0,
    };

    return danaviewOverlayScope(
      context,
      Stack(
        children: [
          Positioned.fill(
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (_) => _close(),
            ),
          ),
          CustomSingleChildLayout(
            delegate: layout,
            child: FadeTransition(
              opacity: _curved,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.95, end: 1).animate(_curved),
                alignment: Alignment(alignX, below ? -1 : 1),
                child: Shortcuts(
                  shortcuts: const <ShortcutActivator, Intent>{
                    SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
                    SingleActivator(LogicalKeyboardKey.arrowDown): NextFocusIntent(),
                    SingleActivator(LogicalKeyboardKey.arrowUp): PreviousFocusIntent(),
                  },
                  child: Actions(
                    actions: <Type, Action<Intent>>{
                      DismissIntent: CallbackAction<DismissIntent>(onInvoke: (_) {
                        _close();
                        return null;
                      }),
                    },
                    child: FocusScope(
                      node: _menuScope,
                      child: _DanaviewMenuPanel(entries: widget.entries, onSelected: _close),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static double _estimateHeight(List<DanaviewMenuEntry> entries, bool touch, double textScale) {
    var height = 12.0;
    for (final entry in entries) {
      height += switch (entry) {
        DanaviewMenuItem(:final subtitle) => (touch ? 44.0 : 36.0) + (subtitle != null ? 16 * textScale : 0),
        DanaviewMenuHeader() => 28 * textScale,
        DanaviewMenuDivider() => 9,
      };
    }
    return height;
  }
}

class _DanaviewMenuLayout extends SingleChildLayoutDelegate {
  _DanaviewMenuLayout({
    required this.anchor,
    required this.safe,
    required this.width,
    required this.maxHeight,
    required this.alignment,
    required this.textDirection,
    required this.estimate,
  });

  static const double gap = 6;
  static const double minUsefulHeight = 120;

  final Rect anchor;
  final EdgeInsets safe;
  final double width;
  final double maxHeight;
  final DanaviewMenuAlignment alignment;
  final TextDirection textDirection;
  final double estimate;

  double _spaceBelow(Size size) => size.height - safe.bottom - anchor.bottom - gap;
  double _spaceAbove() => anchor.top - safe.top - gap;

  bool _overlap(Size size) {
    final best = math.max(_spaceBelow(size), _spaceAbove());
    return best < math.min(minUsefulHeight, estimate);
  }

  bool placeBelow(Size size, double childHeight) {
    if (_overlap(size)) return true;
    final below = _spaceBelow(size);
    return childHeight <= below || below >= _spaceAbove();
  }

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final size = constraints.biggest;
    final availableWidth = math.max(0.0, size.width - safe.horizontal);
    final availableHeight = math.max(0.0, size.height - safe.vertical);
    final w = math.min(width, availableWidth);
    final h = _overlap(size)
        ? availableHeight
        : math.max(0.0, math.max(_spaceBelow(size), _spaceAbove()));
    return BoxConstraints(minWidth: w, maxWidth: w, maxHeight: math.min(h, maxHeight));
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final ltr = textDirection == TextDirection.ltr;
    final start = ltr ? anchor.left : anchor.right - childSize.width;
    final end = ltr ? anchor.right - childSize.width : anchor.left;
    var x = switch (alignment) {
      DanaviewMenuAlignment.start => start,
      DanaviewMenuAlignment.center => anchor.center.dx - childSize.width / 2,
      DanaviewMenuAlignment.end => end,
    };
    final double y;
    if (_overlap(size)) {
      y = anchor.top;
    } else if (placeBelow(size, childSize.height)) {
      y = anchor.bottom + gap;
    } else {
      y = anchor.top - gap - childSize.height;
    }
    final maxX = math.max(safe.left, size.width - safe.right - childSize.width);
    final maxY = math.max(safe.top, size.height - safe.bottom - childSize.height);
    x = x.clamp(safe.left, maxX);
    return Offset(x, y.clamp(safe.top, maxY));
  }

  @override
  bool shouldRelayout(_DanaviewMenuLayout oldDelegate) {
    return anchor != oldDelegate.anchor ||
        safe != oldDelegate.safe ||
        width != oldDelegate.width ||
        maxHeight != oldDelegate.maxHeight ||
        alignment != oldDelegate.alignment ||
        textDirection != oldDelegate.textDirection ||
        estimate != oldDelegate.estimate;
  }
}

class _DanaviewMenuPanel extends StatelessWidget {
  const _DanaviewMenuPanel({required this.entries, required this.onSelected});

  final List<DanaviewMenuEntry> entries;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    return DanaviewSurface(
      color: DanaviewColors.surfaceElevatedHigher,
      shadow: DanaviewShadow.soft,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final entry in entries)
              switch (entry) {
                DanaviewMenuItem() => _DanaviewMenuItemTile(item: entry, onSelected: onSelected),
                DanaviewMenuHeader(:final label) => Padding(
                    padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.2,
                        color: DanaviewColors.textMuted,
                      ),
                    ),
                  ),
                DanaviewMenuDivider() => Container(
                    height: DanaviewBorders.width,
                    margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                    color: DanaviewColors.hairline,
                  ),
              },
          ],
        ),
      ),
    );
  }
}

class _DanaviewMenuItemTile extends StatelessWidget {
  const _DanaviewMenuItemTile({required this.item, required this.onSelected});

  final DanaviewMenuItem item;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final touch = context.isTouchPlatform;
    final fg = item.destructive ? DanaviewColors.errorLight : DanaviewColors.textPrimary;
    return DanaviewPressable.builder(
      onTap: item.enabled
          ? () {
              onSelected();
              item.onTap?.call();
            }
          : null,
      selected: item.selected,
      builder: (context, state) {
        // Owner rule: no hover or press fill; only hardware-keyboard focus marks the item.
        final background = state.focused ? DanaviewColors.hover : const Color(0x00FFFFFF);
        return danaviewDimmed(
          item.enabled,
          AnimatedContainer(
            duration: DanaviewMotion.fast,
            curve: DanaviewMotion.curve,
            constraints: BoxConstraints(minHeight: touch ? 44 : 36),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(color: background, borderRadius: DanaviewRadius.smAll),
            child: Row(
              children: [
                if (item.icon != null || item.glyph != null) ...[
                  danaviewIconOrGlyph(
                    item.icon,
                    item.glyph,
                    size: 18,
                    color: item.destructive ? DanaviewColors.errorLight : DanaviewColors.textSecondary,
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: item.selected ? FontWeight.w600 : FontWeight.w500,
                          color: fg,
                        ),
                      ),
                      if (item.subtitle != null)
                        Text(
                          item.subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12, color: DanaviewColors.textMuted),
                        ),
                    ],
                  ),
                ),
                if (item.trailing != null) ...[
                  const SizedBox(width: 8),
                  item.trailing!,
                ],
                if (item.selected) ...[
                  const SizedBox(width: 8),
                  const Icon(Icons.check_rounded, size: 18, color: DanaviewColors.primaryLight),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class DanaviewDropdown<T> extends StatelessWidget {
  const DanaviewDropdown({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    this.label,
    this.icon,
    this.compact = false,
    this.expand = false,
    this.enabled = true,
    this.menuWidth = 200,
    this.maxWidth = 320,
    this.placeholder = '',
    this.tooltip,
  });

  final T value;
  final List<DanaviewOption<T>> options;
  final ValueChanged<T> onChanged;

  /// Shown as a muted prefix in the trigger (non-compact) and as the menu header.
  final String? label;
  final IconData? icon;
  final bool compact;

  /// Fills the available width; requires bounded width constraints.
  final bool expand;
  final bool enabled;

  /// Minimum menu width; the menu is never narrower than the trigger.
  final double menuWidth;

  /// Trigger width cap when not [expand]ed (also capped to the screen width).
  final double maxWidth;

  /// Trigger text when [value] matches no option.
  final String placeholder;
  final String? tooltip;

  DanaviewOption<T>? get _current {
    for (final option in options) {
      if (option.value == value) return option;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final current = _current;
    return DanaviewMenuAnchor(
      width: menuWidth,
      matchAnchorWidth: true,
      entries: [
        if (label != null) DanaviewMenuHeader(label!),
        for (final option in options)
          DanaviewMenuItem(
            label: option.label,
            icon: option.icon,
            subtitle: option.subtitle,
            enabled: option.enabled,
            selected: option.value == value,
            onTap: () => onChanged(option.value),
          ),
      ],
      builder: (context, open, isOpen) => _DanaviewDropdownTrigger(
        text: current?.label ?? placeholder,
        label: compact ? null : label,
        icon: icon ?? current?.icon,
        compact: compact,
        expand: expand,
        isOpen: isOpen,
        tooltip: tooltip,
        maxWidth: maxWidth,
        onTap: enabled ? open : null,
      ),
    );
  }
}

class _DanaviewDropdownTrigger extends StatelessWidget {
  const _DanaviewDropdownTrigger({
    required this.text,
    required this.label,
    required this.icon,
    required this.compact,
    required this.expand,
    required this.isOpen,
    required this.tooltip,
    required this.maxWidth,
    required this.onTap,
  });

  final String text;
  final String? label;
  final IconData? icon;
  final bool compact;
  final bool expand;
  final bool isOpen;
  final String? tooltip;
  final double maxWidth;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final radius = compact ? DanaviewRadius.smAll : DanaviewRadius.mdAll;
    final fontSize = compact ? 13.0 : 14.0;
    return DanaviewPressable.builder(
      onTap: onTap,
      tooltip: tooltip,
      semanticLabel: label == null ? text : '$label: $text',
      builder: (context, state) {
        final highlighted = isOpen || state.focused;
        Widget visual = AnimatedContainer(
          duration: DanaviewMotion.fast,
          curve: DanaviewMotion.curve,
          constraints: BoxConstraints(minHeight: compact ? 32 : 40),
          padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 12, vertical: 4),
          decoration: BoxDecoration(
            color: danaviewInteractiveFill(
              highlighted ? DanaviewColors.fieldActive : DanaviewColors.surfaceElevatedHigher,
              state,
            ),
            borderRadius: radius,
          ),
          foregroundDecoration: BoxDecoration(
            borderRadius: radius,
            // Open shows as the tinted fill; only keyboard focus draws the ring.
            border: Border.fromBorderSide(state.focused ? DanaviewBorders.focus : DanaviewBorders.hairline),
          ),
          child: Row(
            mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: compact ? 16 : 18, color: DanaviewColors.textSecondary),
                SizedBox(width: compact ? 6 : 8),
              ],
              Flexible(
                fit: expand ? FlexFit.tight : FlexFit.loose,
                child: Text.rich(
                  TextSpan(
                    children: [
                      if (label != null)
                        TextSpan(
                          text: '$label  ',
                          style: const TextStyle(color: DanaviewColors.textSecondary, fontWeight: FontWeight.w500),
                        ),
                      TextSpan(text: text),
                    ],
                  ),
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: fontSize,
                    fontWeight: FontWeight.w600,
                    color: DanaviewColors.textPrimary,
                  ),
                ),
              ),
              SizedBox(width: compact ? 4 : 6),
              AnimatedRotation(
                turns: isOpen ? 0.5 : 0,
                duration: DanaviewMotion.normal,
                curve: DanaviewMotion.curve,
                child: Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: compact ? 18 : 20,
                  color: DanaviewColors.textMuted,
                ),
              ),
            ],
          ),
        );
        visual = expand
            ? SizedBox(width: double.infinity, child: visual)
            : ConstrainedBox(
                constraints: BoxConstraints(maxWidth: math.min(maxWidth, MediaQuery.sizeOf(context).width)),
                child: visual,
              );
        return danaviewDimmed(onTap != null, danaviewTapTarget(context, visual));
      },
    );
  }
}

class DanaviewMenuIconTrigger extends StatelessWidget {
  const DanaviewMenuIconTrigger({
    super.key,
    required this.icon,
    required this.entries,
    this.tooltip,
    this.semanticLabel,
    this.selected = false,
    this.enabled = true,
    this.color,
    this.size = 40,
    this.iconSize,
    this.variant = DanaviewIconButtonVariant.plain,
    this.menuWidth = 220,
    this.alignment = DanaviewMenuAlignment.end,
  });

  final IconData icon;
  final List<DanaviewMenuEntry> entries;
  final String? tooltip;
  final String? semanticLabel;
  final bool selected;
  final bool enabled;
  final Color? color;
  final double size;
  final double? iconSize;
  final DanaviewIconButtonVariant variant;
  final double menuWidth;
  final DanaviewMenuAlignment alignment;

  @override
  Widget build(BuildContext context) {
    return DanaviewMenuAnchor(
      entries: entries,
      width: menuWidth,
      alignment: alignment,
      builder: (context, open, isOpen) => DanaviewIconButton(
        icon: icon,
        onPressed: enabled ? open : null,
        selected: selected || isOpen,
        color: color,
        size: size,
        iconSize: iconSize,
        variant: variant,
        tooltip: tooltip,
        semanticLabel: semanticLabel,
      ),
    );
  }
}
