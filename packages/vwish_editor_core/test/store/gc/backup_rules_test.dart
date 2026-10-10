// OWNER: CORE-28
//
// Android backup rules (ARCH §8.1, D-43 f): the editor and speech trees under `files/` are
// excluded from Auto Backup (API ≤ 30) and from cloud backup and device transfer (API 31+); the
// player's data stays included; the manifest references both rule files. The device check is the
// `bmgr` procedure in README.md (V-A7, QA-10).

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

const _expected = [('exclude', 'file', 'vwish/editor'), ('exclude', 'file', 'vwish/speech')];

void main() {
  test('API 31+: cloud backup and device transfer exclude exactly the editor and speech trees', () {
    final xml = _read('res/xml/vwish_data_extraction_rules.xml');
    expect(xml, contains('<data-extraction-rules>'));
    for (final section in ['cloud-backup', 'device-transfer']) {
      expect(_rules(_section(xml, section)), _expected, reason: section);
    }
    expect(_rules(xml), hasLength(4), reason: 'no include rules (everything else stays included)');
  });

  test('API ≤ 30: full-backup-content excludes the same trees', () {
    final xml = _read('res/xml/vwish_backup_rules.xml');
    expect(xml, contains('<full-backup-content>'));
    expect(_rules(xml), _expected);
  });

  test('the manifest references both rule files on <application>', () {
    final manifest = _read('AndroidManifest.xml');
    final app = RegExp(r'<application\b[^>]*>', dotAll: true).firstMatch(manifest)![0]!;
    expect(app, contains('android:dataExtractionRules="@xml/vwish_data_extraction_rules"'));
    expect(app, contains('android:fullBackupContent="@xml/vwish_backup_rules"'));
    expect(app, isNot(contains('android:allowBackup="false"')), reason: 'the player data stays backed up');
  });
}
