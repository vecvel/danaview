// OWNER: HOM-24
// EXTENDED: HOM-28 (the lead-approved PdfOrganiseHostApi amendment is declared and routed; the page
// tools are no longer placeholders: they advertise their tools and the core is Flutter-free.)
//
// The frozen danaview_pdf surface (BUILD_PLAN HOM-24, ARCH v1.2 V2-25), checked from here because
// HOM-24 owns no test directory inside packages/danaview_pdf: the Pigeon file declares exactly the
// planned APIs and is marked frozen, the committed Dart / Swift / Kotlin output equals a fresh
// Pigeon run, the Apple glue routes every API and the platform view, every tool placeholder carries
// its ticket's OWNER header and answers notSupportedOnDevice, the cores stay Flutter-free, and
// nothing in the plugin opens a socket (rule 21).

@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _pkg = '../danaview_pdf';

const _hostApis = ['PdfDocumentHostApi', 'PdfViewHostApi', 'PdfTextHostApi', 'PdfToolsHostApi'];

/// Host APIs added by lead-approved [INTEGRATION] amendments, each in its own block: API → owner.
/// They are served by an existing Impl (an extension), so only their setUp is checked.
const _amendmentApis = {'PdfOrganiseHostApi': 'HOM-28'};

const _outputs = [
  'lib/src/pigeon/pdf_api.g.dart',
  'darwin/Classes/Glue/PdfApi.g.swift',
  'android/src/main/kotlin/com/vecvel/danaview/pdf/pigeon/PdfApi.g.kt',
];

/// Tool placeholders of later tickets: file → owner.
const _placeholders = {
  'darwin/Classes/Annotate/PdfAnnotator.swift': 'HOM-29',
  'darwin/Classes/Sign/PdfSigner.swift': 'HOM-30',
  'darwin/Classes/Compress/PdfCompressor.swift': 'HOM-31',
};

final _socket = RegExp(
  r'(?<![A-Za-z0-9_$])(?:HttpClient\s*\(|(?:Raw)?(?:Secure)?Socket\s*\.\s*connect\b|WebSocket\s*\.\s*connect\b|HttpURLConnection\b|URLSession\b|NWConnection\b|OkHttpClient\b|java\.net\.Socket\b|CFStreamCreatePairWithSocketToHost\b)',
);

File _f(String path) => File('$_pkg/$path');

List<File> _files(String dir, Set<String> extensions) {
  final d = Directory('$_pkg/$dir');
  if (!d.existsSync()) return <File>[];
  return d.listSync(recursive: true).whereType<File>().where((f) => extensions.any(f.path.endsWith)).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}

String _dartExecutable() {
  final candidates = <String>[
    if (Platform.environment['FLUTTER_ROOT'] case final root?) '$root/bin/dart',
  ];
  var dir = File(Platform.resolvedExecutable).parent;
  for (var i = 0; i < 6; i++) {
    candidates.add('${dir.path}/bin/dart');
    dir = dir.parent;
  }
  for (final c in candidates) {
    if (File(c).existsSync()) return c;
  }
  return 'dart';
}

String _pigeonEntryPoint(File packageConfig) {
  final config = jsonDecode(packageConfig.readAsStringSync()) as Map<String, Object?>;
  final packages = (config['packages']! as List<Object?>).cast<Map<String, Object?>>();
  final pigeon = packages.firstWhere((p) => p['name'] == 'pigeon');
  final rootUri = pigeon['rootUri']! as String;
  final root = packageConfig.uri.resolve(rootUri.endsWith('/') ? rootUri : '$rootUri/');
  return File.fromUri(root.resolve('bin/pigeon.dart')).path;
}

