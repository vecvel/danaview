// OWNER: INT-01
//
// Architecture rules for the editor packages (ARCH §4.2 rules 1–7) and the owner's "no Material
// chrome" rule (ARCH §1.3) for the danaview_features files that editor tickets touch.
//
// * Every `packages/*/pubspec.yaml` is parsed (dependencies, dev_dependencies,
//   dependency_overrides) and every Dart file of the package (excluding build output, hidden
//   directories and nested packages such as `example/`) is scanned for `import`/`export` URIs.
// * A rule whose package does not exist yet is skipped with a notice (danaview_editor arrives with
//   UX-01). Rule 8 (`UserConsent.accepted(`) belongs to UX-01's own architecture test.
// * The Material scan matches the ARCH §1.3 names as whole identifiers in code only (comments and
//   string literals are ignored), so `DanaviewTextField`, `DanaviewIconButton` and other kit wrappers
//   pass. The baseline is empty: these files have zero matches.
// * Every rule is proven to fire by a negative fixture in `test/architecture/fixtures/`. Fixture
//   trees mirror the repo layout with a `.fixture` suffix on every file, so neither the analyzer
//   nor pub treat them as real packages or sources.
//
// No dependency beyond `flutter_test` and `dart:io`: the root pubspec is an integration file, so the
// pubspec reader below handles the block-style YAML subset pub manifests use.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final root = _findRepoRoot();
  final repo = RepoTree(root);

  group('ARCH §4.2 dependency rules hold on this tree', () {
    for (final rule in dependencyRules) {
      final present = repo.hasPackage(rule.package);
      test(
        'rule ${rule.id}: ${rule.summary}',
        () {
          final violations = rule.check(repo);
          expect(violations, isEmpty, reason: _describe(violations));
        },
        skip: present ? false : 'packages/${rule.package} does not exist yet; rule ${rule.id} skipped',
      );
    }
  });

  group('ARCH §1.3 forbidden Material names in editor-touched danaview_features files', () {
    test('every listed file that exists has zero matches (empty baseline)', () {
      final violations = materialRule.check(repo);
      expect(violations, isEmpty, reason: _describe(violations));
    });

    test('the scanned list covers the UX-02, UX-03, UX-04, UX-41 and UX-42 owns lists', () {
      expect(editorTouchedFeatureFiles, hasLength(17));
      expect(editorTouchedFeatureFiles.toSet(), hasLength(17));
      for (final path in editorTouchedFeatureFiles) {
        expect(path, startsWith('packages/danaview_features/lib/'));
        expect(path, endsWith('.dart'));
      }
    });

    test('the scanned list equals every danaview_features Dart file owned in BUILD_PLAN §6', () {
      final plan = repo.readFile('docs/v1.1/editor/BUILD_PLAN.md');
      expect(plan, isNotNull, reason: 'docs/v1.1/editor/BUILD_PLAN.md is missing');
      final owned = featureFilesOwnedInPlan(plan!);
      expect(owned.keys.toSet(), editorTouchedFeatureFiles.toSet());
      expect(owned.values.toSet(), <String>{'UX-02', 'UX-03', 'UX-04', 'UX-41', 'UX-42'});
    });
  });

  group('negative fixtures make each rule fire', () {
    final fixturesDir = Directory('${root.path}/test/architecture/fixtures');
    final onDisk = fixturesDir.existsSync()
        ? (fixturesDir.listSync().whereType<Directory>().map((d) => _baseName(d.path)).toList()..sort())
        : <String>[];

    test('every fixture directory has an expectation and every expectation a directory', () {
      expect(onDisk.toSet(), fixtureExpectations.keys.toSet());
    });

    test('every rule (1–7 and M) has at least one negative fixture', () {
      final covered = fixtureExpectations.values.expand((ids) => ids).toSet();
      expect(covered, containsAll(<String>[...dependencyRules.map((r) => r.id), materialRule.id]));
    });

    for (final entry in fixtureExpectations.entries) {
      test('${entry.key} fires exactly ${entry.value.isEmpty ? 'nothing' : entry.value.join(', ')}', () {
        final fixture = RepoTree(Directory('${fixturesDir.path}/${entry.key}'), suffix: '.fixture');
        final violations = checkAll(fixture);
        final fired = violations.map((v) => v.rule).toSet();
        expect(fired, entry.value, reason: _describe(violations));
        if (entry.value.isNotEmpty) expect(violations, isNotEmpty);
        final count = fixtureViolationCounts[entry.key];
        if (count != null) expect(violations, hasLength(count), reason: _describe(violations));
      });
    }

    test('every counted fixture exists', () {
      expect(fixtureExpectations.keys, containsAll(fixtureViolationCounts.keys));
    });
  });

  group('Dart source reader', () {
    test('blanks comments and, on request, string contents, preserving offsets', () {
      const src = "a /* x /* nested */ y */ b // c\n'Slider \${Card()} \$x' r'\\' \"\"\"Chip\n\"\"\" d";
      final code = blankNonCode(src, blankStrings: true);
      expect(code.length, src.length);
      expect(code.split('\n').length, src.split('\n').length);
      expect(identifiersIn(code), containsAll(<String>['a', 'b', 'Card', 'd']));
      expect(identifiersIn(code), isNot(contains('Slider')));
      expect(identifiersIn(code), isNot(contains('Chip')));
      expect(identifiersIn(code), isNot(contains('nested')));
      expect(identifiersIn(code), isNot(contains('c')));
    });

    test('reads import/export URIs from the directive header only', () {
      const src = '''
#!/usr/bin/env dart
// import 'package:commented/out.dart';
@TestOn('vm')
library;

import 'package:a/a.dart' as a show A;
import 'package:b/b.dart'
    if (dart.library.io) 'package:b_io/b.dart'
    if (dart.library.js_interop) 'package:b_web/b.dart';
export "package:c/c.dart" hide C;
part 'part.dart';

void main() { const s = 'package:not_a_directive/x.dart'; }
import 'package:after_code/x.dart';
''';
      expect(directiveUris(src), <String>[
        'package:a/a.dart',
        'package:b/b.dart',
        'package:b_io/b.dart',
        'package:b_web/b.dart',
        'package:c/c.dart',
      ]);
    });

    test('parses block-style pubspec dependency sections', () {
      const yaml = '''
name: demo # trailing comment
environment:
  sdk: ^3.5.0
dependencies:
  flutter:
    sdk: flutter
  meta: ^1.11.0
  # commented: ^1.0.0
  "quoted_pkg": any
  danaview_editor_core:
    path: ../danaview_editor_core
dev_dependencies:
  test: ^1.25.0
dependency_overrides: {}
flutter:
  uses-material-design: true
''';
      final pubspec = Pubspec.parse(yaml);
      expect(pubspec.name, 'demo');
      expect(pubspec.dependencies, <String>{'flutter', 'meta', 'quoted_pkg', 'danaview_editor_core'});
      expect(pubspec.devDependencies, <String>{'test'});
      expect(pubspec.overrides, isEmpty);
    });
  });
}

