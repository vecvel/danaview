// OWNER: HOM-12
//
// BUILD_PLAN HOM-12, widget half: the multi-select bar shows the right groups for photos-only,
// videos-only, mixed and document selections; montage, batch edit, play and add to playlist
// receive the items in selection order; "Play all" skips photos with a notice (V2-V4); clear,
// Escape and back leave selection mode; drag-select, tap-to-toggle and select all in a group; the
// bar inside the Home shell (DANAVIEW_FILES_HOME on); and ARCH §1.4: no overflow at 280–1280 px ×
// text scale 0.85–1.35, targets ≥ 44 px, semantics labels, computed contrast.

// ignore_for_file: depend_on_referenced_packages

import 'package:danaview_domain/danaview_domain.dart';
import 'package:danaview_features/danaview_features.dart';
import 'package:danaview_features/src/library/selection/selection_bar.dart';
import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../library_test_utils.dart';
import '../home_shell/home_shell_support.dart';
import 'selection_fixtures.dart';

final List<MediaItem> _row = [for (var i = 0; i < 6; i++) photo(i)];
const double _cell = 44; // 6 cells fit the 280 px surface

/// A stand-in tab: a row of [_row] cells inside a drag region; tapping a cell opens or toggles.
class _FakeTab extends ConsumerWidget {
  const _FakeTab({required this.opened});

  final List<int> opened;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selection = ref.watch(homeSelectionProvider);
    return Align(
      alignment: Alignment.topLeft,
      child: SelectionDragRegion(
        items: _row,
        indexAt: (p) => p.dy < 0 || p.dy > _cell ? null : (p.dx ~/ _cell).clamp(0, _row.length - 1),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          for (final (i, item) in _row.indexed)
            GestureDetector(
              key: ValueKey('cell-$i'),
              onTap: selectionAwareTap(ref, item, () => opened.add(i)),
              child: SizedBox(
                width: _cell,
                height: _cell,
                child: Center(child: SelectionCheckMark(order: selection.orderOf(item))),
              ),
            ),
        ]),
      ),
    );
  }
}

Widget _harness(
  LibraryTestEnv env, {
  HomeCallbacks callbacks = HomeCallbacks.none,
  TargetPlatform platform = TargetPlatform.iOS,
  double textScale = 1,
  VoidCallback? onOpenPlayer,
  List<SelectionGroupBuilder> extraGroups = const [],
  List<int>? opened,
  List<Override> overrides = const [],
}) =>
    libraryTestApp(
      env,
      HomeCallbacksScope(
        callbacks: callbacks,
        child: Scaffold(
          backgroundColor: DanaviewColors.background,
          body: Stack(children: [
            Positioned.fill(child: _FakeTab(opened: opened ?? [])),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: HomeSelectionBar(onOpenPlayer: onOpenPlayer, extraGroups: extraGroups),
            ),
          ]),
        ),
      ),
      platform: platform,
      textScale: textScale,
      overrides: overrides,
    );

ProviderContainer _container(WidgetTester tester) => ProviderScope.containerOf(tester.element(find.byType(Scaffold).first));

Future<void> _tapAction(WidgetTester tester, String id) async {
  final finder = find.byKey(ValueKey('selection-action-$id'));
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
}

Future<void> _select(WidgetTester tester, List<MediaItem> items) async {
  final c = _container(tester).read(homeSelectionProvider.notifier);
  c.clear();
  for (final i in items) {
    c.select(i);
  }
  await tester.pump();
}

List<String> _visibleActions(WidgetTester tester) => [
      for (final e in find.byWidgetPredicate((w) => w is DanaviewButton && w.key is ValueKey<String>).evaluate())
        ((e.widget.key! as ValueKey<String>).value).replaceFirst('selection-action-', ''),
    ];

HomeCallbacks _recording(List<List<String>> montage, List<List<String>> batch) => HomeCallbacks(
      onMakeMontage: (items) => montage.add([for (final i in items) i.id.value]),
      onBatchEditPhotos: (items) => batch.add([for (final i in items) i.id.value]),
    );

/// HOM-22's group stand-in: six file actions after the media group.
SelectionActionGroup _files(SelectionActionContext c) => SelectionActionGroup(
      id: 'files',
      title: 'File actions',
      order: 10,
      actions: [
        for (final (id, label) in [('share', 'Share'), ('move', 'Move to…'), ('copy', 'Copy to…'), ('fav', 'Favourite'), ('save', 'Save to Files'), ('delete', 'Delete')])
          SelectionAction(id: id, label: label, icon: Icons.ios_share, onInvoke: (_) {}),
      ],
    );