void main() {
  final pigeon = _f('pigeons/pdf_api.dart').readAsStringSync();

  test('the Pigeon file declares exactly the planned APIs and is marked frozen', () {
    final declared = RegExp(r'@HostApi\(\)\s*abstract class (\w+)').allMatches(pigeon).map((m) => m[1]).toList();
    expect(declared, [..._hostApis, ..._amendmentApis.keys]);
    for (final entry in _amendmentApis.entries) {
      expect(pigeon, contains('${entry.value} amendment [INTEGRATION]'), reason: '${entry.key} sits in its marked block');
    }
    expect(RegExp(r'@EventChannelApi\(\)\s*abstract class PdfEventsApi').hasMatch(pigeon), isTrue);
    expect(pigeon, startsWith('// OWNER: HOM-24'));
    expect(pigeon, contains('FROZEN'));
    for (final method in [
      'probe',
      'open',
      'unlock',
      'outline',
      'close',
      'goToPage',
      'setScale',
      'search',
      'showSearchHit',
      'selectedText',
      'copySelection',
      'pageThumbnail',
      'createTextureView',
      'setTextureViewport',
      'extractText',
      'merge',
      'split',
      'reorder',
      'rotate',
      'deletePages',
      'annotate',
      'sign',
      'compress',
      'cancel',
      'organise',
    ]) {
      expect(RegExp('\\b$method\\(').hasMatch(pigeon), isTrue, reason: method);
    }
  });

  test('generated Dart, Swift and Kotlin are committed and name every API', () {
    for (final path in _outputs) {
      expect(_f(path).existsSync(), isTrue, reason: path);
      final text = _f(path).readAsStringSync();
      for (final api in [..._hostApis, ..._amendmentApis.keys]) {
        expect(text, contains(api), reason: '$path lacks $api');
      }
    }
  });

  test('committed Pigeon output equals a fresh regeneration', () async {
    final packageConfig = File('${Directory(_pkg).absolute.path}/.dart_tool/package_config.json');
    expect(packageConfig.existsSync(), isTrue, reason: 'run `flutter pub get` in packages/danaview_pdf first');
    final tmp = Directory.systemTemp.createTempSync('danaview_pdf_pigeon_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    Directory('${tmp.path}/pigeons').createSync();
    _f('pigeons/pdf_api.dart').copySync('${tmp.path}/pigeons/pdf_api.dart');
    final result = await Process.run(
      _dartExecutable(),
      ['--packages=${packageConfig.path}', _pigeonEntryPoint(packageConfig), '--input', 'pigeons/pdf_api.dart'],
      workingDirectory: tmp.path,
    );
    expect(result.exitCode, 0, reason: 'pigeon failed:\n${result.stdout}\n${result.stderr}');
    for (final path in _outputs) {
      expect(
        _f(path).readAsStringSync() == File('${tmp.path}/$path').readAsStringSync(),
        isTrue,
        reason: '$path differs from a fresh Pigeon run: regenerate with `dart run pigeon --input pigeons/pdf_api.dart`',
      );
    }
  });

  test('the Apple glue sets up every host API, the event stream and the platform view', () {
    final glue = _f('darwin/Classes/Glue/DanaviewPdfPlugin.swift').readAsStringSync();
    for (final api in _hostApis) {
      expect(glue, contains('${api}Setup.setUp('), reason: api);
      final defined = _files('darwin/Classes', {'.swift'}).where((f) => f.readAsStringSync().contains('final class ${api}Impl: $api'));
      expect(defined, hasLength(1), reason: '${api}Impl is defined once');
    }
    for (final api in _amendmentApis.keys) {
      expect(glue, contains('${api}Setup.setUp('), reason: api);
      final served = _files('darwin/Classes', {'.swift'}).where((f) => f.readAsStringSync().contains(': $api {'));
      expect(served, hasLength(1), reason: '$api is served once');
    }
    expect(glue, contains('PdfEventsStreamHandler.register('));
    expect(glue, contains('registrar.register(plugin.makeViewFactory(), withId: PdfViewFactory.viewType)'));
    final view = _f('darwin/Classes/Viewer/PdfPlatformView.swift').readAsStringSync();
    expect(view, contains('static let viewType = "com.vecvel.danaview.pdf/view"'));
    final dart = _f('lib/src/pdf_view.dart').readAsStringSync();
    expect(dart, contains("const String pdfViewType = 'com.vecvel.danaview.pdf/view';"));
  });

  test('every tool placeholder carries its owner and answers notSupportedOnDevice everywhere; landed tools advertise themselves', () {
    for (final entry in _placeholders.entries) {
      final text = _f(entry.key).readAsStringSync();
      expect(text, startsWith('// OWNER: ${entry.value}\n'), reason: entry.key);
      final methods = RegExp(r'^  func ', multiLine: true).allMatches(text).length;
      final answers = RegExp(r'PdfErrors\.notSupported\("' + entry.value + r'"\)').allMatches(text).length;
      expect(methods, greaterThan(0), reason: entry.key);
      expect(answers, methods, reason: '${entry.key}: every method answers notSupportedOnDevice');
      expect(text, contains('static let supported: [PdfToolKindMsg] = []'), reason: entry.key);
    }
    // HOM-28 landed: the page tools advertise their five tools and none answers notSupported.
    final pageTools = _f('darwin/Classes/Tools/PdfPageTools.swift').readAsStringSync();
    expect(pageTools, startsWith('// OWNER: HOM-28\n'));
    expect(pageTools, contains('static let supported: [PdfToolKindMsg] = [.merge, .split, .reorder, .rotate, .deletePages]'));
    expect(pageTools, isNot(contains('PdfErrors.notSupported(')));
    final views = _f('darwin/Classes/Viewer/PdfViewHostApiImpl.swift').readAsStringSync();
    expect(RegExp(r'PdfErrors\.notSupported\("HOM-25"\)').allMatches(views), hasLength(3), reason: 'texture views are Android only');
  });

  test('every native source carries an OWNER header (D-33)', () {
    for (final f in _files('darwin', {'.swift', '.podspec', '.sh'})) {
      if (f.path.endsWith('.g.swift')) continue;
      final head = f.readAsLinesSync().take(3).join('\n');
      expect(RegExp(r'(//|#) OWNER: [A-Z]+-\d+A?').hasMatch(head), isTrue, reason: f.path);
    }
  });

  test('the viewer, text and page-tool cores are Flutter-free (XCTest runs them without an app host)', () {
    for (final path in ['darwin/Classes/Viewer/PdfCore.swift', 'darwin/Classes/Text/PdfTextCore.swift', 'darwin/Classes/Tools/PdfPageToolsCore.swift']) {
      expect(_f(path).readAsStringSync(), isNot(matches(RegExp(r'^import Flutter', multiLine: true))), reason: path);
    }
  });

  test('sources are opened read-only: no PDF write call outside the tool directories (rule 27)', () {
    for (final f in [
      ..._files('darwin/Classes/Glue', {'.swift'}),
      ..._files('darwin/Classes/Viewer', {'.swift'}),
      ..._files('darwin/Classes/Text', {'.swift'})
    ]) {
      if (f.path.endsWith('.g.swift')) continue;
      final text = f.readAsStringSync();
      expect(text, isNot(contains('.write(to:')), reason: f.path);
      expect(text, isNot(contains('dataRepresentation')), reason: f.path);
    }
  });

  test('no socket API in the plugin (rule 21)', () {
    final offenders = <String>[];
    for (final f in [
      ..._files('lib', {'.dart'}),
      ..._files('darwin', {'.swift', '.m', '.h'}),
      ..._files('android/src', {'.kt', '.java'})
    ]) {
      for (final m in _socket.allMatches(f.readAsStringSync())) {
        offenders.add('${f.path}: ${m[0]}');
      }
    }
    expect(offenders, isEmpty);
  });
}
