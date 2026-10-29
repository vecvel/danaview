// OWNER: HOM-30
//
// Fakes for the signature and sign widget tests: an in-memory signature store (the same rules as
// the file store: newest first, at most 10, PNGs only, listeners on change), the bytes of a PNG
// header of a given size, and an image maker that records what it was asked and answers at once.

import 'dart:typed_data';
import 'dart:ui' show Color, Offset, Size;

import 'package:danaview_documents/danaview_documents.dart';

/// The first 33 bytes of a PNG of [width] × [height] (enough for the store's checks).
Uint8List fakePng(int width, int height) {
  final b = Uint8List(33);
  b.setAll(0, const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]);
  final d = ByteData.sublistView(b);
  d.setUint32(16, width);
  d.setUint32(20, height);
  return b;
}

/// An in-memory [SignatureStore].
final class MemorySignatureStore extends SignatureStore {
  /// A store holding [count] signatures (300 × 100 px, drawn), oldest first in the ids.
  MemorySignatureStore({int count = 0}) {
    for (var i = 0; i < count; i++) {
      _items.insert(0, _make(SignatureKind.drawn, 300, 100));
    }
  }

  final List<SavedSignature> _items = [];
  int _next = 0;

  /// Calls of [deleteAll].
  int deleteAlls = 0;

  SavedSignature _make(SignatureKind kind, int w, int h) {
    final n = ++_next;
    return SavedSignature(
      id: 'sig-$n-${kind.name}',
      path: '/support/signatures/sig-$n-${kind.name}.png',
      kind: kind,
      createdAt: DateTime.utc(2026, 10, 30, 12, n),
      width: w,
      height: h,
    );
  }

  @override
  Future<List<SavedSignature>> list() async => List.of(_items);

  @override
  Future<SavedSignature> add(Uint8List png, {required SignatureKind kind}) async {
    if (!SignatureStore.isPng(png)) throw ArgumentError('not a PNG');
    if (_items.length >= SignatureStore.maxCount) throw const SignatureStoreFullException();
    final (w, h) = SignatureStore.pngSize(png);
    final s = _make(kind, w, h);
    _items.insert(0, s);
    notifyListeners();
    return s;
  }

  @override
  Future<void> delete(String id) async {
    final before = _items.length;
    _items.removeWhere((s) => s.id == id);
    if (_items.length != before) notifyListeners();
  }

  @override
  Future<void> deleteAll() async {
    deleteAlls++;
    _items.clear();
    notifyListeners();
  }
}

/// Records what it makes and answers [fakePng]s at once.
final class FakeSignatureImageMaker extends SignatureImageMaker {
  /// A maker.
  FakeSignatureImageMaker();

  /// (strokes, pad size, ink) per drawn call.
  final List<(List<List<Offset>>, Size, Color)> drawnCalls = [];

  /// (name, font, ink) per typed call.
  final List<(String, SignatureFont, Color)> typedCalls = [];

  /// Photo calls.
  int photoCalls = 0;

  /// What the next photo gives.
  SignaturePhotoProblem? photoProblem;

  @override
  Future<Uint8List?> drawn(List<List<Offset>> strokes, Size padSize, Color color) async {
    drawnCalls.add((strokes, padSize, color));
    return fakePng(600, 200);
  }

  @override
  Future<Uint8List?> typed(String name, SignatureFont font, Color color) async {
    typedCalls.add((name, font, color));
    return fakePng(500, 125);
  }

  @override
  Future<({Uint8List? png, SignaturePhotoProblem? problem})> photo(Uint8List bytes) async {
    photoCalls++;
    final p = photoProblem;
    return p == null ? (png: fakePng(400, 100), problem: null) : (png: null, problem: p);
  }
}
