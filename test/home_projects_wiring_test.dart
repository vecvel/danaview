// The app's mapping of the editor's project store onto the Home's projects
// (lib/wiring/projects_wiring.dart; DESIGN_SYSTEM §10.3 #3, §10.4).

import 'package:danaview/wiring/projects_wiring.dart';
import 'package:danaview_editor/danaview_editor.dart' show ProjectHealth, ProjectId, ProjectSummary;
import 'package:danaview_editor_core/model.dart' as core show AspectRatio;
import 'package:danaview_features/danaview_features.dart' show HomeProject;
import 'package:flutter_test/flutter_test.dart';

ProjectSummary _summary(String id, DateTime updatedAt, {ProjectHealth health = ProjectHealth.ok, String? poster}) => ProjectSummary(
      id: ProjectId(id),
      name: 'Project $id',
      updatedAt: updatedAt,
      duration: 0,
      aspect: core.AspectRatio.landscape16x9,
      thumbnailPath: poster,
      health: health,
    );

void main() {
  test('most recently edited first, with the id, name, date and poster', () {
    final older = DateTime.utc(2026, 10, 1);
    final newer = DateTime.utc(2026, 10, 28);
    final projects = homeProjectsOf([_summary('a', older), _summary('b', newer, poster: '/p/b.jpg')]);
    expect(projects, [
      HomeProject(id: 'b', name: 'Project b', updatedAt: newer, thumbnailPath: '/p/b.jpg'),
      HomeProject(id: 'a', name: 'Project a', updatedAt: older),
    ]);
  });

  test('damaged projects stay on the Projects screen, which explains them', () {
    final at = DateTime.utc(2026, 10, 28);
    final projects = homeProjectsOf([
      _summary('ok', at),
      _summary('bad', at, health: ProjectHealth.corrupt),
      _summary('new', at, health: ProjectHealth.readOnlyNewer),
    ]);
    expect([for (final p in projects) p.id], ['new', 'ok']);
  });

  test('no projects: nothing for the Home to show', () {
    expect(homeProjectsOf(const []), isEmpty);
  });
}
