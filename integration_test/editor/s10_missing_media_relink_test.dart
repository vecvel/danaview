// OWNER: QA-00
//
// ARCH §21.2 scenario 10: missing media and relink on sandbox copies. Three files the project
// references in place (Documents) are moved to another folder while the project is closed; on
// reopening, the missing-media banner opens the Missing media sheet, one file is located by itself
// ("Locate… › From Files") and the other two with "Relink several"; one Relink commits all and the
// preview shows the right frames again.

import 'dart:io';

import 'package:danaview_editor_core/model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/e2e.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('scenario 10: missing media, Locate and Relink several', (tester) async {
    await E2eApp.launch(tester);
    final files = [
      E2eMedia.uniqueCopy(Fx.frameCounter, 's10a'),
      E2eMedia.uniqueCopy(Fx.toneUnderVideo, 's10b'),
      E2eMedia.uniqueCopy(Fx.clapFlash, 's10c'),
    ];
    var ed = await E2eEditor.createProject(tester, name: 'E2E relink ${DateTime.now().millisecondsSinceEpoch % 100000}', media: files);
    final id = ed.id;
    final byName = {for (final a in ed.project.pool.assets.values) a.displayName: a.id};
    expect(byName.keys, containsAll([for (final f in files) f.split('/').last]));
    await ed.close();

    // Move the three files away (same names, another folder).
    final moved = Directory('${E2eMedia.dir}/moved-${DateTime.now().millisecondsSinceEpoch}')..createSync(recursive: true);
    final targets = [for (final f in files) '${moved.path}/${f.split('/').last}'];
    for (final (i, f) in files.indexed) {
      File(f).renameSync(targets[i]);
    }

    ed = await E2eEditor.openFromProjects(tester, id);
    await E2eApp.waitKey(tester, 'missing-media-banner', timeout: const Duration(seconds: 30));
    await E2eApp.screenshot(tester, 's10_missing_banner');
    await E2eApp.tapKey(tester, 'missing-media-relink');
    await E2eApp.waitKey(tester, 'relink-sheet');

    // Locate the first file alone (From Files).
    final first = byName[files[0].split('/').last]!;
    E2eApp.world.engine.picker.queue([targets[0]]);
    await E2eApp.tapKey(tester, 'relink-locate-${first.value}');
    if (find.text('From Files').evaluate().isNotEmpty) await E2eApp.tap(tester, find.text('From Files').last, what: 'From Files');
    await E2eApp.waitKey(tester, 'relink-status-${first.value}');

    // Relink several: one multi-pick for the other two.
    E2eApp.world.engine.picker.queue(targets.sublist(1));
    await E2eApp.tapKey(tester, 'relink-several-button');
    if (find.text('From Files').evaluate().isNotEmpty) await E2eApp.tap(tester, find.text('From Files').last, what: 'From Files');
    await E2eApp.waitKey(tester, 'relink-confirm');
    await E2eApp.screenshot(tester, 's10_relink_several_confirm');
    await E2eApp.tapKey(tester, 'relink-confirm-apply');
    await E2eApp.waitKey(tester, 'relink-apply');
    await E2eApp.tapKey(tester, 'relink-apply');

    await E2eApp.pumpUntil(
      tester,
      () => ed.state.media.missing.isEmpty && !E2eApp.hasKey('missing-media-banner'),
      what: 'every file relinked',
      timeout: const Duration(seconds: 60),
    );
    final relinked = {for (final a in ed.project.pool.assets.values) a.displayName: a};
    for (final t in targets) {
      expect(relinked[t.split('/').last], isNotNull);
    }
    // The first clip plays from the moved file.
    final clip = ed.mainTrack.items.first as MediaClip;
    await ed.waitReady();
    await ed.seekTo(clip.start + ed.rate.timeOfFrame(10));
    expect((await ed.barcode()).index, 10);
    await ed.close();
  });
}
