// OWNER: UX-30
//
// Fetches the curated content fonts (ARCH §17.8, D-30) into fonts/<dir>/ and regenerates the
// GENERATED font section of pubspec.yaml and lib/src/bundled_fonts.g.dart from the files present.
//
//   dart run tool/fetch_fonts.dart            # download missing families, then regenerate
//   dart run tool/fetch_fonts.dart --offline  # only regenerate from what is in fonts/
//
// Downloading third-party files needs the owner's approval: run it yourself (not from an agent).
// Sources are the google/fonts repository (OFL-1.1, each family's OFL.txt is fetched with it).
// [VERIFY] the paths below against https://github.com/google/fonts before running; a 404 stops
// the run without touching pubspec.yaml. Most families there ship as variable fonts
// (`Family[wght].ttf`); they are declared at weights 400 and 700, which needs Flutter to apply
// the wght axis for bold (check bold text renders bold in the font golden test,
// danaview_editor/test/panels/text/content_fonts_golden_test.dart, after fetching).
//
// File naming understood by the generator (in fonts/<dir>/):
//   *-Regular.ttf (400), *-Bold.ttf (700), *-Italic.ttf (400 italic), *-BoldItalic.ttf
//   (700 italic), *[wght].ttf / *[opsz,wght].ttf (variable: 400 and 700), *-Italic[...].ttf
//   (variable italic: 400 and 700 italic). OFL.txt is declared as an asset.

import 'dart:io';

const String _base = 'https://raw.githubusercontent.com/google/fonts/main/ofl';

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
  if (!offline) await _fetch(root);
  final section = generate(root);
  _writePubspec(root, section.pubspec);
  File('${root.path}/lib/src/bundled_fonts.g.dart').writeAsStringSync(section.bundled);
  stdout.writeln('Bundled: ${section.ids.join(', ')}');
}

Future<void> _fetch(Directory root) async {
  final client = HttpClient();
  try {
    for (final MapEntry(key: dir, value: (_, files)) in _manifest.entries) {
      if (files.isEmpty) continue;
      final out = Directory('${root.path}/fonts/$dir')..createSync(recursive: true);
      for (final name in [...files, 'OFL.txt']) {
        final target = File('${out.path}/$name');
        if (target.existsSync()) continue;
        final url = Uri.parse('$_base/$dir/${Uri.encodeComponent(name)}');
        final request = await client.getUrl(url);
        final response = await request.close();
        if (response.statusCode != 200) {
          throw HttpException('HTTP ${response.statusCode} for $url', uri: url);
        }
        final bytes = await response.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
        target.writeAsBytesSync(bytes);
        stdout.writeln('fetched $dir/$name (${bytes.length} bytes)');
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

/// (weight, italic) declarations of a font file by its name.
List<(int, bool)> _stylesOf(String name) {
  final variable = name.contains('[');
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
