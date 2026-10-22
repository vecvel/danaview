// OWNER: HOM-02
//
// The frozen surface of danaview_library_native (BUILD_PLAN HOM-02, ARCH v1.2 V2-25): the Pigeon
// file declares exactly the planned APIs, the Apple glue routes each to its class, every
// placeholder of a later ticket carries that ticket's OWNER header and answers
// notSupportedOnDevice in every method, the PhotoLibrary core stays Flutter-free, and nothing in
// the plugin opens a socket (rule 21; the repo-wide check is test/architecture at the root).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _hostApis = [
  'PhotoLibraryHostApi',
  'PickerHostApi',
  'ThumbnailHostApi',
  'ExportOutHostApi',
  'ShareHostApi',
  'OpenInHostApi',
  'QuickLookHostApi',
  'InboxHostApi',
  'IncomingHostApi',
  'BackupFlagHostApi',
];

/// Placeholder classes of later tickets that have not landed yet: file → owner. Pickers (HOM-20),
/// Thumbnails (HOM-04) and ExportOut / Share / OpenIn (HOM-22) are implemented and left this
/// list; their own tests cover them.
const _placeholders = {
  'darwin/Classes/QuickLook/QuickLookHostApiImpl.swift': 'HOM-26',
  'darwin/Classes/Inbox/InboxHostApiImpl.swift': 'HOM-21',
};

final _socket = RegExp(
  r'(?<![A-Za-z0-9_$])(?:HttpClient\s*\(|(?:Raw)?(?:Secure)?Socket\s*\.\s*connect\b|WebSocket\s*\.\s*connect\b|HttpURLConnection\b|URLSession\b|NWConnection\b|OkHttpClient\b|java\.net\.Socket\b|CFStreamCreatePairWithSocketToHost\b)',
);

List<File> _files(String dir, Set<String> extensions) => Directory(dir).existsSync()
    ? (Directory(dir).listSync(recursive: true).whereType<File>().where((f) => extensions.any(f.path.endsWith)).toList()
      ..sort((a, b) => a.path.compareTo(b.path)))
    : <File>[];

void main() {
  final pigeon = File('pigeons/library_api.dart').readAsStringSync();

  test('the Pigeon file declares exactly the planned APIs and is marked frozen', () {
    final declared = RegExp(r'@HostApi\(\)\s*abstract class (\w+)').allMatches(pigeon).map((m) => m[1]).toList();
    expect(declared, _hostApis);
    expect(RegExp(r'@EventChannelApi\(\)\s*abstract class LibraryEventsApi').hasMatch(pigeon), isTrue);
    expect(pigeon, contains('FROZEN'));
    expect(pigeon, startsWith('// OWNER: HOM-02'));
  });

  test('generated Dart, Swift and Kotlin are committed', () {
    for (final path in [
      'lib/src/pigeon/library_api.g.dart',
      'darwin/Classes/Glue/LibraryApi.g.swift',
      'android/src/main/kotlin/com/vecvel/danaview/library/pigeon/LibraryApi.g.kt',
    ]) {
      expect(File(path).existsSync(), isTrue, reason: path);
      final text = File(path).readAsStringSync();
      for (final api in _hostApis) {
        expect(text, contains(api), reason: '$path lacks $api');
      }
    }
  });

  test('the Apple glue sets up every host API and the event stream', () {
    final glue = File('darwin/Classes/Glue/DanaviewLibraryNativePlugin.swift').readAsStringSync();
    for (final api in _hostApis) {
      expect(glue, contains('${api}Setup.setUp('), reason: api);
      final impl = '${api}Impl';
      expect(glue, contains('$impl(context: context)'), reason: impl);
      final defined = _files('darwin/Classes', {'.swift'}).where((f) => f.readAsStringSync().contains('final class $impl: $api'));
      expect(defined, hasLength(1), reason: '$impl is defined once');
    }
    expect(glue, contains('LibraryEventsStreamHandler.register('));
  });

  test('every placeholder carries its owner and answers notSupportedOnDevice everywhere', () {
    for (final entry in _placeholders.entries) {
      final text = File(entry.key).readAsStringSync();
      expect(text, startsWith('// OWNER: ${entry.value}\n'), reason: entry.key);
      final methods = RegExp(r'^  func ', multiLine: true).allMatches(text).length;
      final answers = RegExp(r'LibraryErrors\.notSupported\(').allMatches(text).length;
      expect(methods, greaterThan(0), reason: entry.key);
      expect(answers, methods, reason: '${entry.key}: every method answers notSupportedOnDevice');
    }
    final thumbs = File('darwin/Classes/Thumbnails/ThumbnailHostApiImpl.swift').readAsStringSync();
    expect(
      RegExp(r'func documentThumbnail\([^{]*\{\s*completion\(\.failure\(LibraryErrors\.notSupported\(').hasMatch(thumbs),
      isTrue,
      reason: 'documentThumbnail answers notSupportedOnDevice until HOM-26 lands',
    );
    final incoming = File('darwin/Classes/Glue/IncomingHostApiImpl.swift').readAsStringSync();
    expect(RegExp(r'LibraryErrors\.notSupported\(').allMatches(incoming), hasLength(2), reason: 'Android only');
  });

  test('every native source carries an OWNER header (D-33)', () {
    for (final f in _files('darwin', {'.swift', '.podspec', '.sh'})) {
      if (f.path.endsWith('.g.swift')) continue;
      final head = f.readAsLinesSync().take(3).join('\n');
      expect(RegExp(r'(//|#) OWNER: [A-Z]+-\d+A?').hasMatch(head), isTrue, reason: f.path);
    }
  });

  test('the PhotoLibrary core is Flutter-free (XCTest runs it without an app host)', () {
    for (final f in _files('darwin/Classes/PhotoLibrary', {'.swift'})) {
      expect(f.readAsStringSync(), isNot(matches(RegExp(r'^import Flutter', multiLine: true))), reason: f.path);
    }
  });

  test('no socket API in the plugin (rule 21)', () {
    final offenders = <String>[];
    for (final f in [..._files('lib', {'.dart'}), ..._files('darwin', {'.swift', '.m', '.h'}), ..._files('android/src', {'.kt', '.java'})]) {
      final text = f.readAsStringSync();
      for (final m in _socket.allMatches(text)) {
        offenders.add('${f.path}: ${m[0]}');
      }
    }
    expect(offenders, isEmpty);
  });

  test('PhotoKit never uses the network (ARCH §9.1)', () {
    final service = File('darwin/Classes/PhotoLibrary/PhotoLibraryService.swift').readAsStringSync();
    expect(service, isNot(contains('isNetworkAccessAllowed = true')));
    expect(RegExp('isNetworkAccessAllowed = false').allMatches(service).length, greaterThanOrEqualTo(2));
  });
}
