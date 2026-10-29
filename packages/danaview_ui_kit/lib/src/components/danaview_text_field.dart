import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/danaview_depth.dart';
import '../theme/danaview_theme.dart';
import '../theme/danaview_tokens.dart';
import 'danaview_icon_button.dart';

class DanaviewTextField extends StatefulWidget {
  const DanaviewTextField({
    super.key,
    this.controller,
    this.focusNode,
    this.hint,
    this.prefixIcon,
    this.errorText,
    this.autofocus = false,
    this.enabled = true,
    this.showClearButton = true,
    this.obscureText = false,
    this.keyboardType,
    this.textInputAction,
    this.textCapitalization = TextCapitalization.none,
    this.inputFormatters,
    this.maxLines = 1,
    this.minLines,
    this.onChanged,
    this.onSubmitted,
    this.semanticLabel,
    this.trailing,
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String? hint;
  final IconData? prefixIcon;

  /// Shown below the field (max 2 lines) and tints the border.
  final String? errorText;
  final bool autofocus;
  final bool enabled;
  final bool showClearButton;
  final bool obscureText;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final TextCapitalization textCapitalization;
  final List<TextInputFormatter>? inputFormatters;
  final int? maxLines;
  final int? minLines;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final String? semanticLabel;

  /// Compact widget after the text (and the clear button), e.g. a mic glyph on a search field.
  final Widget? trailing;

  @override
  State<DanaviewTextField> createState() => _DanaviewTextFieldState();
}

class _DanaviewTextFieldState extends State<DanaviewTextField> {
  TextEditingController? _ownedController;
  FocusNode? _ownedFocusNode;

  TextEditingController get _controller => widget.controller ?? (_ownedController ??= TextEditingController());
  FocusNode get _focusNode => widget.focusNode ?? (_ownedFocusNode ??= FocusNode());

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
    _focusNode.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(DanaviewTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      (oldWidget.controller ?? _ownedController)?.removeListener(_onTextChanged);
      _controller.addListener(_onTextChanged);
    }
    if (oldWidget.focusNode != widget.focusNode) {
      (oldWidget.focusNode ?? _ownedFocusNode)?.removeListener(_onFocusChanged);
      _focusNode.addListener(_onFocusChanged);
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _focusNode.removeListener(_onFocusChanged);
    _ownedController?.dispose();
    _ownedFocusNode?.dispose();
    super.dispose();
  }

  void _onTextChanged() => setState(() {});

  void _onFocusChanged() => setState(() {});

  void _clear() {
    _controller.clear();
    widget.onChanged?.call('');
  }

  @override
  Widget build(BuildContext context) {
    final focused = _focusNode.hasFocus;
    final hasError = widget.errorText != null;
    final showClear = widget.showClearButton && widget.enabled && _controller.text.isNotEmpty;
    // Focus shows as the tinted fill and errors as the message below; the outline stays a neutral
    // hairline in every state.
    const border = DanaviewBorders.hairline;
    final fill = focused ? DanaviewColors.fieldActive : DanaviewColors.surfaceElevated;

    final field = AnimatedContainer(
      duration: DanaviewMotion.fast,
      curve: DanaviewMotion.curve,
      constraints: const BoxConstraints(minHeight: DanaviewSpacing.controlHeight),
      padding: EdgeInsets.only(
        left: widget.prefixIcon != null ? 10 : 12,
        right: showClear || widget.trailing != null ? 2 : 12,
      ),
      decoration: ShapeDecoration(color: fill, shape: DanaviewDepth.shape(DanaviewRadius.controlAll)),
      foregroundDecoration: ShapeDecoration(
        shape: DanaviewDepthBorder(borderRadius: DanaviewRadius.controlAll, side: border, highlight: DanaviewColors.highlight),
      ),
      child: Row(
        children: [
          if (widget.prefixIcon != null) ...[
            Icon(
              widget.prefixIcon,
              size: 18,
              color: focused ? DanaviewColors.primaryLight : DanaviewColors.textMuted,
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 11),
              child: Material(
                type: MaterialType.transparency,
                child: TextField(
                  controller: _controller,
                  focusNode: _focusNode,
                  autofocus: widget.autofocus,
                  enabled: widget.enabled,
                  obscureText: widget.obscureText,
                  keyboardType: widget.keyboardType,
                  textInputAction: widget.textInputAction,
                  textCapitalization: widget.textCapitalization,
                  inputFormatters: widget.inputFormatters,
                  maxLines: widget.obscureText ? 1 : widget.maxLines,
                  minLines: widget.minLines,
                  onChanged: widget.onChanged,
                  onSubmitted: widget.onSubmitted,
                  cursorColor: DanaviewColors.primary,
                  cursorRadius: const Radius.circular(2),
                  style: const TextStyle(fontSize: 15, height: 1.3, color: DanaviewColors.textPrimary),
                  // Every border is explicit so the theme's input borders never leak inside the custom frame.
                  decoration: InputDecoration(
                    isCollapsed: true,
                    isDense: true,
                    filled: false,
                    contentPadding: EdgeInsets.zero,
                    hintText: widget.hint,
                    hintStyle: const TextStyle(fontSize: 15, height: 1.3, color: DanaviewColors.textMuted),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    disabledBorder: InputBorder.none,
                    errorBorder: InputBorder.none,
                    focusedErrorBorder: InputBorder.none,
                  ),
                ),
              ),
            ),
          ),
          if (showClear)
            DanaviewIconButton(
              icon: Icons.cancel_rounded,
              size: 30,
              iconSize: 18,
              color: DanaviewColors.textMuted,
              semanticLabel: 'Clear',
              onPressed: _clear,
            ),
          if (widget.trailing != null) widget.trailing!,
        ],
      ),
    );

    return Semantics(
      label: widget.semanticLabel,
      child: Opacity(
        opacity: widget.enabled ? 1 : DanaviewColors.disabledOpacity,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            field,
            if (hasError)
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 4, right: 4),
                // Room for a full sentence at large text sizes; dialogs scroll their body.
                child: Text(
                  widget.errorText!,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: DanaviewColors.errorLight),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
