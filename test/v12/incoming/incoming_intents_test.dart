// OWNER: HOM-21A
//
// The Dart side of Android incoming intents (BUILD_PLAN HOM-21A, ARCH v1.2 §5.6): the plugin's
// batches (fake port here) are imported through the import queue as platform-URI sources into
// Imported, then acknowledged. A VIEW is `openWith` and opens the entry already in the library
// instead of a second copy; shares are `shareExtension` and keep both copies; unreadable items
// count as failed and the batch is still acknowledged; pending batches are taken at start; and the
// app root wires the port on Android only.
//
// The root package reaches danaview_library through danaview_features.
// ignore_for_file: depend_on_referenced_packages, implementation_imports

import 'dart:async';
import 'dart:io';

import 'package:danaview/wiring/documents_wiring.dart' show DocumentViewerSetup, documentsOverrides;
import 'package:danaview_features/src/flags.dart';
import 'package:danaview_features/src/library/files/library_store_providers.dart';
import 'package:danaview_features/src/library/import/incoming_intents.dart';
import 'package:danaview_features/src/player/danaview_player_actions.dart' show inboxResultMessage;
import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_library_native/danaview_library_native.dart' show IncomingAction, IncomingBatch, IncomingItem;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Reads `content://test/<name>` URIs from a local folder, like the plugin's streamed copy.
final class _UriCopier implements ImportCopier {
  _UriCopier(this.dir);

  final Directory dir;
  static const _file = FileImportCopier();

  ImportSource _local(ImportSource s) {
    final f = File('${dir.path}/${Uri.parse(s.location).pathSegments.last}');
    if (!f.existsSync()) throw const ImportException(ImportFailure.sourceUnreadable);
    return ImportSource.file(f.path, displayName: s.displayName);
  }

  @override
  bool handles(ImportSource source) => source.kind == ImportSourceKind.nativeUri;

  @override
  Future<SourceStat> stat(ImportSource source) async => _file.stat(_local(source));

  @override
  ImportCopyRun start({
    required ImportSource source,
    required String partPath,
    required int resumeFrom,
    required bool hash,
    required void Function(int bytesDone) onProgress,
    required void Function(int bytesDone) onCheckpoint,
  }) =>
      _file.start(source: _local(source), partPath: partPath, resumeFrom: resumeFrom, hash: hash, onProgress: onProgress, onCheckpoint: onCheckpoint);
}

final class _Port implements IncomingIntentPort {
  final StreamController<IncomingBatch> controller = StreamController<IncomingBatch>.broadcast();
  final List<IncomingBatch> pending = [];
  final List<String> acknowledged = [];
  int takes = 0;

  @override
  Stream<IncomingBatch> get batches => controller.stream;

  @override
  Future<void> takePending() async {
    takes++;
    for (final b in pending) {
      controller.add(b);
    }
    pending.clear();
  }

  @override
  Future<void> acknowledge(String batchId) async => acknowledged.add(batchId);
}

IncomingItem _item(String name, {String? mime, bool named = true}) =>
    IncomingItem(uri: 'content://test/$name', displayName: named ? name : null, mimeType: mime);

