// OWNER: UX-24
//
// tool/gen_looks.dart (ARCH §10.2): the 12 built-in looks are deterministic `.vlut` v1 files. The
// committed assets equal a fresh generation byte for byte (no diff), every table parses as a 33^3
// float16 LUT, each look does what its name says, and the ids agree between the tool, the Filters
// catalog, the asset folder and the bundled-look extractor.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/panels/filters_panel.dart';
import 'package:danaview_editor/src/editor/state/default_plan_compiler.dart' show BundledLookFiles, vlutTableSizeOf;
import 'package:danaview_editor_core/formats.dart';
import 'package:danaview_editor_core/store.dart' show StoreRoots;

import '../../../tool/gen_looks.dart';
import 'filters_support.dart';

Directory get assets => Directory('assets/looks');

/// The look function through the committed bytes: the entry nearest to [c] (the lattice has 33 nodes).
(double, double, double) sample(VlutTable table, Float32List floats, (double, double, double) c) {
  final n = table.size;
  int idx(double v) => (v * (n - 1)).round();
  final o = ((idx(c.$3) * n + idx(c.$2)) * n + idx(c.$1)) * 3;
  return (floats[o], floats[o + 1], floats[o + 2]);
}

void main() {
  final looks = generateLooks();

  test('twelve looks with lower-case ids the extractor accepts, in carousel order', () {
    expect(lookIds, hasLength(12));
    expect(lookIds.toSet(), hasLength(12));
    expect(looks.keys, orderedEquals(lookIds));
    for (final id in lookIds) {
      expect(RegExp(r'^[a-z0-9_-]{1,64}$').hasMatch(id), isTrue, reason: id);
    }
    expect(BuiltinLooks.all.map((l) => l.id), orderedEquals(lookIds), reason: 'the Filters catalog and the tool agree');
    expect(lookIds.first, 'teal_orange');
  });

  test('generation is reproducible: twice gives identical bytes', () {
    final again = generateLooks();
    for (final id in lookIds) {
      expect(again[id], orderedEquals(looks[id]!), reason: id);
    }
  });

  test('the committed assets equal a fresh generation (no diff) and nothing else is in the folder', () {
    final files = assets.listSync().whereType<File>().map((f) => f.uri.pathSegments.last).toSet();
    expect(files, {'README.md', for (final id in lookIds) '$id.vlut'});
    for (final id in lookIds) {
      final committed = File('${assets.path}/$id.vlut').readAsBytesSync();
      expect(committed, orderedEquals(looks[id]!), reason: '$id.vlut is out of date: run dart run tool/gen_looks.dart');
    }
    expect(writeLooks(assets, check: true), isEmpty);
  });

  test('writeLooks writes into another folder, reports differences in check mode and is idempotent', () {
    final dir = Directory.systemTemp.createTempSync('danaview_looks_');
    addTearDown(() => dir.deleteSync(recursive: true));
    expect(writeLooks(dir, check: true), lookIds, reason: 'nothing there yet');
    expect(dir.listSync(), isEmpty, reason: 'check never writes');
    expect(writeLooks(dir), lookIds);
    expect(writeLooks(dir), isEmpty);
    expect(writeLooks(dir, check: true), isEmpty);
    File('${dir.path}/warm.vlut').writeAsBytesSync([1, 2, 3]);
    expect(writeLooks(dir, check: true), ['warm']);
    expect(writeLooks(dir), ['warm']);
    expect(File('${dir.path}/warm.vlut').readAsBytesSync(), orderedEquals(looks['warm']!));
  });

  test('every table is a valid .vlut v1: 33^3 float16 RGB in [0, 1]', () {
    for (final id in lookIds) {
      final bytes = looks[id]!;
      expect(String.fromCharCodes(bytes.sublist(0, 4)), 'VLUT');
      expect(ByteData.sublistView(bytes).getUint16(4, Endian.little), 1);
      expect(vlutTableSizeOf(bytes), lookTableSize, reason: id);
      expect(bytes.length, vlutHeaderBytes + lookTableSize * lookTableSize * lookTableSize * 3 * 2);
      final table = readVlut(bytes);
      expect(table.size, 33);
      final floats = table.toFloats();
      var outside = 0;
      for (final v in floats) {
        if (!(v >= 0 && v <= 1)) outside++;
      }
      expect(outside, 0, reason: '$id has values outside [0, 1]');
    }
  });

  group('each look does what its name says', () {
    final tables = <String, (VlutTable, Float32List)>{};
    (VlutTable, Float32List) load(String id) => tables.putIfAbsent(id, () {
          final t = readVlut(looks[id]!);
          return (t, t.toFloats());
        });
    Float32List table(String id) => load(id).$2;
    (double, double, double) at(String id, (double, double, double) c) => sample(load(id).$1, load(id).$2, c);

    test('mono and noir are grey; noir has more contrast', () {
      for (final id in ['mono', 'noir']) {
        final t = table(id);
        var notGrey = 0;
        for (var i = 0; i < t.length; i += 3) {
          if (t[i] != t[i + 1] || t[i + 1] != t[i + 2]) notGrey++;
        }
        expect(notGrey, 0, reason: id);
      }
      expect(at('mono', (1, 0, 0)).$1, closeTo(0.2126, 0.002));
      final darkM = at('mono', (0.25, 0.25, 0.25)).$1;
      final darkN = at('noir', (0.25, 0.25, 0.25)).$1;
      final lightM = at('mono', (0.75, 0.75, 0.75)).$1;
      final lightN = at('noir', (0.75, 0.75, 0.75)).$1;
      expect(darkN, lessThan(darkM));
      expect(lightN, greaterThan(lightM));
    });

    test('warm and cool shift the white balance in opposite directions', () {
      final w = at('warm', (0.5, 0.5, 0.5));
      final c = at('cool', (0.5, 0.5, 0.5));
      expect(w.$1, greaterThan(w.$3));
      expect(c.$3, greaterThan(c.$1));
    });

    test('sepia is a brown monochrome', () {
      final s = at('sepia', (0.5, 0.5, 0.5));
      expect(s.$1, greaterThan(s.$2));
      expect(s.$2, greaterThan(s.$3));
      final white = at('sepia', (1, 1, 1));
      expect(white.$1, 1);
    });

    test('vivid raises saturation, pastel and fade lower it', () {
      double chroma((double, double, double) c) => [c.$1, c.$2, c.$3].reduce((a, b) => a > b ? a : b) - [c.$1, c.$2, c.$3].reduce((a, b) => a < b ? a : b);
      const input = (0.7, 0.4, 0.3);
      final base = chroma(input);
      expect(chroma(at('vivid', input)), greaterThan(base));
      expect(chroma(at('pastel', input)), lessThan(base));
      expect(chroma(at('fade', input)), lessThan(base));
    });

    test('matte, fade, vintage and pastel lift the blacks; matte and fade also lower the whites', () {
      for (final id in ['matte', 'fade', 'pastel']) {
        final black = at(id, (0, 0, 0));
        expect(black.$1 > 0.04 && black.$2 > 0.04 && black.$3 > 0.04, isTrue, reason: '$id lifts blacks: $black');
      }
      // Vintage lifts red and green and keeps blue low (a yellow cast in the shadows).
      final vintage = at('vintage', (0, 0, 0));
      expect(vintage.$1 > 0.04 && vintage.$2 > 0.04 && vintage.$3 < vintage.$1, isTrue, reason: 'vintage blacks: $vintage');
      for (final id in ['matte', 'fade']) {
        final white = at(id, (1, 1, 1));
        expect(white.$1 < 1 && white.$2 < 1 && white.$3 < 1, isTrue, reason: '$id lowers whites: $white');
      }
    });

    test('teal & orange and cinematic push shadows to teal and highlights to orange', () {
      for (final id in ['teal_orange', 'cinematic']) {
        final shadow = at(id, (0.15, 0.15, 0.15));
        final light = at(id, (0.85, 0.85, 0.85));
        expect(shadow.$3, greaterThan(shadow.$1), reason: '$id shadows');
        expect(light.$1, greaterThan(light.$3), reason: '$id highlights');
      }
    });

    test('lookFunction is the tool\'s source of truth and rejects unknown ids', () {
      expect(lookFunction('mono', (1, 1, 1)), (1.0, 1.0, 1.0));
      expect(() => lookFunction('nope', (0, 0, 0)), throwsArgumentError);
      expect(() => generateLook('nope'), throwsArgumentError);
    });
  });

  test('the bundled-look extractor finds every committed file under the asset key convention', () async {
    final dir = Directory.systemTemp.createTempSync('danaview_looks_cache_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final files = BundledLookFiles(
      roots: StoreRoots(support: '${dir.path}/support', cache: '${dir.path}/cache', documents: '${dir.path}/docs'),
      bundle: LooksBundle(),
    );
    for (final id in lookIds) {
      final lut = await files.resolve(id);
      expect(lut, isNotNull, reason: id);
      expect(lut!.size, 33);
      expect(File.fromUri(Uri.parse(lut.uri)).readAsBytesSync(), orderedEquals(looks[id]!));
    }
    expect(await files.resolve('tealOrange'), isNull, reason: 'camelCase ids are not extractable');
  });

  test('assets/looks/ is declared in the pubspec', () {
    expect(File('pubspec.yaml').readAsStringSync(), contains('    - assets/looks/'));
  });
}
