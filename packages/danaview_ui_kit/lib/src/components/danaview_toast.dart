import 'package:flutter/material.dart';

import '../foundation/danaview_internal.dart';
import '../theme/danaview_theme.dart';
import '../theme/danaview_tokens.dart';
import 'danaview_surface.dart';

enum DanaviewToastKind { info, success, error }

abstract final class DanaviewToast {
  static OverlayEntry? _current;

  /// Replaces any visible toast; tapping dismisses it.
  ///
  /// [bottomOffset] is the gap above the bottom safe area, e.g. to clear a control bar.
  /// When [topOffset] is set the toast sits that far below the top safe area instead.
  static void show(
    BuildContext context,
    String message, {
    IconData? icon,
    DanaviewToastKind kind = DanaviewToastKind.info,
    Duration duration = const Duration(milliseconds: 2400),
    double bottomOffset = 24,
    double? topOffset,
  }) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    dismiss();
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) => _DanaviewToastView(
        message: message,
        icon: icon,
        kind: kind,
        duration: duration,
        bottomOffset: bottomOffset,
        topOffset: topOffset,
        onDone: () {
          if (_current == entry) dismiss();
        },
        onDisposed: () {
          if (_current == entry) _current = null;
        },
      ),
    );
    _current = entry;
    overlay.insert(entry);
  }

  static void dismiss() {
    final entry = _current;
    _current = null;
    if (entry == null) return;
    entry
      ..remove()
      ..dispose();
  }
}

class _DanaviewToastView extends StatefulWidget {
  const _DanaviewToastView({
    required this.message,
    required this.icon,
    required this.kind,
    required this.duration,
    required this.bottomOffset,
    required this.topOffset,
    required this.onDone,
    required this.onDisposed,
  });

  final String message;
  final IconData? icon;
  final DanaviewToastKind kind;
  final Duration duration;
  final double bottomOffset;
  final double? topOffset;
  final VoidCallback onDone;

  /// Fires when the host overlay goes away before the toast finished.
  final VoidCallback onDisposed;

  @override
  State<_DanaviewToastView> createState() => _DanaviewToastViewState();
}

class _DanaviewToastViewState extends State<_DanaviewToastView> with SingleTickerProviderStateMixin {
  static const Duration _transition = DanaviewMotion.normal;

  late final AnimationController _controller;
  late final Animation<double> _visibility;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _transition * 2 + widget.duration)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) widget.onDone();
      })
      ..forward();
    _visibility = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(begin: 0.0, end: 1.0).chain(CurveTween(curve: DanaviewMotion.curve)),
        weight: _weight(_transition),
      ),
      TweenSequenceItem(tween: ConstantTween(1.0), weight: _weight(widget.duration)),
      TweenSequenceItem(
        tween: Tween(begin: 1.0, end: 0.0).chain(CurveTween(curve: Curves.easeInCubic)),
        weight: _weight(_transition),
      ),
    ]).animate(_controller);
  }

  double _weight(Duration d) => d.inMilliseconds.toDouble().clamp(1, double.infinity);

  @override
  void dispose() {
    widget.onDisposed();
    _controller.dispose();
    super.dispose();
  }

  void _dismissNow() {
    final total = _controller.duration!.inMilliseconds;
    final fadeOutStart = (total - _transition.inMilliseconds) / total;
    if (_controller.value < fadeOutStart) _controller.value = fadeOutStart;
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final (IconData defaultIcon, Color accent) = switch (widget.kind) {
      DanaviewToastKind.info => (Icons.info_rounded, DanaviewColors.primaryLight),
      DanaviewToastKind.success => (Icons.check_circle_rounded, DanaviewColors.success),
      DanaviewToastKind.error => (Icons.error_rounded, DanaviewColors.errorLight),
    };
    // With the keyboard up the band above it belongs to the focused field and a dialog's
    // buttons, so the toast moves to the top.
    final keyboardUp = media.viewInsets.bottom > 0;
    final topOffset = widget.topOffset ?? (keyboardUp ? 16.0 : null);
    final top = topOffset == null ? null : media.padding.top + topOffset;
    final bottom = media.padding.bottom + widget.bottomOffset;
    final slide = top == null ? 16.0 : -16.0;

    return Positioned(
      left: media.padding.left + 16,
      right: media.padding.right + 16,
      top: top,
      bottom: top == null ? bottom : null,
      child: danaviewOverlayScope(
        context,
        Center(
          child: AnimatedBuilder(
            animation: _visibility,
            builder: (context, child) => Opacity(
              opacity: _visibility.value,
              child: Transform.translate(offset: Offset(0, (1 - _visibility.value) * slide), child: child),
            ),
            child: Semantics(
              liveRegion: true,
              container: true,
              child: GestureDetector(
                onTap: _dismissNow,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: DanaviewSurface(
                    color: DanaviewColors.surfaceElevatedHigher,
                    borderRadius: DanaviewRadius.mdAll,
                    shadow: DanaviewShadow.soft,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(widget.icon ?? defaultIcon, size: 18, color: accent),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Text(
                            widget.message,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              height: 1.3,
                              color: DanaviewColors.textPrimary,
                            ),
                          ),
                        ),
                      ],
                    ),
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
