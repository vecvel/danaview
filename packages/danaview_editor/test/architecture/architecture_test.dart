// OWNER: UX-01
//
// danaview_editor architecture rules:
// * ARCH §1.3 rule 1: no Material chrome in lib/ (and tool/), whole-identifier matching in code.
// * ARCH §4.2 rule 8: `UserConsent.accepted(` only in flows/captions/model_consent_view.dart, checked
//   over every lib/ tree of the repo.
// * ARCH §4.2 rule 7: the manifest and every Dart file of the package use the engine API only (never
//   the plugin), no router, and danaview_features only through chrome/orientation/storage.dart.
// Each rule is proven to fire by the fixtures in fixtures/ (see its README.md).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'arch_scan.dart';

const _package = 'packages/danaview_editor';

/// Fixture -> (scanner, path the source pretends to live at, exact violation count).
final _fixtures = <String, (List<Violation> Function(String path, String source), String, int)>{
  'material/text_field_direct.dart.fixture': (materialViolations, '$_package/lib/src/x.dart', 5),
  'material/wrappers_pass.dart.fixture': (materialViolations, '$_package/lib/src/x.dart', 0),
  'material/in_interpolation.dart.fixture': (materialViolations, '$_package/lib/src/x.dart', 1),
  'consent/call_outside.dart.fixture': (consentViolations, '$_package/lib/src/editor/flows/captions/auto_captions_controller.dart', 1),
  'consent/tear_off.dart.fixture': (consentViolations, '$_package/lib/src/editor/flows/captions/auto_captions_sheet.dart', 1),
  'consent/comment_and_string.dart.fixture': (consentViolations, '$_package/lib/src/editor/flows/captions/language_picker.dart', 0),
  'rule7/imports_forbidden.dart.fixture': (importViolations, '$_package/lib/src/x.dart', 6),
  'rule7/imports_allowed.dart.fixture': (importViolations, '$_package/lib/src/x.dart', 0),
  'rule7/pubspec_plugin.yaml.fixture': (pubspecViolations, '$_package/pubspec.yaml', 3),
};

void main() {
  final root = findRepoRoot();
  String read(String rel) => File('${root.path}/$rel').readAsStringSync();
  String describe(List<Violation> v) => v.isEmpty ? 'no violations' : v.map((e) => '  $e').join('\n');

  group('ARCH §1.3: no Material chrome in danaview_editor', () {
    test('lib/ and tool/ have zero forbidden Material names', () {
      final files = [...dartFilesUnder(root, '$_package/lib'), ...dartFilesUnder(root, '$_package/tool')];
      expect(files, isNotEmpty);
      final violations = [for (final f in files) ...materialViolations(f, read(f))];
      expect(violations, isEmpty, reason: describe(violations));
    });

    test('the forbidden list is the ARCH §1.3 list', () {
      final arch = read('docs/v1.1/editor/ARCHITECTURE.md');
      final ruleLine = arch.split('\n').firstWhere((l) => l.startsWith('1. Custom components only.'));
      final named = RegExp(r'`([A-Za-z]+)`').allMatches(ruleLine.split('Architecture tests').first).map((m) => m[1]!).toSet();
      expect(forbiddenMaterialNames.toSet(), named);
    });
  });

  group('ARCH §4.2 rule 8: UserConsent.accepted( call site', () {
    test('no lib/ file of the repo calls it outside the consent view', () {
      final files = <String>[
        ...dartFilesUnder(root, 'lib'),
        for (final pkg in Directory('${root.path}/packages').listSync().whereType<Directory>())
          ...dartFilesUnder(root, 'packages/${pkg.uri.pathSegments.where((s) => s.isNotEmpty).last}/lib'),
      ];
      expect(files, contains(consentCallSite));
      final violations = [for (final f in files) ...consentViolations(f, read(f))];
      expect(violations, isEmpty, reason: describe(violations));
    });

    test('danaview_editor tests and tools do not construct consent either', () {
      final files = [
        ...dartFilesUnder(root, '$_package/test'),
        ...dartFilesUnder(root, '$_package/tool'),
        ...dartFilesUnder(root, '$_package/integration_test'),
      ];
      final violations = [for (final f in files) ...consentViolations(f, read(f))];
      expect(violations, isEmpty, reason: describe(violations));
    });

    test('the allowed call site itself is not reported', () {
      expect(consentViolations(consentCallSite, read('$_package/test/architecture/fixtures/consent/call_outside.dart.fixture')), isEmpty);
    });
  });

  group('ARCH §4.2 rule 7: dependencies of danaview_editor', () {
    test('pubspec: engine API only, no router, only the planned danaview packages', () {
      final violations = pubspecViolations('$_package/pubspec.yaml', read('$_package/pubspec.yaml'));
      expect(violations, isEmpty, reason: describe(violations));
    });

    test('pubspec declares every planned dependency (BUILD_PLAN UX-01)', () {
      final sections = readPubspecSections(read('$_package/pubspec.yaml'));
      expect(sections['dependencies'], containsAll(<String>['flutter', 'flutter_riverpod', ...allowedDanaviewDependencies]));
      expect(sections['dev_dependencies'], containsAll(<String>['flutter_test', 'integration_test']));
      expect(sections['dependency_overrides'], isEmpty);
    });

    test('every Dart file imports danaview_features only through its entry points and never the plugin', () {
      final files = [
        ...dartFilesUnder(root, '$_package/lib'),
        ...dartFilesUnder(root, '$_package/test'),
        ...dartFilesUnder(root, '$_package/tool'),
        ...dartFilesUnder(root, '$_package/integration_test'),
      ];
      final violations = [for (final f in files) ...importViolations(f, read(f))];
      expect(violations, isEmpty, reason: describe(violations));
    });
  });

  group('negative fixtures make each rule fire', () {
    test('every fixture file has an expectation and vice versa', () {
      final onDisk = dartFilesUnder(root, '$_package/test/architecture/fixtures', suffix: '.fixture')
          .map((p) => p.substring('$_package/test/architecture/fixtures/'.length))
          .toSet();
      expect(onDisk, _fixtures.keys.toSet());
    });

    test('every rule has a firing fixture and a passing look-alike', () {
      final byRule = <List<Violation> Function(String, String), Set<int>>{};
      _fixtures.forEach((_, spec) => (byRule[spec.$1] ??= <int>{}).add(spec.$3));
      for (final scanner in [materialViolations, consentViolations, importViolations]) {
        expect(byRule[scanner]!.any((n) => n > 0), isTrue);
        expect(byRule[scanner]!.contains(0), isTrue);
      }
    });

    _fixtures.forEach((fixture, spec) {
      final (scan, pretendPath, count) = spec;
      test('$fixture -> $count violation(s)', () {
        final violations = scan(pretendPath, read('$_package/test/architecture/fixtures/$fixture'));
        expect(violations, hasLength(count), reason: describe(violations));
      });
    });

    test('TextField used directly fires while DanaviewTextField passes', () {
      expect(materialViolations('x.dart', 'final a = TextField();'), hasLength(1));
      expect(materialViolations('x.dart', 'final a = DanaviewTextField();'), isEmpty);
      expect(materialViolations('x.dart', 'final a = TextFieldTheme.of(c); // TextField'), isEmpty);
    });
  });
}
