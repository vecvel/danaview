import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor/src/editor/layout/editor_layout.dart';

void main() {
  test('probe', () {
    for (final (s, pad, kb, scale, open) in [
      (const Size(280, 500), EdgeInsets.zero, 0.0, 1.35, false),
      (const Size(280, 500), EdgeInsets.zero, 200.0, 1.35, false),
      (const Size(280, 500), EdgeInsets.zero, 200.0, 1.35, true),
      (const Size(280, 500), const EdgeInsets.only(top: 24), 0.0, 1.35, true),
      (const Size(390, 844), const EdgeInsets.only(top: 47, bottom: 34), 0.0, 1.0, false),
      (const Size(390, 844), const EdgeInsets.only(top: 47, bottom: 34), 0.0, 1.0, true),
      (const Size(390, 844), const EdgeInsets.only(top: 47, bottom: 34), 338.0, 1.0, true),
      (const Size(568, 320), EdgeInsets.zero, 0.0, 1.35, false),
      (const Size(568, 320), EdgeInsets.zero, 128.0, 1.35, true),
      (const Size(844, 390), const EdgeInsets.fromLTRB(47, 0, 47, 21), 0.0, 1.0, false),
      (const Size(834, 1194), EdgeInsets.zero, 0.0, 1.0, false),
      (const Size(1280, 800), EdgeInsets.zero, 0.0, 0.85, false),
      (const Size(320, 480), EdgeInsets.zero, 240.0, 1.0, true),
    ]) {
      final spec = EditorLayoutSpec.resolve(size: s, padding: pad, viewInsets: EdgeInsets.only(bottom: kb), textScaler: TextScaler.linear(scale), touch: true, inspectorOpen: open);
      // ignore: avoid_print
      print('$s kb$kb @$scale open=$open -> $spec');
    }
  });
}
