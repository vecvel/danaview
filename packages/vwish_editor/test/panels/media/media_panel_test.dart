// OWNER: UX-36
//
// The media panel (ux.md §10.1) over the real EditorController and FakeEditorEngine: the bin's
// order, usage counts, badges and thumbnails, the filters and the search, the preview strip, and
// every card action (add at the playhead with ripple on and off, add as overlay, replace the
// selected clip, remove an unused asset and undo it, relink, info), the header pickers with the
// import sheet and the "Add to timeline" switch.

import 'package:flutter/gestures.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:meta/meta.dart' show isTestGroup;
import 'package:vwish_editor/src/app/strings/media_strings.dart';
import 'package:vwish_editor/src/editor/actions/bindings/media_bindings.dart';
import 'package:vwish_editor/src/editor/contracts/contracts.dart';
import 'package:vwish_editor/src/editor/panels/media_panel.dart';
import 'package:vwish_editor/src/editor/state/editor_events.dart' show EditorToast;
import 'package:vwish_editor/src/editor/state/plan_compiler_port.dart';
import 'package:vwish_editor/src/editor/wiring/action_bindings.dart' show editorActionBindingsProvider;
import 'package:vwish_editor/src/editor/timeline/timeline_drop_target.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/ops.dart';
import 'package:vwish_editor_core/plan.dart' show MapPlanAssetResolver, PlanAssetResolver;
import 'package:vwish_editor_core/store.dart' show MediaAvailability;
import 'package:vwish_editor_engine_api/vwish_editor_engine_api.dart' show EngineError, EngineErrorCode, MediaPickKind, MediaPickSource;
import 'package:vwish_features/storage.dart' show formatDataSize;
import 'package:vwish_ui_kit/vwish_ui_kit.dart';

import 'media_support.dart';

Widget _panel({double width = 360, double height = 640}) => Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: width, height: height, child: const MediaPanel(route: MediaInspector())),
    );

/// beach (used once, main lane), city, logo, song (used once, music lane): song is the newest.
List<MediaAsset> _assets() => [
      binAsset('vid_a', name: 'beach.mp4', addedAt: DateTime.utc(2026, 10, 1)),
      binAsset('vid_b', name: 'city.mov', duration: 6 * s, addedAt: DateTime.utc(2026, 10, 2)),
      binAsset('img_a', kind: MediaKind.image, name: 'logo.png', addedAt: DateTime.utc(2026, 10, 3)),
      binAsset('aud_a', kind: MediaKind.audio, name: 'song.m4a', duration: 30 * s, addedAt: DateTime.utc(2026, 10, 4)),
    ];

EditProject _project(FakeProjectRepository repo, {List<MediaAsset>? assets, bool clips = true}) => seedMediaProject(
      repo,
      assets: assets ?? _assets(),
      setup: (edit) {
        if (!clips) return;
        applyOrThrow(edit, InsertMedia([const MediaId('vid_a')], 0));
        applyOrThrow(edit, InsertMedia([const MediaId('aud_a')], 0));
      },
    );

Future<MediaRig> _pump(
  WidgetTester tester, {
  EditorSurface surface = SurfaceMatrix.phone,
  Widget? panel,
  EditProject Function(FakeProjectRepository repo)? project,
  ScriptedPool? pool,
  List<Override> overrides = const [],
}) =>
    MediaRig.pump(tester, (_) => panel ?? _panel(), project: project ?? _project, surface: surface, pool: pool, overrides: overrides);

Finder _card(String id) => find.byKey(ValueKey('media-card-$id'));

List<String> _cardOrder(WidgetTester tester) => [
      for (final w in tester.widgetList(
          find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('media-card-'))))
        (w.key! as ValueKey<String>).value.substring('media-card-'.length),
    ];

/// Scrolls the bin until [f] can be hit, then taps it.
Future<void> _tap(WidgetTester tester, Finder f) async {
  for (var i = 0; i < 20 && f.hitTestable().evaluate().isEmpty; i++) {
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -150));
    await tester.pump();
  }
  await tester.tap(f);
  await tester.pumpAndSettle();
}

/// Closes an open menu by tapping outside it.
Future<void> _closeMenu(WidgetTester tester) async {
  await tester.tapAt(const Offset(2, 2));
  await tester.pumpAndSettle();
}