// ---------------------------------------------------------------------------------------------
// Rules
// ---------------------------------------------------------------------------------------------

/// Every package of the editor release (ARCH §4.1). danaview_features may depend on none of them.
const editorPackages = <String>{
  'danaview_editor',
  'danaview_editor_core',
  'danaview_editor_engine_api',
  'danaview_editor_engine',
  'danaview_editor_fonts',
  'danaview_transcription',
  'danaview_whisper',
};

/// The danaview_features files an editor ticket owns (BUILD_PLAN §6 owns lists of UX-02, UX-03,
/// UX-04, UX-41 and UX-42). Files that don't exist yet are skipped.
const editorTouchedFeatureFiles = <String>[
  // UX-02
  'packages/danaview_features/lib/src/player/danaview_player_actions.dart',
  'packages/danaview_features/lib/src/player/screen_orientation_policy.dart',
  'packages/danaview_features/lib/orientation.dart',
  // UX-03
  'packages/danaview_features/lib/src/library/danaview_home_screen.dart',
  'packages/danaview_features/lib/chrome.dart',
  // UX-04
  'packages/danaview_features/lib/src/tools/storage_usage.dart',
  'packages/danaview_features/lib/src/tools/danaview_storage_screen.dart',
  'packages/danaview_features/lib/src/more/danaview_settings_screen.dart',
  'packages/danaview_features/lib/storage.dart',
  // UX-41
  'packages/danaview_features/lib/src/player/danaview_controls_overlay.dart',
  'packages/danaview_features/lib/src/player/danaview_player_screen.dart',
  'packages/danaview_features/lib/src/controllers/player_controller.dart',
  'packages/danaview_features/lib/src/settings/danaview_settings_panel.dart',
  // UX-42
  'packages/danaview_features/lib/src/more/legal_texts.dart',
  'packages/danaview_features/lib/src/more/danaview_licenses_screen.dart',
  'packages/danaview_features/lib/src/more/danaview_about_screen.dart',
  'packages/danaview_features/lib/licenses.dart',
];

