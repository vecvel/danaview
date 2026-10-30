// OWNER: CORE-28
//
// Android backup rules (ARCH §8.1, D-43 f): the editor and speech trees under `files/` are
// excluded from Auto Backup (API ≤ 30) and from cloud backup and device transfer (API 31+); the
// player's data stays included; the manifest references both rule files. The device check is the
// `bmgr` procedure in README.md (V-A7, QA-10).
//
// EXTENDED: D-3, Windows lane (ARCH V2-115, owner 2026-10-22): the Danaview library
// (`files/library`) leaves cloud backup and Auto Backup on API ≤ 30, and stays in device transfer
// except its import part files (`files/library/imports`). The library rules have their own test,
// test/v12/library_storage/android_backup_rules_test.dart at the app root.
//
// EXTENDED: S4-W (the PDF sign tool's saved signatures, `files/signatures`, are in no backup and no
// device transfer: HOM-30 / HOM-30A and the S4 privacy text; checked again by
// test/v12/legal/s4_pdf_tools_text_test.dart at the app root.)

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final String _android = p.normalize(p.join(Directory.current.path, '..', '..', 'android', 'app', 'src', 'main'));

String _read(String rel) => File(p.join(_android, rel)).readAsStringSync();

/// `<exclude …/>` and `<include …/>` elements of [xml] (or of one section) as (tag, domain, path).
List<(String, String, String)> _rules(String xml) => [
      for (final m in RegExp(r'<(exclude|include)\s+domain="([^"]+)"\s+path="([^"]*)"\s*/>').allMatches(xml)) (m[1]!, m[2]!, m[3]!),
    ];

String _section(String xml, String tag) {
  final m = RegExp('<$tag>(.*?)</$tag>', dotAll: true).firstMatch(xml);
  expect(m, isNotNull, reason: 'missing <$tag>');
  return m![1]!;
}

const _editor = [('exclude', 'file', 'danaview/editor'), ('exclude', 'file', 'danaview/speech')];

const _signatures = ('exclude', 'file', 'signatures');

const _expected = {
  'cloud-backup': [..._editor, ('exclude', 'file', 'library'), _signatures],
  'device-transfer': [..._editor, ('exclude', 'file', 'library/imports'), _signatures],
  'full-backup-content': [..._editor, ('exclude', 'file', 'library'), _signatures],
};

void main() {
  test('API 31+: cloud backup and device transfer exclude exactly the editor and speech trees (+ D-3 library rules)', () {
    final xml = _read('res/xml/danaview_data_extraction_rules.xml');
    expect(xml, contains('<data-extraction-rules>'));
    for (final section in ['cloud-backup', 'device-transfer']) {
      expect(_rules(_section(xml, section)), _expected[section], reason: section);
    }
    expect(_rules(xml), hasLength(8), reason: 'no include rules (everything else stays included)');
  });

  test('API ≤ 30: full-backup-content excludes the same trees (+ D-3: the whole library)', () {
    final xml = _read('res/xml/danaview_backup_rules.xml');
    expect(xml, contains('<full-backup-content>'));
    expect(_rules(xml), _expected['full-backup-content']);
  });

  test('the manifest references both rule files on <application>', () {
    final manifest = _read('AndroidManifest.xml');
    final app = RegExp(r'<application\b[^>]*>', dotAll: true).firstMatch(manifest)![0]!;
    expect(app, contains('android:dataExtractionRules="@xml/danaview_data_extraction_rules"'));
    expect(app, contains('android:fullBackupContent="@xml/danaview_backup_rules"'));
    expect(app, isNot(contains('android:allowBackup="false"')), reason: 'the player data stays backed up');
  });
}
