// OWNER: INT-101
//
// BUILD_PLAN v1.2 INT-101 acceptance: with all four 1.2.0 flags false (ARCH v1.2 V2-04, the default
// of every build that passes no `--dart-define`) the Home is the 1.1 Home, there is no photo-editor
// entry and no beauty tab (and the editor shows no photo, beauty, compare, To video or batch-edit
// action). The 1.1 Home suite (test/home_screen_test.dart) pins the Home layout;
// this test pins the flag defaults and the gates the 1.2.0 tickets build on.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/editor_availability.dart';
import 'package:danaview_editor/src/app/flags_v12.dart';
import 'package:danaview_editor/src/editor/actions/editor_action_registry.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/toolbar/tool_sets.dart';
import 'package:danaview_editor/src/editor/wiring/action_bindings.dart';
import 'package:danaview_editor_core/model.dart';
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

/// The photo and beauty actions (INT-101), hidden while their flags are off.
const _ved = <EditorActionId>{
  ...EditorActionId.photoEditorActions,
  ...EditorActionId.beautyActions,
  ...EditorActionId.compareActions,
};

/// An action context for predicates that read nothing (the hidden flagged-off bindings).
final class _BareContext implements EditorActionContext {
  const _BareContext();

  @override
  BuildContext get context => throw UnimplementedError();

  @override
  ProjectId get projectId => const ProjectId('pj_flags_off');

  @override
  T read<T>(ProviderListenable<T> provider) => throw UnimplementedError();

  @override
  EditorActionSource get source => EditorActionSource.button;
}

/// Every action id a static tool set, tool tab or strip tile names (UX-16).
Set<EditorActionId> _toolSetActions() {
  const a = ItemId('it_a'), b = ItemId('it_b');
  final lists = <List<ToolEntry>>[
    ToolSets.video,
    ToolSets.image,
    ToolSets.audio,
    ToolSets.multi,
    ToolSets.gap,
    ToolSets.marker,
    ToolSets.text(a),
    ToolSets.subtitleCue(const TrackId('tr_sub'), a),
    ToolSets.transition(const TransitionRef(TrackId('tr_main'), a, b)),
  ];
  return {
    for (final list in lists)
      for (final e in list)
        if (e is ActionToolEntry) e.action,
    for (final ids in ToolSets.toolTabs.values) ...ids,
    for (final t in ToolId.values) t.primaryAction,
  };
}

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

    test('no photo, beauty, compare, To video or batch-edit action shows, runs or has a shortcut', () {
      expect(_ved, EditorActionId.vedAdditions.toSet());
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final registry = c.read(editorActionRegistryProvider);
      const ctx = _BareContext();
      for (final id in _ved) {
        final spec = registry.spec(id);
        expect(spec.isVisible(ctx), isFalse, reason: id.name);
        expect(spec.isEnabled(ctx), isFalse, reason: id.name);
        expect(spec.combos, isEmpty, reason: id.name);
        expect(registry.invoke(id, ctx), EditorActionResult.hidden, reason: id.name);
        expect(editorActionMeta(id).combos, isEmpty, reason: id.name);
        expect(editorActionMeta(id).label, isNotEmpty, reason: id.name);
      }
      expect(registry.shortcutSpecs.map((s) => s.id).toSet().intersection(_ved), isEmpty);
      final intents = registry.activators.values.whereType<EditorActionIntent>().map((i) => i.id).toSet();
      expect(intents.intersection(_ved), isEmpty);
      expect(_toolSetActions().intersection(_ved), isEmpty);
      // The rich-subtitle actions are not flagged and stay visible.
      expect(registry.spec(EditorActionId.transcriptView).isVisible(ctx), isTrue);
    });

    test('the photo and beauty gate follows each flag; compare needs either', () {
      EditorActionBinding bind(EditorActionId id) => EditorActionBinding(id: id, handler: (_) {});
      final real = {for (final id in _ved) id: bind(id)};
      bool visible(Map<EditorActionId, EditorActionBinding> m, EditorActionId id) => m[id]!.isVisible?.call(const _BareContext()) ?? true;
      final off = gateV12EditorActions(real, photoEditor: false, beauty: false);
      expect([for (final id in _ved) visible(off, id)], everyElement(isFalse));
      final photoOnly = gateV12EditorActions(real, photoEditor: true, beauty: false);
      expect(visible(photoOnly, EditorActionId.editPhoto), isTrue);
      expect(visible(photoOnly, EditorActionId.compareBeforeAfter), isTrue);
      expect(visible(photoOnly, EditorActionId.beauty), isFalse);
      final beautyOnly = gateV12EditorActions(real, photoEditor: false, beauty: true);
      expect(visible(beautyOnly, EditorActionId.beauty), isTrue);
      expect(visible(beautyOnly, EditorActionId.compareBeforeAfter), isTrue);
      expect(visible(beautyOnly, EditorActionId.photoToVideo), isFalse);
      expect(visible(beautyOnly, EditorActionId.batchEditPhotos), isFalse);
      expect(gateV12EditorActions(real, photoEditor: true, beauty: true), same(real));
      expect(mergeEditorActionBindings(), mergeEditorActionBindings());
      expect(mergeEditorActionBindings(null, false, true, true).keys.toSet().intersection(_ved), isEmpty,
          reason: 'with the flags on, the photo and beauty ids are unbound until VED-01…VED-27 bind them');
    });

    test('the Beauty inspector route re-targets and compares by clip and tab', () {
      const a = ItemId('it_a'), b = ItemId('it_b');
      expect(const BeautyInspector(a), const BeautyInspector(a, category: BeautyCategory.faceShape));
      expect(const BeautyInspector(a), isNot(const BeautyInspector(a, category: BeautyCategory.skin)));
      expect(const BeautyInspector(a, category: BeautyCategory.body).retarget(b), const BeautyInspector(b, category: BeautyCategory.body));
      const same0 = BeautyInspector(a);
      expect(same0.retarget(a), same(same0));
      expect(const BeautyInspector(a).withCategory(BeautyCategory.makeup).category, BeautyCategory.makeup);
      expect(const BeautyInspector(a).target, a);
      expect(const BeautyInspector(a).hashCode, const BeautyInspector(a).hashCode);
      expect(const BeautyInspector(a, category: BeautyCategory.eyesBrows).toString(), 'BeautyInspector(it_a, eyesBrows)');
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
