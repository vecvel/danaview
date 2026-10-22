// OWNER: HOM-12
//
// BUILD_PLAN HOM-12, model half: the selection keeps pick order across toggles, select all in a
// group and drag-select; the mix decides the groups; the media group gives the right actions for
// photos-only, videos-only, mixed and document selections on editor and desktop platforms; "Play
// all" keeps selection order and skips photos while the player can't show them (V2-V4).

// ignore_for_file: depend_on_referenced_packages

import 'package:danaview_features/src/library/home/home_callbacks.dart';
import 'package:danaview_features/src/library/selection/selection_bar.dart';
import 'package:danaview_library/danaview_library.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'selection_fixtures.dart';

List<String> ids(Iterable<MediaItem> items) => [for (final i in items) i.id.value];

final HomeCallbacks allCallbacks = HomeCallbacks(onMakeMontage: (_) {}, onBatchEditPhotos: (_) {});

List<String> actionIds(HomeSelection selection,
    {TargetPlatform platform = TargetPlatform.iOS, HomeCallbacks? callbacks, bool photos = false}) {
  final groups = selectionGroupsFor(
    SelectionActionContext(selection: selection, callbacks: callbacks ?? allCallbacks, platform: platform, playerShowsPhotos: photos),
    const [mediaSelectionGroup],
  );
  return [for (final g in groups) for (final a in g.actions) '${g.id}/${a.id}'];
}

