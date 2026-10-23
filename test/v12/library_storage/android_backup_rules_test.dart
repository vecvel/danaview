// OWNER: D-3 (Windows lane)
//
// Android manifest permissions and backup rules for the Danaview library (S2-QA D-3; ARCH v1.2
// V2-115 and §5.2, owner decision 2026-10-22). The library root on Android is `files/library`
// (`libraryRootIn(filesDir, LibraryRootStyle.android)`):
// - API 31+ (`data-extraction-rules`): out of Google's cloud backup, kept in device-to-device
//   transfer except the unfinished import part files under `library/imports`;
// - API ≤ 30 (`full-backup-content`, which can't tell cloud from transfer): left out entirely;
// - the Photos tab permissions: READ_MEDIA_IMAGES/VIDEO (13+), READ_MEDIA_VISUAL_USER_SELECTED (14+),
//   READ_EXTERNAL_STORAGE only up to API 32; no ACCESS_MEDIA_LOCATION and no write permission in the app
//   manifest (the editor engine's plugin manifest still merges its WRITE_EXTERNAL_STORAGE ≤ 28).
// CORE-28's packages/danaview_editor_core/test/store/gc/backup_rules_test.dart keeps the full list.

import 'dart:io';

import 'package:danaview_library/danaview_library.dart';
import 'package:flutter_test/flutter_test.dart';

/// Relative to the app root, where `flutter test` runs (forward slashes work on every host).
String _read(String rel) => File('android/app/src/main/$rel').readAsStringSync();

/// XML comments removed, so a commented-out rule never counts.
String _strip(String xml) => xml.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

/// `<exclude …/>` / `<include …/>` elements with domain `file` as (tag, path).
List<(String, String)> _fileRules(String xml) => [
      for (final m in RegExp(r'<(exclude|include)\s+domain="file"\s+path="([^"]*)"\s*/>').allMatches(_strip(xml)))
        (m[1]!, m[2]!),
    ];

String _section(String xml, String tag) {
  final m = RegExp('<$tag>(.*?)</$tag>', dotAll: true).firstMatch(_strip(xml));
  expect(m, isNotNull, reason: 'missing <$tag>');
  return m![1]!;
}

List<(String, String)> _libraryRules(String xml) =>
    [for (final r in _fileRules(xml)) if (r.$2 == 'library' || r.$2.startsWith('library/')) r];

/// `<uses-permission android:name="…" …/>` → its attributes, by permission name.
Map<String, String> _permissions(String manifest) => {
      for (final m in RegExp(r'<uses-permission\s+([^>]*?)/?>').allMatches(_strip(manifest)))
        RegExp(r'android:name="([^"]+)"').firstMatch(m[1]!)![1]!: m[1]!,
    };

void main() {
  test('the library root on Android is files/library, the path the rules name', () {
    // The host separator joins it (a backslash on a Windows host); the device uses '/'.
    final root = libraryRootIn('/data/user/0/app/files', LibraryRootStyle.android).replaceAll(r'\', '/');
    expect(root, '/data/user/0/app/files/library');
  });

  test('API 31+: library out of cloud backup, in device transfer except imports/', () {
    final xml = _read('res/xml/danaview_data_extraction_rules.xml');
    expect(_libraryRules(_section(xml, 'cloud-backup')), [('exclude', 'library')]);
    expect(_libraryRules(_section(xml, 'device-transfer')), [('exclude', 'library/imports')]);
    expect(_fileRules(xml).where((r) => r.$1 == 'include'), isEmpty, reason: 'no include rules: everything else stays');
  });

  test('API ≤ 30: the whole library is left out of Auto Backup', () {
    final xml = _read('res/xml/danaview_backup_rules.xml');
    expect(xml, contains('<full-backup-content>'));
    expect(_libraryRules(xml), [('exclude', 'library')]);
  });

  test('the rule files carry the D-3 marker', () {
    for (final f in [
      'AndroidManifest.xml',
      'res/xml/danaview_data_extraction_rules.xml',
      'res/xml/danaview_backup_rules.xml',
    ]) {
      expect(_read(f), contains('EXTENDED: D-3, Windows lane'), reason: f);
    }
  });

  test('manifest: Photos tab permissions, no location or write permission', () {
    final perms = _permissions(_read('AndroidManifest.xml'));
    for (final name in [
      'android.permission.READ_MEDIA_IMAGES',
      'android.permission.READ_MEDIA_VIDEO',
      'android.permission.READ_MEDIA_VISUAL_USER_SELECTED',
    ]) {
      expect(perms.keys, contains(name));
      expect(perms[name], isNot(contains('maxSdkVersion')), reason: name);
    }
    expect(perms['android.permission.READ_EXTERNAL_STORAGE'], contains('android:maxSdkVersion="32"'));
    expect(perms.keys, isNot(contains('android.permission.ACCESS_MEDIA_LOCATION')), reason: 'owner: no GPS on Android');
    expect(perms.keys, isNot(contains('android.permission.WRITE_EXTERNAL_STORAGE')), reason: "save out uses MediaStore / SAF (the editor engine's plugin manifest keeps its own WRITE_EXTERNAL_STORAGE ≤ 28)");
    expect(perms.keys, isNot(contains('android.permission.MANAGE_EXTERNAL_STORAGE')));
  });
}