/// ARCH §1.3 rule 1: Material chrome that editor surfaces must not use (whole identifiers).
const forbiddenMaterialNames = <String>[
  'AlertDialog', 'Slider', 'RangeSlider', 'ListTile', 'ExpansionTile', 'showDatePicker', //
  'LinearProgressIndicator', 'CircularProgressIndicator', 'Switch', 'Checkbox', 'PopupMenuButton',
  'showMenu', 'MenuAnchor', 'DropdownButton', 'DropdownMenu', 'showModalBottomSheet', 'showDialog',
  'Dialog', 'SimpleDialog', 'SnackBar', 'LicensePage', 'TextField', 'TextFormField',
  'ElevatedButton', 'TextButton', 'OutlinedButton', 'FilledButton', 'IconButton',
  'FloatingActionButton', 'Chip', 'ChoiceChip', 'FilterChip', 'TabBar', 'ReorderableListView',
  'Card',
];

/// One entry per directory in `test/architecture/fixtures/` (see its README.md) and the exact set
/// of rule ids the fixture must fire. Empty sets are positive controls: look-alikes that must pass.
const fixtureExpectations = <String, Set<String>>{
  'ok_wrappers_and_barrels': <String>{},
  'm_unlisted_file_not_scanned': <String>{},
  'r1_features_depends_on_editor': {'1'},
  'r1_features_dev_dependency_and_override': {'1'},
  'r1_features_imports_editor': {'1'},
  'r2_core_depends_on_flutter': {'2'},
  'r2_core_imports_danaview_package': {'2'},
  'r2_core_dart_io_outside_store': {'2'},
  'r2_core_imports_dart_ui_and_third_party': {'2'},
  'r3_engine_api_extra_dependency': {'3'},
  'r3_engine_api_imports_plugin': {'3'},
  'r4_engine_depends_on_editor': {'4'},
  'r4_engine_imports_transcription': {'4'},
  'r5_whisper_depends_on_danaview': {'5'},
  'r5_whisper_imports_danaview': {'5'},
  'r6_transcription_depends_on_engine_api': {'6'},
  'r6_transcription_widget_code': {'6'},
  'r6_transcription_widget_class_without_import': {'6'},
  'r7_editor_depends_on_plugin': {'7'},
  'r7_editor_imports_features_internals': {'7'},
  'r7_editor_imports_features_barrel': {'7'},
  'm_features_material_chrome': {'M'},
  'm_features_material_in_interpolation': {'M'},
};

/// Exact violation counts for fixtures where the count itself proves something (every offending
/// line or manifest entry is reported, not just the first one).
const fixtureViolationCounts = <String, int>{
  'r1_features_dev_dependency_and_override': 2,
  'r2_core_depends_on_flutter': 2,
  'r2_core_dart_io_outside_store': 1,
  'r2_core_imports_dart_ui_and_third_party': 2,
  'm_features_material_chrome': 5,
};

