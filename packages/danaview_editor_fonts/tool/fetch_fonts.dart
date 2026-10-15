// OWNER: UX-30
//
// Fetches the curated content fonts (ARCH §17.8, D-30) into fonts/<dir>/ and regenerates the
// GENERATED font section of pubspec.yaml and lib/src/bundled_fonts.g.dart from the files present.
//
//   dart run tool/fetch_fonts.dart                 # download missing families, then regenerate
//   dart run tool/fetch_fonts.dart --ref=<commit>  # pin another google/fonts commit
//   dart run tool/fetch_fonts.dart --offline       # only regenerate from what is in fonts/
//
// Downloading third-party files needs the owner's approval (given 2026-10-15, FIX-FONTS-BUNDLE).
// Sources are the google/fonts repository at a pinned commit ([_ref]; OFL-1.1, each family's
// OFL.txt is fetched with it). Paths verified against that commit on 2026-10-15; a 404 stops the
// run without touching pubspec.yaml. Every run rewrites fonts/SOURCES.json (provenance: source
// URL, commit, font version from the name table, byte size and sha256 of every file in fonts/).
// Most families there ship as variable fonts (`Family[wght].ttf`); they are declared at weights
// 400 and 700. Flutter (3.44) sets the wght axis from `TextStyle.fontWeight` for a variable
// face, so w700 renders exactly as `FontVariation('wght', 700)` and no explicit variation is
// needed; danaview_editor/test/panels/text/content_fonts_golden_test.dart checks this (FIX-FONTS-
// BUNDLE, 2026-10-15). Variable files are renamed `-VF` on download (see [localFontName]).
//
// File naming understood by the generator (in fonts/<dir>/):
//   *-Regular.ttf (400), *-Bold.ttf (700), *-Italic.ttf (400 italic), *-BoldItalic.ttf
//   (700 italic), *-VF.ttf (variable, fetched as *[wght].ttf / *[opsz,wght].ttf: 400 and 700),
//   *-Italic-VF.ttf (variable italic: 400 and 700 italic). OFL.txt is declared as an asset.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// The google/fonts commit the files are fetched from (main on 2026-10-14).
const String _ref = '67bc647ce1910e92f461bcc82aae30f21d21a9cc';

String _base(String ref) => 'https://raw.githubusercontent.com/google/fonts/$ref/ofl';

/// dir (below fonts/) -> (family, files to fetch from google/fonts `ofl/<dir>/`).
const Map<String, (String, List<String>)> _manifest = {
  'figtree': ('Figtree', []), // bundled from danaview_ui_kit (same OFL files)
  'inter': ('Inter', ['Inter[opsz,wght].ttf', 'Inter-Italic[opsz,wght].ttf']),
  'montserrat': ('Montserrat', ['Montserrat[wght].ttf', 'Montserrat-Italic[wght].ttf']),
  'oswald': ('Oswald', ['Oswald[wght].ttf']),
  'bebasneue': ('Bebas Neue', ['BebasNeue-Regular.ttf']),
  'playfairdisplay': ('Playfair Display', ['PlayfairDisplay[wght].ttf', 'PlayfairDisplay-Italic[wght].ttf']),
  'lora': ('Lora', ['Lora[wght].ttf', 'Lora-Italic[wght].ttf']),
  'caveat': ('Caveat', ['Caveat[wght].ttf']),
  'pacifico': ('Pacifico', ['Pacifico-Regular.ttf']),
  'jetbrainsmono': ('JetBrains Mono', ['JetBrainsMono[wght].ttf', 'JetBrainsMono-Italic[wght].ttf']),
};

/// dir -> stable content-font id (lib/src/content_fonts.dart).
const Map<String, String> _ids = {
  'figtree': 'figtree',
  'inter': 'inter',
  'montserrat': 'montserrat',
  'oswald': 'oswald',
  'bebasneue': 'bebas',
  'playfairdisplay': 'playfair',
  'lora': 'lora',
  'caveat': 'caveat',
  'pacifico': 'pacifico',
  'jetbrainsmono': 'jetbrains',
};

