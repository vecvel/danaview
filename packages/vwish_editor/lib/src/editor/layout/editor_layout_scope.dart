// OWNER: UX-07
//
// EditorLayoutScope: the resolved EditorLayoutSpec for the widgets of the editor's regions
// (ux.md §6). Region owners read it instead of re-deriving the layout:
// * UX-16: `toolTileHeight` and `iconOnlyTools` (step 3) for the tool strip/rail, `dockHeight` for
//   `VwishDockedPanel.standardHeight`, `inspectorPlacement`.
// * UX-14: `transportInTopBar` (step 4): the TransportBar is then placed in the top bar's title slot
//   and shows play/pause and a compact time only.
// * UX-12: `headerWidth`, `rulerHeight` and `kind` for the timeline.
// Only the scaffold rebuilds it, on layout-affecting changes (ux.md §16.6).

import 'package:flutter/widgets.dart';

import 'editor_layout.dart';

/// Supplies the editor's resolved layout to its regions.
class EditorLayoutScope extends InheritedWidget {
  /// Creates the scope.
  const EditorLayoutScope({super.key, required this.spec, required super.child});

  /// The resolved layout.
  final EditorLayoutSpec spec;

  /// The layout of the nearest editor, or null outside one.
  static EditorLayoutSpec? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<EditorLayoutScope>()?.spec;

  /// The layout of the nearest editor.
  static EditorLayoutSpec of(BuildContext context) {
    final spec = maybeOf(context);
    assert(spec != null, 'EditorLayoutScope.of called outside the editor scaffold');
    return spec!;
  }

  @override
  bool updateShouldNotify(EditorLayoutScope oldWidget) => oldWidget.spec != spec;
}
