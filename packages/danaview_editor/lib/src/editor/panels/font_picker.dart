// OWNER: UX-30
//
// The content-font picker (ux.md §10.8, ARCH §17.8): a search field over the catalog's available
// families and one row per family whose name is drawn *in that family* (content preview, exempt
// from the chrome font rule through EditorContentTextRegion). The category is a Figtree caption
// beside it, so the row also reads in a font the user can't read (Pacifico) and for screen
// readers. Tapping a row reports its id; the selected row shows a check. The list is a Column (ten
// families): the text panel scrolls it.

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../app/strings/text_strings.dart';
import '../contracts/content_text.dart';
import '../text/font_catalog.dart';

/// Content-font picker; each family previewed in itself (ARCH §17.8).
class FontPicker extends StatefulWidget {
  /// Creates the picker for [selectedId], reporting picks to [onSelected].
  const FontPicker({super.key, required this.selectedId, required this.onSelected, this.catalog, this.enabled = true});

  /// The id of the current font (an unknown id selects nothing).
  final String selectedId;

  /// A family was picked.
  final ValueChanged<String> onSelected;

  /// The catalog (default [FontCatalog.instance]).
  final FontCatalog? catalog;

  /// Whether rows accept taps.
  final bool enabled;

  /// The key of the row of [id].
  static ValueKey<String> rowKey(String id) => ValueKey<String>('text.font.$id');

  /// The key of the search field.
  static const ValueKey<String> searchKey = ValueKey<String>('text.font.search');

  @override
  State<FontPicker> createState() => _FontPickerState();
}

class _FontPickerState extends State<FontPicker> {
  String _query = '';

  FontCatalog get _catalog => widget.catalog ?? FontCatalog.instance;

  @override
  Widget build(BuildContext context) {
    final matches = _catalog.search(_query);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        DanaviewSearchField(
          key: FontPicker.searchKey,
          hint: TextStrings.searchFonts,
          semanticLabel: TextStrings.searchFonts,
          debounce: Duration.zero,
          onChanged: (q) => setState(() => _query = q),
        ),
        const SizedBox(height: DanaviewSpacing.sm),
        if (matches.isEmpty)
          Padding(
            key: const ValueKey<String>('text.font.empty'),
            padding: const EdgeInsets.symmetric(vertical: DanaviewSpacing.md),
            child: Text(
              TextStrings.noFonts(_query.trim()),
              style: DanaviewTextStyles.caption.copyWith(fontFamily: DanaviewFonts.family, color: DanaviewColors.textSecondary),
            ),
          ),
        for (final f in matches)
          _FontRow(
            key: FontPicker.rowKey(f.id),
            family: f,
            selected: f.id == widget.selectedId,
            enabled: widget.enabled,
            onTap: () => widget.onSelected(f.id),
          ),
      ],
    );
  }
}

class _FontRow extends StatelessWidget {
  const _FontRow({super.key, required this.family, required this.selected, required this.enabled, required this.onTap});

  final ContentFontFamily family;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? DanaviewColors.textPrimary : DanaviewColors.textSecondary;
    return Padding(
      padding: const EdgeInsets.only(bottom: DanaviewSpacing.xxs),
      child: DanaviewPressable(
        onTap: enabled ? onTap : null,
        enabled: enabled,
        selected: selected,
        semanticLabel: TextStrings.fontRow(family.family, family.category, selected: selected),
        borderRadius: DanaviewRadius.controlAll,
        child: Container(
          constraints: const BoxConstraints(minHeight: DanaviewSpacing.minTapTarget),
          padding: const EdgeInsets.symmetric(horizontal: DanaviewSpacing.md, vertical: DanaviewSpacing.xs),
          decoration: BoxDecoration(
            color: selected ? DanaviewColors.surfaceElevatedHigher : null,
            borderRadius: DanaviewRadius.controlAll,
          ),
          child: ExcludeSemantics(
            child: Row(
              children: [
                Expanded(
                  child: EditorContentTextRegion(
                    child: Text(
                      family.family,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontFamily: family.packagedFamily, fontSize: 18, height: 1.3, color: DanaviewColors.textPrimary),
                    ),
                  ),
                ),
                const SizedBox(width: DanaviewSpacing.sm),
                Flexible(
                  child: Text(
                    TextStrings.categoryName(family.category),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
                    style: DanaviewTextStyles.caption.copyWith(fontFamily: DanaviewFonts.family, color: fg),
                  ),
                ),
                SizedBox(
                  width: 28,
                  child: selected ? const Icon(Icons.check_rounded, size: 20, color: DanaviewColors.primary) : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