Future<void> main(List<String> args) async {
  final root = File.fromUri(Platform.script).parent.parent;
  final offline = args.contains('--offline');
  final refArg = args.where((a) => a.startsWith('--ref=')).map((a) => a.substring(6)).firstOrNull;
  final ref = refArg ?? _ref;
  if (!offline) await _fetch(root, ref);
  final section = generate(root);
  _writePubspec(root, section.pubspec);
  File('${root.path}/lib/src/bundled_fonts.g.dart').writeAsStringSync(section.bundled);
  _writeSources(root, offline ? null : ref);
  stdout.writeln('Bundled: ${section.ids.join(', ')}');
}

Future<void> _fetch(Directory root, String ref) async {
  final client = HttpClient();
  try {
    for (final MapEntry(key: dir, value: (_, files)) in _manifest.entries) {
      if (files.isEmpty) continue;
      final out = Directory('${root.path}/fonts/$dir')..createSync(recursive: true);
      for (final name in [...files, 'OFL.txt']) {
        final target = File('${out.path}/${localFontName(name)}');
        if (target.existsSync()) continue;
        final url = Uri.parse('${_base(ref)}/$dir/${Uri.encodeComponent(name)}');
        final request = await client.getUrl(url);
        final response = await request.close();
        if (response.statusCode != 200) {
          throw HttpException('HTTP ${response.statusCode} for $url', uri: url);
        }
        final bytes = await response.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
        target.writeAsBytesSync(bytes);
        stdout.writeln('fetched $dir/$name -> ${localFontName(name)} (${bytes.length} bytes)');
      }
    }
  } finally {
    client.close();
  }
}

/// The generated pubspec section and bundled-id file for the files present under [root]/fonts.
({String pubspec, String bundled, List<String> ids}) generate(Directory root) {
  final assets = <String>[];
  final fonts = StringBuffer();
  final ids = <String>[];
  for (final MapEntry(key: dir, value: (family, _)) in _manifest.entries) {
    final d = Directory('${root.path}/fonts/$dir');
    if (!d.existsSync()) continue;
    final names = d.listSync().whereType<File>().map((f) => f.uri.pathSegments.last).toList()..sort();
    final styles = <(int, bool, String)>[];
    for (final name in names) {
      if (!name.endsWith('.ttf') && !name.endsWith('.otf')) continue;
      for (final (weight, italic) in _stylesOf(name)) {
        styles.add((weight, italic, name));
      }
    }
    // Regular before italic, light before bold.
    styles.sort((a, b) => a.$2 != b.$2 ? (a.$2 ? 1 : -1) : a.$1.compareTo(b.$1));
    final entries = [
      for (final (weight, italic, name) in styles)
        '        - asset: fonts/$dir/$name\n          weight: $weight${italic ? '\n          style: italic' : ''}',
    ];
    if (entries.isEmpty || !names.contains('OFL.txt')) continue;
    ids.add(_ids[dir]!);
    assets.add('    - fonts/$dir/OFL.txt');
    fonts.writeln('    - family: $family\n      fonts:\n${entries.join('\n')}');
  }
  final pubspec = '  assets:\n${assets.join('\n')}\n  fonts:\n${fonts.toString().trimRight()}';
  final bundled = '// OWNER: UX-30\n'
      '// GENERATED by tool/fetch_fonts.dart from the files in fonts/. Do not edit by hand.\n\n'
      '/// Ids of the content-font families whose files are in this bundle.\n'
      'const Set<String> bundledContentFontIds = {${ids.map((i) => "'$i'").join(', ')}};\n';
  return (pubspec: pubspec, bundled: bundled, ids: ids);
}

/// The bundle's name of a google/fonts file: the axis tag of a variable font becomes `-VF`
/// (`Inter[opsz,wght].ttf` -> `Inter-VF.ttf`), because Flutter's asset keys do not survive
/// `[` `]` `,` in file names (the built asset is stored URL-encoded and then cannot be loaded).
String localFontName(String remote) => remote.replaceAll(RegExp(r'\[[^\]]*\]'), '-VF');

/// (weight, italic) declarations of a font file by its name.
List<(int, bool)> _stylesOf(String name) {
  final variable = name.contains('-VF.');
  final italic = name.contains('Italic');
  if (variable) return [(400, italic), (700, italic)];
  if (name.contains('-BoldItalic')) return [(700, true)];
  if (name.contains('-Bold')) return [(700, false)];
  if (name.contains('-Italic')) return [(400, true)];
  if (name.contains('-Regular')) return [(400, false)];
  return const [];
}

