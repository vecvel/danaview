// OWNER: UX-30
//
// A rig for the text panel tests: the editor harness with a real EditorController opened over
// FakeEditorEngine at 30 fps, and the panel placed in the inspector region by the real
// InspectorHost / InspectorDock.
//
// Main lane: video A 0-10 s. Text lane: "Hello" 1-4 s (it_t1) and "Second" 6-8 s (it_t2). Locked
// text lane: "Locked" 0-2 s (it_lk).

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/editor_scope.dart';
import 'package:danaview_editor/src/editor/inspector/inspector_dock.dart';
import 'package:danaview_editor/src/editor/inspector/inspector_host.dart';
import 'package:danaview_editor/src/editor/layout/editor_layout.dart';
import 'package:danaview_editor/src/editor/state/editor_controller.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart';
import 'package:danaview_editor/src/editor/state/playhead_controller.dart';
import 'package:danaview_editor/src/editor/state/transport_controller.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_engine_api/testing.dart';

import '../../inspector/inspector_rig.dart' show RegionFrame, RigTicker;
import '../../support/support.dart';

export '../../inspector/inspector_rig.dart' show RegionFrame, frameSpec;

const int s = microsPerSecond;

/// The frame grid of the rig's project.
final FrameRate rate = FrameRate.fps30;

/// Ids of the rig's project.
abstract final class Ids {
  static const TrackId main = TrackId('tr_main');
  static const TrackId text = TrackId('tr_text');
  static const TrackId locked = TrackId('tr_locked');
  static const ItemId t1 = ItemId('it_t1');
  static const ItemId t2 = ItemId('it_t2');
  static const ItemId lockedText = ItemId('it_lk');
}

MediaAsset _asset(String id) => MediaAsset(
      id: MediaId(id),
      kind: MediaKind.video,
      displayName: '$id.file',
      locator: AppRelativeLocator(AppRoot.support, 'danaview/editor/media/$id/file'),
      ownership: MediaOwnership.managedCopy,
      fingerprint: MediaFingerprint(sizeBytes: 1000, quickHash: id.padRight(40, '0')),
      probe: MediaProbe(kind: MediaKind.video, duration: 60 * s, hasVideo: true, hasAudio: true, width: 1920, height: 1080),
      origin: MediaOrigin.files,
      addedAt: DateTime.utc(2026, 10, 1),
    );

/// The project of the rig.
EditProject textProject(ProjectId id) => EditProject(
      id: id,
      meta: ProjectMeta(name: 'Text', createdAt: DateTime.utc(2026, 10, 1), updatedAt: DateTime.utc(2026, 10, 1)),
      timeline: Timeline(tracks: [
        Track(id: Ids.main, kind: TrackKind.video, isMain: true, items: [
          MediaClip(id: const ItemId('it_a'), start: 0, duration: 10 * s, media: const MediaId('m_a'), sourceIn: 0, visual: const VisualProps()),
        ]),
        Track(id: Ids.text, kind: TrackKind.text, items: [
          TextItem(id: Ids.t1, start: 1 * s, duration: 3 * s, text: 'Hello'),
          TextItem(id: Ids.t2, start: 6 * s, duration: 2 * s, text: 'Second'),
        ]),
        Track(id: Ids.locked, kind: TrackKind.text, locked: true, items: [
          TextItem(id: Ids.lockedText, start: 0, duration: 2 * s, text: 'Locked'),
        ]),
      ]),
      pool: MediaPool({const MediaId('m_a'): _asset('m_a')}),
    );

/// The harness around the real inspector with a real, opened EditorController.
class TextRig {
  TextRig._(this.harness, this.id, this.tester, this.ticker);

  /// Harness.
  final EditorTestHarness harness;

  /// Project id.
  final ProjectId id;

  /// Tester.
  final WidgetTester tester;

  /// The playhead's ticker.
  final RigTicker ticker;

  /// The fake engine.
  FakeEditorEngine get engine => harness.engine;

  /// The container of the pumped app.
  ProviderContainer get container => harness.containerOf(tester);

  /// The editor controller.
  EditorController get editor => container.read(editorControllerProvider(id).notifier);

  /// The editor state.
  EditorState get state => container.read(editorControllerProvider(id));

  /// The playhead.
  PlayheadController get playhead => container.read(playheadProvider(id));

  /// The transport.
  TransportController get transport => container.read(transportProvider(id));

  /// The working project.
  EditProject get project => state.project!;

  /// The text item [item].
  TextItem text(ItemId item) => project.index.item(item)! as TextItem;

  /// The history position (entries applied).
  int get entries => state.history.position;

  /// Pumps the panel host and opens the editor; [open] is the item whose panel opens on [tab].
  static Future<TextRig> pump(
    WidgetTester tester, {
    EditorSurface surface = const EditorSurface(Size(1280, 900)),
    ItemId? open = Ids.t1,
    TextPanelTab tab = TextPanelTab.edit,
    List<Override> overrides = const [],
  }) async {
    final repo = FakeProjectRepository();
    final empty = repo.seedEmpty('Text');
    final project = textProject(empty.id);
    repo.seed(project);
    final ticker = RigTicker();
    final engine = FakeEditorEngine(validatePlans: false);
    final harness = EditorTestHarness(
      engine: engine,
      repository: repo,
      overrides: [
        playheadProvider.overrideWith((ref, pid) => createPlayheadController(ref, pid, ticker: ticker, clock: () => Duration.zero)),
        ...overrides,
      ],
    );
    final rig = TextRig._(harness, project.id, tester, ticker);
    await harness.pumpApp(
      tester,
      EditorScope(
        projectId: project.id,
        child: const RegionFrame(
          inspectorOpen: true,
          regions: {EditorRegion.pane: InspectorHost()},
          dock: InspectorDock(),
        ),
      ),
      surface: surface,
    );
    await rig.real(() => rig.editor.open());
    if (open != null) await rig.openPanel(open, tab: tab);
    return rig;
  }

  /// Selects [item] and opens its panel on [tab].
  Future<void> openPanel(ItemId item, {TextPanelTab tab = TextPanelTab.edit}) async {
    editor
      ..select(item)
      ..openInspector(TextInspector(item, tab: tab));
    await tester.pump();
    await settle();
  }

  /// Closes the inspector and lets the panel restore the transport.
  Future<void> closePanel() async {
    editor.closeInspector();
    await tester.pump();
    await settle();
  }

  /// Lets queued async work (transport operations) finish.
  Future<void> settle() async {
    await real(() async {});
    await tester.pump();
  }

  /// Runs [body] with real async and pumps.
  Future<void> real(Future<void> Function() body) async {
    await tester.runAsync(() async {
      await body();
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    });
    await tester.pump();
  }

  /// Seeks the playhead exactly to [t] and settles.
  Future<void> seek(TimeUs t) async {
    await real(() async {
      await playhead.seekExact(t);
    });
  }
}
