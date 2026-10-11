// OWNER: UX-01
//
// Source scanning helpers for danaview_editor's architecture tests (ARCH §1.3, §4.2 rules 7 and 8).
// Comments and string literals are blanked before matching (interpolated `${…}` code is kept), so
// names in docs or copy never count; names are matched as whole identifiers, so kit wrappers such as
// `DanaviewTextField` pass. The pubspec reader handles the block-style YAML subset pub manifests use.

import 'dart:io';

/// ARCH §1.3 rule 1: Material chrome editor surfaces must not use (whole identifiers).
const forbiddenMaterialNames = <String>[
  'AlertDialog', 'Slider', 'RangeSlider', 'ListTile', 'ExpansionTile', 'showDatePicker', //
  'LinearProgressIndicator', 'CircularProgressIndicator', 'Switch', 'Checkbox', 'PopupMenuButton',
  'showMenu', 'MenuAnchor', 'DropdownButton', 'DropdownMenu', 'showModalBottomSheet', 'showDialog',
  'Dialog', 'SimpleDialog', 'SnackBar', 'LicensePage', 'TextField', 'TextFormField',
  'ElevatedButton', 'TextButton', 'OutlinedButton', 'FilledButton', 'IconButton',
  'FloatingActionButton', 'Chip', 'ChoiceChip', 'FilterChip', 'TabBar', 'ReorderableListView',
  'Card',
];

/// The only file allowed to call `UserConsent.accepted(` (ARCH §4.2 rule 8).
const consentCallSite = 'packages/danaview_editor/lib/src/editor/flows/captions/model_consent_view.dart';

/// The file declaring `UserConsent.accepted` (its constructor declaration is not a call).
const consentDeclaration = 'packages/danaview_transcription/lib/src/contracts/consent.dart';

/// `danaview_features` libraries danaview_editor may import (ARCH §4.2 rule 7).
const featureEntryPoints = {
  'package:danaview_features/chrome.dart',
  'package:danaview_features/orientation.dart',
  'package:danaview_features/storage.dart',
};

/// The `danaview_*` packages danaview_editor depends on (BUILD_PLAN UX-01).
const allowedDanaviewDependencies = {
  'danaview_editor_core',
  'danaview_editor_engine_api',
  'danaview_transcription',
  'danaview_editor_fonts',
  'danaview_ui_kit',
  'danaview_data',
  'danaview_platform',
  'danaview_domain',
  'danaview_features',
};

/// Packages danaview_editor must never depend on or import: the engine plugin (rule 7) and the router
/// (screens take navigation callbacks).
const forbiddenPackages = {'danaview_editor_engine', 'go_router'};

/// One rule violation.
class Violation {
  /// Creates a violation.
  const Violation(this.rule, this.location, this.message);

  /// Rule id (`M`, `7`, `8`).
  final String rule;

  /// `path:line` or a manifest path.
  final String location;

  /// What is wrong.
  final String message;

  @override
  String toString() => 'rule $rule: $location: $message';
}

/// Forbidden Material names used in [source] (rule `M`).
List<Violation> materialViolations(String path, String source) {
  final pattern = RegExp('(?<![A-Za-z0-9_\$])(${forbiddenMaterialNames.join('|')})(?![A-Za-z0-9_\$])');
  final code = blankNonCode(source, blankStrings: true);
  return [
    for (final m in pattern.allMatches(code))
      Violation('M', '$path:${_lineOf(code, m.start)}', 'Material chrome `${m[1]}` (ARCH §1.3); use the Danaview kit component'),
  ];
}

/// `UserConsent.accepted` uses in [source] outside the consent view (rule 8).
List<Violation> consentViolations(String path, String source) {
  if (path == consentCallSite || path == consentDeclaration) return const [];
  final pattern = RegExp(r'(?<![A-Za-z0-9_$])UserConsent\s*\.\s*accepted(?![A-Za-z0-9_$])');
  final code = blankNonCode(source, blankStrings: true);
  return [
    for (final m in pattern.allMatches(code))
      Violation('8', '$path:${_lineOf(code, m.start)}', 'UserConsent.accepted( may be called only in $consentCallSite'),
  ];
}

