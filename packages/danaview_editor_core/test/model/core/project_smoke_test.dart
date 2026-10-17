// OWNER: CORE-03
//
// Smoke test of the project root and its id index (CORE-03 completes the model tests).

import 'package:test/test.dart';
import 'package:danaview_editor_core/model.dart';

void main() {
  test('EditProject getters and index', () {
    final ids = SeededIdGenerator(7);
    final media = ids.mediaId();
    final clip = MediaClip(id: ids.itemId(), start: 0, duration: FrameRate.fps30.timeOfFrame(90), media: media);
    final main = Track(id: ids.trackId(), kind: TrackKind.video, isMain: true, items: [clip]);
    final now = DateTime.utc(2026, 10, 8);
    final project = EditProject(
      id: ids.projectId(),
      meta: ProjectMeta(name: 'Trip', createdAt: now, updatedAt: now),
      timeline: Timeline(tracks: [main]),
    );
    expect(project.duration, 3000000);
    expect(project.index.locate(clip.id)?.track.id, main.id);
    expect(identical(project.index, project.index), isTrue);
    expect(project.settings.frameRate, FrameRate.fps30);
  });
}
