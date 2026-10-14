// OWNER: CORE-37
//
// Render-preview files are preview-only (ARCH D-45(A), §9.5): export plans never reference cache
// files. Checked two ways: (1) compile export (and preview) plans of random projects, with proxies
// available, and assert no asset points into `<cache>/danaview/editor/renders/` or names a
// `<rangeHash>.mp4`; (2) the export compile path does not import the render-cache model at all,
// so it has no way to reach the index. Also the purity rules for this ticket's files (no
// package:flutter; dart:io only under lib/src/store/; OWNER headers; the barrel exports exactly
// the two source files).

import 'dart:io';

import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/plan.dart';
import 'package:test/test.dart';

import '../../purity_test.dart' show purityViolations;
import '../../support/random_project.dart';
import '../compile_visual/support.dart' show resolverFor;

final RegExp renderFile = RegExp(r'(^|/)[0-9a-f]{64}(\.partial)?\.mp4$');

bool referencesRenderCache(RenderPlan plan) => plan.assets.values.any((a) {
      for (final uri in [a.uri, a.proxyUri]) {
        if (uri == null) continue;
        if (uri.contains('/danaview/editor/renders/') || renderFile.hasMatch(uri)) return true;
      }
      return false;
    });

void main() {
  test('compiled export and preview plans never reference render-cache files', () {
    for (var seed = 0; seed < 16; seed++) {
      final project = randomProject(seed, const RandomProjectSpec(items: 40));
      final resolver = resolverFor(project, proxied: {for (final a in project.pool.assets.values) if (a.kind == MediaKind.video) a.id.value});
      final export = compileRenderPlan(project, PlanTarget.export, resolver);
      expect(export.target, PlanTarget.export);
      expect(referencesRenderCache(export), isFalse, reason: 'seed $seed export');
      expect(export.assets.values.every((a) => a.proxyUri == null), isTrue);
      final preview = compileRenderPlan(project, PlanTarget.preview, resolver);
      expect(referencesRenderCache(preview), isFalse, reason: 'seed $seed preview: rendered ranges travel through setRenderedRanges only');
    }
  });

  test('the detector itself recognises render-cache uris', () {
    final plan = RenderPlan(rev: 1, target: PlanTarget.export, canvas: const PlanCanvas(w: 16, h: 16, fps: 30), durUs: 0, assets: {
      'x': PlanAsset(kind: PlanAssetKind.video, uri: 'file:///c/danaview/editor/renders/${'a' * 64}.mp4'),
    });
    expect(referencesRenderCache(plan), isTrue);
  });

  test('the plan compile path does not import the render-cache model', () {
    final offenders = <String>[];
    for (final f in Directory('lib/src').listSync(recursive: true).whereType<File>()) {
      final rel = f.path.replaceAll(r'\', '/');
      if (!rel.endsWith('.dart') || rel.endsWith('render_ranges.dart') || rel.endsWith('render_cache_index.dart')) continue;
      final src = f.readAsStringSync();
      if (src.contains('render_ranges.dart') || src.contains('render_cache_index.dart') || src.contains('render_cache.dart')) {
        offenders.add(rel);
      }
    }
    expect(offenders, isEmpty);
    for (final name in ['compiler.dart', 'compile_export.dart', 'asset_resolver.dart']) {
      expect(File('lib/src/plan/$name').readAsStringSync(), isNot(contains("'renders'")), reason: name);
    }
  });

  test('purity of the CORE-37 files', () {
    const files = ['lib/render_cache.dart', 'lib/src/plan/render_ranges.dart', 'lib/src/store/render_cache_index.dart'];
    for (final path in files) {
      final src = File(path).readAsStringSync();
      expect(purityViolations(path, src), isEmpty, reason: path);
      expect(src, startsWith('// OWNER: CORE-37'), reason: path);
    }
    expect(File('lib/src/plan/render_ranges.dart').readAsStringSync(), isNot(contains("import 'dart:io'")));
    final barrel = File('lib/render_cache.dart').readAsStringSync();
    final exports = RegExp(r"^export '([^']+)';", multiLine: true).allMatches(barrel).map((m) => m[1]).toList();
    expect(exports, ['src/plan/render_ranges.dart', 'src/store/render_cache_index.dart']);
  });
}