/// Import/export violations of rule 7 in a danaview_editor Dart file.
List<Violation> importViolations(String path, String source) {
  final out = <Violation>[];
  for (final uri in directiveUris(source)) {
    final pkg = packageOf(uri);
    if (pkg == null) continue;
    if (forbiddenPackages.contains(pkg)) {
      out.add(Violation('7', path, 'imports `$uri`: danaview_editor never uses $pkg (engine API only, no router)'));
    } else if (pkg == 'danaview_features' && !featureEntryPoints.contains(uri)) {
      out.add(Violation('7', path, 'imports `$uri`: use ${featureEntryPoints.join(', ')}'));
    } else if (pkg.startsWith('danaview_') && pkg != 'danaview_editor' && !allowedDanaviewDependencies.contains(pkg)) {
      out.add(Violation('7', path, 'imports `$uri`: $pkg is not a dependency of danaview_editor'));
    }
  }
  return out;
}

/// Manifest violations of rule 7 in danaview_editor's pubspec.
List<Violation> pubspecViolations(String path, String yaml) {
  final out = <Violation>[];
  final sections = readPubspecSections(yaml);
  sections.forEach((section, deps) {
    for (final dep in deps) {
      if (forbiddenPackages.contains(dep)) {
        out.add(Violation('7', path, '$section lists `$dep`: danaview_editor never depends on it'));
      } else if (dep.startsWith('danaview_') && dep != 'danaview_editor' && !allowedDanaviewDependencies.contains(dep)) {
        out.add(Violation('7', path, '$section lists `$dep`: not one of ${allowedDanaviewDependencies.join(', ')}'));
      }
    }
  });
  return out;
}

/// Dependency names per section (`dependencies`, `dev_dependencies`, `dependency_overrides`).
Map<String, Set<String>> readPubspecSections(String yaml) {
  const sections = {'dependencies', 'dev_dependencies', 'dependency_overrides'};
  final out = {for (final s in sections) s: <String>{}};
  String? current;
  for (final raw in yaml.split('\n')) {
    final line = raw.replaceFirst(RegExp(r'\s+#.*$'), '').trimRight();
    if (line.trim().isEmpty || line.trimLeft().startsWith('#')) continue;
    final top = RegExp(r'^([A-Za-z_][\w-]*):').firstMatch(line);
    if (top != null) {
      current = sections.contains(top[1]) ? top[1] : null;
      continue;
    }
    final entry = RegExp(r'^  ([A-Za-z_][\w]*):').firstMatch(line);
    if (current != null && entry != null) out[current]!.add(entry[1]!);
  }
  return out;
}

/// The package named by a `package:` URI, else null.
String? packageOf(String uri) {
  if (!uri.startsWith('package:')) return null;
  final rest = uri.substring('package:'.length);
  final slash = rest.indexOf('/');
  return slash < 0 ? rest : rest.substring(0, slash);
}

/// The URIs of the `import` and `export` directives of [source] (incl. conditional imports).
List<String> directiveUris(String source) {
  final code = blankNonCode(source, blankStrings: false);
  final uris = <String>[];
  final directive = RegExp(r'''(?:^|;|\n)\s*(?:import|export)\s+((?:['"][^'"]*['"]\s*(?:if\s*\([^)]*\)\s*)?)+)''');
  final quoted = RegExp(r'''['"]([^'"]*)['"]''');
  for (final m in directive.allMatches(code)) {
    for (final q in quoted.allMatches(m[1]!)) {
      uris.add(q[1]!);
    }
  }
  return uris;
}

