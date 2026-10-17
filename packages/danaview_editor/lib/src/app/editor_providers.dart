// OWNER: UX-01
//
// Riverpod 2 providers of the editor (ARCH §17.3).
//
// * Root providers are overridden by `EditorBootstrap` (INT-02) in the app and by
//   `EditorTestHarness` (test/support/) in tests. Unconfigured roots throw
//   [EditorNotConfiguredError] naming the provider.
// * Per-project families are keyed by `ProjectId` and are `autoDispose`; each family delegates to
//   a factory function declared in its owner's file (D-33), so owners implement construction
//   (including `ref.keepAlive()` until `close()` completes) without editing this file:
//
//   | Provider                         | Factory                          | Owner |
//   |----------------------------------|----------------------------------|-------|
//   | editorSessionProvider            | createEditorSession              | UX-08 |
//   | editorControllerProvider         | createEditorController           | UX-08 |
//   | playheadProvider                 | createPlayheadController         | UX-14 |
//   | transportProvider                | createTransportController        | UX-14 |
//   | viewportProvider                 | createViewportController         | UX-09 |
//   | interactionProvider              | createInteractionController      | UX-13 |
//   | timelineSnapshotProvider         | buildTimelineSnapshot            | UX-10 |
//   | exportControllerProvider         | createExportController           | UX-39 |
//   | autoCaptionsControllerProvider   | createAutoCaptionsController     | UX-37 |
//   | relinkControllerProvider         | createRelinkController           | UX-40 |
//
// App-level providers that are not in ARCH §17.3 (projects controller, launcher, clipboard,
// caches) are declared by their owners in their own files.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/store.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';
import 'package:danaview_transcription/danaview_transcription.dart';

import '../editor/flows/captions/auto_captions_controller.dart';
import '../editor/flows/export/export_controller.dart';
import '../editor/flows/relink/relink_controller.dart';
import '../editor/state/editor_controller.dart';
import '../editor/state/editor_session.dart';
import '../editor/state/editor_state.dart';
import '../editor/state/playhead_controller.dart';
import '../editor/state/transport_controller.dart';
import '../editor/timeline/timeline_interaction.dart';
import '../editor/timeline/timeline_snapshot.dart';
import '../editor/timeline/timeline_viewport.dart';
import 'editor_prefs.dart';

/// Thrown when a root provider is read without an override (the app did not run
/// `EditorBootstrap`, or a test did not use `EditorTestHarness`).
///
/// See ARCH §17.3.
final class EditorNotConfiguredError extends StateError {
  /// Creates the error for [provider].
  EditorNotConfiguredError(this.provider)
      : super('$provider is not configured: override it through EditorBootstrap (INT-02) or EditorTestHarness');

  /// The provider's name.
  final String provider;
}

// -------------------------------------------------------------------------------------------------
// Root providers (overridden by EditorBootstrap)
// -------------------------------------------------------------------------------------------------

/// The engine (`MobileEditorEngine` on iOS/Android, `FakeEditorEngine` in tests).
///
/// See ARCH §17.3, §12.1.
final editorEngineProvider = Provider<EditorEngine>(
  (ref) => throw EditorNotConfiguredError('editorEngineProvider'),
  name: 'editorEngineProvider',
);

/// The project store (`FileProjectRepository`, CORE-25).
///
/// See ARCH §17.3, §8.4.
final projectRepositoryProvider = Provider<ProjectRepository>(
  (ref) => throw EditorNotConfiguredError('projectRepositoryProvider'),
  name: 'projectRepositoryProvider',
);

/// The media pool service (`FileMediaPoolService`, CORE-27/CORE-28).
///
/// See ARCH §17.3, §9.2.
final mediaPoolServiceProvider = Provider<MediaPoolService>(
  (ref) => throw EditorNotConfiguredError('mediaPoolServiceProvider'),
  name: 'mediaPoolServiceProvider',
);