/// One rule violation: which rule, where, and what.
class Violation {
  const Violation(this.rule, this.location, this.message);

  final String rule;
  final String location;
  final String message;

  @override
  String toString() => 'rule $rule: $location: $message';
}

/// A dependency rule bound to the package it constrains.
class DependencyRule {
  const DependencyRule(this.id, this.package, this.summary, this._check);

  final String id;
  final String package;
  final String summary;
  final void Function(RepoTree repo, PackageView pkg, void Function(String location, String message) report)
      _check;

  List<Violation> check(RepoTree repo) {
    final pkg = repo.package(package);
    if (pkg == null) return const [];
    final out = <Violation>[];
    _check(repo, pkg, (location, message) => out.add(Violation(id, location, message)));
    return out;
  }
}

/// The Material scan, as a rule with id `M`.
class MaterialRule {
  const MaterialRule();

  String get id => 'M';

  List<Violation> check(RepoTree repo) {
    final pattern = RegExp('(?<![A-Za-z0-9_\$])(${forbiddenMaterialNames.join('|')})(?![A-Za-z0-9_\$])');
    final out = <Violation>[];
    for (final path in editorTouchedFeatureFiles) {
      final source = repo.readFile(path);
      if (source == null) continue;
      final code = blankNonCode(source, blankStrings: true);
      for (final m in pattern.allMatches(code)) {
        final line = '\n'.allMatches(code.substring(0, m.start)).length + 1;
        out.add(Violation(id, '$path:$line', 'Material chrome `${m[1]}` (ARCH §1.3); use the Danaview kit component'));
      }
    }
    return out;
  }
}

const materialRule = MaterialRule();