/// The repository root above the working directory (`flutter test` runs in the package).
Directory findRepoRoot() {
  var dir = Directory.current.absolute;
  while (true) {
    if (File('${dir.path}/docs/editor/BUILD_PLAN.md').existsSync() && Directory('${dir.path}/packages').existsSync()) return dir;
    final parent = dir.parent;
    if (parent.path == dir.path) throw StateError('repository root not found above ${Directory.current.path}');
    dir = parent;
  }
}

/// Dart files below [dir] (recursive), skipping build output and hidden directories, as
/// repo-relative paths with `/` separators.
List<String> dartFilesUnder(Directory root, String relativeDir, {String suffix = '.dart'}) {
  final dir = Directory('${root.path}/$relativeDir');
  if (!dir.existsSync()) return const [];
  final out = <String>[];
  for (final entity in dir.listSync(recursive: true, followLinks: false)) {
    if (entity is! File || !entity.path.endsWith(suffix)) continue;
    final rel = entity.path.substring(root.path.length + 1).replaceAll(Platform.pathSeparator, '/');
    if (rel.split('/').any((part) => part.startsWith('.') || part == 'build' || part == 'third_party')) continue;
    out.add(rel);
  }
  out.sort();
  return out;
}

int _lineOf(String code, int offset) => '\n'.allMatches(code.substring(0, offset)).length + 1;

/// Returns [source] with comments replaced by spaces and, when [blankStrings], the contents of
/// string literals too (interpolated `${…}` code is kept). Offsets and newlines are preserved.
String blankNonCode(String source, {required bool blankStrings}) => _Blanker(source, blankStrings).run();

class _Blanker {
  _Blanker(this.s, this.blankStrings) : out = List<int>.of(s.codeUnits);

  final String s;
  final bool blankStrings;
  final List<int> out;
  int i = 0;

  static final _identChar = RegExp(r'[A-Za-z0-9_$]');

  String run() {
    _code(inInterpolation: false);
    return String.fromCharCodes(out);
  }

  void _blank(int from, int to) {
    for (var k = from; k < to && k < out.length; k++) {
      if (out[k] != 0x0A) out[k] = 0x20;
    }
  }

  bool _at(String token) => s.startsWith(token, i);

  void _code({required bool inInterpolation}) {
    var depth = 0;
    while (i < s.length) {
      final c = s[i];
      if (_at('//')) {
        final start = i;
        while (i < s.length && s[i] != '\n') {
          i++;
        }
        _blank(start, i);
      } else if (_at('/*')) {
        final start = i;
        var nesting = 0;
        while (i < s.length) {
          if (_at('/*')) {
            nesting++;
            i += 2;
          } else if (_at('*/')) {
            nesting--;
            i += 2;
            if (nesting == 0) break;
          } else {
            i++;
          }
        }
        _blank(start, i);
      } else if (c == "'" || c == '"') {
        _string(raw: false);
      } else if ((c == 'r' || c == 'R') &&
          i + 1 < s.length &&
          (s[i + 1] == "'" || s[i + 1] == '"') &&
          (i == 0 || !_identChar.hasMatch(s[i - 1]))) {
        i++;
        _string(raw: true);
      } else if (c == '{') {
        depth++;
        i++;
      } else if (c == '}') {
        if (inInterpolation && depth == 0) return;
        depth--;
        i++;
      } else {
        i++;
      }
    }
  }

  void _string({required bool raw}) {
    final q = s[i];
    final triple = s.startsWith('$q$q$q', i);
    final delimiter = triple ? '$q$q$q' : q;
    i += delimiter.length;
    var segment = i;
    while (i < s.length) {
      if (!raw && s[i] == r'\') {
        i += 2;
      } else if (_at(delimiter)) {
        if (blankStrings) _blank(segment, i);
        i += delimiter.length;
        return;
      } else if (!triple && s[i] == '\n') {
        break;
      } else if (!raw && _at(r'${')) {
        if (blankStrings) _blank(segment, i);
        i += 2;
        _code(inInterpolation: true);
        i++;
        segment = i;
      } else {
        i++;
      }
    }
    if (blankStrings) _blank(segment, i);
  }
}
