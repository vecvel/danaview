// OWNER: HOM-31
//
// BUILD_PLAN HOM-31 wiring (S4, behind DANAVIEW_FILES_HOME): "Compress…" is offered in HOM-22's
// file menu of a PDF once the platform's PDF plugin lists the compress tool (iOS and macOS now,
// Android with HOM-31A), never for other files, never on Windows or Linux and never with the flag
// off; the result is saved through the import path as a NEW library file "<name>
// (compressed).pdf" next to the original (a clash gets " (2)"), the temporary file is gone and
// the original is untouched (G-H6).

// The root package reaches the library through danaview_features in its fixtures.
// ignore_for_file: depend_on_referenced_packages, implementation_imports

import 'dart:io';

import 'package:danaview/wiring/documents_wiring.dart';
import 'package:danaview_features/src/flags.dart';
import 'package:danaview_features/src/library/file_actions/file_actions.dart';
import 'package:danaview_features/src/library/files/library_store_providers.dart';
import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_pdf/danaview_pdf.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final class _Docs implements PdfDocuments {
  _Docs(this.caps);

  final PdfCapabilities caps;

  @override
  Future<PdfCapabilities> capabilities() async => caps;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

final class _Engine implements PdfCompressEngine {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

const _withCompress = PdfCapabilities(platformView: true, tools: {PdfTool.compress});
const _withoutCompress = PdfCapabilities(platformView: true);

DocumentItem _doc(String name, {DocumentKind kind = DocumentKind.pdf, String mime = 'application/pdf'}) => DocumentItem(
      id: ItemId.opaque('lk:test/$name'),
      uri: '/tmp/$name',
      name: name,
      modifiedAt: DateTime.utc(2026, 10, 30),
      mimeType: mime,
      sizeBytes: 10,
      docKind: kind,
    );

void main() {
  tearDown(FeatureFlags.debugReset);

  Future<CompressPdfHandler?> handlerFor(TargetPlatform platform, PdfCapabilities caps) async {
    final container = ProviderContainer(overrides: [
      ...documentsOverrides(
        platform: platform,
        support: Directory.systemTemp.path,
        pdf: _Docs(caps),
        compressEngine: _Engine(),
        excludeStagingFromBackup: false,
      ),
    ]);
    addTearDown(container.dispose);
    await container.read(pdfCapabilitiesProvider.future);
    return container.read(compressPdfHandlerProvider);
  }

  test('flag off: no override, so no Compress action', () async {
    FeatureFlags.debugFilesHomeOverride = false;
    expect(documentsOverrides(platform: TargetPlatform.macOS, support: '/s', compressEngine: _Engine()), isEmpty);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(compressPdfHandlerProvider), isNull);
  });

  test('flag on: the action appears where the plugin lists compress', () async {
    FeatureFlags.debugFilesHomeOverride = true;
    expect(await handlerFor(TargetPlatform.macOS, _withCompress), isNotNull);
    expect(await handlerFor(TargetPlatform.android, _withCompress), isNotNull, reason: 'Android lights up with HOM-31A');
    expect(await handlerFor(TargetPlatform.android, _withoutCompress), isNull, reason: 'not before HOM-31A lands');
    expect(await handlerFor(TargetPlatform.windows, _withCompress), isNull);
    expect(await handlerFor(TargetPlatform.linux, _withCompress), isNull);
  });

  test('the file menu offers "Compress…" for a readable PDF only', () {
    final port = NativeFileOut(FileOutPlatform.macOS);
    expect(fileMenuActions(_doc('Report.pdf'), port, canCompress: true), contains(FileAction.compressPdf));
    expect(fileMenuActions(_doc('Report.pdf'), port), isNot(contains(FileAction.compressPdf)), reason: 'no handler wired');
    expect(fileMenuActions(_doc('Notes.docx', kind: DocumentKind.word, mime: 'application/msword'), port, canCompress: true),
        isNot(contains(FileAction.compressPdf)));
    expect(fileActionLabel(FileAction.compressPdf), 'Compress…');
    expect(fileActionId(FileAction.compressPdf), 'file-compress-pdf');
  });

  test('a compressed PDF is saved as a new file next to the original', () async {
    final root = Directory.systemTemp.createTempSync('hom31_lib_');
    addTearDown(() => root.deleteSync(recursive: true));
    final store = await LibraryStore.open(root: root.path, background: false);
    addTearDown(store.close);
    final container = ProviderContainer(overrides: [libraryStoreProvider.overrideWithValue(store)]);
    addTearDown(container.dispose);
    final folder = await store.write((w, now) => w.createFolder('Work', now: now));
    final original = await store.write((w, now) {
      final job = w.beginImport(target: folder, now: now);
      (w.fs.openPart(job.id)..writeFromSync(List.filled(5000, 7))).closeSync();
      return w.commitImport(job.id, const ImportedFileInfo(displayName: 'Report.pdf', kind: FileKind.document), now: now);
    });
    final originalPath = store.paths.entryFile(original.id, original.displayName);
    final originalBytes = File(originalPath).readAsBytesSync();

    Future<String> save() async {
      final temp = '${root.path}/dv_compress_test_${DateTime.now().microsecondsSinceEpoch}.pdf';
      File(temp).writeAsBytesSync(Uint8List(1200));
      final name = await saveCompressedPdf(container.read, tempPath: temp, fileName: 'Report (compressed).pdf', folder: folder);
      expect(File(temp).existsSync(), isFalse, reason: 'the temporary file is the import\'s staged copy');
      return name;
    }

    expect(await save(), 'Report (compressed).pdf');
    expect(await save(), 'Report (compressed) (2).pdf');
    final names = store.reader.allEntries().where((e) => e.folderId == folder).map((e) => e.displayName).toSet();
    expect(names, {'Report.pdf', 'Report (compressed).pdf', 'Report (compressed) (2).pdf'});
    final saved = store.reader.allEntries().firstWhere((e) => e.displayName == 'Report (compressed).pdf');
    expect(File(store.paths.entryFile(saved.id, saved.displayName)).lengthSync(), 1200);
    expect(File(originalPath).readAsBytesSync(), originalBytes, reason: 'the original is never modified');
  });
}
