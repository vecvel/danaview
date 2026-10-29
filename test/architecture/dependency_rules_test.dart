// OWNER: INT-01
// EXTENDED: AIS-01 (1.2.0 rules 9–12, 14 and 15 of AI_STUDIO_PLAN §3.1 / ARCH v1.2 §4.2)
// EXTENDED: INT-101 (1.2.0 rules 20–31 of ARCH v1.2 §4.2 and the V2-04 flag rule F)
//
// Architecture rules for the editor packages (ARCH §4.2 rules 1–7) and the owner's "no Material
// chrome" rule (ARCH §1.3) for the danaview_features files that editor tickets touch.
//
// 1.2.0 (AIS-01): the AI rules 9–12 (per package) and 14–15 (over every AI package) of
// AI_STUDIO_PLAN §3.1, in their ARCH v1.2 §4.2 wording (which wins). Rule 13's consent call sites
// are checked by packages/danaview_editor/test/architecture/ai_call_sites_test.dart (rule 17 paths,
// V2-20). AIS-43 adds rule 17; INT-101 rules 16, 18–31.
//
// 1.2.0 (INT-101): rules 20, 22–24 and 29 per package (library purity, documents, features, search,
// editor ports), and repo-wide greps for rule 21 (plugins standalone, no sockets in Dart, Swift or
// Kotlin), 25 (pure photo and beauty core), 26 (library writes, App Group, create-new save-out), 27
// (read-only source opens, PDF tools write new files only), 28 (OpenNetworkConsent call site), 30
// (no content in logs), 31 (Material ban on the 1.2.0 UI files) and F (V2-04: the 1.2.0 flags are
// read only in each package's flags file). Their fixtures are under `fixtures/v12/`.
// INT-101 also adds the AIS rules 16 (danaview_ai purity; skipped until the package exists), 18 (no
// sockets in diarization, media analysis and search) and 19 (Genkit only in danaview_ai_genkit,
// through the injected transport) ahead of AIS-43, for the S1 exit criterion (FIX-S1Q-2).
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
    for (final rule in [...repoRules, ...v12RepoRules]) {
      final present = rule.packages.any(repo.hasPackage);
      test(
        'rule ${rule.id}: ${rule.summary}',
        () {
          final violations = rule.check(repo);
          expect(violations, isEmpty, reason: _describe(violations));
        },
        skip: present ? false : 'none of ${rule.packages.join(', ')} exists yet; rule ${rule.id} skipped',
      );
    }
    for (final rule in [...dependencyRules, ...v12DependencyRules]) {
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
        ? (fixturesDir.listSync().whereType<Directory>().map((d) => _baseName(d.path)).where((n) => n != 'v12').toList()..sort())
        : <String>[];
    final v12Dir = Directory('${fixturesDir.path}/v12');
    final v12OnDisk = v12Dir.existsSync()
        ? (v12Dir.listSync().whereType<Directory>().map((d) => _baseName(d.path)).toList()..sort())
        : <String>[];

    test('every fixture directory has an expectation and every expectation a directory', () {
      expect(onDisk.toSet(), fixtureExpectations.keys.toSet());
    });

    test('every rule (1–12, 14, 15 and M) has at least one negative fixture', () {
      final covered = fixtureExpectations.values.expand((ids) => ids).toSet();
      expect(covered, containsAll(<String>[...dependencyRules.map((r) => r.id), ...repoRules.map((r) => r.id), materialRule.id]));
    });

    test('every v12 fixture directory has an expectation and every expectation a directory', () {
      expect(v12OnDisk.toSet(), v12FixtureExpectations.keys.toSet());
      expect(v12FixtureExpectations.keys, containsAll(v12FixtureViolationCounts.keys));
    });

    test('every 1.2.0 rule (16, 18, 19, 20–31 and F) has a negative fixture that fires it alone or with its overlap', () {
      final ids = <String>[...v12DependencyRules.map((r) => r.id), ...v12RepoRules.map((r) => r.id)];
      expect(ids.toSet(), {'16', '18', '19', for (var i = 20; i <= 31; i++) '$i', 'F'});
      final covered = v12FixtureExpectations.values.expand((fired) => fired).toSet();
      expect(covered, containsAll(ids));
      for (final id in ids) {
        expect(v12FixtureExpectations.entries.where((e) => e.value.contains(id) && v12FixtureViolationCounts.containsKey(e.key)),
            isNotEmpty, reason: 'rule $id has no counted fixture');
      }
    });

    test('the 1.2.0 rules are ARCH v1.2 §4.2 rules 16, 18, 19, 20–31 and V2-04', () {
      final arch = repo.readFile('docs/v1.2/ARCHITECTURE.md');
      expect(arch, isNotNull, reason: 'docs/v1.2/ARCHITECTURE.md is missing');
      for (final id in [16, 18, 19, for (var i = 20; i <= 31; i++) i]) {
        expect(arch, contains('\n$id. '), reason: 'ARCH v1.2 §4.2 has no rule $id');
      }
      expect(arch, contains('**V2-04**'));
      expect(arch, contains('lib/src/{store,import,inbox,actions,db,desktop}/'), reason: 'rule 20 records the desktop/ allowance');
    });

    for (final entry in v12FixtureExpectations.entries) {
      test('v12/${entry.key} fires exactly ${entry.value.isEmpty ? 'nothing' : entry.value.join(', ')}', () {
        final fixture = RepoTree(Directory('${fixturesDir.path}/v12/${entry.key}'), suffix: '.fixture');
        final violations = checkAll(fixture);
        final fired = violations.map((v) => v.rule).toSet();
        expect(fired, entry.value, reason: _describe(violations));
        if (entry.value.isNotEmpty) expect(violations, isNotEmpty);
        final count = v12FixtureViolationCounts[entry.key];
        if (count != null) expect(violations, hasLength(count), reason: _describe(violations));
      });
    }

    test('the AI rules are ARCH v1.2 §4.2 rules 9–12, 14 and 15', () {
      expect(<String>[...dependencyRules.map((r) => r.id), ...repoRules.map((r) => r.id)],
          containsAll(<String>['9', '10', '11', '12', '14', '15']));
      final arch = repo.readFile('docs/v1.2/ARCHITECTURE.md');
      expect(arch, isNotNull, reason: 'docs/v1.2/ARCHITECTURE.md is missing');
      for (final id in ['9', '10', '11', '12', '14', '15']) {
        expect(arch, contains('\n$id. '), reason: 'ARCH v1.2 §4.2 has no rule $id');
      }
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
  // 1.2.0 (AIS-01).
  'ok_ai_packages_clean': <String>{},
  'r9_providers_depends_on_flutter': {'9'},
  'r9_providers_imports_flutter_and_danaview': {'9'},
  'r10_studio_depends_on_editor_and_keys': {'10'},
  'r10_studio_widget_code': {'10'},
  'r11_secure_keys_depends_on_danaview': {'11'},
  'r11_features_imports_secure_keys': {'11'},
  'r12_editor_imports_native_plugins': {'12'},
  'r14_http_client_outside_transport': {'14'},
  'r15_key_in_url': {'15'},
  'r15_logs_content': {'15'},
};

/// Exact violation counts for fixtures where the count itself proves something (every offending
/// line or manifest entry is reported, not just the first one).
const fixtureViolationCounts = <String, int>{
  'r1_features_dev_dependency_and_override': 2,
  'r2_core_depends_on_flutter': 2,
  'r2_core_dart_io_outside_store': 1,
  'r2_core_imports_dart_ui_and_third_party': 2,
  'm_features_material_chrome': 5,
  'r9_providers_depends_on_flutter': 3,
  'r9_providers_imports_flutter_and_danaview': 3,
  'r10_studio_depends_on_editor_and_keys': 3,
  'r10_studio_widget_code': 2,
  'r11_secure_keys_depends_on_danaview': 2,
  'r11_features_imports_secure_keys': 2,
  'r12_editor_imports_native_plugins': 3,
  'r14_http_client_outside_transport': 3,
  'r15_key_in_url': 2,
  'r15_logs_content': 4,
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
      _forbidWidgetCode(pkg, report);
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
  // 1.2.0 (AIS-01; AI_STUDIO_PLAN §3.1, ARCH v1.2 §4.2).
  DependencyRule(
    '9',
    'danaview_ai_providers',
    'danaview_ai_providers depends only on meta, collection, crypto and the SDK (no Flutter, no danaview_*)',
    (repo, pkg, report) {
      const allowed = {'meta', 'collection', 'crypto'};
      for (final dep in pkg.pubspec.dependencies) {
        if (!allowed.contains(dep)) report(pkg.pubspecPath, 'dependency `$dep` is not one of ${allowed.join(', ')}');
      }
      for (final dep in {...pkg.pubspec.devDependencies, ...pkg.pubspec.overrides}) {
        if (dep == 'flutter' || dep == 'flutter_test' || (dep.startsWith('danaview_') && dep != pkg.name)) {
          report(pkg.pubspecPath, 'dev dependency `$dep` is not allowed in danaview_ai_providers');
        }
      }
      for (final file in pkg.dartFiles) {
        final shipped = file.packagePath.startsWith('lib/') || file.packagePath.startsWith('tool/');
        for (final uri in file.uris) {
          final p = packageOf(uri);
          if (uri == 'dart:ui' || p == 'flutter' || p == 'flutter_test' || p == 'sky_engine') {
            report(file.repoPath, 'imports `$uri`: no Flutter in danaview_ai_providers');
          } else if (p != null && p.startsWith('danaview_') && p != pkg.name) {
            report(file.repoPath, 'imports `$uri`: no danaview_* package in danaview_ai_providers');
          } else if (shipped && p != null && p != pkg.name && !allowed.contains(p)) {
            report(file.repoPath, 'imports `$uri`: lib/ and tool/ may import only ${allowed.join(', ')} and the SDK');
          }
        }
      }
    },
  ),
  DependencyRule(
    '10',
    'danaview_ai_studio',
    'danaview_ai_studio depends on the AI layer, core, transcription, characters, collection, meta, path only; no widgets',
    (repo, pkg, report) {
      const allowed = {
        'flutter', // only because danaview_transcription needs it; no widget code (below)
        'characters',
        'collection',
        'meta',
        'path',
        'danaview_ai',
        'danaview_ai_providers',
        'danaview_editor_core',
        'danaview_transcription',
      };
      const forbidden = {
        'danaview_editor_engine',
        'danaview_editor_engine_api',
        'danaview_editor',
        'danaview_features',
        'danaview_secure_keys',
      };
      for (final dep in pkg.pubspec.dependencies) {
        if (!forbidden.contains(dep) && !allowed.contains(dep)) {
          report(pkg.pubspecPath, 'dependency `$dep` is not one of ${allowed.join(', ')}');
        }
      }
      _forbidPackages(pkg, forbidden, report, why: 'AI Studio never reaches the engine, the editor UI, features or the key store');
      for (final file in pkg.dartFiles.where((f) => f.packagePath.startsWith('lib/'))) {
        for (final uri in file.uris) {
          final p = packageOf(uri);
          if (p != null && p != pkg.name && !allowed.contains(p) && !forbidden.contains(p)) {
            report(file.repoPath, 'imports `$uri`: lib/ may import only ${allowed.join(', ')}');
          }
        }
      }
      _forbidWidgetCode(pkg, report);
    },
  ),
  DependencyRule(
    '11',
    'danaview_secure_keys',
    'danaview_secure_keys depends on no danaview_* package and only the app root imports it',
    (repo, pkg, report) {
      _forbidPackages(pkg, null, report, allowDanaview: const {}, why: 'the key store plugin is standalone');
      for (final name in repo.packageNames) {
        if (name == pkg.name) continue;
        final other = repo.package(name)!;
        _forbidPackages(other, {pkg.name}, report, why: 'only the app root imports danaview_secure_keys');
      }
    },
  ),
  DependencyRule(
    '12',
    'danaview_editor',
    'danaview_editor never depends on the key store or the 1.2.0 native plugins (AI packages as types only)',
    (repo, pkg, report) {
      _forbidPackages(
        pkg,
        const {
          'danaview_secure_keys',
          'danaview_face_tracking',
          'danaview_diarization',
          'danaview_media_analysis',
          'danaview_pdf',
          'danaview_library_native',
        },
        report,
        why: 'danaview_editor reaches native plugins only through ports adapted at the app root',
      );
    },
  ),
];

/// The 1.2.0 AI packages (AI_STUDIO_PLAN §3.1, ARCH v1.2 §4.1); rules 14 and 15 scan their lib/ and
/// tool/ code. `danaview_ai`, `danaview_ai_ui` and `danaview_ai_genkit` arrive with AIS-43/AIS-42.
const aiPackages = <String>{
  'danaview_ai_providers',
  'danaview_ai_studio',
  'danaview_ai',
  'danaview_ai_ui',
  'danaview_ai_genkit',
};

/// The only file of the AI packages that may construct an `HttpClient` (rule 14).
const httpClientSite = 'packages/danaview_ai_providers/lib/src/transport/http_transport.dart';

/// Logging-call arguments (exact source text, trimmed) that rule 15 accepts although they are not
/// plain string literals. Each entry must interpolate nothing but counts, ids, status codes or
/// durations; add one only with a comment naming the call site. Empty: every log is a literal.
const aiLogFormatAllowList = <String>{};

/// A rule over several packages (rules 14 and 15); it runs while any of [packages] exists.
class RepoRule {
  const RepoRule(this.id, this.packages, this.summary, this._check);

  final String id;
  final Set<String> packages;
  final String summary;
  final void Function(RepoTree repo, void Function(String location, String message) report) _check;

  List<Violation> check(RepoTree repo) {
    if (!packages.any(repo.hasPackage)) return const [];
    final out = <Violation>[];
    _check(repo, (location, message) => out.add(Violation(id, location, message)));
    return out;
  }
}

/// The lib/ and tool/ Dart files of every AI package in [repo].
Iterable<DartFileView> _aiShippedFiles(RepoTree repo) sync* {
  for (final name in aiPackages) {
    final pkg = repo.package(name);
    if (pkg == null) continue;
    yield* pkg.dartFiles.where((f) => f.packagePath.startsWith('lib/') || f.packagePath.startsWith('tool/'));
  }
}

int _lineAt(String text, int offset) => '\n'.allMatches(text.substring(0, offset)).length + 1;

/// The offset of the `)` closing the `(` at [open] in [code] (strings already blanked), or -1.
int _closingParen(String code, int open) {
  var depth = 0;
  for (var i = open; i < code.length; i++) {
    if (code[i] == '(') depth++;
    if (code[i] == ')') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return -1;
}

/// Rule 15's logging calls: `print`, `debugPrint`, a bare `log`, `developer.log` and
/// `stdout`/`stderr` writes. Method calls such as `math.log(` or `ledger.log(` are not logging.
final _logCall = RegExp(
  r'(?<![A-Za-z0-9_$.])(?:print|debugPrint|log)\s*\(|(?<![A-Za-z0-9_$.])developer\s*\.\s*log\s*\(|(?<![A-Za-z0-9_$.])(?:stdout|stderr)\s*\.\s*(?:write|writeln|writeAll)\s*\(',
);

/// AI_STUDIO_PLAN §3.1 rules 14 and 15.
final repoRules = <RepoRule>[
  RepoRule(
    '14',
    aiPackages,
    'HttpClient( is constructed in the AI packages only in danaview_ai_providers/lib/src/transport/http_transport.dart',
    (repo, report) {
      final construct = RegExp(r'(?<![A-Za-z0-9_$])HttpClient\s*(?:\(|\.\s*new\b)');
      for (final file in _aiShippedFiles(repo)) {
        if (file.repoPath == httpClientSite) continue;
        final code = blankNonCode(file.source, blankStrings: true);
        for (final m in construct.allMatches(code)) {
          report('${file.repoPath}:${_lineAt(code, m.start)}', 'constructs an HttpClient: only $httpClientSite may (rule 14)');
        }
      }
    },
  ),
  RepoRule(
    '15',
    aiPackages,
    'no `?key=` in AI package sources; no AI package log call takes a body, response, key or caption',
    (repo, report) {
      for (final file in _aiShippedFiles(repo)) {
        for (final m in '?key='.allMatches(file.source)) {
          report('${file.repoPath}:${_lineAt(file.source, m.start)}', 'contains `?key=`: keys go in a header, never in a URL (rule 15)');
        }
        final code = blankNonCode(file.source, blankStrings: true);
        final withStrings = blankNonCode(file.source, blankStrings: false);
        for (final m in _logCall.allMatches(code)) {
          final open = m.end - 1;
          final close = _closingParen(code, open);
          if (close < 0) continue;
          final raw = withStrings.substring(open + 1, close).trim();
          if (aiLogFormatAllowList.contains(raw)) continue;
          final leftover = code.substring(open + 1, close).replaceAll(RegExp(r'''\br(?=['"])|['"\s,]'''), '');
          final interpolates = RegExp(r'\$[A-Za-z_{]').hasMatch(raw);
          if (leftover.isNotEmpty || interpolates) {
            report('${file.repoPath}:${_lineAt(code, m.start)}',
                'logs `${raw.length > 40 ? '${raw.substring(0, 40)}…' : raw}`: AI packages log only string literals (rule 15)');
          }
        }
      }
    },
  ),
];

// ---------------------------------------------------------------------------------------------
// 1.2.0 (INT-101): ARCH v1.2 §4.2 rules 20–31 and the V2-04 flag rule F
// ---------------------------------------------------------------------------------------------

/// The plugins of rule 21 (no `danaview_*` dependency, no sockets). `danaview_secure_keys`'s
/// dependency check is rule 11's; rule 21 adds the socket ban for it.
const v12PluginPackages = <String>{
  'danaview_library_native',
  'danaview_pdf',
  'danaview_face_tracking',
  'danaview_media_analysis',
  'danaview_diarization',
  'danaview_secure_keys',
};

/// The 1.2.0 non-AI packages INT-101 creates (ARCH v1.2 §4.3).
const v12NewPackages = <String>{
  'danaview_library',
  'danaview_library_native',
  'danaview_pdf',
  'danaview_documents',
  'danaview_face_tracking',
  'danaview_search',
};

/// The AI packages rule 23 keeps out of danaview_features (`danaview_secure_keys` is rule 11's).
const v12AiPackagesForFeatures = <String>{
  'danaview_ai_providers',
  'danaview_ai',
  'danaview_ai_ui',
  'danaview_ai_studio',
  'danaview_ai_genkit',
};

/// Native source extensions scanned by the grep rules (21, 26, 27, 30).
const nativeExtensions = <String>{'.swift', '.kt', '.kts', '.java', '.m', '.mm', '.h', '.c', '.cc', '.cpp'};

/// Directories of a package whose code ships (lib/ and the native trees); tests, examples, tools
/// and pigeon inputs are not scanned by the grep rules.
bool _shipped(String packagePath) =>
    packagePath.startsWith('lib/') ||
    packagePath.startsWith('darwin/') ||
    packagePath.startsWith('ios/') ||
    packagePath.startsWith('macos/') ||
    packagePath.startsWith('android/src/main/');

/// Rule 30's and rule 31's 1.2.0 UI and content code outside the new packages: the new
/// danaview_features library directories and settings sections, the speed-test files ST-04 touches,
/// the core photo/colour/beauty code and the editor's photo and beauty code.
const v12ScannedDirs = <String>[
  'packages/danaview_features/lib/src/library/files/',
  'packages/danaview_features/lib/src/library/sources/',
  'packages/danaview_features/lib/src/library/desktop/',
  'packages/danaview_features/lib/src/library/thumbs/',
  'packages/danaview_features/lib/src/library/home/',
  'packages/danaview_features/lib/src/library/tabs/',
  'packages/danaview_features/lib/src/library/photos/',
  'packages/danaview_features/lib/src/library/photo_viewer/',
  'packages/danaview_features/lib/src/library/selection/',
  'packages/danaview_features/lib/src/library/badges/',
  'packages/danaview_features/lib/src/library/filters/',
  'packages/danaview_features/lib/src/library/folders/',
  'packages/danaview_features/lib/src/library/organise/',
  'packages/danaview_features/lib/src/library/search/',
  'packages/danaview_features/lib/src/library/import/',
  'packages/danaview_features/lib/src/library/file_actions/',
  'packages/danaview_features/lib/src/more/settings_sections/',
  'packages/danaview_editor/lib/src/editor/photo/',
  'packages/danaview_editor/lib/src/editor/panels/beauty/',
  'packages/danaview_editor/lib/src/editor/panels/beauty_presets/',
  'packages/danaview_editor/lib/src/editor/beauty/',
];

/// Rule 30's core directories (content: recipes, landmarks).
const v12CoreDirs = <String>[
  'packages/danaview_editor_core/lib/src/photo/',
  'packages/danaview_editor_core/lib/src/color/',
  'packages/danaview_editor_core/lib/src/beauty/',
];

/// The speed-test files of ST-04 (rule 31).
const v12SpeedTestFiles = <String>[
  'packages/danaview_features/lib/src/tools/speed_consent_sheet.dart',
  'packages/danaview_features/lib/src/tools/danaview_speed_test_screen.dart',
  'packages/danaview_features/lib/src/tools/network_tool_providers.dart',
  'packages/danaview_features/lib/src/tools/network_format.dart',
];

/// The only file that may call `OpenNetworkConsent.accepted(` (rule 28, V2-23).
const openNetworkConsentSite = 'packages/danaview_features/lib/src/tools/speed_consent_sheet.dart';

/// The 1.2.0 build flags (V2-04) and the one file per package that reads them (rule F).
const v12Flags = <String>{'DANAVIEW_FILES_HOME', 'DANAVIEW_PHOTO_EDITOR', 'DANAVIEW_BEAUTY', 'DANAVIEW_AI_STUDIO'};

/// File -> the 1.2.0 flags it may read. `editor_availability.dart` keeps AIS-01's
/// `DANAVIEW_AI_STUDIO` read; `flags_v12.dart` re-exposes it instead of reading it again.
const v12FlagFiles = <String, Set<String>>{
  'packages/danaview_features/lib/src/flags.dart': v12Flags,
  'packages/danaview_editor/lib/src/app/flags_v12.dart': {'DANAVIEW_FILES_HOME', 'DANAVIEW_PHOTO_EDITOR', 'DANAVIEW_BEAUTY'},
  'packages/danaview_editor/lib/src/app/editor_availability.dart': {'DANAVIEW_AI_STUDIO'},
};

/// Native and Dart log-call arguments rule 30 accepts although they are not plain literals (exact
/// source text, trimmed). Each entry must log nothing but counts, ids, status codes or durations;
/// add one only with a comment naming the call site.
const v12LogFormatAllowList = <String>{
  // HOM-31: PdfCompressCoreTests.measured (packages/danaview_pdf/darwin/Tests/Compress/), the XCTest
  // measurement lines for BUILD_STATE: fixture kinds, preset names and byte counts only.
  'hom31MeasurementLine',
};

/// The shipped files of [pkg] with [extensions] (fixture suffix stripped).
Iterable<SourceFileView> _shippedSources(PackageView pkg, Set<String> extensions) =>
    pkg.sourceFiles(extensions).where((f) => _shipped(f.packagePath));

/// The Dart files under any of [dirs] (repo-relative prefixes) in [repo].
Iterable<DartFileView> _dartFilesUnder(RepoTree repo, Iterable<String> dirs) sync* {
  final seen = <String>{};
  for (final dir in dirs) {
    final name = RegExp(r'^packages/([^/]+)/').firstMatch(dir)?[1];
    final pkg = name == null ? null : repo.package(name);
    if (pkg == null) continue;
    for (final f in pkg.dartFiles) {
      if (f.repoPath.startsWith(dir) && seen.add(f.repoPath)) yield f;
    }
  }
}

/// Checks [pkg]'s manifest and lib/ imports against [allowed] (plus the SDK and the package itself).
void _onlyAllowed(PackageView pkg, Set<String> allowed, void Function(String, String) report, String rule) {
  for (final dep in pkg.pubspec.dependencies) {
    if (!allowed.contains(dep)) report(pkg.pubspecPath, 'dependency `$dep` is not one of ${allowed.join(', ')} ($rule)');
  }
  for (final file in pkg.dartFiles.where((f) => f.packagePath.startsWith('lib/'))) {
    for (final uri in file.uris) {
      final p = packageOf(uri);
      if (uri == 'dart:ui' && !allowed.contains('flutter')) {
        report(file.repoPath, 'imports `$uri`: no Flutter in ${pkg.name} ($rule)');
      } else if (p != null && p != pkg.name && !allowed.contains(p)) {
        report(file.repoPath, 'imports `$uri`: lib/ may import only ${allowed.join(', ')} ($rule)');
      }
    }
  }
}

/// Reports Flutter and `danaview_*` dev dependencies of a pure package.
void _pureDevDependencies(PackageView pkg, Set<String> allowedDanaview, void Function(String, String) report, String rule) {
  for (final dep in {...pkg.pubspec.devDependencies, ...pkg.pubspec.overrides}) {
    if (dep == 'flutter' || dep == 'flutter_test' || (dep.startsWith('danaview_') && dep != pkg.name && !allowedDanaview.contains(dep))) {
      report(pkg.pubspecPath, 'dev dependency `$dep` is not allowed in the pure package ${pkg.name} ($rule)');
    }
  }
}

/// ARCH v1.2 §4.2 rules 20, 22, 23, 24 and 29 (one package each).
final v12DependencyRules = <DependencyRule>[
  DependencyRule(
    '16',
    'danaview_ai',
    'danaview_ai is pure Dart (danaview_ai_providers, meta, collection and the SDK)',
    (repo, pkg, report) {
      _onlyAllowed(pkg, const {'danaview_ai_providers', 'meta', 'collection'}, report, 'rule 16');
      _pureDevDependencies(pkg, const {'danaview_ai_providers'}, report, 'rule 16');
    },
  ),
  DependencyRule(
    '20',
    'danaview_library',
    'danaview_library is pure Dart (danaview_domain, sqlite3, meta, collection, crypto, path; dart:io only in lib/src/{store,import,inbox,actions,db,desktop}/)',
    (repo, pkg, report) {
      const allowed = {'danaview_domain', 'sqlite3', 'meta', 'collection', 'crypto', 'path'};
      const ioDirs = ['store', 'import', 'inbox', 'actions', 'db', 'desktop'];
      _onlyAllowed(pkg, allowed, report, 'rule 20');
      _pureDevDependencies(pkg, const {'danaview_domain'}, report, 'rule 20');
      for (final file in pkg.dartFiles) {
        final inLib = file.packagePath.startsWith('lib/');
        final ioAllowed = ioDirs.any((d) => file.packagePath.startsWith('lib/src/$d/'));
        for (final uri in file.uris) {
          final p = packageOf(uri);
          if (!inLib && (p == 'flutter' || p == 'flutter_test' || p == 'sky_engine')) {
            // lib/ imports are checked against the allowed set above.
            report(file.repoPath, 'imports `$uri`: no Flutter in danaview_library (rule 20)');
          } else if (inLib && !ioAllowed && (uri == 'dart:io' || uri == 'dart:isolate')) {
            report(file.repoPath, 'imports `$uri` outside lib/src/{${ioDirs.join(',')}}/ (rule 20)');
          }
        }
      }
    },
  ),
  DependencyRule(
    '22',
    'danaview_documents',
    'danaview_documents depends on danaview_ui_kit, danaview_library, danaview_pdf, danaview_library_native, flutter_riverpod, characters only',
    (repo, pkg, report) {
      const allowed = {
        'flutter',
        'danaview_ui_kit',
        'danaview_library',
        'danaview_pdf',
        'danaview_library_native',
        'flutter_riverpod',
        'characters',
      };
      _onlyAllowed(pkg, allowed, report, 'rule 22');
      final forbidden = {'danaview_features', 'danaview_search', ...editorPackages, ...aiPackages};
      for (final dep in {...pkg.pubspec.devDependencies, ...pkg.pubspec.overrides}.where(forbidden.contains)) {
        report(pkg.pubspecPath, 'dev dependency `$dep`: documents never reach features, the editor, AI or search (rule 22)');
      }
    },
  ),
  DependencyRule(
    '23',
    'danaview_features',
    'danaview_features never imports an AI package or danaview_pdf (editor packages: rule 1; the key store: rule 11)',
    (repo, pkg, report) {
      _forbidPackages(
        pkg,
        {...v12AiPackagesForFeatures, 'danaview_pdf'},
        report,
        why: 'AI entry points are app-root callbacks and PDFs go through danaview_documents (rule 23)',
      );
    },
  ),
  DependencyRule(
    '24',
    'danaview_search',
    'danaview_search is pure Dart (danaview_library, danaview_ai, sqlite3, meta, collection, characters)',
    (repo, pkg, report) {
      const allowed = {'danaview_library', 'danaview_ai', 'sqlite3', 'meta', 'collection', 'characters'};
      _onlyAllowed(pkg, allowed, report, 'rule 24');
      _pureDevDependencies(pkg, const {'danaview_library', 'danaview_ai'}, report, 'rule 24');
      for (final file in pkg.dartFiles.where((f) => !f.packagePath.startsWith('lib/'))) {
        for (final uri in file.uris) {
          final p = packageOf(uri);
          if (p == 'flutter' || p == 'flutter_test' || p == 'sky_engine') {
            report(file.repoPath, 'imports `$uri`: no Flutter in danaview_search (rule 24)');
          }
        }
      }
    },
  ),
  DependencyRule(
    '29',
    'danaview_editor',
    'danaview_editor reaches library files only through MediaAccessPort (no danaview_library, danaview_documents, danaview_search)',
    (repo, pkg, report) {
      // danaview_face_tracking, danaview_library_native and danaview_pdf are rule 12's.
      _forbidPackages(
        pkg,
        const {'danaview_library', 'danaview_documents', 'danaview_search'},
        report,
        why: 'the editor uses FaceTrackingPort and MediaAccessPort, adapted at the app root (rule 29)',
      );
    },
  ),
];

/// Socket-opening constructs banned in the rule 21 plugins (Dart, Swift, Kotlin, Java, C).
final _socketApi = RegExp(
  r'(?<![A-Za-z0-9_$])(?:HttpClient\s*\(|HttpClient\s*\.\s*new\b|(?:Raw)?(?:Secure)?Socket\s*\.\s*connect\b|WebSocket\s*\.\s*connect\b|HttpURLConnection\b|URLSession\b|NWConnection\b|OkHttpClient\b|java\.net\.Socket\b|CFStreamCreatePairWithSocketToHost\b)',
);

/// `print`-like native log calls (Swift, Kotlin, Java, ObjC) for rule 30.
final _nativeLogCall = RegExp(
  r'(?<![A-Za-z0-9_$.])(?:print|debugPrint|NSLog|os_log|println)\s*\(|(?<![A-Za-z0-9_$])(?:Log|logger|log)\s*\.\s*(?:v|d|i|w|e|wtf|debug|info|notice|warning|error|fault|trace|critical)\s*\(',
);

/// The offline packages of rule 18 (no sockets; models only through the consented downloader).
const offlinePackages = <String>{'danaview_diarization', 'danaview_media_analysis', 'danaview_search'};

/// The only package that may use Genkit (rule 19).
const genkitPackage = 'danaview_ai_genkit';

/// Imports and dependencies that open a network path around the injected `HttpTransport` (rule 19).
const _networkPackages = <String>{'http', 'dio', 'web_socket_channel', 'grpc'};

/// ARCH v1.2 §4.2 rules 18, 19, 21, 25–28, 30, 31 and F.
final v12RepoRules = <RepoRule>[
  RepoRule(
    '18',
    offlinePackages,
    'danaview_diarization, danaview_media_analysis and danaview_search open no sockets (Dart, Swift, Kotlin)',
    (repo, report) {
      for (final name in offlinePackages) {
        final pkg = repo.package(name);
        if (pkg == null) continue;
        for (final file in _shippedSources(pkg, {'.dart', ...nativeExtensions})) {
          final code = blankNonCode(file.source, blankStrings: true);
          for (final m in _socketApi.allMatches(code)) {
            report('${file.repoPath}:${_lineAt(code, m.start)}', 'uses `${m[0]!.trim()}`: ${pkg.name} is offline (rule 18)');
          }
        }
      }
    },
  ),
  RepoRule(
    '19',
    {genkitPackage, 'danaview_features', 'danaview_editor', 'danaview_ai_providers', 'danaview_ai_studio'},
    'only danaview_ai_genkit uses package:genkit*, and it reaches the network only through the injected HttpTransport',
    (repo, report) {
      bool isGenkit(String name) => name == 'genkit' || name.startsWith('genkit_');
      for (final name in repo.packageNames.where((n) => n != genkitPackage)) {
        final pkg = repo.package(name)!;
        _forbidPackages(pkg, null, report, why: 'only $genkitPackage uses Genkit (rule 19)', isForbidden: isGenkit);
      }
      for (final file in repo.appLibFiles) {
        for (final uri in file.uris) {
          final p = packageOf(uri);
          if (p != null && isGenkit(p)) report(file.repoPath, 'imports `$uri`: only $genkitPackage uses Genkit (rule 19)');
        }
      }
      final genkit = repo.package(genkitPackage);
      if (genkit == null) return;
      _forbidPackages(genkit, _networkPackages, report, why: 'Genkit calls go through the injected HttpTransport (rule 19)');
      for (final file in _shippedSources(genkit, const {'.dart'})) {
        final code = blankNonCode(file.source, blankStrings: true);
        for (final m in _socketApi.allMatches(code)) {
          report('${file.repoPath}:${_lineAt(code, m.start)}',
              'uses `${m[0]!.trim()}`: Genkit calls go through the injected HttpTransport (rule 19)');
        }
      }
    },
  ),
  RepoRule(
    '21',
    v12PluginPackages,
    'the 1.2.0 plugins depend on no danaview_* package and open no sockets; face tracking loads models only from given paths',
    (repo, report) {
      for (final name in v12PluginPackages) {
        final pkg = repo.package(name);
        if (pkg == null) continue;
        if (name != 'danaview_secure_keys') {
          _forbidPackages(pkg, null, report, allowDanaview: const {}, why: 'the 1.2.0 plugins are standalone (rule 21)');
        }
        for (final file in _shippedSources(pkg, {'.dart', ...nativeExtensions})) {
          final code = blankNonCode(file.source, blankStrings: true);
          for (final m in _socketApi.allMatches(code)) {
            report('${file.repoPath}:${_lineAt(code, m.start)}', 'uses `${m[0]!.trim()}`: plugins open no sockets (rule 21)');
          }
          if (name == 'danaview_face_tracking') {
            final withStrings = blankNonCode(file.source, blankStrings: false);
            for (final m in RegExp(r'https?://').allMatches(withStrings)) {
              report('${file.repoPath}:${_lineAt(withStrings, m.start)}',
                  'names a URL: face tracking loads models only from the paths it is given (rule 21)');
            }
          }
        }
      }
    },
  ),
  RepoRule(
    '25',
    {'danaview_editor_core'},
    'the core photo, colour and beauty code is pure (no Flutter, no danaview_*, no dart:io or dart:isolate)',
    (repo, report) {
      final pkg = repo.package('danaview_editor_core')!;
      bool inScope(String p) =>
          p == 'lib/photo.dart' ||
          p == 'lib/beauty.dart' ||
          p.startsWith('lib/src/photo/') ||
          p.startsWith('lib/src/color/') ||
          p.startsWith('lib/src/beauty/') ||
          p == 'lib/src/plan/lowering_photo_clip.dart' ||
          p == 'lib/src/plan/lowering_beauty.dart';
      for (final file in pkg.dartFiles.where((f) => inScope(f.packagePath))) {
        for (final uri in file.uris) {
          final p = packageOf(uri);
          if (uri == 'dart:io' || uri == 'dart:isolate' || uri == 'dart:ui' || p == 'flutter' || (p != null && p.startsWith('danaview_') && p != pkg.name)) {
            report(file.repoPath, 'imports `$uri`: photo and beauty code is pure Dart without dart:io (rule 25)');
          }
        }
      }
    },
  ),
  RepoRule(
    '26',
    {'danaview_library', 'danaview_library_native'},
    'only danaview_library lib/src/{store,import}/ write under the library root; only the Inbox touches the App Group; save-out is create-new only',
    (repo, report) {
      final writeApi = RegExp(
        r'\.\s*(?:writeAsBytes|writeAsBytesSync|writeAsString|writeAsStringSync|openWrite|rename|renameSync|delete|deleteSync|copy|copySync|createSync|setLastModified|setLastModifiedSync)\s*\(|\.\s*create\s*\(\s*recursive|FileMode\s*\.\s*(?:write|append|writeOnly|writeOnlyAppend)\b',
      );
      final library = repo.package('danaview_library');
      if (library != null) {
        for (final file in library.dartFiles.where((f) => f.packagePath.startsWith('lib/') && f.uris.contains('dart:io'))) {
          if (file.packagePath.startsWith('lib/src/store/') || file.packagePath.startsWith('lib/src/import/')) continue;
          final code = blankNonCode(file.source, blankStrings: true);
          for (final m in writeApi.allMatches(code)) {
            report('${file.repoPath}:${_lineAt(code, m.start)}',
                'writes files (`${m[0]!.trim()}`): only lib/src/store/ and lib/src/import/ write under the library root (rule 26)');
          }
        }
      }
      // The App Group container: only danaview_library_native's Inbox (any package, shipped code).
      final appGroup = RegExp(r'group\.com\.vecvel\.danaview|containerURL\s*\(\s*forSecurityApplicationGroupIdentifier');
      const inboxDir = 'packages/danaview_library_native/darwin/Classes/Inbox/';
      for (final name in repo.packageNames) {
        final pkg = repo.package(name)!;
        for (final file in _shippedSources(pkg, {'.dart', ...nativeExtensions})) {
          if (file.repoPath.startsWith(inboxDir)) continue;
          final code = blankNonCode(file.source, blankStrings: false);
          final lines = <int>{};
          for (final m in appGroup.allMatches(code)) {
            final line = _lineAt(code, m.start);
            if (lines.add(line)) report('${file.repoPath}:$line', 'touches the App Group container: only the Inbox class may (rule 26)');
          }
        }
      }
      // Save-out is create-new only.
      final native = repo.package('danaview_library_native');
      if (native != null) {
        final overwrite = RegExp(
          r'replaceItemAt\s*\(|replaceItem\s*\(|openOutputStream\s*\([^)]*,\s*"|(?<![A-Za-z0-9_$])(?:overwrite|replace|replaceExisting)\s*:\s*true\b',
        );
        // Android save-out (HOM-22A) writes with openOutputStream(uri, "w") only into a URI it has
        // just created itself (MediaStore insert with IS_PENDING, or the system's
        // ACTION_CREATE_DOCUMENT result), which is the create-new rule; other files stay checked.
        const androidSaveOut = 'packages/danaview_library_native/android/src/main/kotlin/com/vecvel/danaview/library/exportout/AndroidFileOut.kt';
        for (final file in _shippedSources(native, {'.dart', ...nativeExtensions})) {
          final code = blankNonCode(file.source, blankStrings: false);
          for (final m in overwrite.allMatches(code)) {
            if (file.repoPath == androidSaveOut && m[0]!.startsWith('openOutputStream')) continue;
            report('${file.repoPath}:${_lineAt(code, m.start)}',
                'overwrites (`${m[0]!.trim()}`): save-out writes only to a URI it just created (rule 26)');
          }
        }
      }
    },
  ),
  RepoRule(
    '27',
    {'danaview_library_native', 'danaview_pdf', 'danaview_face_tracking', 'danaview_media_analysis'},
    'plugins open external sources read-only; PDF tools write only new files (from their own directories)',
    (repo, report) {
      final descriptorMode = RegExp(r'openFileDescriptor\s*\([^,()]+,\s*"([^"]*)"');
      final writable = RegExp(
        r'ParcelFileDescriptor\s*\.\s*MODE_(?:READ_WRITE|WRITE_ONLY|TRUNCATE|APPEND|CREATE)\b|(?<![A-Za-z0-9_])O_(?:RDWR|WRONLY|TRUNC|APPEND)\b|FileHandle\s*\(\s*(?:forUpdating|forWritingTo|forWritingAtPath|forUpdatingAtPath)\b',
      );
      final randomAccessWrite = RegExp(r'RandomAccessFile\s*\([^)]*"rw');
      final pdfWrite = RegExp(r'\.\s*write\s*\(\s*(?:to|toFile)\s*:|\.\s*writeTo\s*\(|dataRepresentation\s*\(');
      const pdfToolDirs = [
        'packages/danaview_pdf/darwin/Classes/Tools/',
        'packages/danaview_pdf/darwin/Classes/Annotate/',
        'packages/danaview_pdf/darwin/Classes/Sign/',
        'packages/danaview_pdf/darwin/Classes/Compress/',
        'packages/danaview_pdf/android/src/main/kotlin/com/vecvel/danaview/pdf/tools/',
        'packages/danaview_pdf/android/src/main/kotlin/com/vecvel/danaview/pdf/annotate/',
        'packages/danaview_pdf/android/src/main/kotlin/com/vecvel/danaview/pdf/sign/',
        'packages/danaview_pdf/android/src/main/kotlin/com/vecvel/danaview/pdf/compress/',
      ];
      const exportOutDir = 'packages/danaview_library_native/darwin/Classes/ExportOut/';
      for (final name in const ['danaview_library_native', 'danaview_pdf', 'danaview_face_tracking', 'danaview_media_analysis']) {
        final pkg = repo.package(name);
        if (pkg == null) continue;
        for (final file in _shippedSources(pkg, nativeExtensions)) {
          final withStrings = blankNonCode(file.source, blankStrings: false);
          for (final m in descriptorMode.allMatches(withStrings)) {
            if (m[1] != 'r') {
              report('${file.repoPath}:${_lineAt(withStrings, m.start)}', 'opens a source with mode "${m[1]}": sources are read-only (rule 27)');
            }
          }
          for (final m in randomAccessWrite.allMatches(withStrings)) {
            // The Android picker copier (HOM-20A) opens its OWN staging copy "rw" to resume a copy;
            // the picked source itself is read through a "r" descriptor, which stays checked above.
            if (file.repoPath == 'packages/danaview_library_native/android/src/main/kotlin/com/vecvel/danaview/library/pickers/PickerSupport.kt') continue;
            report('${file.repoPath}:${_lineAt(withStrings, m.start)}', 'opens a RandomAccessFile for writing: sources are read-only (rule 27)');
          }
          final code = blankNonCode(file.source, blankStrings: true);
          if (!file.repoPath.startsWith(exportOutDir)) {
            for (final m in writable.allMatches(code)) {
              report('${file.repoPath}:${_lineAt(code, m.start)}', 'opens for writing (`${m[0]!.trim()}`): sources are read-only (rule 27)');
            }
          }
          if (name == 'danaview_pdf' && !pdfToolDirs.any(file.repoPath.startsWith)) {
            for (final m in pdfWrite.allMatches(code)) {
              report('${file.repoPath}:${_lineAt(code, m.start)}',
                  'writes a PDF (`${m[0]!.trim()}`) outside the tool directories: viewers never write back (rule 27)');
            }
          }
        }
      }
    },
  ),
  RepoRule(
    '28',
    {'danaview_features', 'danaview_data'},
    'OpenNetworkConsent.accepted( only in danaview_features/lib/src/tools/speed_consent_sheet.dart',
    (repo, report) {
      final call = RegExp(r'(?<![A-Za-z0-9_$])OpenNetworkConsent\s*\.\s*accepted\b');
      // The declaration (`factory OpenNetworkConsent.accepted(…)` in danaview_data) creates nothing.
      final declaration = RegExp(r'(?<![A-Za-z0-9_$])factory\s+OpenNetworkConsent\s*\.\s*accepted\s*\(');
      for (final file in [...repo.allPackageLibFiles, ...repo.appLibFiles]) {
        if (file.repoPath == openNetworkConsentSite) continue;
        final code = blankNonCode(file.source, blankStrings: true)
            .replaceAllMapped(declaration, (m) => m[0]!.replaceAll(RegExp(r'[^\n]'), ' '));
        for (final m in call.allMatches(code)) {
          report('${file.repoPath}:${_lineAt(code, m.start)}', 'creates an OpenNetworkConsent: only $openNetworkConsentSite may (rule 28)');
        }
      }
    },
  ),
  RepoRule(
    '30',
    {...v12NewPackages, 'danaview_features', 'danaview_editor', 'danaview_editor_core'},
    'no 1.2.0 package or surface logs names, paths, document or OCR text, labels, landmarks, captions or queries',
    (repo, report) {
      final dartFiles = <DartFileView>[
        for (final name in v12NewPackages)
          if (repo.package(name) case final pkg?) ...pkg.dartFiles.where((f) => f.packagePath.startsWith('lib/')),
        ..._dartFilesUnder(repo, [...v12ScannedDirs, ...v12CoreDirs]),
      ];
      for (final file in dartFiles) {
        final code = blankNonCode(file.source, blankStrings: true);
        final withStrings = blankNonCode(file.source, blankStrings: false);
        for (final m in _logCall.allMatches(code)) {
          final open = m.end - 1;
          final close = _closingParen(code, open);
          if (close < 0) continue;
          final raw = withStrings.substring(open + 1, close).trim();
          if (v12LogFormatAllowList.contains(raw)) continue;
          final leftover = code.substring(open + 1, close).replaceAll(RegExp(r'''\br(?=['"])|['"\s,]'''), '');
          if (leftover.isNotEmpty || RegExp(r'\$[A-Za-z_{]').hasMatch(raw)) {
            report('${file.repoPath}:${_lineAt(code, m.start)}', 'logs `${_short(raw)}`: 1.2.0 code logs only string literals (rule 30)');
          }
        }
      }
      for (final name in v12NewPackages) {
        final pkg = repo.package(name);
        if (pkg == null) continue;
        for (final file in _shippedSources(pkg, nativeExtensions)) {
          final code = blankNonCode(file.source, blankStrings: true);
          final withStrings = blankNonCode(file.source, blankStrings: false);
          for (final m in _nativeLogCall.allMatches(code)) {
            final open = m.end - 1;
            final close = _closingParen(code, open);
            if (close < 0) continue;
            final raw = withStrings.substring(open + 1, close).trim();
            if (v12LogFormatAllowList.contains(raw)) continue;
            // Literals only: no Swift `\(…)` or Kotlin `$x` / `${…}` interpolation, no `+` concatenation
            // of a value. A leading tag constant (Kotlin `Log.d(TAG, "…")`) is allowed.
            final args = code.substring(open + 1, close).replaceFirst(RegExp(r'^\s*TAG\s*,'), '');
            final leftover = args.replaceAll(RegExp(r'''['"\s,]'''), '');
            if (leftover.isNotEmpty || raw.contains(r'\(') || RegExp(r'\$[A-Za-z_{]').hasMatch(raw)) {
              report('${file.repoPath}:${_lineAt(code, m.start)}', 'logs `${_short(raw)}`: 1.2.0 native code logs only string literals (rule 30)');
            }
          }
        }
      }
    },
  ),
  RepoRule(
    '31',
    {'danaview_documents', 'danaview_ai_ui', 'danaview_features', 'danaview_editor'},
    'no Material chrome in the 1.2.0 UI files (documents, AI UI, new Home and settings files, speed test, photo and beauty)',
    (repo, report) {
      final pattern = RegExp('(?<![A-Za-z0-9_\$])(${forbiddenMaterialNames.join('|')})(?![A-Za-z0-9_\$])');
      final files = <DartFileView>[
        for (final name in const ['danaview_documents', 'danaview_ai_ui'])
          if (repo.package(name) case final pkg?) ...pkg.dartFiles.where((f) => f.packagePath.startsWith('lib/')),
        ..._dartFilesUnder(repo, [...v12ScannedDirs, ...v12SpeedTestFiles]),
      ];
      for (final file in files) {
        final code = blankNonCode(file.source, blankStrings: true);
        for (final m in pattern.allMatches(code)) {
          report('${file.repoPath}:${_lineAt(code, m.start)}', 'Material chrome `${m[1]}` (ARCH v1.2 §1.4, rule 31); use the Danaview kit component');
        }
      }
    },
  ),
  RepoRule(
    'F',
    {'danaview_features', 'danaview_editor'},
    'the 1.2.0 flags are read only in each package\'s flags file (V2-04)',
    (repo, report) {
      final read = RegExp(r'''(?:bool|int|String)\s*\.\s*(?:fromEnvironment|hasEnvironment)\s*\(\s*['"](DANAVIEW_[A-Z_]+)['"]''');
      for (final file in [...repo.allPackageLibFiles, ...repo.appLibFiles]) {
        final code = blankNonCode(file.source, blankStrings: false);
        final allowed = v12FlagFiles[file.repoPath] ?? const <String>{};
        for (final m in read.allMatches(code)) {
          final flag = m[1]!;
          if (!v12Flags.contains(flag) || allowed.contains(flag)) continue;
          report('${file.repoPath}:${_lineAt(code, m.start)}', 'reads `$flag`: 1.2.0 flags are read only in the package flags file (V2-04)');
        }
      }
    },
  ),
];

String _short(String raw) => raw.length > 40 ? '${raw.substring(0, 40)}…' : raw;

/// The 1.2.0 fixtures in `test/architecture/fixtures/v12/` (see its README.md) and the exact rule
/// ids each must fire. Empty sets are positive controls.
const v12FixtureExpectations = <String, Set<String>>{
  'ok_v12_clean': <String>{},
  'r16_ai_depends_on_flutter': {'16'},
  'r18_search_opens_socket': {'18'},
  'r19_genkit_outside_genkit_package': {'19'},
  'r20_library_depends_on_flutter': {'20'},
  'r20_library_dart_io_outside_allowed': {'20'},
  'r21_plugin_depends_on_danaview_and_sockets': {'21'},
  'r21_face_tracking_downloads_model': {'21'},
  'r22_documents_depends_on_features_and_search': {'22'},
  'r23_features_imports_ai_and_pdf': {'23'},
  'r24_search_depends_on_flutter': {'24'},
  'r25_core_photo_imports_io': {'2', '25'},
  'r26_library_writes_outside_store': {'26'},
  'r27_plugin_opens_source_for_writing': {'27'},
  'r28_open_network_consent_outside_sheet': {'28'},
  'r29_editor_imports_library': {'29'},
  'r30_v12_logs_content': {'30'},
  'r31_v12_material_chrome': {'31'},
  'rF_flag_read_outside_flags_file': {'F'},
};

/// Exact violation counts of the 1.2.0 fixtures.
const v12FixtureViolationCounts = <String, int>{
  'r16_ai_depends_on_flutter': 3,
  'r18_search_opens_socket': 2,
  'r19_genkit_outside_genkit_package': 3,
  'r20_library_depends_on_flutter': 3,
  'r20_library_dart_io_outside_allowed': 1,
  'r21_plugin_depends_on_danaview_and_sockets': 4,
  'r21_face_tracking_downloads_model': 1,
  'r22_documents_depends_on_features_and_search': 5,
  'r23_features_imports_ai_and_pdf': 2,
  'r24_search_depends_on_flutter': 2,
  'r25_core_photo_imports_io': 2,
  'r26_library_writes_outside_store': 4,
  'r27_plugin_opens_source_for_writing': 4,
  'r28_open_network_consent_outside_sheet': 2,
  'r29_editor_imports_library': 2,
  'r30_v12_logs_content': 4,
  'r31_v12_material_chrome': 3,
  'rF_flag_read_outside_flags_file': 2,
};

/// Runs every rule (1–12, 14–16, 18–31, F and M) against [repo].
List<Violation> checkAll(RepoTree repo) => <Violation>[
      for (final rule in dependencyRules) ...rule.check(repo),
      for (final rule in repoRules) ...rule.check(repo),
      for (final rule in v12DependencyRules) ...rule.check(repo),
      for (final rule in v12RepoRules) ...rule.check(repo),
      ...materialRule.check(repo),
    ];

/// Reports widget library imports and widget classes in the package's lib/ (rules 6 and 10).
void _forbidWidgetCode(PackageView pkg, void Function(String location, String message) report) {
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
      report(file.repoPath, 'imports `$uri`: no widget code in ${pkg.name}');
    }
    if (widgetClass.hasMatch(blankNonCode(file.source, blankStrings: true))) {
      report(file.repoPath, 'declares a widget: no widget code in ${pkg.name}');
    }
  }
}

/// Reports manifest entries and imports naming a package in [forbidden], or (when [allowDanaview] is
/// given) any `danaview_*` package outside [allowDanaview] and the package itself.
void _forbidPackages(
  PackageView pkg,
  Set<String>? forbidden,
  void Function(String location, String message) report, {
  Set<String>? allowDanaview,
  bool Function(String name)? isForbidden,
  required String why,
}) {
  bool bad(String name) {
    if (name == pkg.name) return false;
    if (forbidden != null && forbidden.contains(name)) return true;
    if (isForbidden != null && isForbidden(name)) return true;
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

  /// The names of every `packages/<name>/` that has a manifest, sorted.
  List<String> get packageNames {
    final dir = Directory('${root.path}/packages');
    if (!dir.existsSync()) return const [];
    return [
      for (final d in dir.listSync().whereType<Directory>())
        if (hasPackage(_baseName(d.path))) _baseName(d.path),
    ]..sort();
  }

  /// The package at `packages/<name>/` when it has a manifest, else null.
  PackageView? package(String name) => _packages.putIfAbsent(name, () {
        final dir = Directory('${root.path}/packages/$name');
        final manifest = File('${dir.path}/pubspec.yaml$suffix');
        if (!manifest.existsSync()) return null;
        return PackageView._(this, name, dir, Pubspec.parse(manifest.readAsStringSync()));
      });

  /// The lib/ Dart files of every package.
  List<DartFileView> get allPackageLibFiles => [
        for (final name in packageNames) ...package(name)!.dartFiles.where((f) => f.packagePath.startsWith('lib/')),
      ];

  /// The Dart files of the app's own `lib/`.
  List<DartFileView> get appLibFiles {
    final dir = Directory('${root.path}/lib');
    if (!dir.existsSync()) return const [];
    return [
      for (final f in dir.listSync(recursive: true).whereType<File>().toList()..sort((a, b) => a.path.compareTo(b.path)))
        if (f.path.endsWith('.dart$suffix'))
          () {
            final rel = f.path.substring(root.path.length + 1).replaceAll(Platform.pathSeparator, '/');
            final path = rel.substring(0, rel.length - suffix.length);
            return DartFileView(path, path, f.readAsStringSync());
          }(),
    ];
  }

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
  List<DartFileView> get dartFiles => _files ??= [
        for (final (repoPath, packagePath, source) in _walk(const {'.dart'})) DartFileView(repoPath, packagePath, source),
      ];

  final Map<String, List<SourceFileView>> _sources = {};

  /// Every file of this package with one of [extensions] (`.swift`, `.kt`, …; 1.2.0 grep rules),
  /// with the same exclusions as [dartFiles].
  List<SourceFileView> sourceFiles(Set<String> extensions) => _sources.putIfAbsent(
        (extensions.toList()..sort()).join(','),
        () => [for (final (repoPath, packagePath, source) in _walk(extensions)) SourceFileView(repoPath, packagePath, source)],
      );

  List<(String, String, String)> _walk(Set<String> extensions) {
    final suffix = _repo.suffix;
    final out = <(String, String, String)>[];
    void walk(Directory d, String rel) {
      final entries = d.listSync(followLinks: false)..sort((a, b) => a.path.compareTo(b.path));
      for (final e in entries) {
        final base = _baseName(e.path);
        if (e is Directory) {
          if (base.startsWith('.') || _skippedDirs.contains(base)) continue;
          if (File('${e.path}/pubspec.yaml$suffix').existsSync()) continue;
          walk(e, '$rel$base/');
        } else if (e is File && base.endsWith(suffix)) {
          final name = base.substring(0, base.length - suffix.length);
          final dot = name.lastIndexOf('.');
          if (dot < 0 || !extensions.contains(name.substring(dot))) continue;
          out.add(('packages/${this.name}/$rel$name', '$rel$name', e.readAsStringSync()));
        }
      }
    }

    walk(dir, '');
    return out;
  }
}

/// One non-Dart source file (1.2.0 grep rules).
class SourceFileView {
  SourceFileView(this.repoPath, this.packagePath, this.source);

  /// Path relative to the repo root.
  final String repoPath;

  /// Path relative to the package root.
  final String packagePath;
  final String source;
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