/// Opens the card's menu and runs [item]. A toast lives for ~2.8 s of animation, so [settle] false
/// pumps only a moment (to look at the toast).
Future<void> _menu(WidgetTester tester, String id, String item, {bool settle = true}) async {
  await _tap(tester, find.byKey(ValueKey('media-menu-$id')));
  await tester.tap(find.text(item));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }
}

/// Lets a toast finish so no timer is pending.
Future<void> _drain(WidgetTester tester) => tester.pump(const Duration(seconds: 4));

/// A widget test that lets toasts and the announcer's one-per-second gate expire before it ends
/// (no timer may stay pending).
@isTestGroup
void _test(String description, Future<void> Function(WidgetTester tester) body) => testWidgets(description, (tester) async {
      await body(tester);
      await tester.pump(const Duration(seconds: 4));
    });

void main() {
  group('the bin', () {
    _test('lists the assets newest first with their usage counts', (tester) async {
      await _pump(tester);
      expect(_cardOrder(tester), ['aud_a', 'img_a', 'vid_b', 'vid_a']);
      expect(find.descendant(of: _card('vid_a'), matching: find.text('Used ×1')), findsOneWidget);
      expect(find.descendant(of: _card('aud_a'), matching: find.text('Used ×1')), findsOneWidget);
      expect(find.descendant(of: _card('vid_b'), matching: find.text('Not used')), findsOneWidget);
      expect(find.descendant(of: _card('vid_a'), matching: find.text('beach.mp4')), findsOneWidget);
      expect(find.descendant(of: _card('vid_a'), matching: find.text('0:10')), findsOneWidget);
      expect(find.descendant(of: _card('img_a'), matching: find.textContaining(':')), findsNothing, reason: 'photos show no duration');
    });

    _test('usage counts follow the timeline', (tester) async {
      final rig = await _pump(tester);
      await rig.apply(InsertMedia([const MediaId('vid_a')], 10 * s));
      expect(find.descendant(of: _card('vid_a'), matching: find.text('Used ×2')), findsOneWidget);
      rig.editor.undo();
      await tester.pump();
      expect(find.descendant(of: _card('vid_a'), matching: find.text('Used ×1')), findsOneWidget);
    });

    _test('reversed renditions made for a clip are not listed', (tester) async {
      await _pump(
        tester,
        project: (repo) => _project(repo, assets: [
          ..._assets(),
          binAsset('vid_rev',
              name: 'beach reversed.mp4',
              derived: const ReversedSpec(MediaId('vid_a'), TimeRange(0, 4 * s), sourceQuickHash: 'q'),
              ownership: MediaOwnership.projectOwned),
        ]),
      );
      expect(_cardOrder(tester), isNot(contains('vid_rev')));
      expect(_cardOrder(tester), hasLength(4));
    });

    _test('an empty bin explains what to do', (tester) async {
      await _pump(tester, project: (repo) => _project(repo, assets: const [], clips: false));
      expect(find.byKey(const ValueKey('media-empty')), findsOneWidget);
      expect(find.text(MediaStrings.emptyTitle), findsOneWidget);
      expect(find.byKey(const ValueKey('media-filter-all')), findsNothing, reason: 'no filters without media');
    });

    _test('badges: missing, processing, optimizing, proxy ready and failed', (tester) async {
      final rig = await _pump(
        tester,
        project: (repo) => _project(repo, assets: [
          ..._assets(),
          binAsset('vid_p', name: 'making.mp4', status: const PendingStatus('job1')),
          binAsset('vid_o', name: 'opt.mp4', proxy: ProxyState.pending),
          binAsset('vid_r', name: 'proxy.mp4', proxy: ProxyState.ready),
          binAsset('vid_f', name: 'bad.mp4', status: const FailedStatus('decoderInitFailed')),
        ]),
      );
      rig.harness.mediaPool
          .emitAvailability({const MediaId('vid_b'): MediaAvailability.missing, const MediaId('img_a'): MediaAvailability.accessLost});
      await tester.pump();
      await tester.pump();
      Finder badge(String id, String text) => find.descendant(of: _card(id), matching: find.text(text));
      expect(badge('vid_b', MediaStrings.badgeMissing), findsOneWidget);
      expect(badge('img_a', MediaStrings.badgeNoAccess), findsOneWidget);
      expect(badge('vid_p', MediaStrings.badgeProcessing), findsOneWidget);
      expect(badge('vid_o', MediaStrings.badgeOptimizing), findsOneWidget);
      expect(badge('vid_r', MediaStrings.badgeProxyReady), findsOneWidget);
      expect(badge('vid_f', MediaStrings.badgeFailed), findsOneWidget);
      expect(badge('vid_a', MediaStrings.badgeMissing), findsNothing);
    });

    _test('thumbnails come from the engine for resolvable video and photos, not for audio or offline media', (tester) async {
      final rig = await _pump(
        tester,
        overrides: [
          planCompilerPortProvider.overrideWithValue(ResolvingPlanCompilerPort((_, p) => _resolver(p, offline: {const MediaId('vid_b')})))
        ],
      );
      final requests = rig.engine.thumbnails.requests;
      expect(requests.map((r) => r.media.uri), unorderedEquals(['file:///fake/vid_a', 'file:///fake/img_a']));
      expect(requests.every((r) => r.framesPerTile == 1 && r.tileIndex == 0), isTrue);
    });
  });

  group('filters and search', () {
    _test('the chips narrow the bin by kind; LUT shows only when the project has one', (tester) async {
      await _pump(tester);
      expect(find.byKey(const ValueKey('media-filter-lut')), findsNothing);
      await _tap(tester, find.byKey(const ValueKey('media-filter-video')));
      expect(_cardOrder(tester), ['vid_b', 'vid_a']);
      await _tap(tester, find.byKey(const ValueKey('media-filter-photos')));
      expect(_cardOrder(tester), ['img_a']);
      await _tap(tester, find.byKey(const ValueKey('media-filter-audio')));
      expect(_cardOrder(tester), ['aud_a']);
      await _tap(tester, find.byKey(const ValueKey('media-filter-all')));
      expect(_cardOrder(tester), hasLength(4));
    });

    _test('a LUT chip appears with a LUT in the pool and lists it', (tester) async {
      await _pump(tester,
          project: (repo) => _project(repo, assets: [..._assets(), binAsset('lut_a', kind: MediaKind.lut, name: 'teal.cube')]));
      await _tap(tester, find.byKey(const ValueKey('media-filter-lut')));
      expect(_cardOrder(tester), ['lut_a']);
    });

    _test('recordings count as audio and freeze frames as photos', (tester) async {
      await _pump(
        tester,
        project: (repo) => _project(repo, assets: [
          ..._assets(),
          binAsset('rec_a', kind: MediaKind.recording, name: 'voice.wav'),
          binAsset('still_a',
              kind: MediaKind.still, name: 'freeze.png', derived: const StillSpec(MediaId('vid_a'), 2 * s, sourceQuickHash: 'q')),
        ]),
      );
      await _tap(tester, find.byKey(const ValueKey('media-filter-audio')));
      expect(_cardOrder(tester), containsAll(['rec_a', 'aud_a']));
      await _tap(tester, find.byKey(const ValueKey('media-filter-photos')));
      expect(_cardOrder(tester), containsAll(['still_a', 'img_a']));
    });

    _test('search shows with more than 12 items and matches names case-insensitively', (tester) async {
      await _pump(tester);
      expect(find.byKey(const ValueKey('media-search')), findsNothing, reason: '4 items');
      await tester.pumpWidget(const SizedBox.shrink()); // a new ProviderScope for the next project
      final many = [for (var i = 0; i < 13; i++) binAsset('clip_$i', name: i == 7 ? 'Sunset Beach.mp4' : 'clip $i.mp4')];
      await _pump(tester, project: (repo) => _project(repo, assets: many, clips: false));
      expect(find.byKey(const ValueKey('media-search')), findsOneWidget);
      await tester.enterText(
          find.descendant(of: find.byKey(const ValueKey('media-search')), matching: find.byType(EditableText)), 'sunset');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(_cardOrder(tester), ['clip_7']);
      await tester.enterText(find.descendant(of: find.byKey(const ValueKey('media-search')), matching: find.byType(EditableText)), 'zzz');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('media-no-match')), findsOneWidget);
    });

    _test('exactly 12 items show no search field', (tester) async {
      await _pump(tester, project: (repo) => _project(repo, assets: [for (var i = 0; i < 12; i++) binAsset('c$i')], clips: false));
      expect(find.byKey(const ValueKey('media-search')), findsNothing);
    });
  });

  group('preview', () {
    _test('a tap previews the card in place: facts and actions, no timeline change', (tester) async {
      final rig = await _pump(tester);
      final depth = rig.historyDepth;
      await _tap(tester, _card('vid_b'));
      expect(find.byKey(const ValueKey('media-preview')), findsOneWidget);
      expect(find.byKey(const ValueKey('media-preview-facts')), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const ValueKey('media-preview-facts'))).data,
          'Video · 0:06 · 1920×1080 · ${formatDataSize(2 * 1024 * 1024)}');
      expect(rig.historyDepth, depth);
      await _tap(tester, _card('vid_b'));
      expect(find.byKey(const ValueKey('media-preview')), findsNothing, reason: 'a second tap closes it');
      await _tap(tester, _card('vid_b'));
      await _tap(tester, find.byKey(const ValueKey('media-preview-close')));
      expect(find.byKey(const ValueKey('media-preview')), findsNothing);
    });

    _test('the strip offers every action; overlays only for pictures', (tester) async {
      await _pump(tester);
      await _tap(tester, _card('aud_a'));
      expect(find.byKey(const ValueKey('media-preview-add')), findsOneWidget);
      expect(find.byKey(const ValueKey('media-preview-overlay')), findsNothing);
      await _tap(tester, _card('vid_b'));
      expect(find.byKey(const ValueKey('media-preview-overlay')), findsOneWidget);
      expect(find.byKey(const ValueKey('media-preview-info')), findsOneWidget);
      expect(find.byKey(const ValueKey('media-preview-remove')), findsOneWidget);
    });
  });

  group('add at the playhead', () {
    _test('"+" with ripple off adds a clip at the playhead: free space on the main lane, one entry', (tester) async {
      final rig = await _pump(tester);
      rig.editor.setModes((m) => m.copyWith(ripple: false));
      await rig.seek(12 * s);
      final depth = rig.historyDepth;
      await _tap(tester, find.byKey(const ValueKey('media-add-vid_b')));
      final main = rig.trackOf(TrackKind.video)!;
      expect(main.items.map((i) => i.range), [const TimeRange(0, 10 * s), const TimeRange(12 * s, 18 * s)]);
      expect((main.items.last as MediaClip).media, const MediaId('vid_b'));
      expect(rig.historyDepth, depth + 1);
      expect(rig.undoLabel, 'Add clip');
      expect(rig.state.selection.items, {main.items.last.id}, reason: 'the new clip is selected');
    });

    _test('"+" over an occupied main lane goes to a new lane when ripple is off', (tester) async {
      final rig = await _pump(tester);
      rig.editor.setModes((m) => m.copyWith(ripple: false));
      await rig.seek(4 * s);
      await _tap(tester, find.byKey(const ValueKey('media-add-vid_b')));
      final videoLanes = rig.project.timeline.tracks.where((t) => t.kind == TrackKind.video).toList();
      expect(videoLanes, hasLength(2));
      expect(videoLanes.first.items.single.range, const TimeRange(0, 10 * s), reason: 'the main lane is untouched');
      expect(videoLanes.last.items.single.range, const TimeRange(4 * s, 10 * s));
    });

    _test('with ripple on the main lane takes an insert: later clips move right', (tester) async {
      final rig = await _pump(tester);
      rig.editor.setModes((m) => m.copyWith(ripple: true));
      await rig.seek(10 * s); // the end of beach
      await rig.apply(InsertMedia([const MediaId('vid_a')], 10 * s));
      await rig.seek(10 * s);
      expect(rig.trackOf(TrackKind.video)!.items.map((i) => i.range), [const TimeRange(0, 10 * s), const TimeRange(10 * s, 20 * s)]);
      await _tap(tester, find.byKey(const ValueKey('media-add-vid_b')));
      final main = rig.trackOf(TrackKind.video)!;
      expect(
          main.items.map((i) => i.range), [const TimeRange(0, 10 * s), const TimeRange(10 * s, 16 * s), const TimeRange(16 * s, 26 * s)]);
      expect((main.items[1] as MediaClip).media, const MediaId('vid_b'));
      expect(rig.undoLabel, 'Add clip');
    });

    _test('audio goes to the music lane and a photo gets the default image length', (tester) async {
      final rig = await _pump(tester);
      rig.editor.setModes((m) => m.copyWith(ripple: false));
      await rig.seek(30 * s); // the end of the project
      await _tap(tester, find.byKey(const ValueKey('media-add-aud_a')));
      final music = rig.trackOf(TrackKind.audio)!;
      expect(music.items.last.range, const TimeRange(30 * s, 60 * s));
      await _tap(tester, find.byKey(const ValueKey('media-add-img_a')));
      final photo = rig.trackOf(TrackKind.video)!.items.last;
      expect(photo.range, const TimeRange(30 * s, 33 * s));
    });

    _test('a failed asset or a LUT cannot be added and says why', (tester) async {
      final rig = await _pump(
        tester,
        project: (repo) => _project(repo,
            assets: [..._assets(), binAsset('vid_f', status: const FailedStatus('x')), binAsset('lut_a', kind: MediaKind.lut)]),
      );
      final depth = rig.historyDepth;
      expect(tester.widget<VwishIconButton>(find.byKey(const ValueKey('media-add-vid_f'))).onPressed, isNull);
      expect(tester.widget<VwishIconButton>(find.byKey(const ValueKey('media-add-lut_a'))).onPressed, isNull);
      await _tap(tester, _card('lut_a'));
      expect(find.text(MediaStrings.lutNotPlaceable), findsOneWidget);
      expect(rig.historyDepth, depth);
    });

    _test('a refused add shows why and records nothing (locked main lane)', (tester) async {
      final rig = await _pump(tester);
      final main = rig.trackOf(TrackKind.video)!;
      await rig.apply(SetTrackFlags(main.id, locked: true));
      rig.editor.setModes((m) => m.copyWith(ripple: false));
      final depth = rig.historyDepth;
      await _tap(tester, find.byKey(const ValueKey('media-add-vid_b')));
      expect(rig.historyDepth, depth);
      expect(rig.eventsOf<EditorToast>(), isNotEmpty);
      await _drain(tester);
    });

    _test('the menu adds at the playhead too, and the semantics action does', (tester) async {
      final rig = await _pump(tester);
      rig.editor.setModes((m) => m.copyWith(ripple: false));
      await rig.seek(20 * s);
      await _menu(tester, 'vid_b', MediaStrings.addAtPlayhead);
      expect(rig.trackOf(TrackKind.video)!.items.last.start, 20 * s);
      final handle = tester.ensureSemantics();
      final node = tester.getSemantics(_card('img_a'));
      expect(node.label, contains('logo.png'));
      expect(node.label, contains('Photo'));
      final actions = node.getSemanticsData().customSemanticsActionIds!.map((id) => CustomSemanticsAction.getAction(id)!.label).toList();
      expect(actions, containsAll([MediaStrings.addAtPlayhead, MediaStrings.addAsOverlay, MediaStrings.info, MediaStrings.remove]));
      handle.dispose();
    });
  });

  group('add as overlay', () {
    _test('creates an overlay lane when none exists: picture-in-picture at 40 %, one history entry', (tester) async {
      final rig = await _pump(tester);
      await rig.seek(2 * s);
      final depth = rig.historyDepth;
      await _menu(tester, 'vid_b', MediaStrings.addAsOverlay);
      final overlay = rig.trackOf(TrackKind.overlay)!;
      final clip = overlay.items.single as MediaClip;
      expect(clip.media, const MediaId('vid_b'));
      expect(clip.range, const TimeRange(2 * s, 8 * s));
      expect(clip.visual!.transform.scale, 0.4);
      expect(clip.visual!.transform.position.x, greaterThan(0), reason: 'centre-right');
      expect(rig.historyDepth, depth + 1, reason: 'the lane, the clip and the placement are one entry');
      rig.editor.undo();
      await tester.pump();
      expect(rig.trackOf(TrackKind.overlay), isNull, reason: 'one undo removes the lane and the clip');
      expect(rig.project.timeline.tracks.expand((t) => t.items).whereType<MediaClip>().where((c) => c.media == const MediaId('vid_b')),
          isEmpty);
    });

    _test('reuses the topmost overlay lane while it is free, else makes another', (tester) async {
      final rig = await _pump(tester);
      await rig.seek(2 * s);
      await _menu(tester, 'vid_b', MediaStrings.addAsOverlay);
      await rig.seek(20 * s);
      await _menu(tester, 'img_a', MediaStrings.addAsOverlay);
      expect(rig.project.timeline.tracks.where((t) => t.kind == TrackKind.overlay), hasLength(1), reason: 'free at 20 s');
      await rig.seek(3 * s);
      await _menu(tester, 'img_a', MediaStrings.addAsOverlay);
      final overlays = rig.project.timeline.tracks.where((t) => t.kind == TrackKind.overlay).toList();
      expect(overlays, hasLength(2), reason: 'busy at 3 s');
      expect(overlays.last.items.single.range, const TimeRange(3 * s, 6 * s));
      await _drain(tester);
    });

    _test('audio cannot be an overlay: the menu item is disabled with the reason', (tester) async {
      final rig = await _pump(tester);
      await _tap(tester, find.byKey(const ValueKey('media-menu-aud_a')));
      expect(find.text(MediaStrings.overlayNeedsVisual), findsOneWidget);
      await tester.tap(find.text(MediaStrings.addAsOverlay));
      await tester.pumpAndSettle();
      expect(rig.trackOf(TrackKind.overlay), isNull);
    });
  });

  group('replace selected clip', () {
    _test('swaps the media and keeps the range; a shorter asset trims the clip', (tester) async {
      final rig = await _pump(tester);
      final clip = rig.trackOf(TrackKind.video)!.items.single;
      rig.editor.select(clip.id);
      await tester.pump();
      await _menu(tester, 'vid_b', MediaStrings.replaceSelected);
      final replaced = rig.trackOf(TrackKind.video)!.items.single as MediaClip;
      expect(replaced.id, clip.id);
      expect(replaced.media, const MediaId('vid_b'));
      expect(replaced.range, const TimeRange(0, 6 * s), reason: 'city is 6 s: the 10 s clip is trimmed to fit');
      expect(rig.undoLabel, 'Replace clip');
      rig.editor.undo();
      await tester.pump();
      expect((rig.trackOf(TrackKind.video)!.items.single as MediaClip).media, const MediaId('vid_a'));
      await _drain(tester);
    });

    _test('a longer replacement keeps the clip length', (tester) async {
      final rig = await _pump(tester, project: (repo) => _project(repo, assets: [..._assets(), binAsset('vid_long', duration: 60 * s)]));
      final clip = rig.trackOf(TrackKind.video)!.items.single;
      rig.editor.select(clip.id);
      await tester.pump();
      await _menu(tester, 'vid_long', MediaStrings.replaceSelected);
      expect(rig.trackOf(TrackKind.video)!.items.single.range, const TimeRange(0, 10 * s));
      await _drain(tester);
    });

    _test('without a selected clip it is disabled and the strip explains', (tester) async {
      final rig = await _pump(tester);
      await _tap(tester, find.byKey(const ValueKey('media-menu-vid_b')));
      expect(find.text(MediaStrings.replaceNeedsClip), findsOneWidget);
      await _closeMenu(tester);
      final depth = rig.historyDepth;
      await _tap(tester, _card('vid_b'));
      expect(rig.historyDepth, depth);
      expect(find.byKey(const ValueKey('media-preview-replace-reason')), findsOneWidget);
      expect(tester.widget<VwishButton>(find.byKey(const ValueKey('media-preview-replace'))).onPressed, isNull);
    });

    _test('a kind mismatch (audio on a video clip) and a locked lane are refused with reasons', (tester) async {
      final rig = await _pump(tester);
      final clip = rig.trackOf(TrackKind.video)!.items.single;
      rig.editor.select(clip.id);
      await tester.pump();
      await _tap(tester, _card('aud_a'));
      expect(find.text(MediaStrings.replaceKindMismatch), findsOneWidget);
      expect(MediaOperations.forProject(rig.id, rig.container.read).replaceBlocker(_assets()[3]), MediaStrings.replaceKindMismatch);
      await rig.apply(SetTrackFlags(rig.trackOf(TrackKind.video)!.id, locked: true));
      expect(MediaOperations.forProject(rig.id, rig.container.read).replaceBlocker(_assets()[1]), MediaStrings.replaceLocked);
    });

    _test('an audio clip takes audio', (tester) async {
      final rig = await _pump(tester,
          project: (repo) => _project(repo, assets: [..._assets(), binAsset('aud_b', kind: MediaKind.audio, duration: 60 * s)]));
      final song = rig.trackOf(TrackKind.audio)!.items.single;
      rig.editor.select(song.id);
      await tester.pump();
      await _menu(tester, 'aud_b', MediaStrings.replaceSelected);
      expect((rig.trackOf(TrackKind.audio)!.items.single as MediaClip).media, const MediaId('aud_b'));
    });
  });

  group('remove from project', () {
    _test('only unused media: one undoable pool edit that brings the card back', (tester) async {
      final rig = await _pump(tester);
      await _tap(tester, find.byKey(const ValueKey('media-menu-vid_a')));
      expect(find.text(MediaStrings.removeInUse), findsOneWidget, reason: 'beach is on the timeline');
      await _closeMenu(tester);
      final depth = rig.historyDepth;
      await _menu(tester, 'vid_b', MediaStrings.remove, settle: false);
      expect(_card('vid_b'), findsNothing);
      expect(rig.project.pool.contains(const MediaId('vid_b')), isFalse);
      expect(rig.historyDepth, depth + 1);
      expect(rig.undoLabel, MediaStrings.remove);
      expect(find.text(MediaStrings.removed), findsOneWidget);
      rig.editor.undo();
      await tester.pump();
      expect(_card('vid_b'), findsOneWidget);
      expect(rig.project.pool.contains(const MediaId('vid_b')), isTrue);
      await _drain(tester);
    });

    _test('the strip removes too, and a used asset stays', (tester) async {
      final rig = await _pump(tester);
      await _tap(tester, _card('vid_a'));
      expect(tester.widget<VwishButton>(find.byKey(const ValueKey('media-preview-remove'))).onPressed, isNull);
      expect(find.byKey(const ValueKey('media-preview-remove-reason')), findsOneWidget);
      await _tap(tester, _card('img_a'));
      await _tap(tester, find.byKey(const ValueKey('media-preview-remove')));
      expect(rig.project.pool.contains(const MediaId('img_a')), isFalse);
      expect(find.byKey(const ValueKey('media-preview')), findsNothing, reason: 'the strip closes with its asset');
      await _drain(tester);
    });
  });

  group('relink and info', () {
    _test('an offline asset offers Relink…, which runs the relink action', (tester) async {
      var relinks = 0;
      final rig = await _pump(
        tester,
        overrides: [
          editorActionBindingsProvider.overrideWithValue({
            EditorActionId.relink: EditorActionBinding(id: EditorActionId.relink, handler: (_) => relinks++),
          }),
        ],
      );
      rig.harness.mediaPool.emitAvailability({const MediaId('vid_b'): MediaAvailability.missing});
      await tester.pump();
      await tester.pump();
      await _tap(tester, find.byKey(const ValueKey('media-menu-vid_a')));
      expect(find.text(MediaStrings.relink), findsNothing, reason: 'available media has no Relink');
      await _closeMenu(tester);
      await _menu(tester, 'vid_b', MediaStrings.relink);
      expect(relinks, 1);
    });

    _test('Info lists the facts, where the file lives and how it is used', (tester) async {
      await _pump(tester);
      await _menu(tester, 'vid_a', MediaStrings.info);
      expect(find.byKey(const ValueKey('media-info-sheet')), findsOneWidget);
      for (final text in [
        'beach.mp4',
        'Video',
        '0:10',
        '1920×1080',
        '30 fps',
        'hevc',
        'aac',
        formatDataSize(2 * 1024 * 1024),
        MediaStrings.locationManaged,
        'Used ×1',
        MediaStrings.statusAvailable
      ]) {
        expect(find.text(text), findsWidgets, reason: text);
      }
    });
  });

  group('header', () {
    _test('the picker buttons import the picks through the import sheet and place them (switch on by default for an empty timeline)',
        (tester) async {
      final pool = ScriptedPool();
      final rig = await _pump(tester,
          project: (repo) => _project(repo, assets: const [], clips: false),
          pool: pool,
          surface: const EditorSurface(Size(390, 844), platform: TargetPlatform.android));
      expect(tester.widget<VwishSwitchRow>(find.byKey(const ValueKey('media-add-to-timeline'))).value, isTrue);
      expect(find.text('Gallery'), findsOneWidget, reason: 'Android names the photo picker Gallery');
      rig.engine.picker.nextPicks = [pickOf('new.mp4', size: 1000)];
      await _tap(tester, find.byKey(const ValueKey('media-pick-photos')));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(rig.engine.picker.requests.single.source, MediaPickSource.photos);
      expect(rig.engine.picker.requests.single.kinds, {MediaPickKind.video, MediaPickKind.image, MediaPickKind.audio});
      expect(pool.imported, ['new.mp4']);
      expect(rig.project.pool.length, 1);
      expect(rig.trackOf(TrackKind.video)!.items.single.range, const TimeRange(0, 4 * s));
      expect(find.text('new.mp4'), findsWidgets, reason: 'the card is in the bin');
      expect(rig.historyDepth, 1);
    });

    _test('Files also asks for LUTs; with the switch off the media goes to the bin only', (tester) async {
      final pool = ScriptedPool();
      final rig = await _pump(tester, pool: pool);
      expect(tester.widget<VwishSwitchRow>(find.byKey(const ValueKey('media-add-to-timeline'))).value, isFalse,
          reason: 'the timeline has clips');
      rig.engine.picker.nextPicks = [pickOf('extra.mp4', size: 1000)];
      await _tap(tester, find.byKey(const ValueKey('media-pick-files')));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(rig.engine.picker.requests.single.kinds, contains(MediaPickKind.lut));
      expect(rig.project.pool.length, 5);
      expect(rig.trackOf(TrackKind.video)!.items, hasLength(1), reason: 'bin only');
      expect(rig.historyDepth, 0, reason: 'imports are sticky pool changes, not history entries');
      expect(find.text('extra.mp4'), findsWidgets);
      // And with the switch on the same pick is placed at the playhead.
      await _tap(tester, find.byKey(const ValueKey('media-add-to-timeline')));
      rig.editor.setModes((m) => m.copyWith(ripple: false));
      await rig.seek(30 * s);
      rig.engine.picker.nextPicks = [pickOf('placed.mp4', size: 1000)];
      await _tap(tester, find.byKey(const ValueKey('media-pick-files')));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(rig.trackOf(TrackKind.video)!.items.last.start, 30 * s);
    });

    _test('a cancelled picker changes nothing; a failing picker explains', (tester) async {
      final rig = await _pump(tester);
      await _tap(tester, find.byKey(const ValueKey('media-pick-files')));
      expect(rig.project.pool.length, 4);
      expect(find.text('Import media'), findsNothing);
      rig.engine.failNext['picker.pick'] = const EngineError(EngineErrorCode.mediaOffline);
      await _tap(tester, find.byKey(const ValueKey('media-pick-files')));
      await _drain(tester);
    });

    _test('a rejected pick leaves the project alone and the sheet says why', (tester) async {
      final pool = ScriptedPool()..steps['bad.mkv'] = const RejectStep('containerUnsupportedIos');
      final rig = await _pump(tester, pool: pool);
      rig.engine.picker.nextPicks = [pickOf('bad.mkv', size: 1000)];
      await _tap(tester, find.byKey(const ValueKey('media-pick-files')));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.textContaining("can't be edited"), findsOneWidget);
      expect(rig.project.pool.length, 4);
      expect(rig.historyDepth, 0);
    });
  });

  group('drag from the bin', () {
    _test('touch long-presses, a pointer drags: the card carries MediaDragData', (tester) async {
      await _pump(tester);
      expect(find.descendant(of: _card('vid_a'), matching: find.byWidgetPredicate((w) => w is LongPressDraggable<MediaDragData>)),
          findsOneWidget);
      expect(
          tester.widget<LongPressDraggable<MediaDragData>>(find.byType(LongPressDraggable<MediaDragData>).first).data!.media, isNotEmpty);
    });

    _test('with a mouse the card is a plain Draggable', (tester) async {
      await _pump(tester, surface: const EditorSurface(Size(1280, 800), platform: TargetPlatform.macOS));
      expect(find.byType(Draggable<MediaDragData>), findsNWidgets(4));
      expect(find.byType(LongPressDraggable<MediaDragData>), findsNothing);
      final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await g.addPointer(location: tester.getCenter(_card('vid_a')));
      await g.down(tester.getCenter(_card('vid_a')));
      await g.moveBy(const Offset(40, 40));
      await tester.pump();
      expect(find.text('beach.mp4'), findsWidgets);
      await g.up();
      await tester.pump();
    });
  });

  group('the media action', () {
    test('binds only media and merges without duplicates', () {
      expect({for (final b in mediaBindings) b.id}, {EditorActionId.media});
      expect(identical(mediaBindings, mediaBindings), isTrue);
    });

    _test('opens the Media panel; "Add media here" seeks first so the bin adds there', (tester) async {
      final rig = await _pump(tester, panel: const SizedBox.shrink());
      expect(rig.state.inspector, isNull);
      rig.editor.openInspector(const MediaInspector());
      await tester.pump();
      expect(rig.state.inspector, isA<MediaInspector>());
    });
  });
}

/// A resolver that resolves every asset of a project except [offline] to a fake file.
PlanAssetResolver _resolver(EditProject project, {Set<MediaId> offline = const {}}) => MapPlanAssetResolver(originals: {
      for (final a in project.pool.assets.values)
        if (!offline.contains(a.id)) a.id: ResolvedMedia(uri: 'file:///fake/${a.id.value}', fingerprint: 'fp-${a.id.value}'),
    });
