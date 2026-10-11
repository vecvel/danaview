import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../foundation/danaview_internal.dart';
import '../theme/danaview_theme.dart';
import '../theme/danaview_tokens.dart';
import 'danaview_icon_button.dart';

/// The two resting heights of a [DanaviewDockedPanel].
enum DanaviewDockDetent { standard, expanded }

/// Non-modal bottom dock with the look of the kit's sheet (top radius, elevated surface, hairline
/// border, drag handle) that leaves the content behind it interactive.
///
/// Unlike [showDanaviewSheet] it is an ordinary widget: place it at the bottom of a Stack or Column and
/// the rest of the screen (a video preview, a timeline) stays visible and touchable. It rests at one
/// of two detents, [standardHeight] or [expandedFraction] of the screen, and the user moves between
/// them by dragging the handle (a fling or passing the midpoint settles on the nearer detent), by
/// tapping it, or with the keyboard (Enter/Space toggle, Up/Down choose) when it is focused.
/// Assistive technology gets an increase/decrease control on the handle.
///
/// The panel is keyboard-aware: it lifts by the on-screen keyboard's inset (zero when an ancestor
/// Scaffold already resized for it) and never grows taller than the space above it. The body
/// scrolls (set [scrollable] to false to lay out a child that scrolls itself, such as a list).
///
/// [detent] is the starting and externally driven detent; user changes are reported through
/// [onDetentChanged] and kept internally, so the panel works with or without a controlling parent.
class DanaviewDockedPanel extends StatefulWidget {
  const DanaviewDockedPanel({
    super.key,
    required this.child,
    this.title,
    this.onClose,
    this.detent = DanaviewDockDetent.standard,
    this.onDetentChanged,
    this.standardHeight = 240,
    this.expandedFraction = 0.85,
    this.maxWidth,
    this.scrollable = true,
    this.padding = const EdgeInsets.fromLTRB(16, 4, 16, 16),
    this.showDragHandle = true,
    this.semanticLabel,
  })  : assert(expandedFraction > 0 && expandedFraction <= 1, 'expandedFraction must be in (0, 1]'),
        assert(standardHeight > 0, 'standardHeight must be positive');

  final Widget child;

  /// One-line header (ellipsized) shown under the handle.
  final String? title;

  /// Adds a close button to the header when non-null (a header is drawn when [title] or this is set).
  final VoidCallback? onClose;

  final DanaviewDockDetent detent;
  final ValueChanged<DanaviewDockDetent>? onDetentChanged;

  /// Height at the standard detent, before clamping to the room above.
  final double standardHeight;

  /// Share of the screen height at the expanded detent, before clamping to the room above.
  final double expandedFraction;

  /// Centers the panel at this width when the parent is wider (null fills the width).
  final double? maxWidth;

  /// Wrap [child] in a vertical scroll view with [padding]. When false the child gets [padding]
  /// and the remaining height as tight constraints.
  final bool scrollable;
  final EdgeInsetsGeometry padding;
  final bool showDragHandle;

  /// Spoken name of the panel region.
  final String? semanticLabel;

  /// Visible and hit height of the handle row.
  static const double handleHeight = 28;

  /// Smallest height the panel is ever drawn at (handle plus a sliver of body).
  static const double minHeight = 96;

  /// Height of the panel at [detent] given the screen and what sits around it.
  ///
  /// Exposed so layouts can reserve room for the dock without building it.
  static double heightFor({
    required DanaviewDockDetent detent,
    required double screenHeight,
    double keyboardInset = 0,
    double topPadding = 0,
    double standardHeight = 240,
    double expandedFraction = 0.85,
  }) {
    final limit = math.max(0.0, screenHeight - keyboardInset - topPadding - 8);
    final target = switch (detent) {
      DanaviewDockDetent.standard => standardHeight,
      DanaviewDockDetent.expanded => screenHeight * expandedFraction,
    };
    return math.min(target, limit);
  }

  @override
  State<DanaviewDockedPanel> createState() => _DanaviewDockedPanelState();
}

class _DanaviewDockedPanelState extends State<DanaviewDockedPanel> {
  late DanaviewDockDetent _detent = widget.detent;
  double? _dragHeight;
  final FocusNode _handleFocus = FocusNode(debugLabel: 'DanaviewDockedPanel handle');
  bool _handleFocused = false;

  @override
  void initState() {
    super.initState();
    _handleFocus.addListener(_onFocus);
  }

  void _onFocus() {
    if (_handleFocused != _handleFocus.hasFocus) setState(() => _handleFocused = _handleFocus.hasFocus);
  }

