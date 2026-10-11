// OWNER: CORE-03
//
// EditProject getters (ux.md §2.1), the lazily built cached index, Timeline duration.

import 'package:test/test.dart';
import 'package:danaview_editor_core/model.dart';

import 'model_fixtures.dart';

void main() {
  final a = clip('it_aaaaaaaaaaa1', 0, 30);
  final b = clip('it_aaaaaaaaaaa2', 30, 30);
  final tx = text('it_aaaaaaaaaaa3', 10, 100);
  final au = clip('it_aaaaaaaaaaa4', 5, 20);
  final tVideo = track('tr_video0000001', TrackKind.video, main: true, items: [a, b]);
  final tText = track('tr_text00000001', TrackKind.text, items: [tx]);
  final tAudio = track('tr_audio0000001', TrackKind.audio, items: [au]);

  EditProject build({int docRevision = 0}) => EditProject(
        id: const ProjectId('pr_aaaaaaaaaaaa'),
        meta: ProjectMeta(name: 'Trip', createdAt: t0, updatedAt: t0),
        timeline: Timeline(
          tracks: [tVideo, tText, tAudio],
          markers: const [Marker(id: MarkerId('mk_a'), time: 5)],
          revision: 7,
        ),
        docRevision: docRevision,
      );

  group('ux.md §2.1 getters', () {
    final p = build();
    test('id, name, revision, settings, tracks, markers, media, duration', () {
      expect(p.id, 'pr_aaaaaaaaaaaa');
      expect(p.name, 'Trip');
      expect(p.revision, 7);
      expect(p.settings, const ProjectSettings());
      expect(p.tracks.map((t) => t.id), ['tr_video0000001', 'tr_text00000001', 'tr_audio0000001']);
      expect(p.markers.single.time, 5);
      expect(p.media, MediaPool.empty);
      expect(identical(p.media, p.pool), isTrue);
      expect(p.duration, f(110), reason: 'end of the last item over all tracks');
    });

    test('duration of an empty project is 0 and a timeline caches it', () {
      expect(project().duration, 0);
      final tl = Timeline(tracks: [tVideo]);
      expect(tl.duration, f(60));
      expect(identical(tl.duration, tl.duration), isTrue);
    });

    test('mainTrack is the first video track', () {
      expect(p.timeline.mainTrack?.id, 'tr_video0000001');
      expect(Timeline().mainTrack, isNull);
    });

    test('copyWith keeps unchanged parts and distinguishes docRevision', () {
      final q = p.copyWith(docRevision: 1);
      expect(q.timeline, same(p.timeline));
      expect(q.pool, same(p.pool));
      expect(q, isNot(p));
      expect(p.copyWith(), p);
      expect(p.copyWith(meta: p.meta.copyWith(name: 'x')).name, 'x');
      expect(p.copyWith(view: const ViewState(playhead: 5)).view.playhead, 5);
    });

    test('equality and hashCode', () {
      expect(build(), build());
      expect(build().hashCode, build().hashCode);
      expect(build(), isNot(build(docRevision: 1)));
    });
  });

  group('index', () {
    test('is built once per instance (lazy and cached)', () {
      final p = build();
      final i1 = p.index;
      final i2 = p.index;
      expect(identical(i1, i2), isTrue);
      expect(identical(p.copyWith(docRevision: 3).index, i1), isFalse, reason: 'a new project builds its own index');
    });

    test('locates items, tracks and positions', () {
      final p = build();
      final loc = p.index.locate(b.id)!;
      expect(loc.track.id, 'tr_video0000001');
      expect(loc.trackIndex, 0);
      expect(loc.itemIndex, 1);
      expect(loc.item, b);
      expect(p.index.locate(au.id)!.trackIndex, 2);
      expect(p.index.item(tx.id), tx);
      expect(p.index.item(const ItemId('it_unknown')), isNull);
      expect(p.index.locate(const ItemId('it_unknown')), isNull);
      expect(p.index.trackIndexOf(const TrackId('tr_text00000001')), 1);
      expect(p.index.trackIndexOf(const TrackId('tr_nope')), isNull);
      expect(p.index.itemCount, 4);
    });

    test('an empty project has an empty index', () {
      expect(project().index.itemCount, 0);
    });
  });

  group('ProjectOrigin', () {
    test('default is projects; a player origin carries the fingerprint, never a path', () {
      expect(ProjectMeta(name: 'n', createdAt: t0, updatedAt: t0).origin, ProjectOrigin.projects);
      const o = FromPlayerOrigin(quickHash: 'abc', sizeBytes: 5);
      expect(o.quickHash, 'abc');
      expect(o.sizeBytes, 5);
      String name(ProjectOrigin o) => switch (o) {
            ProjectsOrigin() => 'projects',
            FromPlayerOrigin() => 'player',
          };
      expect([ProjectOrigin.projects, o].map(name), ['projects', 'player']);
    });
  });
}
