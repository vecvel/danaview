// OWNER: HOM-30
//
// The state of one sign session in the PDF viewer (HOM plan §8.5 "place and resize it on a page"):
// the chosen saved signature, the signatures placed on the pages (image stamps in page space) with
// undo / redo (a history of immutable lists, capped), and the selected one. Placing centres the
// signature on the tapped point at a size that suits the page, kept inside the page and upright as
// the page is shown (on a page turned 90° or 270° the stamp's rect is its footprint in page space and
// its image is turned back by the page's rotation); moving and resizing replace a stamp (one undo
// step each). The native viewer only previews what this model
// holds; nothing is written until Save. Nothing here logs a path (rule 30).

import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'package:danaview_pdf/danaview_pdf.dart';
import 'package:flutter/foundation.dart';

import '../../signatures/signature_store.dart';

/// The sign session of one PDF.
class PdfSignModel extends ChangeNotifier {
  /// An empty session.
  PdfSignModel();

  /// Undo keeps at most this many steps.
  static const int historyLimit = 200;

  /// A placed signature is at most this wide (points) …
  static const double maxPlacedWidth = 180;

  /// … and at most this share of the page's width.
  static const double maxPageShare = 0.4;

  /// … and at most this tall (points).
  static const double maxPlacedHeight = 90;

  final List<List<PdfAnnotateItem>> _history = [const []];
  int _index = 0;
  String? _selectedId;
  SavedSignature? _signature;
  int _nextId = 0;

  /// The signature the next tap places, or null.
  SavedSignature? get signature => _signature;

  set signature(SavedSignature? value) {
    if (value == _signature) return;
    _signature = value;
    notifyListeners();
  }

  /// The placed signatures, oldest first.
  List<PdfAnnotateItem> get items => _history[_index];

  /// The placed stamps, oldest first.
  List<PdfStamp> get stamps => [for (final i in items) i.stamp!];

  /// Something is placed (to save, or to lose).
  bool get isDirty => items.isNotEmpty;

  /// Undo is possible.
  bool get canUndo => _index > 0;

  /// Redo is possible.
  bool get canRedo => _index < _history.length - 1;

  /// The selected stamp's id, or null.
  String? get selectedId => _selectedId;

  /// The pages that carry a signature, in order.
  List<int> get signedPages => (items.map((i) => i.pageIndex).toSet().toList())..sort();

  /// Image paths in use by placed (or undoable) stamps.
  Set<String> get pathsInUse => {
        for (final step in _history)
          for (final i in step) i.stamp!.imagePath,
      };

  PdfAnnotateItem? _byId(String id) {
    for (final i in items) {
      if (i.id == id) return i;
    }
    return null;
  }

  /// The stamp of item [id], or null.
  PdfStamp? stampOf(String id) => _byId(id)?.stamp;

  void _commit(List<PdfAnnotateItem> next) {
    _history.removeRange(_index + 1, _history.length);
    _history.add(List.unmodifiable(next));
    if (_history.length > historyLimit + 1) _history.removeAt(0);
    _index = _history.length - 1;
    if (_selectedId != null && _byId(_selectedId!) == null) _selectedId = null;
    notifyListeners();
  }

  /// The rect (page space) of [signature] placed upright and centred on [point] of [page].
  static PdfRect placedRect(SavedSignature signature, Offset point, PdfPageSize page) {
    final aspect = signature.aspectRatio;
    // The size as seen on screen, from the page as it is shown.
    var w = math.min(maxPlacedWidth, page.displayWidth * maxPageShare);
    var h = w / aspect;
    if (h > maxPlacedHeight) {
      h = maxPlacedHeight;
      w = h * aspect;
    }
    // Its footprint in (unrotated) page space.
    final quarter = page.rotation % 180 != 0;
    final pw = math.min(quarter ? h : w, page.width);
    final ph = math.min(quarter ? w : h, page.height);
    final x = (point.dx - pw / 2).clamp(0.0, math.max(0.0, page.width - pw)).toDouble();
    final y = (point.dy - ph / 2).clamp(0.0, math.max(0.0, page.height - ph)).toDouble();
    return PdfRect(x, y, pw, ph);
  }

  /// The image turn (clockwise) that shows a stamp upright on [page].
  static double uprightRotation(PdfPageSize page) => ((360 - page.rotation % 360) % 360).toDouble();

  /// Places the chosen signature upright and centred on [point] of page [pageIndex] ([page]) and
  /// selects it; one undo step. Returns its id, or null without a signature.
  String? place(int pageIndex, Offset point, PdfPageSize page) {
    final signature = _signature;
    if (signature == null) return null;
    final item = PdfAnnotateItem.stamp(
      's${++_nextId}',
      PdfStamp(
        pageIndex: pageIndex,
        rect: placedRect(signature, point, page),
        imagePath: signature.path,
        rotationDegrees: uprightRotation(page),
      ),
    );
    _selectedId = item.id;
    _commit([...items, item]);
    return item.id;
  }

  /// Moves or resizes stamp [id] to [rect] (one undo step); false when it isn't there or nothing
  /// changed.
  bool move(String id, PdfRect rect) {
    final current = _byId(id)?.stamp;
    if (current == null || rect.width <= 0 || rect.height <= 0) return false;
    if (current.rect.x == rect.x && current.rect.y == rect.y && current.rect.width == rect.width && current.rect.height == rect.height) return false;
    _commit([for (final i in items) i.id == id ? PdfAnnotateItem.stamp(id, current.withRect(rect)) : i]);
    return true;
  }

  /// Removes stamp [id] (one undo step); false when it isn't there.
  bool remove(String id) {
    if (_byId(id) == null) return false;
    _commit([
      for (final i in items)
        if (i.id != id) i,
    ]);
    return true;
  }

  /// Selects stamp [id] (null or an unknown id deselects).
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