void _writePubspec(Directory root, String section) {
  final file = File('${root.path}/pubspec.yaml');
  final text = file.readAsStringSync();
  const begin = '  # BEGIN GENERATED FONTS (tool/fetch_fonts.dart)\n';
  const end = '  # END GENERATED FONTS';
  final a = text.indexOf(begin);
  final b = text.indexOf(end);
  if (a < 0 || b < a) throw StateError('pubspec.yaml has no GENERATED FONTS markers');
  file.writeAsStringSync('${text.substring(0, a + begin.length)}$section\n${text.substring(b)}');
}

/// Rewrites fonts/SOURCES.json: one record per file below fonts/ (provenance of the bundle).
/// Files fetched by an earlier run keep their recorded source and commit; [ref] is the commit of
/// files with no record yet (null on an offline run: they are recorded without a source).
void _writeSources(Directory root, String? ref) {
  final file = File('${root.path}/fonts/SOURCES.json');
  final previous = <String, Map<String, Object?>>{};
  if (file.existsSync()) {
    final old = json.decode(file.readAsStringSync()) as Map<String, Object?>;
    for (final f in (old['files']! as List<Object?>).cast<Map<String, Object?>>()) {
      previous[f['path']! as String] = f;
    }
  }
  final records = <Map<String, Object?>>[];
  for (final MapEntry(key: dir, value: (family, fetched)) in _manifest.entries) {
    final d = Directory('${root.path}/fonts/$dir');
    if (!d.existsSync()) continue;
    final names = d.listSync().whereType<File>().map((f) => f.uri.pathSegments.last).toList()..sort();
    for (final name in names) {
      final bytes = File('${d.path}/$name').readAsBytesSync();
      final path = '$dir/$name';
      final old = previous[path];
      final String? source;
      final String? commit;
      if (fetched.isEmpty) {
        source = 'danaview_ui_kit (same files as the UI font; google/fonts ofl/figtree)';
        commit = null;
      } else if (old != null && old['sha256'] == sha256.convert(bytes).toString()) {
        source = old['source'] as String?;
        commit = old['commit'] as String?;
      } else {
        final remote = [...fetched, 'OFL.txt'].where((r) => localFontName(r) == name).firstOrNull;
        commit = remote == null ? null : ref;
        source = remote == null || ref == null ? null : '${_base(ref)}/$dir/${Uri.encodeComponent(remote)}';
      }
      records.add({
        'path': path,
        'family': family,
        if (source != null) 'source': source,
        if (commit != null) 'commit': commit,
        if (name.endsWith('.ttf') || name.endsWith('.otf')) 'fontVersion': fontVersionOf(bytes),
        'bytes': bytes.length,
        'sha256': sha256.convert(bytes).toString(),
      });
    }
  }
  final total = records.fold<int>(0, (a, r) => a + (r['bytes']! as int));
  const encoder = JsonEncoder.withIndent('  ');
  file.writeAsStringSync('${encoder.convert({
        'licence': 'OFL-1.1 (each family directory holds its OFL.txt)',
        'totalBytes': total,
        'files': records,
      })}\n');
  stdout.writeln('fonts/SOURCES.json: ${records.length} files, $total bytes');
}

/// The version string (name id 5) of a TrueType/OpenType font, or null when it has none.
String? fontVersionOf(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final numTables = data.getUint16(4);
  for (var i = 0; i < numTables; i++) {
    final rec = 12 + 16 * i;
    if (String.fromCharCodes(bytes, rec, rec + 4) != 'name') continue;
    final table = data.getUint32(rec + 8);
    final count = data.getUint16(table + 2);
    final strings = table + data.getUint16(table + 4);
    for (var j = 0; j < count; j++) {
      final r = table + 6 + 12 * j;
      final platform = data.getUint16(r);
      final nameId = data.getUint16(r + 6);
      if (nameId != 5) continue;
      final length = data.getUint16(r + 8);
      final offset = strings + data.getUint16(r + 10);
      if (platform == 3 || platform == 0) {
        return String.fromCharCodes([
          for (var k = 0; k < length; k += 2) data.getUint16(offset + k),
        ]);
      }
      if (platform == 1) return String.fromCharCodes(bytes, offset, offset + length);
    }
  }
  return null;
}