/// ARCH §4.2 rules 1–7.
final dependencyRules = <DependencyRule>[
  DependencyRule('1', 'danaview_features', 'danaview_features depends on no editor package', (repo, pkg, report) {
    _forbidPackages(pkg, editorPackages, report, why: 'danaview_features must not depend on editor packages');
  }),
  DependencyRule(
    '2',
    'danaview_editor_core',
    'danaview_editor_core is pure Dart (meta, collection, crypto, path, characters; dart:io/isolate only in lib/src/store/)',
    (repo, pkg, report) {
      const allowed = {'meta', 'collection', 'crypto', 'path', 'characters'};
      for (final dep in pkg.pubspec.dependencies) {
        if (!allowed.contains(dep)) {
          report(pkg.pubspecPath, 'dependency `$dep` is not one of ${allowed.join(', ')}');
        }
      }
      for (final dep in {...pkg.pubspec.devDependencies, ...pkg.pubspec.overrides}) {
        if (dep == 'flutter' || dep == 'flutter_test' || (dep.startsWith('danaview_') && dep != pkg.name)) {
          report(pkg.pubspecPath, 'dev dependency `$dep` is not allowed in the pure core package');
        }
      }
      for (final file in pkg.dartFiles) {
        final inLib = file.packagePath.startsWith('lib/');
        final inStore = file.packagePath.startsWith('lib/src/store/');
        for (final uri in file.uris) {
          final p = packageOf(uri);
          if (uri == 'dart:ui' || p == 'flutter' || p == 'flutter_test' || p == 'sky_engine') {
            report(file.repoPath, 'imports `$uri`: no Flutter in danaview_editor_core');
          } else if (p != null && p.startsWith('danaview_') && p != pkg.name) {
            report(file.repoPath, 'imports `$uri`: no danaview_* package in danaview_editor_core');
          } else if (inLib && p != null && p != pkg.name && !allowed.contains(p)) {
            report(file.repoPath, 'imports `$uri`: lib/ may import only ${allowed.join(', ')}');
          } else if (inLib && !inStore && (uri == 'dart:io' || uri == 'dart:isolate')) {
            report(file.repoPath, 'imports `$uri` outside lib/src/store/');
          }
        }
      }
    },
  ),
  DependencyRule(
    '3',
    'danaview_editor_engine_api',
    'danaview_editor_engine_api depends only on flutter, meta, collection, danaview_editor_core',
    (repo, pkg, report) {
      const allowed = {'flutter', 'meta', 'collection', 'danaview_editor_core'};
      const forbidden = {'danaview_editor_engine', 'danaview_editor', 'danaview_transcription', 'danaview_features'};
      for (final dep in pkg.pubspec.dependencies) {
        if (!allowed.contains(dep)) report(pkg.pubspecPath, 'dependency `$dep` is not one of ${allowed.join(', ')}');
      }
      _forbidPackages(pkg, forbidden, report, why: 'the engine API never depends on the plugin, UX, AI or features');
      for (final file in pkg.dartFiles.where((f) => f.packagePath.startsWith('lib/'))) {
        for (final uri in file.uris) {
          final p = packageOf(uri);
          if (p != null && p != pkg.name && !allowed.contains(p) && !forbidden.contains(p)) {
            report(file.repoPath, 'imports `$uri`: lib/ may import only ${allowed.join(', ')}');
          }
        }
      }
    },
  ),
  DependencyRule(
    '4',
    'danaview_editor_engine',
    'danaview_editor_engine depends on danaview_editor_engine_api and danaview_editor_core only (no danaview_editor, features, transcription)',
    (repo, pkg, report) {
      const allowedDanaview = {'danaview_editor_engine_api', 'danaview_editor_core'};
      _forbidPackages(
        pkg,
        null,
        report,
        allowDanaview: allowedDanaview,
        why: 'the plugin depends only on the engine API and core among danaview packages',
      );
    },
  ),
  DependencyRule('5', 'danaview_whisper', 'danaview_whisper depends on no danaview_* package', (repo, pkg, report) {
    _forbidPackages(pkg, null, report, allowDanaview: const {}, why: 'danaview_whisper is standalone');
  }),
  DependencyRule(
    '6',
    'danaview_transcription',
    'danaview_transcription never depends on the engine packages, danaview_editor or danaview_features; no widget code',
    (repo, pkg, report) {
      const forbidden = {'danaview_editor_engine', 'danaview_editor_engine_api', 'danaview_editor', 'danaview_features'};
      _forbidPackages(pkg, forbidden, report, why: 'transcription is independent of the engine and the UI');
      const widgetLibraries = {
        'package:flutter/widgets.dart',
        'package:flutter/material.dart',
        'package:flutter/cupertino.dart',
      };
      final widgetClass = RegExp(
        r'\b(?:extends|with|implements)\s+(?:StatelessWidget|StatefulWidget|InheritedWidget|RenderObjectWidget|State\s*<)',
      );
      for (final file in pkg.dartFiles.where((f) => f.packagePath.startsWith('lib/'))) {
        for (final uri in file.uris.where(widgetLibraries.contains)) {
          report(file.repoPath, 'imports `$uri`: no widget code in danaview_transcription');
        }
        if (widgetClass.hasMatch(blankNonCode(file.source, blankStrings: true))) {
          report(file.repoPath, 'declares a widget: no widget code in danaview_transcription');
        }
      }
    },
  ),
  DependencyRule(
    '7',
    'danaview_editor',
    'danaview_editor never depends on the plugin; danaview_features only via chrome/orientation/storage.dart',
    (repo, pkg, report) {
      _forbidPackages(pkg, {'danaview_editor_engine'}, report, why: 'danaview_editor talks to the engine API only');
      const featureEntryPoints = {
        'package:danaview_features/chrome.dart',
        'package:danaview_features/orientation.dart',
        'package:danaview_features/storage.dart',
      };
      for (final file in pkg.dartFiles) {
        for (final uri in file.uris) {
          if (packageOf(uri) == 'danaview_features' && !featureEntryPoints.contains(uri)) {
            report(file.repoPath, 'imports `$uri`: use ${featureEntryPoints.join(', ')}');
          }
        }
      }
    },
  ),
];

