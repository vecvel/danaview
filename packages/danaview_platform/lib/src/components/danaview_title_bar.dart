import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

// danaview_platform does not depend on the design system, so its colors mirror the Danaview tokens.
const Color _background = Color(0xFF07080C);
const Color _hairline = Color(0x14FFFFFF);
const Color _textSecondary = Color(0xFFA0A6BC);
const Color _primary = Color(0xFF5E60EE);
const Color _primaryLight = Color(0xFF818CF8);
const Color _hoverFill = Color(0x0FFFFFFF);
const Color _pressedFill = Color(0x1AFFFFFF);
const Color _closeHover = Color(0x29EF4444);

class DanaviewTitleBar extends StatelessWidget {
  static const double height = 38;

  /// Hidden, along with the app mark, when null (e.g. while the player is locked).
  final String? title;
  final Widget? trailing;
  final bool isAlwaysOnTop;
  final VoidCallback? onToggleAlwaysOnTop;

  const DanaviewTitleBar({
    super.key,
    this.title,
    this.trailing,
    this.isAlwaysOnTop = false,
    this.onToggleAlwaysOnTop,
  });

  @override
  Widget build(BuildContext context) {
    if (kIsWeb || (!Platform.isMacOS && !Platform.isWindows && !Platform.isLinux)) {
      return const SizedBox.shrink();
    }

    final isMac = Platform.isMacOS;
    final title = this.title;

    return Container(
      height: height,
      padding: EdgeInsets.only(left: isMac ? 78 : 12, right: 8),
      decoration: const BoxDecoration(
        color: _background,
        border: Border(bottom: BorderSide(color: _hairline, width: 0.8)),
      ),
      child: Stack(
        children: [
          const Positioned.fill(
            child: DragToMoveArea(
              child: SizedBox.expand(),
            ),
          ),
          Row(
            children: [
              if (!isMac && title != null)
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: Icon(Icons.play_circle_fill_rounded, color: _primary, size: 18),
                ),
              Expanded(
                child: title == null
                    ? const SizedBox.shrink()
                    : IgnorePointer(
                        child: Text(
                          title,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: _textSecondary,
                          ),
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
              ),
              if (onToggleAlwaysOnTop != null)
                _TitleBarButton(
                  icon: isAlwaysOnTop ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                  color: isAlwaysOnTop ? _primaryLight : _textSecondary,
                  tooltip: isAlwaysOnTop ? 'Unpin window (T)' : 'Pin window on top (T)',
                  onPressed: onToggleAlwaysOnTop!,
                ),
              if (trailing != null) trailing!,
              if (Platform.isWindows || Platform.isLinux) ...[
                const SizedBox(width: 4),
                _TitleBarButton(
                  icon: Icons.minimize_rounded,
                  tooltip: 'Minimize',
                  onPressed: () => windowManager.minimize(),
                ),
                _TitleBarButton(
                  icon: Icons.crop_square_rounded,
                  tooltip: 'Maximize',
                  onPressed: () async {
                    if (await windowManager.isMaximized()) {
                      windowManager.unmaximize();
                    } else {
                      windowManager.maximize();
                    }
                  },
                ),
                _TitleBarButton(
                  icon: Icons.close_rounded,
                  tooltip: 'Close',
                  hoverColor: _closeHover,
                  onPressed: () => windowManager.close(),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// Small circular icon button with hover and press tints (no ripple).
class _TitleBarButton extends StatefulWidget {
  const _TitleBarButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.color = _textSecondary,
    this.hoverColor = _hoverFill,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final Color color;
  final Color hoverColor;

  @override
  State<_TitleBarButton> createState() => _TitleBarButtonState();
}

class _TitleBarButtonState extends State<_TitleBarButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final fill = _pressed
        ? _pressedFill
        : _hovered
            ? widget.hoverColor
            : const Color(0x00FFFFFF);
    return Tooltip(
      message: widget.tooltip,
      child: Semantics(
        button: true,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (_) => setState(() => _pressed = true),
            onTapCancel: () => setState(() => _pressed = false),
            onTapUp: (_) => setState(() => _pressed = false),
            onTap: widget.onPressed,
            child: SizedBox(
              width: 34,
              height: DanaviewTitleBar.height,
              child: Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: fill),
                  child: Icon(widget.icon, size: 16, color: widget.color),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }}
