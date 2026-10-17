import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../foundation/danaview_internal.dart';
import '../theme/danaview_theme.dart';
import '../theme/danaview_tokens.dart';
import 'danaview_icon_button.dart';
import 'danaview_toast.dart';

/// The sheet is its own route: read providers inside [builder] with Consumer/ref.watch so it stays live.
Future<T?> showDanaviewSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  String? title,
  bool isScrollControlled = true,
  bool isDismissible = true,
  bool showDragHandle = true,
  bool useRootNavigator = false,
  double maxHeightFactor = 0.85,
  double maxWidth = 640,
  EdgeInsetsGeometry padding = const EdgeInsets.fromLTRB(16, 4, 16, 16),
}) {
  final navigator = Navigator.of(context, rootNavigator: useRootNavigator);
  // Toasts live in the root overlay and would otherwise float over the sheet's content.
  DanaviewToast.dismiss();
  return navigator.push<T>(
    _DanaviewSheetRoute<T>(
      builder: builder,
      title: title,
      isScrollControlled: isScrollControlled,
      dismissible: isDismissible,
      showDragHandle: showDragHandle,
      maxHeightFactor: maxHeightFactor,
      maxWidth: maxWidth,
      padding: padding,
      capturedThemes: InheritedTheme.capture(from: context, to: navigator.context),
    ),
  );
}

class _DanaviewSheetRoute<T> extends PopupRoute<T> {
  _DanaviewSheetRoute({
    required this.builder,
    required this.title,
    required this.isScrollControlled,
    required this.dismissible,
    required this.showDragHandle,
    required this.maxHeightFactor,
    required this.maxWidth,
    required this.padding,
    required this.capturedThemes,
  });

  final WidgetBuilder builder;
  final String? title;
  final bool isScrollControlled;
  final bool dismissible;
  final bool showDragHandle;
  final double maxHeightFactor;
  final double maxWidth;
  final EdgeInsetsGeometry padding;
  final CapturedThemes capturedThemes;

  CurvedAnimation? _curved;

  @override
  Color? get barrierColor => DanaviewColors.scrim;

  @override
  bool get barrierDismissible => dismissible;

  @override
  String? get barrierLabel => 'Dismiss';

  @override
  Duration get transitionDuration => DanaviewMotion.slow;

  @override
  Duration get reverseTransitionDuration => DanaviewMotion.normal;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) {
    final curved = _curved ??= CurvedAnimation(
      parent: animation,
      curve: DanaviewMotion.curve,
      reverseCurve: Curves.easeInCubic,
    );
    return capturedThemes.wrap(
      _DanaviewSheet(
        animation: curved,
        title: title,
        builder: builder,
        isScrollControlled: isScrollControlled,
        dismissible: dismissible,
        showDragHandle: showDragHandle,
        maxHeightFactor: maxHeightFactor,
        maxWidth: maxWidth,
        padding: padding,
      ),
    );
  }

  @override
  void dispose() {
    _curved?.dispose();
    super.dispose();
  }
}

class _DanaviewSheet extends StatefulWidget {
  const _DanaviewSheet({
    required this.animation,
    required this.title,
    required this.builder,
    required this.isScrollControlled,
    required this.dismissible,
    required this.showDragHandle,
    required this.maxHeightFactor,
    required this.maxWidth,
    required this.padding,
  });

  final Animation<double> animation;
  final String? title;
  final WidgetBuilder builder;
  final bool isScrollControlled;
  final bool dismissible;
  final bool showDragHandle;
  final double maxHeightFactor;
  final double maxWidth;
  final EdgeInsetsGeometry padding;

  @override
  State<_DanaviewSheet> createState() => _DanaviewSheetState();
}

class _DanaviewSheetState extends State<_DanaviewSheet> with SingleTickerProviderStateMixin {
  final GlobalKey _sheetKey = GlobalKey();
  double _drag = 0;
  double _settleFrom = 0;
  late final AnimationController _settle;
  late final Animation<Offset> _slide;
  late final CurvedAnimation _fade;