/// Contrast of [fg] on [bg] composited over [under].
double _contrastOver(Color fg, Color bg, Color under) => DanaviewColors.contrastRatio(fg, Color.alphaBlend(bg, under));

void main() {
  late LibraryTestEnv env;

  setUp(() async => env = await LibraryTestEnv.create());

  Future<void> finish(WidgetTester tester) async {
    DanaviewToast.dismiss();
    await tester.pumpWidget(const SizedBox());
    await env.dispose();
  }

  testWidgets('hidden until something is selected; count and groups follow the selection', (tester) async {
    useSurface(tester, librarySurfaces[2]);
    await tester.pumpWidget(_harness(env, callbacks: _recording([], [])));
    expect(find.byKey(const ValueKey('home-selection-bar')), findsNothing);

    await _select(tester, [photo(1), photo(2)]);
    expect(find.text('2 selected'), findsOneWidget);
    expect(find.byKey(const ValueKey('selection-group-media')), findsOneWidget);
    expect(_visibleActions(tester), ['montage', 'batch-edit']);
    expect(find.text('Batch edit photos'), findsOneWidget);

    await _select(tester, [video(1), video(2), video(3)]);
    expect(find.text('3 selected'), findsOneWidget);
    expect(_visibleActions(tester), ['montage', 'play', 'add-to-playlist']);
    expect(find.text('Add to playlist'), findsOneWidget);

    await _select(tester, [photo(1), video(1)]);
    expect(_visibleActions(tester), ['montage', 'play', 'add-to-playlist']);
    expect(find.text('Add videos to playlist'), findsOneWidget);

    await _select(tester, [document(1)]);
    expect(find.text('1 selected'), findsOneWidget);
    expect(find.byKey(const ValueKey('selection-group-media')), findsNothing);
    expect(_visibleActions(tester), isEmpty);

    await _select(tester, [photo(1), document(1)]);
    expect(find.byKey(const ValueKey('selection-group-media')), findsNothing);
    await finish(tester);
  });

  testWidgets('a provider-registered group (HOM-22) joins the bar after the media group', (tester) async {
    useSurface(tester, librarySurfaces[2]);
    await tester.pumpWidget(_harness(
      env,
      callbacks: _recording([], []),
      overrides: [selectionActionGroupsProvider.overrideWithValue(const [mediaSelectionGroup, _files])],
    ));
    await _select(tester, [video(1)]);
    expect(_visibleActions(tester), ['montage', 'play', 'add-to-playlist', 'share', 'move', 'copy', 'fav', 'save', 'delete']);
    await _select(tester, [document(1)]);
    expect(find.byKey(const ValueKey('selection-group-files')), findsOneWidget);
    expect(_visibleActions(tester), ['share', 'move', 'copy', 'fav', 'save', 'delete']);
    await finish(tester);
  });

  testWidgets('desktop hides the editor actions', (tester) async {
    useSurface(tester, librarySurfaces[4]);
    await tester.pumpWidget(_harness(env, callbacks: _recording([], []), platform: TargetPlatform.macOS));
    await _select(tester, [photo(1), video(1)]);
    expect(_visibleActions(tester), ['play', 'add-to-playlist']);
    await _select(tester, [photo(1)]);
    expect(_visibleActions(tester), isEmpty);
    await finish(tester);
  });

  testWidgets('montage and batch edit receive the items in selection order and end selection mode', (tester) async {
    useSurface(tester, librarySurfaces[2]);
    final montage = <List<String>>[], batch = <List<String>>[];
    await tester.pumpWidget(_harness(env, callbacks: _recording(montage, batch)));

    await _select(tester, [video(2), photo(3), video(1), photo(1)]);
    await _tapAction(tester, 'montage');
    await tester.pump();
    expect(montage, [
      ['fe_video2', 'fe_photo3', 'fe_video1', 'fe_photo1'],
    ]);
    expect(_container(tester).read(homeSelectionProvider).isEmpty, isTrue);
    expect(find.byKey(const ValueKey('home-selection-bar')), findsNothing);

    await _select(tester, [photo(4), photo(2), photo(3)]);
    await _tapAction(tester, 'batch-edit');
    await tester.pump();
    expect(batch, [
      ['fe_photo4', 'fe_photo2', 'fe_photo3'],
    ]);
    await finish(tester);
  });

  testWidgets('Play all queues the videos in selection order, skips photos with a notice, opens the player', (tester) async {
    useSurface(tester, librarySurfaces[2]);
    var opened = 0;
    await tester.pumpWidget(_harness(env, onOpenPlayer: () => opened++));

    await _select(tester, [video(3), photo(1), video(1), video(2)]);
    await _tapAction(tester, 'play');
    await tester.pump();
    final queue = _container(tester).read(queueControllerProvider);
    expect([for (final r in queue.items) r.id], ['fe_video3', 'fe_video1', 'fe_video2']);
    expect(queue.currentIndex, 0);
    expect(opened, 1);
    expect(find.text("The photo was skipped: the player can't show photos yet"), findsOneWidget);
    expect(_container(tester).read(homeSelectionProvider).isEmpty, isTrue);
    await finish(tester);
  });

  testWidgets('photos-only Play all appears only where the player shows photos', (tester) async {
    useSurface(tester, librarySurfaces[2]);
    var opened = 0;
    await tester.pumpWidget(_harness(
      env,
      onOpenPlayer: () => opened++,
      overrides: [playerShowsPhotosProvider.overrideWithValue(true)],
    ));
    await _select(tester, [photo(2), photo(1)]);
    expect(_visibleActions(tester), ['play']);
    await _tapAction(tester, 'play');
    await tester.pump();
    expect([for (final r in _container(tester).read(queueControllerProvider).items) r.id], ['fe_photo2', 'fe_photo1']);
    expect(opened, 1);
    await finish(tester);
  });

  testWidgets('Add to playlist adds the selected videos in selection order', (tester) async {
    useSurface(tester, librarySurfaces[2]);
    await env.library.createPlaylist('Trip');
    await tester.pumpWidget(_harness(env));
    await tester.pump();

    await _select(tester, [video(2), photo(1), video(1)]);
    await _tapAction(tester, 'add-to-playlist');
    await tester.pumpAndSettle();
    expect(find.text('Add 2 videos to playlist'), findsOneWidget);
    await tester.tap(find.text('Trip'));
    await tester.pumpAndSettle();
    expect([for (final r in env.library.getPlaylist('Trip')) r.id], ['fe_video2', 'fe_video1']);
    expect(_container(tester).read(homeSelectionProvider).isEmpty, isTrue);
    await finish(tester);
  });

  testWidgets('clear button, Escape and back leave selection mode', (tester) async {
    useSurface(tester, librarySurfaces[2]);
    await tester.pumpWidget(_harness(env));

    await _select(tester, [video(1)]);
    await tester.tap(find.byKey(const ValueKey('selection-clear')));
    await tester.pump();
    expect(_container(tester).read(homeSelectionProvider).isEmpty, isTrue);

    await _select(tester, [video(1)]);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(_container(tester).read(homeSelectionProvider).isEmpty, isTrue);

    await _select(tester, [video(1)]);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
    await navigator.maybePop();
    await tester.pump();
    expect(_container(tester).read(homeSelectionProvider).isEmpty, isTrue);
    await finish(tester);
  });

  testWidgets('long press and drag selects a range; taps open, or toggle while selecting', (tester) async {
    useSurface(tester, librarySurfaces[2]);
    final opened = <int>[];
    await tester.pumpWidget(_harness(env, opened: opened));

    await tester.tap(find.byKey(const ValueKey('cell-0')));
    await tester.pump();
    expect(opened, [0]);

    final start = tester.getCenter(find.byKey(const ValueKey('cell-1')));
    final gesture = await tester.startGesture(start);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    expect([for (final i in _container(tester).read(homeSelectionProvider).items) i.id.value], ['fe_photo1']);
    for (final i in [2, 3, 4]) {
      await gesture.moveTo(tester.getCenter(find.byKey(ValueKey('cell-$i'))));
      await tester.pump();
    }
    await gesture.moveTo(tester.getCenter(find.byKey(const ValueKey('cell-3'))));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect([for (final i in _container(tester).read(homeSelectionProvider).items) i.id.value], ['fe_photo1', 'fe_photo2', 'fe_photo3']);
    expect(find.text('3 selected'), findsOneWidget);
    expect(find.text('2'), findsOneWidget); // photo2's pick number on its check mark

    await tester.tap(find.byKey(const ValueKey('cell-5')));
    await tester.tap(find.byKey(const ValueKey('cell-1')));
    await tester.pump();
    expect([for (final i in _container(tester).read(homeSelectionProvider).items) i.id.value], ['fe_photo2', 'fe_photo3', 'fe_photo5']);
    expect(opened, [0]);
    await finish(tester);
  });

  testWidgets('select all in a group toggles the whole group', (tester) async {
    final handle = tester.ensureSemantics();
    useSurface(tester, librarySurfaces[2]);
    await tester.pumpWidget(libraryTestApp(
      env,
      Scaffold(body: Center(child: SelectAllInGroupButton(items: _row.take(3).toList(), groupLabel: 'Today'))),
    ));
    expect(find.bySemanticsLabel('Select all in Today'), findsOneWidget);
    await tester.tap(find.text('Select all'));
    await tester.pump();
    expect(_container(tester).read(homeSelectionProvider).length, 3);
    expect(find.bySemanticsLabel('Deselect all in Today'), findsOneWidget);
    await tester.tap(find.text('Deselect all'));
    await tester.pump();
    expect(_container(tester).read(homeSelectionProvider).isEmpty, isTrue);
    handle.dispose();
    await finish(tester);
  });

  testWidgets('inside the Home shell: the slot draws the bar over every tab (DANAVIEW_FILES_HOME on)', (tester) async {
    useFilesHome(true);
    useSurface(tester, librarySurfaces[2]);
    final montage = <List<String>>[];
    await tester.pumpWidget(libraryTestApp(
      env,
      DanaviewHomeScreen(
        onOpenPlayer: () {},
        onOpenFolder: (_) {},
        onOpenPlaylist: (_) {},
        callbacks: _recording(montage, []),
        tabSlots: HomeTabSlots(selectionBar: (context) => const HomeSelectionBar()),
      ),
    ));
    await pumpFrames(tester);
    expect(find.byKey(const ValueKey('home-selection-bar')), findsNothing);
    await _select(tester, [video(1), photo(1)]);
    expect(find.byKey(const ValueKey('home-selection-bar')), findsOneWidget);
    await tester.tap(find.byKey(homeTabKey(HomeTab.photos)));
    await pumpFrames(tester, count: 2);
    expect(find.byKey(const ValueKey('home-selection-bar')), findsOneWidget);
    await _tapAction(tester, 'montage');
    await tester.pump();
    expect(montage, [
      ['fe_video1', 'fe_photo1'],
    ]);
    await finish(tester);
  });

  testWidgets('no overflow at 280–1280 px × 0.85–1.35; targets ≥ 44 px; semantics labels', (tester) async {
    final handle = tester.ensureSemantics();
    for (final surface in homeShellSurfaces) {
      useSurface(tester, surface);
      await tester.pumpWidget(_harness(
        env,
        callbacks: _recording([], []),
        textScale: surface.textScale,
        extraGroups: const [_files],
      ));
      await _select(tester, [for (var i = 0; i < 12; i++) i.isEven ? video(i) : photo(i)]);
      expect(tester.takeException(), isNull, reason: '$surface');
      final bar = tester.getRect(find.byKey(const ValueKey('home-selection-bar')));
      expect(bar.left >= 0 && bar.right <= surface.size.width, isTrue, reason: '$surface');
      expect(bar.bottom <= surface.size.height - surface.padding.bottom, isTrue, reason: '$surface');
      for (final key in ['selection-clear', 'selection-action-montage', 'selection-action-play', 'selection-action-add-to-playlist']) {
        final size = tester.getSize(find.byKey(ValueKey(key)));
        expect(size.height >= 44 && size.width >= 44, isTrue, reason: '$key $size $surface');
      }
      expect(find.text('12 selected'), findsOneWidget);
    }
    expect(find.bySemanticsLabel('Clear selection'), findsOneWidget);
    expect(find.bySemanticsLabel('Play all'), findsOneWidget);
    expect(find.bySemanticsLabel('Make video montage'), findsOneWidget);
    expect(find.bySemanticsLabel('Media actions'), findsOneWidget);
    expect(find.bySemanticsLabel('File actions'), findsOneWidget);
    handle.dispose();
    await finish(tester);
  });

  test('computed contrast of the bar text and buttons is at least 4.5:1', () {
    const bar = DanaviewColors.surfaceElevated;
    expect(DanaviewColors.contrastRatio(DanaviewColors.foregroundOn(bar), bar), greaterThanOrEqualTo(4.5));
    expect(_contrastOver(DanaviewColors.primaryLight, DanaviewColors.primaryTonal, bar), greaterThanOrEqualTo(4.5));
    final onCheck = DanaviewColors.foregroundOn(DanaviewColors.primary);
    expect(DanaviewColors.contrastRatio(onCheck, DanaviewColors.primary), greaterThanOrEqualTo(4.5));
  });

  test('count labels', () {
    expect(selectionCountLabel(1), '1 selected');
    expect(selectionCountLabel(40), '40 selected');
    expect(skippedPhotosNotice(3, nothingQueued: false), "3 photos were skipped: the player can't show photos yet");
    expect(const MediaRef(id: 'x', title: 'x', pathOrUri: '/x').id, 'x');
  });
}