/// Runs every rule (1–7 and M) against [repo].
List<Violation> checkAll(RepoTree repo) => <Violation>[
      for (final rule in dependencyRules) ...rule.check(repo),
      ...materialRule.check(repo),
    ];

/// Reports manifest entries and imports naming a package in [forbidden], or (when [allowDanaview] is
/// given) any `danaview_*` package outside [allowDanaview] and the package itself.
void _forbidPackages(
  PackageView pkg,
  Set<String>? forbidden,
  void Function(String location, String message) report, {
  Set<String>? allowDanaview,
  required String why,
}) {
  bool bad(String name) {
    if (name == pkg.name) return false;
    if (forbidden != null && forbidden.contains(name)) return true;
    if (allowDanaview != null && name.startsWith('danaview_') && !allowDanaview.contains(name)) return true;
    return false;
  }

  final sections = <String, Set<String>>{
    'dependencies': pkg.pubspec.dependencies,
    'dev_dependencies': pkg.pubspec.devDependencies,
    'dependency_overrides': pkg.pubspec.overrides,
  };
  for (final section in sections.entries) {
    for (final dep in section.value.where(bad)) {
      report(pkg.pubspecPath, '${section.key} lists `$dep`: $why');
    }
  }
  for (final file in pkg.dartFiles) {
    for (final uri in file.uris) {
      final p = packageOf(uri);
      if (p != null && bad(p)) report(file.repoPath, 'imports `$uri`: $why');
    }
  }
}

/// Every `packages/danaview_features/lib/**.dart` path listed under a ticket's **Owns** in the build
/// plan, mapped to the owning ticket id (so a new editor ticket that touches danaview_features shows
/// up as a drift in the scanned list).
Map<String, String> featureFilesOwnedInPlan(String plan) {
  final heading = RegExp(r'^#### ([A-Z]+-\d+) ');
  final ownedPath = RegExp(r'^\s+- `(packages/danaview_features/lib/[^`]+\.dart)`');
  final out = <String, String>{};
  String? ticket;
  var inOwns = false;
  for (final line in plan.split('\n')) {
    final h = heading.firstMatch(line);
    if (h != null) {
      ticket = h[1];
      inOwns = false;
      continue;
    }
    if (line.startsWith('- **Owns:**')) {
      inOwns = true;
      continue;
    }
    if (line.startsWith('- **') || line.startsWith('#')) {
      inOwns = false;
      continue;
    }
    final m = ownedPath.firstMatch(line);
    if (inOwns && ticket != null && m != null) out[m[1]!] = ticket;
  }
  return out;
}

/// `package:foo/bar.dart` → `foo`; anything else → null.
String? packageOf(String uri) => RegExp(r'^package:([^/]+)/').firstMatch(uri)?.group(1);

// ---------------------------------------------------------------------------------------------
// Repository view (real tree or a `.fixture` tree)
// ---------------------------------------------------------------------------------------------

/// A read-only view of a repository root: its `packages/*` and arbitrary files. Fixture trees use
/// [suffix] `.fixture` on every file name.
class RepoTree {
  RepoTree(this.root, {this.suffix = ''});

  final Directory root;
  final String suffix;
  final Map<String, PackageView?> _packages = {};

  bool hasPackage(String name) => package(name) != null;

  /// The package at `packages/<name>/` when it has a manifest, else null.
  PackageView? package(String name) => _packages.putIfAbsent(name, () {
        final dir = Directory('${root.path}/packages/$name');
        final manifest = File('${dir.path}/pubspec.yaml$suffix');
        if (!manifest.existsSync()) return null;
        return PackageView._(this, name, dir, Pubspec.parse(manifest.readAsStringSync()));
      });

  /// Contents of the file at repo-relative [path], or null when absent.
  String? readFile(String path) {
    final file = File('${root.path}/$path$suffix');
    return file.existsSync() ? file.readAsStringSync() : null;
  }
}

/// One package: its parsed manifest and its Dart files.
class PackageView {
  PackageView._(this._repo, this.name, this.dir, this.pubspec);