  @override
  void initState() {
    super.initState();
    _settle = AnimationController(vsync: this, duration: DanaviewMotion.normal)
      ..addListener(() {
        setState(() => _drag = _settleFrom * (1 - DanaviewMotion.curve.transform(_settle.value)));
      });
    _slide = Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero).animate(widget.animation);
    _fade = CurvedAnimation(parent: widget.animation, curve: const Interval(0, 0.5));
  }

  @override
  void dispose() {
    _settle.dispose();
    _fade.dispose();
    super.dispose();
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (!widget.dismissible) return;
    _settle.stop();
    setState(() => _drag = math.max(0, _drag + (details.primaryDelta ?? 0)));
  }

  void _onDragEnd(DragEndDetails details) {
    if (!widget.dismissible) return;
    final height = _sheetKey.currentContext?.size?.height ?? 1;
    final velocity = details.primaryVelocity ?? 0;
    if (velocity > 700 || _drag > height * 0.3) {
      Navigator.of(context).maybePop();
      return;
    }
    _settleFrom = _drag;
    _settle.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final keyboard = media.viewInsets.bottom;
    final maxHeight = math.max(
      0.0,
      math.min(
        media.size.height * widget.maxHeightFactor,
        media.size.height - keyboard - media.padding.top - 8,
      ),
    );
    final content = widget.builder(context);
    // Centred and narrower than a landscape phone, the sheet only needs the part of a side inset
    // (notch, rounded corners) it actually reaches; a full-width sheet still clears all of it.
    final sideGap = math.max(0.0, (media.size.width - widget.maxWidth) / 2);
    final sideInsets = EdgeInsets.only(
      left: math.max(0.0, media.padding.left - sideGap),
      right: math.max(0.0, media.padding.right - sideGap),
    );

    final sheet = DecoratedBox(
      key: _sheetKey,
      decoration: const BoxDecoration(
        color: DanaviewColors.surfaceElevated,
        borderRadius: DanaviewRadius.sheetTop,
      ),
      position: DecorationPosition.background,
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: const BoxDecoration(borderRadius: DanaviewRadius.sheetTop, border: DanaviewBorders.all),
        child: ClipRRect(
          borderRadius: DanaviewRadius.sheetTop,
          child: MediaQuery.removePadding(
            context: context,
            removeLeft: true,
            removeRight: true,
            child: SafeArea(
              top: false,
              minimum: sideInsets,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (widget.showDragHandle)
                    Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 4),
                      child: Center(
                        child: Container(
                          width: 36,
                          height: 5,
                          decoration: BoxDecoration(
                            color: const Color(0x33FFFFFF),
                            borderRadius: BorderRadius.circular(2.5),
                          ),
                        ),
                      ),
                    )
                  else
                    const SizedBox(height: 8),
                  if (widget.title != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 2, 8, 6),
                      child: Row(
                        children: [
                          Expanded(
                            child: Semantics(
                              header: true,
                              child: Text(
                                widget.title!,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: DanaviewTextStyles.title,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          DanaviewIconButton(
                            icon: Icons.close_rounded,
                            size: 32,
                            iconSize: 18,
                            variant: DanaviewIconButtonVariant.filled,
                            tooltip: 'Close',
                            onPressed: () => Navigator.of(context).maybePop(),
                          ),
                        ],
                      ),
                    ),
                  Flexible(
                    child: widget.isScrollControlled
                        ? SingleChildScrollView(padding: widget.padding, child: content)
                        : Padding(padding: widget.padding, child: content),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    return danaviewOverlayScope(
      context,
      Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: EdgeInsets.only(bottom: keyboard),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: widget.maxWidth, maxHeight: maxHeight),
            child: FadeTransition(
              opacity: _fade,
              child: SlideTransition(
                position: _slide,
                child: Transform.translate(
                  offset: Offset(0, _drag),
                  child: GestureDetector(
                    onVerticalDragUpdate: _onDragUpdate,
                    onVerticalDragEnd: _onDragEnd,
                    child: sheet,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
