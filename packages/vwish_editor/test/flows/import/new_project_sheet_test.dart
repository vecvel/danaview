// OWNER: UX-06
//
// The New project sheet (ux.md §5.3) with fakes: Photos/Gallery and Files pickers, the picked list
// with remove, the format choice (preselected from preferences), the name, Create (the import flow
// in the same sheet: success opens the project, partial failure, nothing added with inline errors
// back on the list, cancel mid-copy deleting the partial copy and the half-made project, the
// free-space refusal), Start empty, the iOS-only Photos hint, picker failures and the surface
// matrix.

import 'package:flutter/material.dart' show Scaffold;
import 'package:flutter/widgets.dart' hide AspectRatio;
import 'package:flutter_riverpod/flutter_riverpod.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor/src/editor/flows/import_media_sheet.dart';
import 'package:vwish_editor/src/projects/new_project_sheet.dart';
import 'package:vwish_editor/vwish_editor.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/store.dart';
import 'package:vwish_editor_core/testing.dart';
import 'package:vwish_editor_engine_api/vwish_editor_engine_api.dart';
import 'package:vwish_ui_kit/vwish_ui_kit.dart';

import '../../support/support.dart';
import 'import_fakes.dart';

const _mb = 1024 * 1024;
const _iosPhone = EditorSurface(Size(390, 844), platform: TargetPlatform.iOS);

class _Sheet {
  ProjectId? id;
  bool closed = false;
}

Future<_Sheet> _open(WidgetTester tester, EditorTestHarness h, {EditorSurface surface = SurfaceMatrix.phone}) async {
  final sheet = _Sheet();
  await h.pumpApp(
    tester,
    Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: VwishButton.primary(
            label: 'Open sheet',
            onPressed: () => showNewProjectSheet(context).then((id) {
              sheet
                ..id = id
                ..closed = true;
            }),
          ),
        ),
      ),
    ),
    surface: surface,
  );
  await tester.tap(find.text('Open sheet'));
  await _settle(tester);
  return sheet;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await _settle(tester);
}

Finder _key(String key) => find.byKey(ValueKey(key));

Future<void> _pickPhotos(WidgetTester tester, EditorTestHarness h, List<PickedMedia> picks) async {
  h.engine.picker.nextPicks = picks;
  await _tap(tester, _key('new-project-photos'));
}

EditorTestHarness _harness({ScriptedPool? pool, EditorPrefs? prefs, List<Override> overrides = const []}) =>
    EditorTestHarness(mediaPool: pool ?? ScriptedPool(), prefs: prefs, overrides: overrides);

