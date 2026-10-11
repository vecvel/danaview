// OWNER: UX-01
//
// EditorTestHarness: a ProviderScope whose root providers (ARCH §17.3) are fakes: FakeEditorEngine
// (engine API), FakeProjectRepository, FakeMediaPoolService, FakeTranscriptionService and in-memory
// EditorPrefs. Widget tests of every editor ticket build on it:
//
//   final h = EditorTestHarness();
//   final id = await h.pumpEditor(tester, surface: SurfaceMatrix.narrowest);
//   expectNoOverflow(tester);
//   expectOwnerUiRules(tester);

import 'package:flutter/material.dart' show MaterialApp;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/editor_prefs.dart';
import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor/src/editor/editor_screen.dart';
import 'package:danaview_editor_core/model.dart' show ProjectId, TimeUs;
import 'package:danaview_editor_engine_api/testing.dart';
import 'package:danaview_transcription/testing.dart';

import 'fake_media_pool_service.dart';
import 'fake_project_repository.dart';
import 'surface_matrix.dart';

/// Fakes for every root provider plus helpers to pump editor surfaces.
class EditorTestHarness {
  /// Creates the harness; pass a fake to script it, or use the defaults.
  EditorTestHarness({
    FakeEditorEngine? engine,
    FakeProjectRepository? repository,
    FakeMediaPoolService? mediaPool,
    FakeTranscriptionService? transcription,
    EditorPrefs? prefs,
    List<Override> overrides = const [],
  })  : engine = engine ?? FakeEditorEngine(),
        repository = repository ?? FakeProjectRepository(),
        mediaPool = mediaPool ?? FakeMediaPoolService(),
        transcription = transcription ?? FakeTranscriptionService(),
        prefs = prefs ?? EditorPrefs.memory(),
        extraOverrides = List.unmodifiable(overrides);

  /// The engine.
  final FakeEditorEngine engine;

  /// The project store.
  final FakeProjectRepository repository;

  /// The media pool service.
  final FakeMediaPoolService mediaPool;

  /// Auto captions.
  final FakeTranscriptionService transcription;

  /// Preferences.
  final EditorPrefs prefs;

  /// Overrides added after the root ones (later entries win for the same provider).
  final List<Override> extraOverrides;

  /// `EditorScreen.onClose` calls seen by [pumpEditor].
  int closeRequests = 0;

  /// `EditorScreen.onOpenProjects` calls seen by [pumpEditor].
  int openProjectsRequests = 0;

  /// The root overrides (ARCH §17.3) followed by [extraOverrides].
  List<Override> get overrides => [
        editorEngineProvider.overrideWithValue(engine),
        projectRepositoryProvider.overrideWithValue(repository),
        mediaPoolServiceProvider.overrideWithValue(mediaPool),
        transcriptionServiceProvider.overrideWithValue(transcription),
        editorPrefsProvider.overrideWithValue(prefs),
        ...extraOverrides,
      ];

  /// A container with [overrides] for unit tests of providers and controllers; disposed at the end
  /// of the test.
  ProviderContainer container() {
    final c = ProviderContainer(overrides: overrides);
    addTearDown(c.dispose);
    return c;
  }

  /// [home] inside the harness' ProviderScope and a dark Danaview app for [surface].
  Widget app(Widget home, {EditorSurface surface = SurfaceMatrix.phone}) =>
      ProviderScope(overrides: overrides, child: surfaceApp(surface, home));

  /// Sizes the view for [surface] and pumps [home] in the harness.
  Future<void> pumpApp(WidgetTester tester, Widget home, {EditorSurface surface = SurfaceMatrix.phone}) async {
    applySurface(tester, surface);
    await tester.pumpWidget(app(home, surface: surface));
    await tester.pump();
  }

  /// Pumps `EditorScreen` for [projectId] (default: a new empty project seeded in [repository]) and
  /// returns the id.
  Future<ProjectId> pumpEditor(
    WidgetTester tester, {
    ProjectId? projectId,
    TimeUs? initialPlayhead,
    EditorSurface surface = SurfaceMatrix.phone,
  }) async {
    final id = projectId ?? repository.seedEmpty('Test project').id;
    await pumpApp(
      tester,
      EditorScreen(
        projectId: id,
        initialPlayhead: initialPlayhead,
        onClose: () => closeRequests++,
        onOpenProjects: () => openProjectsRequests++,
      ),
      surface: surface,
    );
    return id;
  }

  /// The ProviderContainer of the pumped app.
  ProviderContainer containerOf(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(MaterialApp).first), listen: false);
}