  final RepoTree _repo;
  final String name;
  final Directory dir;
  final Pubspec pubspec;
  List<DartFileView>? _files;

  String get pubspecPath => 'packages/$name/pubspec.yaml';

  /// Directories never scanned: build output, tool caches, native dependency trees, vendored code.
  static const _skippedDirs = {'build', 'Pods', 'ephemeral', 'third_party', 'node_modules'};

  /// Every Dart file of this package, excluding hidden and skipped directories and nested
  /// packages (a directory with its own manifest, e.g. a plugin's `example/`).
  List<DartFileView> get dartFiles => _files ??= () {
        final suffix = _repo.suffix;
        final out = <DartFileView>[];
        void walk(Directory d, String rel) {
          final entries = d.listSync(followLinks: false)..sort((a, b) => a.path.compareTo(b.path));
          for (final e in entries) {
            final base = _baseName(e.path);
            if (e is Directory) {
              if (base.startsWith('.') || _skippedDirs.contains(base)) continue;
              if (File('${e.path}/pubspec.yaml$suffix').existsSync()) continue;
              walk(e, '$rel$base/');
            } else if (e is File && base.endsWith('.dart$suffix')) {
              final relPath = '$rel${base.substring(0, base.length - suffix.length)}';
              out.add(DartFileView('packages/$name/$relPath', relPath, e.readAsStringSync()));
            }
          }
        }

        walk(dir, '');
        return out;
      }();
}

/// One Dart file with its directive URIs.
class DartFileView {
  DartFileView(this.repoPath, this.packagePath, this.source) : uris = directiveUris(source);

  /// Path relative to the repo root, e.g. `packages/danaview_editor_core/lib/model.dart`.
  final String repoPath;

  /// Path relative to the package root, e.g. `lib/model.dart`.
  final String packagePath;
  final String source;
  final List<String> uris;
}

/// The dependency sections of a pub manifest (block-style YAML, as pub writes and the repo uses).
class Pubspec {
  Pubspec._(this.name, this.dependencies, this.devDependencies, this.overrides);

  final String? name;
  final Set<String> dependencies;
  final Set<String> devDependencies;
  final Set<String> overrides;

  static Pubspec parse(String yaml) {
    String? name;
    final sections = <String, Set<String>>{
      'dependencies': <String>{},
      'dev_dependencies': <String>{},
      'dependency_overrides': <String>{},
    };
    Set<String>? current;
    int? childIndent;
    final topKey = RegExp(r'''^(["']?)([A-Za-z_][\w-]*)\1\s*:\s*(.*)$''');
    final childKey = RegExp(r'''^(\s+)(["']?)([A-Za-z_]\w*)\2\s*:''');
    for (final raw in yaml.split('\n')) {
      final line = _stripYamlComment(raw).trimRight();
      if (line.trim().isEmpty) continue;
      if (!line.startsWith(' ') && !line.startsWith('\t')) {
        final m = topKey.firstMatch(line);
        current = null;
        childIndent = null;
        if (m == null) continue;
        final key = m[2]!;
        final value = m[3]!.trim();
        if (key == 'name') name = _unquote(value);
        if (sections.containsKey(key)) {
          current = sections[key];
          if (value.startsWith('{') && value != '{}') {
            // Flow mapping on one line: `dependencies: {a: ^1.0.0, b: any}`.
            for (final part in value.substring(1, value.length - 1).split(',')) {
              final k = part.split(':').first.trim();
              if (k.isNotEmpty) current!.add(_unquote(k));
            }
            current = null;
          }
        }
        continue;
      }
      if (current == null) continue;
      final m = childKey.firstMatch(line);
      if (m == null) continue;
      final indent = m[1]!.length;
      childIndent ??= indent;
      if (indent == childIndent) current.add(m[3]!);
    }
    return Pubspec._(name, sections['dependencies']!, sections['dev_dependencies']!, sections['dependency_overrides']!);
  }

