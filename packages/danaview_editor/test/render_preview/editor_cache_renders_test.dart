// OWNER: UX-44
//
// Render-preview files and UX-04's "Editor cache" contributor (BUILD_PLAN UX-44 acceptance, ARCH
// D-45, §17.10): files written through CORE-37's index under `<cache>/danaview/editor/renders/`
// count in the contributor's bytes, its clear removes them, and it never touches anything outside
// the cache folders. These tests need UX-04's amendment (2026-10-11: `renders` in
// `EditorCacheCleaner.folders`).

import 'package:danaview_editor/src/app/editor_storage_contributor.dart';
import 'package:danaview_editor_core/render_cache.dart';
import 'package:danaview_editor_core/store.dart';
import 'package:danaview_editor_core/testing.dart';
import 'package:flutter_test/flutter_test.dart';

const _roots = StoreRoots(support: '/app/support', cache: '/app/cache', documents: '/app/documents');
const _project = '/app/support/danaview/editor/projects/p1/main.dnproj';
const _hashA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _hashB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

void main() {
  late MemoryStoreFs memory;
  late RenderCacheIndex index;
  late EditorCacheCleaner cleaner;

  setUp(() async {
    memory = MemoryStoreFs()
      ..putFile(_project, List<int>.filled(900, 1))
      ..putFile('/app/cache/danaview/editor/thumbs/m1/strip-0.jpg', List<int>.filled(100, 1));
    final deleter = OwnedFileDeleter(_roots, fs: memory, assertOnViolation: false);
    index = RenderCacheIndex(roots: _roots, deleter: deleter, fs: memory);
    await index.open();
    for (final (hash, size) in [(_hashA, 3000), (_hashB, 5000)]) {
      memory.putFile(index.stagingPathFor(hash), List<int>.filled(size, 2));
      await index.put(hash, index.stagingPathFor(hash));
    }
    cleaner = EditorCacheCleaner(roots: _roots, fs: memory, deleter: deleter);
  });

  test('the "Editor cache" bytes include render-preview files', () async {
    final renders = await index.bytes();
    expect(renders, greaterThanOrEqualTo(8000));
    expect(await cleaner.measure(), 100 + renders);
  });

  test('clearing the editor cache removes render-preview files and nothing outside the cache', () async {
    await cleaner.clear();
    expect(memory.filePaths.where((p) => p.contains('/renders/') && p.endsWith('.mp4')), isEmpty);
    expect(memory.peek(_project), isNotNull);
    expect(await cleaner.measure(), 0);
    await index.open();
    expect(index.entries, isEmpty, reason: 'a reopened index finds no renders');
  });
}