/// Auto captions (`TranscriptionServiceImpl`, wired by INT-04).
///
/// See ARCH §17.3, §16.
final transcriptionServiceProvider = Provider<TranscriptionService>(
  (ref) => throw EditorNotConfiguredError('transcriptionServiceProvider'),
  name: 'transcriptionServiceProvider',
);

/// Editor preferences (`editor.` keys).
///
/// See ARCH §17.3, §17.10.
final editorPrefsProvider = Provider<EditorPrefs>(
  (ref) => throw EditorNotConfiguredError('editorPrefsProvider'),
  name: 'editorPrefsProvider',
);

/// Device capabilities from the engine (cached by the engine after the first call).
///
/// See ARCH §17.3, §12.5.
final editorCapabilitiesProvider = FutureProvider<EditorCapabilities>(
  (ref) => ref.watch(editorEngineProvider).capabilities(),
  name: 'editorCapabilitiesProvider',
);

// -------------------------------------------------------------------------------------------------
// Per-project families (autoDispose; the factories keep them alive until close() completes)
// -------------------------------------------------------------------------------------------------

/// The open editing session of a project (wraps core `EditSession`).
///
/// See ARCH §17.3.
final editorSessionProvider = Provider.autoDispose.family<EditorSession, ProjectId>(
  (ref, id) => createEditorSession(ref, id),
  name: 'editorSessionProvider',
);

/// The editor controller and its `EditorState`.
///
/// See ARCH §17.3.
final editorControllerProvider = StateNotifierProvider.autoDispose.family<EditorController, EditorState, ProjectId>(
  (ref, id) => createEditorController(ref, id),
  name: 'editorControllerProvider',
);

/// The playhead (`ValueListenable<TimeUs>` outside Riverpod state).
///
/// See ARCH §17.3.
final playheadProvider = Provider.autoDispose.family<PlayheadController, ProjectId>(
  (ref, id) => createPlayheadController(ref, id),
  name: 'playheadProvider',
);

/// Transport (play state, rate, loop range).
///
/// See ARCH §17.3.
final transportProvider = Provider.autoDispose.family<TransportController, ProjectId>(
  (ref, id) => createTransportController(ref, id),
  name: 'transportProvider',
);

/// Timeline zoom and scroll.
///
/// See ARCH §17.3, §17.4.
final viewportProvider = Provider.autoDispose.family<TimelineViewportController, ProjectId>(
  (ref, id) => createViewportController(ref, id),
  name: 'viewportProvider',
);

/// Drag ghosts, guides, marquee and trim pills.
///
/// See ARCH §17.3, §17.4.
final interactionProvider = Provider.autoDispose.family<TimelineInteractionController, ProjectId>(
  (ref, id) => createInteractionController(ref, id),
  name: 'interactionProvider',
);

/// The timeline view model of the committed project (instances reused when domain objects are
/// identical).
///
/// See ARCH §17.3, §17.4.
final timelineSnapshotProvider = Provider.autoDispose.family<TimelineSnapshot, ProjectId>(
  (ref, id) => buildTimelineSnapshot(ref, id),
  name: 'timelineSnapshotProvider',
);

/// The export flow.
///
/// See ARCH §17.3, §14.1.
final exportControllerProvider = StateNotifierProvider.autoDispose.family<ExportController, ExportUiState, ProjectId>(
  (ref, id) => createExportController(ref, id),
  name: 'exportControllerProvider',
);

/// The Auto captions flow.
///
/// See ARCH §17.3, §16.
final autoCaptionsControllerProvider = StateNotifierProvider.autoDispose.family<AutoCaptionsController, AutoCaptionsState, ProjectId>(
  (ref, id) => createAutoCaptionsController(ref, id),
  name: 'autoCaptionsControllerProvider',
);

/// The relink flow.
///
/// See ARCH §17.3, §9.3.
final relinkControllerProvider = StateNotifierProvider.autoDispose.family<RelinkController, RelinkState, ProjectId>(
  (ref, id) => createRelinkController(ref, id),
  name: 'relinkControllerProvider',
);
