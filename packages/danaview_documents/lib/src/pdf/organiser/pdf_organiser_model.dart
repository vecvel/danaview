// OWNER: HOM-28
//
// The state of the page organiser (HOM plan §8.5): the pages in their new order with their extra
// rotation, the selection, and the edits the toolbar and drag-and-drop make (select, rotate,
// delete, move, reset). The result is an organise plan for `PdfPageTools.organise` (reorder +
// rotate + delete in one native write) or, for the selection, an "extract selected pages" plan.
// Pure Dart; the screen listens to it.

import 'package:danaview_pdf/danaview_pdf.dart';
import 'package:flutter/foundation.dart';

/// The organiser's pages, selection and edits.
class PdfOrganiserModel extends ChangeNotifier {
  /// A model of the [pageCount] pages of a document, in their original order.
  PdfOrganiserModel(this.pageCount) : _pages = identityPlan(pageCount);

  /// Pages of the source document.
  final int pageCount;

  List<PdfPagePlan> _pages;
  final Set<int> _selected = {};

  /// The pages in their current order (source page and extra rotation).
  List<PdfPagePlan> get pages => List.unmodifiable(_pages);

  /// The plan to save.
  List<PdfPagePlan> get plan => pages;

  /// Pages shown.
  int get length => _pages.length;

  /// True when the pages differ from the original (something to save).
  bool get isDirty => !isIdentityPlan(_pages, pageCount);

  /// Selected source pages.
  Set<int> get selected => Set.unmodifiable(_selected);

  /// Number of selected pages.
  int get selectedCount => _selected.length;

  /// True when at least one page is selected.
  bool get hasSelection => _selected.isNotEmpty;

  /// True when every shown page is selected.
  bool get allSelected => _selected.length == _pages.length && _pages.isNotEmpty;

  /// Whether source page [sourcePage] is selected.
  bool isSelected(int sourcePage) => _selected.contains(sourcePage);

  /// The selected pages in their current order.
  List<PdfPagePlan> get selectedInOrder => [
        for (final p in _pages)
          if (_selected.contains(p.sourcePage)) p,
      ];

  /// Delete is possible: something selected and at least one page would remain.
  bool get canDelete => hasSelection && _selected.length < _pages.length;

  /// Toggles source page [sourcePage].
  void toggle(int sourcePage) {
    if (!_selected.remove(sourcePage)) _selected.add(sourcePage);
    notifyListeners();
  }

  /// Selects every page, or clears the selection when all are selected.
  void toggleAll() {
    if (allSelected) {
      _selected.clear();
    } else {
      _selected
        ..clear()
        ..addAll(_pages.map((p) => p.sourcePage));
    }
    notifyListeners();
  }

  /// Clears the selection.
  void clearSelection() {
    if (_selected.isEmpty) return;
    _selected.clear();
    notifyListeners();
  }

  /// Turns the selected pages (or [only] when given) by [degrees] clockwise.
  void rotate({int degrees = 90, int? only}) {
    final targets = only == null ? _selected : {only};
    if (targets.isEmpty) return;
    _pages = [for (final p in _pages) targets.contains(p.sourcePage) ? p.rotated(degrees) : p];
    notifyListeners();
  }

  /// Removes the selected pages (never the last one); returns how many were removed.
  int deleteSelected() {
    if (!canDelete) return 0;
    final before = _pages.length;
    _pages = [
      for (final p in _pages)
        if (!_selected.contains(p.sourcePage)) p,
    ];
    _selected.clear();
    notifyListeners();
    return before - _pages.length;
  }

  /// Moves the page at position [from] to position [to] (positions in the current order).
  void move(int from, int to) {
    if (from == to || from < 0 || from >= _pages.length) return;
    final target = to.clamp(0, _pages.length - 1);
    final next = [..._pages];
    final page = next.removeAt(from);
    next.insert(target, page);
    _pages = next;
    notifyListeners();
  }

  /// The position of source page [sourcePage], or -1.
  int indexOf(int sourcePage) => _pages.indexWhere((p) => p.sourcePage == sourcePage);

  /// Restores the original pages and clears the selection.
  void reset() {
    _pages = identityPlan(pageCount);
    _selected.clear();
    notifyListeners();
  }
}