  static String _unquote(String s) {
    final t = s.trim();
    if (t.length >= 2 && (t[0] == '"' || t[0] == "'") && t[t.length - 1] == t[0]) return t.substring(1, t.length - 1);
    return t;
  }

  /// Removes a `#` comment that starts a line or follows whitespace outside quotes.
  static String _stripYamlComment(String line) {
    String? quote;
    for (var i = 0; i < line.length; i++) {
      final c = line[i];
      if (quote != null) {
        if (c == quote) quote = null;
      } else if (c == '"' || c == "'") {
        quote = c;
      } else if (c == '#' && (i == 0 || line[i - 1] == ' ' || line[i - 1] == '\t')) {
        return line.substring(0, i);
      }
    }
    return line;
  }
}

// ---------------------------------------------------------------------------------------------
// Dart source reading
// ---------------------------------------------------------------------------------------------

/// Returns [source] with comments replaced by spaces and, when [blankStrings], the contents of
/// string literals too (interpolated `${…}` code is kept). Offsets and newlines are preserved.
String blankNonCode(String source, {required bool blankStrings}) =>
    _Blanker(source, blankStrings).run();

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

  /// Lexes code until the end, or (inside `${…}`) until the unmatched `}`.
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
        break; // Unterminated single-line literal: stop at the line end.
      } else if (!raw && _at(r'${')) {
        if (blankStrings) _blank(segment, i);
        i += 2;
        _code(inInterpolation: true);
        i++; // the closing `}`
        segment = i;
      } else {
        i++;
      }
    }
    if (blankStrings) _blank(segment, i);
  }
}

/// The URIs named by the `import` and `export` directives (including conditional imports) at the
/// top of a Dart file. Parsing stops at the first declaration.
List<String> directiveUris(String source) {
  final s = blankNonCode(source, blankStrings: false);
  final uris = <String>[];
  var i = 0;
  if (s.startsWith('#!')) i = s.contains('\n') ? s.indexOf('\n') : s.length;
  final keyword = RegExp(r'(library|import|export|part)\b');
  final annotation = RegExp(r'@[A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*');
  final quoted = RegExp(r'''(['"])(.*?)\1''');
  while (true) {
    while (i < s.length && s[i].trim().isEmpty) {
      i++;
    }
    if (i >= s.length) break;
    final at = annotation.matchAsPrefix(s, i);
    if (at != null) {
      i = at.end;
      while (i < s.length && s[i].trim().isEmpty) {
        i++;
      }
      if (i < s.length && s[i] == '(') {
        var depth = 0;
        do {
          if (s[i] == '(') depth++;
          if (s[i] == ')') depth--;
          i++;
        } while (i < s.length && depth > 0);
      }
      continue;
    }
    final m = keyword.matchAsPrefix(s, i);
    if (m == null) break;
    final end = s.indexOf(';', i);
    if (end < 0) break;
    if (m[1] == 'import' || m[1] == 'export') {
      for (final q in quoted.allMatches(s.substring(i, end))) {
        uris.add(q[2]!);
      }
    }
    i = end + 1;
  }
  return uris;
}

/// Identifiers in already-blanked code (test helper).
Set<String> identifiersIn(String code) =>
    RegExp(r'[A-Za-z_$][A-Za-z0-9_$]*').allMatches(code).map((m) => m[0]!).toSet();

// ---------------------------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------------------------

String _baseName(String path) => path.split(Platform.pathSeparator).last;

String _describe(List<Violation> violations) =>
    violations.isEmpty ? 'no violations' : violations.map((v) => '  $v').join('\n');

/// The repository root: the nearest ancestor of the working directory that holds the app
/// manifest and `packages/` (`flutter test` runs from the app root).
Directory _findRepoRoot() {
  var dir = Directory.current.absolute;
  while (true) {
    if (File('${dir.path}/pubspec.yaml').existsSync() &&
        Directory('${dir.path}/packages').existsSync() &&
        Directory('${dir.path}/test/architecture').existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('repository root not found above ${Directory.current.path}');
    }
    dir = parent;
  }
}
