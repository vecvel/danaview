// The Home's editor projects (DESIGN_SYSTEM §10.3 #3, §10.4 `Projects`). danaview_features never
// imports the editor (ARCH v1.2 rule 23), so the app root maps the editor's project store onto the
// Home's neutral [HomeProject]s here, the same way the Projects screen reads it
// (`ProjectRepository.watchSummaries()`, most recently edited first). The overrides join the
// editor's only where the editor runs and was wired (`editorAppOverrides` in main.dart); elsewhere
// `homeProjectsProvider` stays empty and the Home hides its Projects section.

import 'package:danaview_editor/danaview_editor.dart' show ProjectHealth, ProjectSummary, projectRepositoryProvider;
import 'package:danaview_features/danaview_features.dart' show HomeProject, homeProjectsProvider;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The editor's project summaries as the repository lists them (live).
final editorProjectSummariesProvider = StreamProvider<List<ProjectSummary>>(
  (ref) => ref.watch(projectRepositoryProvider).watchSummaries(),
  name: 'editorProjectSummariesProvider',
);

/// The Home's view of one project summary.
HomeProject homeProjectOf(ProjectSummary summary) => HomeProject(
      id: summary.id,
      name: summary.name,
      updatedAt: summary.updatedAt,
      thumbnailPath: summary.thumbnailPath,
    );

/// The Home's projects from [summaries]: every project that opens (a damaged one is left to the
/// Projects screen, which explains it), most recently edited first.
List<HomeProject> homeProjectsOf(List<ProjectSummary> summaries) {
  final sorted = [
    for (final s in summaries)
      if (s.health != ProjectHealth.corrupt) s,
  ]..sort((a, b) {
      final c = b.updatedAt.compareTo(a.updatedAt);
      return c != 0 ? c : a.id.compareTo(b.id);
    });
  return List.unmodifiable([for (final s in sorted) homeProjectOf(s)]);
}

/// The overrides that feed the Home's Projects section and tab from the editor's store.
List<Override> homeProjectsOverrides() => [
      homeProjectsProvider.overrideWith(
        (ref) => homeProjectsOf(ref.watch(editorProjectSummariesProvider).valueOrNull ?? const []),
      ),
    ];