void main() {
  group('NewProjectSheet', () {
    testWidgets('the photo picker is "Gallery" on Android and asks for videos, photos and audio', (tester) async {
      final h = _harness();
      await _open(tester, h);
      expect(find.text('Gallery'), findsOneWidget);
      await _pickPhotos(tester, h, [pickOf('a.mp4', origin: MediaOrigin.photos, size: 12 * 1000 * 1000)]);
      final request = h.engine.picker.requests.single;
      expect(request.source, MediaPickSource.photos);
      expect(request.kinds, {MediaPickKind.video, MediaPickKind.image, MediaPickKind.audio});
      expect(request.multiple, isTrue);
      expect(find.text('a.mp4'), findsOneWidget);
      expect(find.text('Video · 12 MB'), findsOneWidget);

      h.engine.picker.nextPicks = [pickOf('song.mp3'), pickOf('a.mp4', origin: MediaOrigin.photos)];
      await _tap(tester, _key('new-project-files'));
      expect(h.engine.picker.requests.last.source, MediaPickSource.files);
      expect(find.text('song.mp3'), findsOneWidget);
      expect(find.text('a.mp4'), findsOneWidget, reason: 'the same file is listed once');
    });

    testWidgets('the photo picker is "Photos" on iOS', (tester) async {
      await _open(tester, _harness(), surface: _iosPhone);
      expect(find.text('Photos'), findsOneWidget);
      expect(find.text('Gallery'), findsNothing);
    });

    testWidgets('picked items can be removed; Create needs at least one', (tester) async {
      final h = _harness();
      await _open(tester, h);
      expect(tester.widget<VwishButton>(_key('new-project-create')).onPressed, isNull);
      await _pickPhotos(tester, h, [pickOf('a.mp4'), pickOf('b.jpg')]);
      expect(tester.widget<VwishButton>(_key('new-project-create')).onPressed, isNotNull);
      await _tap(tester, find.bySemanticsLabel('Remove a.mp4'));
      expect(find.text('a.mp4'), findsNothing);
      expect(find.text('b.jpg'), findsOneWidget);
      await _tap(tester, find.bySemanticsLabel('Remove b.jpg'));
      expect(tester.widget<VwishButton>(_key('new-project-create')).onPressed, isNull);
    });

    testWidgets('the format is preselected from the editor preference', (tester) async {
      final h = _harness(prefs: EditorPrefs.memory({EditorPrefKeys.newProjectAspect: 'portrait9x16'}));
      await _open(tester, h);
      expect(tester.widget<VwishSegmentedControl<NewProjectFormat>>(_key('new-project-format')).value, NewProjectFormat.portrait9x16);
      expect(find.text(NewProjectStringsProbe.autoHint), findsNothing);
    });

    testWidgets('Create imports, saves and opens the new project', (tester) async {
      final pool = ScriptedPool()..steps['portrait.mp4'] = const AddStep(width: 1080, height: 1920, fps: 30);
      final h = _harness(pool: pool);
      final sheet = await _open(tester, h);
      await _pickPhotos(tester, h, [pickOf('portrait.mp4', origin: MediaOrigin.photos), pickOf('song.mp3')]);
      await tester.enterText(_key('new-project-name'), '  Goa trip  ');
      await _tap(tester, _key('new-project-create'));

      expect(sheet.closed, isTrue);
      final id = sheet.id!;
      final project = h.repository.projects[id]!;
      expect(project.name, 'Goa trip');
      expect(project.settings.canvas.aspect, AspectRatio.portrait9x16);
      expect(project.pool.assets, hasLength(2));
      expect(h.repository.calls, containsAllInOrder(['create', 'open:$id', 'save', 'close:$id']));
      expect(pool.imported, ['portrait.mp4', 'song.mp3']);
    });

    testWidgets('a chosen format is used even with a video of another shape', (tester) async {
      final h = _harness();
      final sheet = await _open(tester, h);
      await _pickPhotos(tester, h, [pickOf('wide.mp4')]);
      await _tap(tester, find.descendant(of: _key('new-project-format'), matching: find.text('4:3')));
      await _tap(tester, _key('new-project-create'));
      expect(h.repository.projects[sheet.id]!.settings.canvas.aspect, AspectRatio.classic4x3);
    });

    testWidgets('partial failure: the summary shows what failed and Open project opens it', (tester) async {
      final pool = ScriptedPool()..steps['clip.mkv'] = const RejectStep('containerUnsupportedIos');
      final h = _harness(pool: pool);
      final sheet = await _open(tester, h, surface: _iosPhone);
      await _pickPhotos(tester, h, [pickOf('a.mp4'), pickOf('clip.mkv')]);
      await _tap(tester, _key('new-project-create'));
      expect(sheet.closed, isFalse);
      expect(find.text('1 of 2 added'), findsOneWidget);
      expect(find.textContaining("MKV, WebM and AVI videos can't be edited on iPhone and iPad"), findsOneWidget);
      await _tap(tester, find.text('Open project'));
      expect(sheet.closed, isTrue);
      expect(h.repository.projects[sheet.id]!.pool.assets, hasLength(1));
    });

    testWidgets('nothing added: Back returns to the list with each error inline; no project is kept', (tester) async {
      final pool = ScriptedPool()
        ..steps['a.avi'] = const RejectStep('unsupported')
        ..steps['b.mov'] = const RejectStep('accessDenied');
      final h = _harness(pool: pool);
      final sheet = await _open(tester, h);
      await _pickPhotos(tester, h, [pickOf('a.avi'), pickOf('b.mov')]);
      await _tap(tester, _key('new-project-create'));
      expect(find.text('Nothing was added'), findsOneWidget);
      expect(h.repository.projects, isEmpty);

      await _tap(tester, _key('import-back'));
      expect(_key('new-project-sheet'), findsOneWidget);
      expect(find.text('This format is not supported for editing.'), findsOneWidget);
      expect(find.textContaining('Vwish is not allowed to read this file'), findsOneWidget);
      // Remove the failed item, keep the other; errors stay on the chip they belong to.
      await _tap(tester, find.bySemanticsLabel('Remove a.avi'));
      expect(find.text('This format is not supported for editing.'), findsNothing);
      expect(sheet.closed, isFalse);
    });

    testWidgets('cancel mid-copy deletes the partial copy and the half-made project', (tester) async {
      final fs = MemoryStoreFs();
      final copy = CopyStep(fraction: 0.25);
      final pool = ScriptedPool(fs: fs)..steps['big.mov'] = copy;
      final h = _harness(pool: pool);
      final sheet = await _open(tester, h);
      await _pickPhotos(tester, h, [pickOf('first.mp4'), pickOf('big.mov', size: 800 * _mb), pickOf('last.mp4')]);
      await _tap(tester, _key('new-project-create'));
      expect(find.text('Copying into Vwish… 25%'), findsOneWidget);
      expect(fs.filePaths, hasLength(1));

      await _tap(tester, _key('import-cancel'));

      expect(fs.filePaths, isEmpty, reason: 'the partial copy is deleted');
      expect(h.repository.projects, isEmpty, reason: 'the half-made project is deleted');
      expect(pool.imported, ['first.mp4', 'big.mov']);
      expect(find.text('Import cancelled'), findsOneWidget);
      expect(find.text('Nothing was added and no copies were kept.'), findsOneWidget);
      await _tap(tester, _key('import-back'));
      expect(_key('new-project-sheet'), findsOneWidget);
      expect(find.text('big.mov'), findsOneWidget, reason: 'the selection is kept');
      expect(sheet.closed, isFalse);
    });

    testWidgets('free-space refusal: nothing is created and the selection is kept', (tester) async {
      final h = _harness(overrides: [
        importSpaceCheckProvider.overrideWithValue(ImportSpaceCheck(freeBytes: () async => 50 * _mb, needsCopy: (p) async => true)),
      ]);
      await _open(tester, h);
      await _pickPhotos(tester, h, [pickOf('a.mp4', size: 100 * _mb)]);
      await _tap(tester, _key('new-project-create'));
      expect(find.text('Not enough space'), findsOneWidget);
      expect(h.repository.createdSpecs, isEmpty);
      await _tap(tester, _key('import-back'));
      expect(find.text('a.mp4'), findsOneWidget);
    });

    testWidgets('Start empty creates a project with the chosen format and the default name', (tester) async {
      final h = _harness();
      final sheet = await _open(tester, h);
      await _tap(tester, find.descendant(of: _key('new-project-format'), matching: find.text('1:1')));
      await _tap(tester, _key('new-project-start-empty'));
      expect(sheet.closed, isTrue);
      final spec = h.repository.createdSpecs.single as EmptyProjectSpec;
      expect(spec.name, 'Untitled project');
      expect(spec.canvas?.aspect, AspectRatio.square);
      expect(h.repository.projects[sheet.id], isNotNull);
    });

    testWidgets('Start empty with Auto makes a 16:9 project', (tester) async {
      final h = _harness();
      await _open(tester, h);
      await _tap(tester, _key('new-project-start-empty'));
      expect((h.repository.createdSpecs.single as EmptyProjectSpec).canvas?.aspect, AspectRatio.landscape16x9);
    });

    testWidgets('a name over 80 characters is refused before anything is created', (tester) async {
      final h = _harness();
      await _open(tester, h);
      await tester.enterText(_key('new-project-name'), 'x' * 81);
      await _tap(tester, _key('new-project-start-empty'));
      expect(find.text('Use 80 characters or fewer.'), findsOneWidget);
      expect(h.repository.createdSpecs, isEmpty);
    });

    testWidgets('a failing picker explains what to do', (tester) async {
      final h = _harness();
      h.engine.failNext['picker.pick'] = EngineFailure.of(EngineErrorCode.permissionDenied);
      await _open(tester, h);
      await _tap(tester, _key('new-project-photos'));
      expect(_key('new-project-notice'), findsOneWidget);
    });

    testWidgets('the Photos hint shows only for iOS Photos picks', (tester) async {
      final h = _harness();
      await _open(tester, h, surface: _iosPhone);
      await _pickPhotos(tester, h, [pickOf('clip.mov')]);
      expect(_key('import-photos-hint'), findsNothing);
      await _pickPhotos(tester, h, [pickOf('IMG_1.mov', origin: MediaOrigin.photos, temporary: true)]);
      expect(_key('import-photos-hint'), findsOneWidget);
    });

    testWidgets('no Photos hint on Android', (tester) async {
      final h = _harness();
      await _open(tester, h);
      await _pickPhotos(tester, h, [pickOf('IMG_1.mp4', origin: MediaOrigin.photos)]);
      expect(_key('import-photos-hint'), findsNothing);
    });

    testSurfaces('no overflow with many picks, long names, errors and the hint', (tester, surface) async {
      final pool = ScriptedPool()..steps['broken-${'y' * 50}.webm'] = const RejectStep('containerUnsupportedIos');
      final h = _harness(pool: pool);
      final ios = surface.copyWith(platform: TargetPlatform.iOS);
      await _open(tester, h, surface: ios);
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
      await _pickPhotos(tester, h, [
        pickOf('broken-${'y' * 50}.webm', origin: MediaOrigin.photos, size: 123456789),
        pickOf('A very long video name from the summer holiday at the beach with friends.mov', origin: MediaOrigin.photos),
        pickOf('song.mp3', size: 4000000),
        pickOf('photo.heic'),
      ]);
      await tester.enterText(_key('new-project-name'), 'A project name that is long enough to wrap anywhere');
      await tester.pump();
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
      await _tap(tester, _key('new-project-create'));
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
      expect(find.text('3 of 4 added'), findsOneWidget);
      await tester.ensureVisible(find.text('Open project'));
      await tester.pump();
      expectInside(tester, find.text('Open project'));
    });
  });
}

/// Copy the tests refer to.
abstract final class NewProjectStringsProbe {
  /// The Auto hint.
  static const String autoHint = 'Matches the first video. Without media, new projects are 16:9.';
}
