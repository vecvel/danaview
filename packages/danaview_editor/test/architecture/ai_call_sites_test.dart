// OWNER: AIS-01
//
// AI consent call sites (AI_STUDIO_PLAN §3.1 rule 13, replaced by ARCH v1.2 rule 17 / V2-20 /
// V2-23): `AiSendConsent.accepted(` may appear only in the one send view and
// `ProviderProbeConsent.accepted(` only in the provider sheet. The send view and the AI settings
// moved from danaview_editor to danaview_ai_ui (V2-20, which wins over the AIS plan's §3.2 paths),
// so no danaview_editor file may call either. Every lib/ and tool/ tree of the repo is scanned, plus
// danaview_editor's tests and integration tests. Comments and strings are ignored; tear-offs count.
// The fixtures in ai_fixtures/ prove each kind fires. AIS-43 moves this test next to the send view.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'arch_scan.dart';

const _package = 'packages/danaview_editor';

/// A consent kind, its only allowed call site and the files declaring it.
typedef AiConsentSite = ({String name, String callSite, String declaration});

/// ARCH v1.2 rule 17 (V2-20): the call sites; the declarations are AIS-08's consent files.
const List<AiConsentSite> aiConsents = [
  (
    name: 'AiSendConsent',
    callSite: 'packages/danaview_ai_ui/lib/src/ai_send_view.dart',
    declaration: 'packages/danaview_ai_providers/lib/src/consent/ai_send_consent.dart',
  ),
  (
    name: 'ProviderProbeConsent',
    callSite: 'packages/danaview_ai_ui/lib/src/settings/provider_sheet.dart',
    declaration: 'packages/danaview_ai_providers/lib/src/consent/provider_probe_consent.dart',
  ),
];

/// Uses of `<Consent>.accepted` in [source] (code only) outside each consent's allowed file.
List<Violation> aiConsentViolations(String path, String source) {
  final code = blankNonCode(source, blankStrings: true);
  final out = <Violation>[];
  for (final c in aiConsents) {
    if (path == c.callSite || path == c.declaration) continue;
    final pattern = RegExp('(?<![A-Za-z0-9_\$])${c.name}\\s*\\.\\s*accepted(?![A-Za-z0-9_\$])');
    for (final m in pattern.allMatches(code)) {
      final line = '\n'.allMatches(code.substring(0, m.start)).length + 1;
      out.add(Violation('13', '$path:$line', '${c.name}.accepted( may be called only in ${c.callSite} (ARCH v1.2 rule 17)'));
    }
  }
  return out;
}

/// Fixture -> (path the source pretends to live at, exact violation count).
const _fixtures = <String, (String, int)>{
  'call_outside.dart.fixture': ('$_package/lib/src/editor/flows/ai/ai_studio_controller.dart', 2),
  'tear_off.dart.fixture': ('$_package/lib/src/editor/flows/ai/ask_ai_controller.dart', 1),
  'comment_and_string.dart.fixture': ('$_package/lib/src/editor/flows/ai/ai_studio_sheet.dart', 0),
};

void main() {
  final root = findRepoRoot();
  String read(String rel) => File('${root.path}/$rel').readAsStringSync();
  String describe(List<Violation> v) => v.isEmpty ? 'no violations' : v.map((e) => '  $e').join('\n');
  String fixture(String name) => read('$_package/test/architecture/ai_fixtures/$name');

  group('rule 13/17: AI consent is accepted only in its view', () {
    test('no lib/ or tool/ file of the repo calls it outside the allowed sites', () {
      final packages = [
        for (final pkg in Directory('${root.path}/packages').listSync().whereType<Directory>())
          pkg.uri.pathSegments.where((s) => s.isNotEmpty).last,
      ];
      final files = <String>[
        ...dartFilesUnder(root, 'lib'),
        for (final p in packages) ...[...dartFilesUnder(root, 'packages/$p/lib'), ...dartFilesUnder(root, 'packages/$p/tool')],
      ];
      expect(files, contains('$_package/lib/src/editor/flows/ai/ai_studio_sheet.dart'));
      final violations = [for (final f in files) ...aiConsentViolations(f, read(f))];
      expect(violations, isEmpty, reason: describe(violations));
    });

    test('danaview_editor never accepts AI consent, not even in tests', () {
      final files = [
        ...dartFilesUnder(root, '$_package/lib'),
        ...dartFilesUnder(root, '$_package/test'),
        ...dartFilesUnder(root, '$_package/tool'),
        ...dartFilesUnder(root, '$_package/integration_test'),
      ];
      final violations = [for (final f in files) ...aiConsentViolations(f, read(f))];
      expect(violations, isEmpty, reason: describe(violations));
      for (final c in aiConsents) {
        expect(c.callSite, isNot(startsWith(_package)), reason: 'V2-20 moved ${c.name}\'s call site to danaview_ai_ui');
      }
    });

    test('the call sites are the ARCH v1.2 rule 17 paths', () {
      final arch = read('docs/v1.2/ARCHITECTURE.md');
      final rule17 = arch.split('\n').firstWhere((l) => l.startsWith('17. `AiSendConsent.accepted('));
      for (final c in aiConsents) {
        expect(rule17, contains('`${c.callSite}`'));
      }
    });
  });

  group('negative fixtures make rule 13/17 fire', () {
    test('every fixture file has an expectation and vice versa', () {
      final onDisk = dartFilesUnder(root, '$_package/test/architecture/ai_fixtures', suffix: '.fixture')
          .map((p) => p.substring('$_package/test/architecture/ai_fixtures/'.length))
          .toSet();
      expect(onDisk, _fixtures.keys.toSet());
    });

    _fixtures.forEach((name, spec) {
      final (path, count) = spec;
      test('$name -> $count violation(s)', () {
        final violations = aiConsentViolations(path, fixture(name));
        expect(violations, hasLength(count), reason: describe(violations));
      });
    });

    test('each consent kind is allowed only at its own site', () {
      final source = fixture('call_outside.dart.fixture');
      final atSendView = aiConsentViolations(aiConsents[0].callSite, source);
      expect(atSendView.map((v) => v.message), [contains('ProviderProbeConsent')]);
      final atSheet = aiConsentViolations(aiConsents[1].callSite, source);
      expect(atSheet.map((v) => v.message), [contains('AiSendConsent')]);
      expect(aiConsentViolations(aiConsents[0].declaration, 'const AiSendConsent.accepted(this.d);'), isEmpty);
    });
  });
}