void main() {
  late Directory root;
  late Directory src;
  late LibraryStore store;
  late ImportService service;
  late _Port port;
  late IncomingIntentImporter importer;

  void write(String name, int size, {int seed = 1}) =>
      File('${src.path}/$name').writeAsBytesSync(List<int>.generate(size, (i) => (i * seed + 7) % 251));

  setUp(() async {
    root = Directory.systemTemp.createTempSync('hom21a_lib_');
    src = Directory.systemTemp.createTempSync('hom21a_src_');
    store = await LibraryStore.open(root: root.path, background: false);
    service = ImportService(store: store, copiers: [const FileImportCopier(), _UriCopier(src)]);
    port = _Port();
    importer = IncomingIntentImporter(port: port, imports: service);
  });

  tearDown(() async {
    importer.dispose();
    await service.dispose();
    await store.close();
    root.deleteSync(recursive: true);
    src.deleteSync(recursive: true);
  });

  test('item names and sources: provider name, URI segment, fallback; no grant released by the import', () {
    expect(incomingItemName(_item('Report.pdf')), 'Report.pdf');
    expect(incomingItemName(_item('Scan.jpg', named: false)), 'Scan.jpg');
    expect(incomingItemName(const IncomingItem(uri: 'content://x/', displayName: '  ')), 'Shared file');
    final view = incomingImportSource(_item('Report.pdf', mime: 'application/pdf'), IncomingAction.view);
    expect(view.kind, ImportSourceKind.nativeUri);
    expect(view.sourceHint, SourceHint.openWith);
    expect(view.mime, 'application/pdf');
    expect(view.releaseUri, isNull);
    expect(incomingImportSource(_item('a.txt'), IncomingAction.send).sourceHint, SourceHint.shareExtension);
    expect(incomingImportSource(_item('a.txt'), IncomingAction.sendMultiple).sourceHint, SourceHint.shareExtension);
  });

  test('a VIEW imports into Imported as openWith, then opens the existing entry instead of a copy', () async {
    write('Report.pdf', 3000);
    final first = await importer.handle(IncomingBatch(batchId: 'v1', action: IncomingAction.view, items: [_item('Report.pdf')]));
    expect(first!.imported, hasLength(1));
    expect(first.toOpen!.displayName, 'Report.pdf');
    expect(first.toOpen!.sourceHint, SourceHint.openWith);
    expect(port.acknowledged, ['v1']);

    final again = await importer.handle(IncomingBatch(batchId: 'v2', action: IncomingAction.view, items: [_item('Report.pdf')]));
    expect(again!.imported, isEmpty);
    expect(again.skipped, 1);
    expect(again.toOpen!.id, first.toOpen!.id);
    expect(port.acknowledged, ['v1', 'v2']);
  });

  test('a share keeps both copies, counts failures, and is acknowledged anyway', () async {
    write('Photo.jpg', 2000, seed: 3);
    write('Clip.mp4', 4000, seed: 5);
    final r = await importer.handle(IncomingBatch(
      batchId: 's1',
      action: IncomingAction.sendMultiple,
      items: [_item('Photo.jpg'), _item('Clip.mp4'), _item('Gone.pdf')],
    ));
    expect(r!.imported.map((e) => e.displayName), ['Photo.jpg', 'Clip.mp4']);
    expect(r.imported.every((e) => e.sourceHint == SourceHint.shareExtension), isTrue);
    expect(r.failed, 1);
    expect(r.toOpen, isNull);
    expect(r.asInboxResult.imported, hasLength(2));
    expect(inboxResultMessage(r.asInboxResult), contains('2 shared items saved'));
    expect(port.acknowledged, ['s1']);

    final twice = await importer.handle(IncomingBatch(batchId: 's2', action: IncomingAction.send, items: [_item('Photo.jpg')]));
    expect(twice!.imported, hasLength(1), reason: 'a share keeps both copies');
  });

  test('start takes the pending batches and reports each once; warm batches follow', () async {
    write('Notes.txt', 100);
    write('Doc.pdf', 500, seed: 9);
    port.pending.add(IncomingBatch(batchId: 'cold', action: IncomingAction.view, items: [_item('Notes.txt')]));
    final results = <IncomingIntentResult>[];
    final sub = importer.results.listen(results.add);
    importer.start(observeLifecycle: false);
    importer.start(observeLifecycle: false);
    expect(port.takes, 1);
    port.controller.add(IncomingBatch(batchId: 'warm', action: IncomingAction.send, items: [_item('Doc.pdf')]));
    for (var i = 0; i < 200 && results.length < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(results.map((r) => r.action), [IncomingAction.view, IncomingAction.send]);
    expect(port.acknowledged, ['cold', 'warm']);
    await sub.cancel();
  });

  test('a disposed import service leaves the batch unacknowledged', () async {
    await service.dispose();
    expect(await importer.handle(IncomingBatch(batchId: 'x', action: IncomingAction.view, items: [_item('a.pdf')])), isNull);
    expect(port.acknowledged, isEmpty);
  });

  test('the provider starts an importer only with a port and an import service', () {
    final none = ProviderContainer(overrides: [libraryStoreProvider.overrideWithValue(store)]);
    addTearDown(none.dispose);
    expect(none.read(incomingIntentImportProvider), isNull);
  });

  test('the app root wires the incoming port on Android only, and only with the flag on', () {
    addTearDown(FeatureFlags.debugReset);
    FeatureFlags.debugFilesHomeOverride = false;
    for (final platform in TargetPlatform.values) {
      expect(documentsOverrides(platform: platform, support: root.path, incoming: port, excludeStagingFromBackup: false), isEmpty);
    }
    FeatureFlags.debugFilesHomeOverride = true;
    const viewers = DocumentViewerSetup.builtInOnly;
    for (final platform in TargetPlatform.values) {
      final overrides = documentsOverrides(platform: platform, support: root.path, incoming: port, viewers: viewers, excludeStagingFromBackup: false);
      final container = ProviderContainer(overrides: overrides);
      addTearDown(container.dispose);
      expect(container.read(incomingIntentPortProvider), platform == TargetPlatform.android ? same(port) : isNull, reason: platform.name);
    }
  });
}