void main() {
  group('HomeSelectionController', () {
    test('toggle keeps pick order and drops on second tap', () {
      final c = HomeSelectionController();
      c.toggle(video(3));
      c.toggle(photo(1));
      c.toggle(video(2));
      expect(ids(c.state.items), ['fe_video3', 'fe_photo1', 'fe_video2']);
      c.toggle(photo(1));
      expect(ids(c.state.items), ['fe_video3', 'fe_video2']);
      c.toggle(photo(1));
      expect(ids(c.state.items), ['fe_video3', 'fe_video2', 'fe_photo1']);
      expect(c.state.orderOf(photo(1)), 3);
      expect(c.state.orderOf(photo(9)), isNull);
    });

    test('items compare by id, so the same file from two tabs is one entry', () {
      final c = HomeSelectionController();
      c.select(photo(1));
      c.select(photo(1, uri: '/elsewhere.jpg'));
      expect(c.state.length, 1);
      expect(HomeSelection.of([photo(1), photo(2), photo(1)]).length, 2);
    });

    test('select all in a group appends the missing ones, then deselects all', () {
      final c = HomeSelectionController();
      c.select(photo(2));
      final groupItems = [photo(1), photo(2), photo(3)];
      c.toggleAll(groupItems);
      expect(ids(c.state.items), ['fe_photo2', 'fe_photo1', 'fe_photo3']);
      expect(c.state.containsAll(groupItems), isTrue);
      c.select(video(1));
      c.toggleAll(groupItems);
      expect(ids(c.state.items), ['fe_video1']);
      c.toggleAll(const []);
      expect(ids(c.state.items), ['fe_video1']);
    });

    test('removeIds drops vanished items; clear leaves selection mode', () {
      final c = HomeSelectionController()
        ..select(photo(1))
        ..select(video(1));
      c.removeIds({photo(1).id});
      expect(ids(c.state.items), ['fe_video1']);
      c.clear();
      expect(c.state.isActive, isFalse);
    });

    test('toString never prints names or paths', () {
      final s = HomeSelection.of([photo(1), video(1)]).toString();
      expect(s, isNot(contains('Photo')));
      expect(s, isNot(contains('/library')));
    });
  });

  group('DragSelectSession', () {
    final row = [for (var i = 0; i < 8; i++) photo(i)];

    test('selects from the anchor toward the finger, in reach order, and shrinks back', () {
      final base = HomeSelection.of([video(1)]);
      final s = DragSelectSession(base: base, items: row, anchor: 5);
      expect(s.selecting, isTrue);
      expect(ids(s.update(2).items), ['fe_video1', 'fe_photo5', 'fe_photo4', 'fe_photo3', 'fe_photo2']);
      expect(ids(s.update(4).items), ['fe_video1', 'fe_photo5', 'fe_photo4']);
      expect(ids(s.update(7).items), ['fe_video1', 'fe_photo5', 'fe_photo6', 'fe_photo7']);
      expect(ids(s.update(99).items), ['fe_video1', 'fe_photo5', 'fe_photo6', 'fe_photo7']);
    });

    test('starting on a selected item deselects the range and restores it when moving back', () {
      final base = HomeSelection.of([row[1], row[2], row[3], row[4]]);
      final s = DragSelectSession(base: base, items: row, anchor: 2);
      expect(s.selecting, isFalse);
      expect(ids(s.update(4).items), ['fe_photo1']);
      expect(ids(s.update(2).items), ['fe_photo1', 'fe_photo3', 'fe_photo4']);
    });

    test('items already selected keep their original pick order', () {
      final base = HomeSelection.of([row[3]]);
      final s = DragSelectSession(base: base, items: row, anchor: 1);
      expect(ids(s.update(4).items), ['fe_photo3', 'fe_photo1', 'fe_photo2', 'fe_photo4']);
    });
  });

  group('mix', () {
    test('classifies every combination', () {
      expect(HomeSelection.empty.mix, SelectionMix.empty);
      expect(HomeSelection.of([photo(1), photo(2)]).mix, SelectionMix.photos);
      expect(HomeSelection.of([video(1)]).mix, SelectionMix.videos);
      expect(HomeSelection.of([video(1), photo(1)]).mix, SelectionMix.media);
      expect(HomeSelection.of([document(1)]).mix, SelectionMix.documents);
      expect(HomeSelection.of([photo(1), document(1)]).mix, SelectionMix.mixedWithDocuments);
    });
  });

  group('media group', () {
    test('photos only: montage, batch edit (no play while the player shows no photos)', () {
      expect(actionIds(HomeSelection.of([photo(1), photo(2)])), ['media/montage', 'media/batch-edit']);
      expect(actionIds(HomeSelection.of([photo(1)]), photos: true), ['media/montage', 'media/batch-edit', 'media/play']);
    });

    test('videos only: montage, play, add to playlist', () {
      expect(actionIds(HomeSelection.of([video(1), video(2)])), ['media/montage', 'media/play', 'media/add-to-playlist']);
    });

    test('mixed photos and videos: montage, play, add to playlist; no batch edit', () {
      expect(actionIds(HomeSelection.of([photo(1), video(1)])), ['media/montage', 'media/play', 'media/add-to-playlist']);
    });

    test('documents (alone or mixed) get no media group', () {
      expect(actionIds(HomeSelection.of([document(1)])), isEmpty);
      expect(actionIds(HomeSelection.of([video(1), document(1)])), isEmpty);
    });

    test('editor actions are hidden on desktop and when their callback is null', () {
      for (final p in [TargetPlatform.macOS, TargetPlatform.windows, TargetPlatform.linux]) {
        expect(actionIds(HomeSelection.of([photo(1), video(1)]), platform: p), ['media/play', 'media/add-to-playlist']);
        expect(actionIds(HomeSelection.of([photo(1)]), platform: p), isEmpty);
      }
      expect(actionIds(HomeSelection.of([photo(1)]), platform: TargetPlatform.android), ['media/montage', 'media/batch-edit']);
      expect(actionIds(HomeSelection.of([photo(1)]), callbacks: HomeCallbacks.none), isEmpty);
    });

    test('groups from several builders are sorted by order, empty ones dropped', () {
      SelectionActionGroup files(SelectionActionContext c) => SelectionActionGroup(
            id: 'files',
            title: 'File actions',
            order: 10,
            actions: [SelectionAction(id: 'share', label: 'Share', icon: Icons.share, onInvoke: (_) {})],
          );
      SelectionActionGroup? none(SelectionActionContext c) => null;
      SelectionActionGroup first(SelectionActionContext c) => const SelectionActionGroup(id: 'empty', title: 'x', actions: [], order: -1);
      final groups = selectionGroupsFor(
        SelectionActionContext(selection: HomeSelection.of([document(1)]), callbacks: allCallbacks, platform: TargetPlatform.iOS),
        [files, none, first, mediaSelectionGroup],
      );
      expect([for (final g in groups) g.id], ['files']);
      final media = selectionGroupsFor(
        SelectionActionContext(selection: HomeSelection.of([video(1)]), callbacks: allCallbacks, platform: TargetPlatform.iOS),
        [files, mediaSelectionGroup],
      );
      expect([for (final g in media) g.id], ['media', 'files']);
    });
  });

  group('play queue (V2-V4)', () {
    test('no platform is verified to show photos in the player yet', () {
      for (final p in TargetPlatform.values) {
        expect(playerShowsPhotos(p), isFalse, reason: '$p');
      }
    });

    test('keeps selection order and skips photos while unsupported', () {
      final q = playQueueFor([video(2), photo(1), video(1), photo(2)], photosPlayable: false);
      expect([for (final r in q.refs) r.id], ['fe_video2', 'fe_video1']);
      expect(q.skippedPhotos, 2);
      expect(q.refs.first.pathOrUri, '/library/files/video2.mp4');
    });

    test('queues file photos in order once supported; system assets are still skipped', () {
      final q = playQueueFor([photo(1), video(1), photo(2, uri: 'ph://ABC'), photo(3, uri: 'file:///x.jpg')], photosPlayable: true);
      expect([for (final r in q.refs) r.id], ['fe_photo1', 'fe_video1', 'fe_photo3']);
      expect(q.skippedPhotos, 1);
    });

    test('only JPEG stills join the queue: the bundled libmpv has no PNG/HEIC/TIFF/GIF decoder', () {
      final q = playQueueFor([
        photo(1),
        photo(2, uri: '/library/files/photo2.heic', mimeType: 'image/heic'),
        video(1),
        photo(3, uri: '/library/files/photo3.png', mimeType: 'image/png'),
        photo(4, uri: '/library/files/photo4.JPEG', mimeType: ''),
        photo(5, uri: '/library/files/photo5.gif', mimeType: 'application/octet-stream'),
      ], photosPlayable: true);
      expect([for (final r in q.refs) r.id], ['fe_photo1', 'fe_video1', 'fe_photo4']);
      expect(q.skippedPhotos, 3);
      expect(playerDecodesPhoto(photo(6, mimeType: 'image/JPEG')), isTrue);
      expect(playerDecodesPhoto(photo(7, uri: '/x/a.webp', mimeType: 'image/webp')), isFalse);
    });
  });
}
