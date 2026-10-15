// OWNER: QA-00 (temporary probe, deleted after use)
// ignore_for_file: implementation_imports
import 'dart:io';
import 'package:danaview_editor/src/editor/contracts/action_ids.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/e2e.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('freeze probe', (tester) async {
    await E2eApp.launch(tester);
    final ed = await E2eEditor.createProject(tester, name: 'probe freeze', media: [E2eMedia.fixture(Fx.frameCounter)]);
    final c1 = ed.mainTrack.items[0] as MediaClip;
    ed.apply(SetSpeed(c1.id, const ConstantSpeed(2)));
    await ed.waitProject((p) => ed.item(c1.id).duration == 4000000, what: '2x');
    await ed.seekFrame(30);
    await ed.select(c1.id);
    await ed.invoke(EditorActionId.freeze);
    await E2eApp.waitKey(tester, 'freeze.sheet');
    await E2eApp.tapKey(tester, 'freeze.confirm');
    await ed.waitProject((p) => ed.items<MediaClip>().any((c) => p.pool[c.media]?.kind == MediaKind.still), what: 'still');
    final still = ed.items<MediaClip>().firstWhere((c) => ed.project.pool[c.media]?.kind == MediaKind.still);
    await E2eApp.pumpUntil(tester, () => ed.project.pool[still.media]!.status is ReadyStatus, what: 'ready', timeout: const Duration(seconds: 60));
    final asset = ed.project.pool[still.media]!;
    final loc = asset.locator;
    debugPrint('PROBE still ${still.start}..${still.end} locator ${loc.runtimeType} ${loc is AppRelativeLocator ? '$loc' : loc}');
    try {
      final r = await E2eApp.pumpWhile(tester, E2eApp.world.engine.access.resolve(loc), what: 'resolve');
      debugPrint('PROBE still resolved ${r.uri} exists=${File(Uri.parse(r.uri).toFilePath()).existsSync()}');
    } catch (e) {
      debugPrint('PROBE still resolve failed $e');
    }
    debugPrint('PROBE asset status ${asset.status} kind ${asset.kind}');
    for (var i = 0; i < 6; i++) {
      await ed.seekTo(still.start + still.duration ~/ 2);
      final f = await ed.capture();
      debugPrint('PROBE $i ${f.width}x${f.height} ${f.barcode} health=${ed.state.media}');
      File('${E2eConfig.outDir}/still-$i-${f.width}x${f.height}.rgba')..createSync(recursive: true)..writeAsBytesSync(f.rgba);
      await tester.pump(const Duration(seconds: 1));
    }
  });
}
