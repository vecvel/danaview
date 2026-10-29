// OWNER: HOM-29
//
// The state of one annotate session in the PDF viewer (HOM plan §8.5): the tool, its colours and
// pen width, the session's annotations with undo / redo (a history of immutable lists, capped), and
// the selected item. The native viewer only previews what this model holds; nothing is written
// until Save. Nothing here logs annotation text (rule 30).

import 'package:danaview_pdf/danaview_pdf.dart';
import 'package:flutter/foundation.dart';

/// What a touch does while annotating.
enum PdfAnnotateTool {
  /// Scroll and select text (then Highlight, Underline or Strike through); a tap selects a mark.
  select,

  /// Freehand ink.
  pen,

  /// A tap places a text box.
  text,

  /// A tap removes a mark.
  eraser,
}

/// The annotate session of one PDF.
class PdfAnnotateModel extends ChangeNotifier {
  /// An empty session.
  PdfAnnotateModel();

  /// Markup colours (highlight, underline, strike-through): yellow, green, blue, pink, red, black.
  static const List<int> markupColors = [0xFFFFD60A, 0xFF34C759, 0xFF5AC8FA, 0xFFFF6FB5, 0xFFE53935, 0xFF1C1C1E];

  /// Pen and text colours: black, red, blue, green.
  static const List<int> inkColors = [0xFF1C1C1E, 0xFFE53935, 0xFF1E6FE5, 0xFF2E9E44];

  /// Pen widths in points: fine, medium, bold.
  static const List<double> penWidths = [1.5, 3, 6];

  /// Undo keeps at most this many steps.
  static const int historyLimit = 200;

  PdfAnnotateTool _tool = PdfAnnotateTool.select;
  int _markupColor = markupColors.first;
  int _penColor = inkColors[1];
  double _penWidth = penWidths[1];
  int _textColor = inkColors.first;
  final List<List<PdfAnnotateItem>> _history = [const []];
  int _index = 0;
  String? _selectedId;
  int _nextId = 0;

  /// The current tool.
  PdfAnnotateTool get tool => _tool;

  set tool(PdfAnnotateTool value) {
    if (value == _tool) return;
    _tool = value;
    if (value == PdfAnnotateTool.pen) _selectedId = null;
    notifyListeners();
  }

  /// The colour of the next highlight, underline or strike-through.
  int get markupColor => _markupColor;

  set markupColor(int value) => _set(() => _markupColor = value, value != _markupColor);

  /// The pen colour.
  int get penColor => _penColor;

  set penColor(int value) => _set(() => _penColor = value, value != _penColor);

  /// The pen width in points.
  double get penWidth => _penWidth;

  set penWidth(double value) => _set(() => _penWidth = value, value != _penWidth);

  /// The colour of new text boxes.
  int get textColor => _textColor;

  set textColor(int value) => _set(() => _textColor = value, value != _textColor);

  void _set(VoidCallback change, bool changed) {
    if (!changed) return;
    change();
    notifyListeners();
  }

  /// The session's items, oldest first.
  List<PdfAnnotateItem> get items => _history[_index];

  /// There is something to save.
  bool get isDirty => items.isNotEmpty;

  /// Undo is possible.
  bool get canUndo => _index > 0;

  /// Redo is possible.
  bool get canRedo => _index < _history.length - 1;

  /// The selected item's id, or null.
  String? get selectedId => _selectedId;

  /// The selected item, or null.
  PdfAnnotateItem? get selected => _selectedId == null ? null : _byId(_selectedId!);

  PdfAnnotateItem? _byId(String id) {
    for (final i in items) {
      if (i.id == id) return i;
    }
    return null;
  }

  /// The annotation of item [id], or null.
  PdfAnnotation? annotationOf(String id) => _byId(id)?.annotation;

  /// The viewer's mode for the current tool.
  PdfAnnotateMode get mode => PdfAnnotateMode(
        input: switch (_tool) {
          PdfAnnotateTool.select => PdfAnnotateInput.select,
          PdfAnnotateTool.pen => PdfAnnotateInput.ink,
          PdfAnnotateTool.text => PdfAnnotateInput.text,
          PdfAnnotateTool.eraser => PdfAnnotateInput.erase,
        },
        inkColorArgb: _penColor,
        inkWidth: _penWidth,
      );

  void _commit(List<PdfAnnotateItem> next) {
    _history.removeRange(_index + 1, _history.length);
    _history.add(List.unmodifiable(next));
    if (_history.length > historyLimit + 1) _history.removeAt(0);
    _index = _history.length - 1;
    if (_selectedId != null && _byId(_selectedId!) == null) _selectedId = null;
    notifyListeners();
  }

  /// Adds [annotation] (one undo step); returns its id.
  String add(PdfAnnotation annotation) => addAll([annotation]).single;

  /// Adds [annotations] as one undo step; returns their ids.
  List<String> addAll(List<PdfAnnotation> annotations) {
    if (annotations.isEmpty) return const [];
    final added = [for (final a in annotations) PdfAnnotateItem.annotation('a${++_nextId}', a)];
    _commit([...items, ...added]);
    return [for (final a in added) a.id];
  }

  /// Removes item [id] (one undo step); false when it isn't there.
  bool remove(String id) {
    if (_byId(id) == null) return false;
    _commit([
      for (final i in items)
        if (i.id != id) i,
    ]);
    return true;
  }

  /// Replaces the annotation of item [id] (one undo step); false when it isn't there.
  bool replace(String id, PdfAnnotation annotation) {
    if (_byId(id) == null) return false;
    _commit([for (final i in items) i.id == id ? PdfAnnotateItem.annotation(id, annotation) : i]);
    return true;
  }

  /// Selects item [id] (null deselects; an unknown id deselects too).
  void select(String? id) {
    final next = id != null && _byId(id) != null ? id : null;
    if (next == _selectedId) return;
    _selectedId = next;
    notifyListeners();
  }

  /// Steps back.
  void undo() {
    if (!canUndo) return;
    _index--;
    _dropStaleSelection();
    notifyListeners();
  }

  /// Steps forward again.
  void redo() {
    if (!canRedo) return;
    _index++;
    _dropStaleSelection();
    notifyListeners();
  }

  void _dropStaleSelection() {
    if (_selectedId != null && _byId(_selectedId!) == null) _selectedId = null;
  }
}