  @override
  void didUpdateWidget(DanaviewDockedPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.detent != oldWidget.detent) _detent = widget.detent;
  }

  @override
  void dispose() {
    _handleFocus.removeListener(_onFocus);
    _handleFocus.dispose();
    super.dispose();
  }

  void _setDetent(DanaviewDockDetent next) {
    if (next == _detent) return;
    setState(() => _detent = next);
    widget.onDetentChanged?.call(next);
  }

  void _toggle() => _setDetent(
        _detent == DanaviewDockDetent.standard ? DanaviewDockDetent.expanded : DanaviewDockDetent.standard,
      );

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.space || key == LogicalKeyboardKey.numpadEnter) {
      _toggle();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _setDetent(DanaviewDockDetent.expanded);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _setDetent(DanaviewDockDetent.standard);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _onDragStart(double standard, double expanded) {
    _dragHeight = _detent == DanaviewDockDetent.standard ? standard : expanded;
  }

  void _onDragUpdate(DragUpdateDetails details, double standard, double expanded) {
    final low = math.min(standard, expanded);
    final high = math.max(standard, expanded);
    final current = _dragHeight ?? (_detent == DanaviewDockDetent.standard ? standard : expanded);
    // Dragging up (negative delta) grows the panel; stay between a little under standard and expanded.
    final floor = math.max(DanaviewDockedPanel.minHeight, low - 24);
    setState(() => _dragHeight = (current - (details.primaryDelta ?? 0)).clamp(floor, math.max(floor, high)));
  }

  void _onDragEnd(DragEndDetails details, double standard, double expanded) {
    final height = _dragHeight;
    final velocity = details.primaryVelocity ?? 0; // negative: moving up
    var next = _detent;
    if (velocity < -700) {
      next = DanaviewDockDetent.expanded;
    } else if (velocity > 700) {
      next = DanaviewDockDetent.standard;
    } else if (height != null) {
      next = (height - standard).abs() <= (height - expanded).abs() ? DanaviewDockDetent.standard : DanaviewDockDetent.expanded;
    }
    setState(() => _dragHeight = null);
    _setDetent(next);
  }

  Widget _handle(double standard, double expanded) {
    final expandedNow = _detent == DanaviewDockDetent.expanded;
    final bar = AnimatedContainer(
      duration: DanaviewMotion.press,
      width: 36,
      height: 5,
      decoration: BoxDecoration(
        color: _handleFocused ? DanaviewColors.primaryLight : const Color(0x33FFFFFF),
        borderRadius: BorderRadius.circular(2.5),
      ),
    );
    return Semantics(
      container: true,
      button: true,
      focusable: true,
      focused: _handleFocused,
      label: 'Resize panel',
      value: expandedNow ? 'Expanded' : 'Default height',
      increasedValue: 'Expanded',
      decreasedValue: 'Default height',
      onTap: _toggle,
      onIncrease: expandedNow ? null : () => _setDetent(DanaviewDockDetent.expanded),
      onDecrease: expandedNow ? () => _setDetent(DanaviewDockDetent.standard) : null,
      child: ExcludeSemantics(
        child: Focus(
          focusNode: _handleFocus,
          onKeyEvent: _onKey,
          child: MouseRegion(
            cursor: SystemMouseCursors.resizeUpDown,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                _handleFocus.requestFocus();
                _toggle();
              },
              child: SizedBox(
                height: DanaviewDockedPanel.handleHeight,
                child: Center(child: bar),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget? _header() {
    if (widget.title == null && widget.onClose == null) return null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 6),
      child: Row(
        children: [
          Expanded(
            child: widget.title == null
                ? const SizedBox.shrink()
                : Semantics(
                    container: true,
                    header: true,
                    child: Text(
                      widget.title!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: DanaviewTextStyles.title,
                    ),
                  ),
          ),
          if (widget.onClose != null) ...[
            const SizedBox(width: 8),
            DanaviewIconButton(
              icon: Icons.close_rounded,
              size: 32,
              iconSize: 18,
              variant: DanaviewIconButtonVariant.filled,
              tooltip: 'Close',
              onPressed: widget.onClose,
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final keyboard = media.viewInsets.bottom;
    final screen = media.size.height;
    double heightAt(DanaviewDockDetent detent) => DanaviewDockedPanel.heightFor(
          detent: detent,
          screenHeight: screen,
          keyboardInset: keyboard,
          topPadding: media.padding.top,
          standardHeight: widget.standardHeight,
          expandedFraction: widget.expandedFraction,
        );
    final standard = math.max(DanaviewDockedPanel.minHeight, heightAt(DanaviewDockDetent.standard));
    final expanded = math.max(standard, heightAt(DanaviewDockDetent.expanded));
    final dragging = _dragHeight != null;
    final target = _dragHeight ?? (_detent == DanaviewDockDetent.standard ? standard : expanded);
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;

    final header = _header();
    final body = widget.scrollable
        ? SingleChildScrollView(padding: widget.padding, child: widget.child)
        : Padding(padding: widget.padding, child: widget.child);

    final panel = DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: const BoxDecoration(borderRadius: DanaviewRadius.sheetTop, border: DanaviewBorders.all),
      child: DecoratedBox(
        decoration: const BoxDecoration(
          color: DanaviewColors.surfaceElevated,
          borderRadius: DanaviewRadius.sheetTop,
          boxShadow: _dockShadow,
        ),
        child: ClipRRect(
          borderRadius: DanaviewRadius.sheetTop,
          child: SafeArea(
            top: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onVerticalDragStart: (_) => _onDragStart(standard, expanded),
                  onVerticalDragUpdate: (d) => _onDragUpdate(d, standard, expanded),
                  onVerticalDragEnd: (d) => _onDragEnd(d, standard, expanded),
                  onVerticalDragCancel: () => setState(() => _dragHeight = null),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (widget.showDragHandle) _handle(standard, expanded) else const SizedBox(height: 8),
                      if (header != null) header,
                    ],
                  ),
                ),
                Expanded(child: body),
              ],
            ),
          ),
        ),
      ),
    );

    return danaviewOverlayScope(
      context,
      Align(
        alignment: Alignment.bottomCenter,
        heightFactor: 1,
        child: Padding(
          padding: EdgeInsets.only(bottom: keyboard),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: widget.maxWidth ?? double.infinity),
            child: Semantics(
              container: true,
              label: widget.semanticLabel,
              child: AnimatedContainer(
                duration: dragging || reduceMotion ? Duration.zero : DanaviewMotion.normal,
                curve: DanaviewMotion.curve,
                height: target,
                child: panel,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Lifts the panel off the content behind it; the shadow falls upward because the dock sits at the
/// bottom edge.
const List<BoxShadow> _dockShadow = <BoxShadow>[
  BoxShadow(
    color: Color(0x59000000),
    blurRadius: 32,
    spreadRadius: -8,
    offset: Offset(0, -8),
  ),
];
