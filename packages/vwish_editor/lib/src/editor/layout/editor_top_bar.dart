// OWNER: UX-07
//
// EditorTopBar (ux.md §6.4): [close][title button][undo][redo][export].
// * Close: close_rounded on compact kinds, arrow_back_ios_new_rounded on medium/expanded.
// * Title button: name (headline, 1 line) over the save status (caption, 1 line; one line
//   "Name · Saved" in compactLandscape), trailing expand_more; opens the project sheet, or retries
//   the save when it shows "Couldn't save · Retry" (error colour).
// * Undo/redo: disabled when history doesn't allow; the tooltip carries the label and shortcut;
//   long-press on undo opens the history sheet.
// * Export: a primary text button at ≥ 360 px, an icon-only round primary button below.
// * Ladder step 4: the transport widget replaces the title (play/pause and compact time).
// Width at 280: close 44 + undo 44 + redo 44 + export 44 + paddings 16 = 192, the title keeps 88.

import 'package:flutter/material.dart' show Icons, Theme;
import 'package:flutter/widgets.dart';
import 'package:vwish_ui_kit/vwish_ui_kit.dart';

import '../editor_lifecycle.dart';
import 'editor_layout.dart';
import 'editor_shell_strings.dart';

/// The editor's top bar.
class EditorTopBar extends StatelessWidget {
  /// Creates the bar.
  const EditorTopBar({
    super.key,
    required this.kind,
    required this.status,
    required this.closing,
    required this.onClose,
    this.onTitle,
    this.onRetrySave,
    this.onUndo,
    this.onRedo,
    this.onHistory,
    this.onExport,
    this.transport,
  });

  /// The bar is at least this wide before the export button shows its label.
  static const double exportLabelMinWidth = 360;

  /// Horizontal padding on each side.
  static const double sidePadding = 8;

  /// Layout kind (close icon, one- or two-line title).
  final EditorLayoutKind kind;

  /// Name, save status and history.
  final EditorShellStatus status;

  /// The editor is closing: the status reads "Saving…".
  final bool closing;

  /// Close button.
  final VoidCallback onClose;

  /// Title button (project sheet); null when there is none yet.
  final VoidCallback? onTitle;

  /// "Couldn't save · Retry".
  final VoidCallback? onRetrySave;

  /// Undo; null disables the button.
  final VoidCallback? onUndo;

  /// Redo; null disables the button.
  final VoidCallback? onRedo;

  /// Long-press on undo: the history sheet.
  final VoidCallback? onHistory;

  /// Export; null disables the button.
  final VoidCallback? onExport;

  /// The transport merged into the bar (ladder step 4); replaces the title when set.
  final Widget? transport;

  /// The status line for [status] ("Saved", "Saving…", "Edited", "Couldn't save · Retry").
  static String statusText(EditorShellStatus status, {bool closing = false}) {
    if (closing) return EditorShellStrings.saving;
    return switch (status.save) {
      EditorSaveIndicator.saved => EditorShellStrings.saved,
      EditorSaveIndicator.saving => EditorShellStrings.saving,
      EditorSaveIndicator.edited => EditorShellStrings.edited,
      EditorSaveIndicator.failed => EditorShellStrings.saveFailed,
    };
  }

  @override
  Widget build(BuildContext context) {
    final platform = Theme.of(context).platform;
    final apple = platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;
    final compact = kind == EditorLayoutKind.compactPortrait || kind == EditorLayoutKind.compactLandscape;
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: VwishColors.background,
        border: Border(bottom: VwishBorders.subtle),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= exportLabelMinWidth;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: sidePadding),
            child: Row(
              children: [
                VwishIconButton(
                  icon: compact ? Icons.close_rounded : Icons.arrow_back_ios_new_rounded,
                  iconSize: compact ? 22 : 18,
                  tooltip: EditorShellStrings.closeEditor,
                  onPressed: onClose,
                ),
                Expanded(child: transport ?? _title(context)),
                VwishIconButton(
                  icon: Icons.undo_rounded,
                  iconSize: 20,
                  tooltip: EditorShellStrings.undoTooltip(status.undoLabel, apple: apple),
                  onPressed: status.canUndo && !closing ? onUndo : null,
                  onLongPress: closing ? null : onHistory,
                ),
                VwishIconButton(
                  icon: Icons.redo_rounded,
                  iconSize: 20,
                  tooltip: EditorShellStrings.redoTooltip(status.redoLabel, apple: apple),
                  onPressed: status.canRedo && !closing ? onRedo : null,
                ),
                const SizedBox(width: VwishSpacing.xs),
                if (wide)
                  VwishButton.primary(
                    label: EditorShellStrings.export,
                    size: VwishButtonSize.sm,
                    icon: Icons.upload_rounded,
                    onPressed: closing ? null : onExport,
                  )
                else
                  VwishIconButton(
                    icon: Icons.upload_rounded,
                    variant: VwishIconButtonVariant.primary,
                    size: 36,
                    iconSize: 18,
                    tooltip: EditorShellStrings.export,
                    onPressed: closing ? null : onExport,
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _title(BuildContext context) {
    final failed = !closing && status.save == EditorSaveIndicator.failed;
    final name = status.projectName ?? EditorShellStrings.opening;
    final line = statusText(status, closing: closing);
    final statusStyle = VwishTextStyles.caption.copyWith(
      height: 1.2,
      fontFamily: VwishFonts.family,
      color: failed ? VwishColors.errorLight : VwishColors.textMuted,
      fontWeight: failed ? FontWeight.w600 : FontWeight.w400,
    );
    final nameStyle = VwishTextStyles.headline.copyWith(height: 1.25, fontFamily: VwishFonts.family);
    final twoLines = kind != EditorLayoutKind.compactLandscape;
    final Widget text = twoLines
        ? Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, style: nameStyle),
              Text(line, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, style: statusStyle),
            ],
          )
        : Row(
            children: [
              Flexible(child: Text(name, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, style: nameStyle)),
              Flexible(
                child: Text(' · $line', maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, style: statusStyle),
              ),
            ],
          );
    final onTap = failed ? onRetrySave : onTitle;
    return Semantics(
      container: true,
      button: onTap != null,
      label: '$name, $line',
      hint: onTap == null ? null : (failed ? EditorShellStrings.retryHint : EditorShellStrings.titleHint),
      onTap: onTap,
      excludeSemantics: true,
      child: VwishPressable(
        onTap: onTap,
        enabled: onTap != null,
        isButton: false,
        borderRadius: VwishRadius.smAll,
        pressedScale: 1,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: VwishSpacing.xs),
          child: Row(
            children: [
              Flexible(child: text),
              if (onTap != null && !failed)
                const Padding(
                  padding: EdgeInsets.only(left: VwishSpacing.xxs),
                  child: Icon(Icons.expand_more_rounded, size: 18, color: VwishColors.textSecondary),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
