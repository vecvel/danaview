// OWNER: UX-01
// EXTENDED: AIS-01 (the 1.2.0 binding files of AI_STUDIO_PLAN §5.5 are merged too)
// EXTENDED: INT-101 (and the Still Photo Mode and Beauty binding files of the v1.2 BUILD_PLAN)
//
// D-33 skeleton coverage (BUILD_PLAN §2, UX-01): every danaview_editor path a ticket owns in
// BUILD_PLAN §6 exists from M0 (a placeholder until the owner lands), headers name the owning
// ticket, and every per-feature binding file is merged by wiring/action_bindings.dart.
// Per-feature copy files (`app/strings/<feature>_strings.dart`) and test directories are created by
// their owners and are not part of the skeleton.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/wiring/action_bindings.dart';

import 'arch_scan.dart';

const _package = 'packages/danaview_editor';
const _placeholderMark = 'Placeholder (D-33) created by UX-01.';

/// Owned path -> owner ticket, for every `packages/danaview_editor/{lib,tool,assets}` path in §6.
Map<String, String> _ownedEditorPaths(String plan) {
  final out = <String, String>{};
  String? ticket;
  var inOwns = false;
  for (final line in plan.split('\n')) {
    final heading = RegExp(r'^#### ([A-Z]+-\d+) ').firstMatch(line);
    if (heading != null) {
      ticket = heading[1];
      inOwns = false;
      continue;
    }
    if (line.startsWith('- **Owns:**')) {
      inOwns = true;
      continue;
    }
    if (line.startsWith('- **')) inOwns = false;
    final owned = RegExp(r'^  - `([^`]+)`').firstMatch(line);
    if (inOwns && ticket != null && owned != null) {
      final path = owned[1]!;
      if (RegExp('^$_package/(lib|tool|assets)/').hasMatch(path) && !path.contains('/lib/src/app/strings/')) {
        out[path] = ticket;
      }
    }
  }
  return out;
}

/// The binding files of the v1.2 BUILD_PLAN (owns lines use the `ED/` abbreviation), file -> owner,
/// plus `photo_bindings` (VED-01): INT-101 creates and merges it, the plan names no path for it.
Map<String, String> _v12BindingFiles(String plan) {
  final out = <String, String>{'photo_bindings': 'VED-01'};
  String? ticket;
  for (final line in plan.split('\n')) {
    final heading = RegExp(r'^#### ([A-Z]+-\d+A?) ').firstMatch(line);
    if (heading != null) ticket = heading[1];
    if (ticket == null || !line.startsWith('- **Owns')) continue;
    for (final m in RegExp(r'`ED/editor/actions/bindings/(\w+)\.dart`').allMatches(line)) {
      out[m[1]!] = ticket;
    }
  }
  return out;
}

String? _ownerHeader(String source) => RegExp(r'^(?://|#|<!--) OWNER: ([A-Z]+-\d+)').firstMatch(source)?[1];

void main() {
  final root = findRepoRoot();
  final plan = File('${root.path}/docs/v1.1/editor/BUILD_PLAN.md').readAsStringSync();
  final owned = _ownedEditorPaths(plan);
  String read(String rel) => File('${root.path}/$rel').readAsStringSync();

  test('BUILD_PLAN §6 names the danaview_editor skeleton (sanity)', () {
    expect(owned.length, greaterThan(120));
    expect(owned['$_package/lib/src/app/editor_availability.dart'], 'UX-01');
    expect(owned['$_package/lib/src/editor/editor_screen.dart'], 'UX-07');
    expect(owned['$_package/lib/src/app/adapters/'], 'INT-04');
  });

  test('every owned file exists; headers name the owner', () {
    final problems = <String>[];
    owned.forEach((path, ticket) {
      if (path.endsWith('/')) return;
      final file = File('${root.path}/$path');
      if (!file.existsSync()) {
        problems.add('$path ($ticket) is missing');
        return;
      }
      final source = file.readAsStringSync();
      final header = _ownerHeader(source);
      if (source.contains(_placeholderMark) && header != ticket) problems.add('$path: placeholder header names $header, not $ticket');
      if (header != null && header != ticket) problems.add('$path: OWNER $header, BUILD_PLAN says $ticket');
    });
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  test('every owned directory exists with files whose headers name the owner', () {
    final problems = <String>[];
    owned.forEach((path, ticket) {
      if (!path.endsWith('/')) return;
      final dir = Directory('${root.path}/$path');
      if (!dir.existsSync()) {
        problems.add('$path ($ticket) is missing');
        return;
      }
      final files = dir.listSync(recursive: true).whereType<File>().toList();
      if (files.isEmpty) problems.add('$path ($ticket) is empty');
      for (final f in files) {
        // Generated binaries (assets/looks/*.vlut, UX-24) carry no header.
        if (f.path.endsWith('.vlut')) continue;
        final header = _ownerHeader(f.readAsStringSync());
        if (header != null && header != ticket) problems.add('${f.path}: OWNER $header, BUILD_PLAN says $ticket');
      }
    });
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  test('every remaining placeholder names a BUILD_PLAN ticket that owns it', () {
    final problems = <String>[];
    for (final path in dartFilesUnder(root, '$_package/lib')) {
      final source = read(path);
      if (!source.contains(_placeholderMark)) continue;
      final header = _ownerHeader(source);
      final owner =
          owned[path] ?? owned.entries.where((e) => e.key.endsWith('/') && path.startsWith(e.key)).map((e) => e.value).firstOrNull;
      if (header == null || header != owner) problems.add('$path: header $header, owner $owner');
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  test('every per-feature binding file is merged by wiring/action_bindings.dart', () {
    final aisOwned = _ownedEditorPaths(File('${root.path}/docs/v1.2/ai-studio/AI_STUDIO_PLAN.md').readAsStringSync());
    final planned = {
      for (final e in [...owned.entries, ...aisOwned.entries])
        if (e.key.contains('/actions/bindings/')) e.key.split('/').last.replaceAll('.dart', ''): e.value,
      // 1.2.0 VED binding files (v1.2 BUILD_PLAN; INT-101 merges them).
      ..._v12BindingFiles(File('${root.path}/docs/v1.2/BUILD_PLAN.md').readAsStringSync()),
    };
    final onDisk = Directory('${root.path}/$_package/lib/src/editor/actions/bindings')
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last.replaceAll('.dart', ''))
        .toSet();
    final wired = {for (final s in editorBindingSources) s.file: s.owner};
    expect(planned, hasLength(22 + 7 + 2));
    expect(onDisk, planned.keys.toSet());
    expect(wired, planned);
  });

  test('the merged bindings are consistent (no id bound twice)', () {
    expect(mergeEditorActionBindings, returnsNormally);
  });

  test('assets/looks/ is declared in the pubspec and danaview_editor_fonts exists', () {
    expect(read('$_package/pubspec.yaml'), contains('    - assets/looks/'));
    expect(File('${root.path}/$_package/assets/looks/README.md').existsSync(), isTrue);
    final fonts = read('packages/danaview_editor_fonts/pubspec.yaml');
    expect(fonts, contains('name: danaview_editor_fonts'));
    expect(_ownerHeader(fonts), 'UX-30');
  });
}
