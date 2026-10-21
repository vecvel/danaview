// OWNER: INT-101
//
// BUILD_PLAN v1.2 INT-101 acceptance: with all four 1.2.0 flags false (ARCH v1.2 V2-04, the default
// of every build that passes no `--dart-define`) the Home is the 1.1 Home, there is no photo-editor
// entry and no beauty tab. The 1.1 Home suite (test/home_screen_test.dart) pins the Home layout;
// this test pins the flag defaults and the gates the 1.2.0 tickets build on.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/editor_availability.dart';
import 'package:danaview_editor/src/app/flags_v12.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/wiring/action_bindings.dart';
import 'package:danaview_features/danaview_features.dart';
import 'package:danaview_features/src/flags.dart';

import '../../library_test_utils.dart';

/// Labels a 1.2.0 Home would add (HOM-05 / HOM-18 filter tabs, VED-01 / HOM-12 photo entries,
/// VED-26 beauty, AIS-51 AI search). The 1.1 Home already has a "Folders" section, so the Folders
/// tab is not listed.
const _v12HomeLabels = <String>[
  'All',
  'Videos',
  'Photos',
  'Documents',
  'Edit photo',
  'Batch edit photos',
  'Make video montage',
  'Beauty',
  'Search with AI',
];

void main() {
  tearDown(() {
    FeatureFlags.debugReset();
    EditorFlagsV12.debugReset();
    EditorFlags.debugAiStudioOverride = null;
  });

  group('the 1.2.0 flags default to false (V2-04)', () {
    test('danaview_features', () {
      expect(FeatureFlags.filesHome, isFalse);
      expect(FeatureFlags.photoEditor, isFalse);
      expect(FeatureFlags.beauty, isFalse);
      expect(FeatureFlags.aiStudio, isFalse);
      expect(
        [FeatureFlags.filesHomeEnabled, FeatureFlags.photoEditorEnabled, FeatureFlags.beautyEnabled, FeatureFlags.aiStudioEnabled],
        everyElement(isFalse),
      );
    });

    test('danaview_editor', () {
      expect(EditorFlagsV12.photoEditor, isFalse);
      expect(EditorFlagsV12.beauty, isFalse);
      expect(EditorFlagsV12.filesHome, isFalse);
      expect(EditorFlagsV12.aiStudio, isFalse);
      expect(EditorFlagsV12.aiStudio, aiStudioFlag);
      expect(
        [EditorFlagsV12.photoEditorEnabled, EditorFlagsV12.beautyEnabled, EditorFlagsV12.filesHomeEnabled, EditorFlagsV12.aiStudioEnabled],
        everyElement(isFalse),
      );
    });

    test('test overrides are effective and reset', () {
      FeatureFlags.debugFilesHomeOverride = true;
      EditorFlagsV12.debugBeautyOverride = true;
      EditorFlags.debugAiStudioOverride = true;
      expect(FeatureFlags.filesHomeEnabled, isTrue);
      expect(EditorFlagsV12.beautyEnabled, isTrue);
      expect(EditorFlagsV12.aiStudioEnabled, isTrue);
      FeatureFlags.debugReset();
      EditorFlagsV12.debugReset();
      EditorFlags.debugAiStudioOverride = null;
      expect(FeatureFlags.filesHomeEnabled, isFalse);
      expect(EditorFlagsV12.beautyEnabled, isFalse);
      expect(EditorFlagsV12.aiStudioEnabled, isFalse);
    });
  });

  group('flags off', () {
    for (final surface in [librarySurfaces.first, librarySurfaces[2], librarySurfaces.last]) {
      testWidgets('the Home is the 1.1 Home with no photo-editor or beauty entry at $surface', (tester) async {
        useSurface(tester, surface);
        final env = await LibraryTestEnv.create();
        await tester.pumpWidget(libraryTestApp(
          env,
          DanaviewHomeScreen(onOpenPlayer: () {}, onOpenFolder: (_) {}, onOpenPlaylist: (_) {}),
          textScale: surface.textScale,
        ));
        await pumpFrames(tester);
        expect(tester.takeException(), isNull);
        // The 1.1 Home's empty-library actions are there.
        for (final label in ['Open file', 'Open folder', 'Open link']) {
          expect(find.text(label), findsWidgets, reason: label);
        }
        // Nothing 1.2.0 shows: no filter tabs, no photo or montage entry, no beauty, no AI search.
        for (final label in _v12HomeLabels) {
          expect(find.text(label), findsNothing, reason: label);
          expect(find.bySemanticsLabel(label), findsNothing, reason: label);
        }
        await tester.pumpWidget(const SizedBox());
        await env.dispose();
      });
    }

    test('the photo tray has no Beauty tool and the editor binds no photo or beauty action', () {
      final tray = PhotoToolId.tray(beauty: EditorFlagsV12.beautyEnabled);
      expect(tray, isNot(contains(PhotoToolId.beauty)));
      expect(tray, [
        PhotoToolId.crop,
        PhotoToolId.tone,
        PhotoToolId.hsl,
        PhotoToolId.curves,
        PhotoToolId.masks,
        PhotoToolId.text,
        PhotoToolId.presets,
      ]);
      expect(PhotoToolId.tray(beauty: true), PhotoToolId.trayOrder);
      final sources = {for (final s in editorBindingSources) s.file: s};
      expect(sources['photo_bindings']!.owner, 'VED-01');
      expect(sources['beauty_bindings']!.owner, 'VED-26');
      expect(sources['photo_bindings']!.bindings(), isEmpty);
      expect(sources['beauty_bindings']!.bindings(), isEmpty);
      // The timeline tool strip is the 1.1 strip.
      expect(ToolId.stripOrder.map((t) => t.name),
          ['media', 'audio', 'text', 'captions', 'overlay', 'effects', 'filters', 'transitions', 'format']);
    });

    test('photo tool routes compare by tool and, for Beauty, by tab', () {
      expect(const PhotoToolRoute(PhotoToolId.tone), const PhotoToolRoute(PhotoToolId.tone, beautyCategory: BeautyCategory.skin));
      expect(const PhotoToolRoute(PhotoToolId.beauty), isNot(const PhotoToolRoute(PhotoToolId.beauty, beautyCategory: BeautyCategory.skin)));
      expect(const PhotoToolRoute(PhotoToolId.beauty).withBeautyCategory(BeautyCategory.skin),
          const PhotoToolRoute(PhotoToolId.beauty, beautyCategory: BeautyCategory.skin));
      expect(const PhotoToolRoute(PhotoToolId.beauty, beautyCategory: BeautyCategory.body).hashCode,
          const PhotoToolRoute(PhotoToolId.beauty, beautyCategory: BeautyCategory.body).hashCode);
      expect(const PhotoToolRoute(PhotoToolId.crop).toString(), 'PhotoToolRoute(crop)');
      expect(BeautyCategory.values, hasLength(8));
    });
  });
}
