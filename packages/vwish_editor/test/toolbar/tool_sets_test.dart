// OWNER: UX-16
//
// Table-driven tests of ToolSets.forSelection (ux.md §9.2) and of the panel support used for
// re-targeting (ux.md §9.3).

import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor/src/editor/contracts/contracts.dart';
import 'package:vwish_editor/src/editor/state/editor_state.dart';
import 'package:vwish_editor/src/editor/toolbar/tool_sets.dart';
import 'package:vwish_editor/src/editor/toolbar/toolbar_strings.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/ops.dart' show GapRef;

const int s = microsPerSecond;

MediaAsset _asset(String id, MediaKind kind, {bool hasAudio = true, DerivedSpec? derived}) => MediaAsset(
      id: MediaId(id),
      kind: kind,
      displayName: '$id.file',
      locator: AppRelativeLocator(AppRoot.support, 'vwish/editor/media/$id/file'),
      ownership: MediaOwnership.managedCopy,
      fingerprint: MediaFingerprint(sizeBytes: 1000, quickHash: id.padRight(40, '0')),
      probe: MediaProbe(kind: kind, duration: 60 * s, hasVideo: kind != MediaKind.audio, hasAudio: hasAudio, width: 1920, height: 1080),
      origin: MediaOrigin.files,
      derived: derived,
      addedAt: DateTime.utc(2026, 10, 1),
    );

MediaClip _clip(String id, String media, TimeUs start, {bool visual = true}) => MediaClip(
      id: ItemId(id),
      start: start,
      duration: 2 * s,
      media: MediaId(media),
      visual: visual ? const VisualProps() : null,
    );

final EditProject project = EditProject(
  id: const ProjectId('pr_tools'),
  meta: ProjectMeta(name: 'Tools', createdAt: DateTime.utc(2026, 10, 1), updatedAt: DateTime.utc(2026, 10, 1)),
  timeline: Timeline(
    tracks: [
      Track(id: const TrackId('tr_main'), kind: TrackKind.video, isMain: true, items: [
        _clip('it_video', 'm_video', 0),
        _clip('it_image', 'm_image', 2 * s),
        _clip('it_still', 'm_still', 4 * s),
        _clip('it_silent', 'm_silent', 6 * s),
      ]),
      Track(id: const TrackId('tr_overlay'), kind: TrackKind.overlay, items: [
        _clip('it_ovideo', 'm_video', 0),
        _clip('it_oimage', 'm_image', 2 * s),
      ]),
      Track(id: const TrackId('tr_text'), kind: TrackKind.text, items: [
        const TextItem(id: ItemId('it_text'), start: 0, duration: 2 * s, text: 'Hi'),
      ]),
      Track(id: const TrackId('tr_subs'), kind: TrackKind.subtitle, items: [
        const SubtitleCue(id: ItemId('it_cue'), start: 0, duration: 2 * s, text: 'Hello'),
      ]),
      Track(id: const TrackId('tr_audio'), kind: TrackKind.audio, items: [
        _clip('it_audio', 'm_song', 0, visual: false),
        _clip('it_voice', 'm_voice', 2 * s, visual: false),
      ]),
      Track(id: const TrackId('tr_locked'), kind: TrackKind.audio, locked: true, items: [
        _clip('it_locked', 'm_song', 0, visual: false),
      ]),
    ],
    markers: const [Marker(id: MarkerId('mk_1'), time: 3 * s)],
  ),
  pool: MediaPool({
    for (final a in [
      _asset('m_video', MediaKind.video),
      _asset('m_silent', MediaKind.video, hasAudio: false),
      _asset('m_image', MediaKind.image, hasAudio: false),
      _asset('m_still', MediaKind.still, hasAudio: false, derived: const StillSpec(MediaId('m_video'), 2 * s, sourceQuickHash: 'q')),
      _asset('m_song', MediaKind.audio),
      _asset('m_voice', MediaKind.recording),
    ])
      a.id: a,
  }),
);

EditorSelection item(String id) => EditorSelection(items: {ItemId(id)}, primary: ItemId(id));

List<String> keys(ToolSet? set) => [for (final e in set!.entries) e.key];

void main() {
  group('ToolSets.forSelection (ux.md §9.2)', () {
    const video = [
      'split', 'speed', 'volume', 'transform', 'crop', 'adjust', 'filters', 'chromaKey', 'mask', 'keyframes', //
      'reverse', 'freeze', 'extractAudio', 'replace', 'duplicate', 'copy', 'rippleDelete', 'delete', 'clipInfo',
    ];
    const image = [
      'split',
      'transform',
      'crop',
      'adjust',
      'filters',
      'chromaKey',
      'mask',
      'keyframes',
      'replace',
      'duplicate',
      'copy',
      'delete',
      'clipInfo',
    ];
    const audio = ['split', 'volume', 'fades', 'speed', 'keyframes', 'replace', 'duplicate', 'copy', 'rippleDelete', 'delete', 'clipInfo'];

    final table = <String, (EditorSelection, SelectionKind, List<String>, String)>{
      'video clip on the main lane': (item('it_video'), SelectionKind.videoClip, video, 'Video clip'),
      'video clip without audio keeps the video set': (item('it_silent'), SelectionKind.videoClip, video, 'Video clip'),
      'overlay video: the video set + lane order': (
        item('it_ovideo'),
        SelectionKind.overlayVideo,
        [...video, 'bringForward', 'sendBackward'],
        'Overlay'
      ),
      'image': (item('it_image'), SelectionKind.image, image, 'Image'),
      'freeze frame': (item('it_still'), SelectionKind.freezeFrame, image, 'Freeze frame'),
      'overlay image': (item('it_oimage'), SelectionKind.overlayImage, [...image, 'bringForward', 'sendBackward'], 'Overlay'),
      'audio clip': (item('it_audio'), SelectionKind.audioClip, audio, 'Audio clip'),
      'voice recording': (item('it_voice'), SelectionKind.audioClip, audio, 'Audio clip'),
      'text': (
        item('it_text'),
        SelectionKind.text,
        ['text.edit', 'text.font', 'text.style', 'text.animation', 'transform', 'keyframes', 'duplicate', 'copy', 'delete'],
        'Text'
      ),
      'subtitle cue': (
        item('it_cue'),
        SelectionKind.subtitleCue,
        ['cue.edit', 'cue.timing', 'split', 'cue.merge', 'cue.style', 'cue.position', 'delete'],
        'Caption'
      ),
      'multi-selection': (
        EditorSelection(
            items: {const ItemId('it_video'), const ItemId('it_text'), const ItemId('it_audio')}, primary: const ItemId('it_text')),
        SelectionKind.multi,
        ['duplicate', 'copy', 'cut', 'moveToTrack', 'rippleDelete', 'delete'],
        '3 items'
      ),
      'transition': (
        EditorSelection(transition: const TransitionRef(TrackId('tr_main'), ItemId('it_video'), ItemId('it_image'))),
        SelectionKind.transition,
        ['transition.type', 'transition.duration', 'transition.direction', 'transition.applyAll', 'delete:Remove'],
        'Transition'
      ),
      'gap': (EditorSelection(gap: const GapRef(TrackId('tr_main'), TimeRange(8 * s, 9 * s))), SelectionKind.gap, ['deleteGap'], 'Gap'),
      'marker': (
        EditorSelection(marker: const MarkerId('mk_1')),
        SelectionKind.marker,
        ['editMarker:Rename', 'editMarker:Color', 'editMarker:Note', 'deleteMarker:Delete'],
        'Marker'
      ),
      'keyframe diamond: its item': (
        EditorSelection(
            items: {const ItemId('it_text')},
            primary: const ItemId('it_text'),
            keyframe: const KeyframeRef(ItemId('it_text'), 'transform.opacity', 0)),
        SelectionKind.text,
        ['text.edit', 'text.font', 'text.style', 'text.animation', 'transform', 'keyframes', 'duplicate', 'copy', 'delete'],
        'Text'
      ),
    };

    for (final MapEntry(key: name, value: (selection, kind, expected, chip)) in table.entries) {
      test(name, () {
        final set = ToolSets.forSelection(selection, project);
        expect(set, isNotNull);
        expect(set!.kind, kind);
        expect(keys(set), expected);
        expect(set.chipLabel, chip);
      });
    }

    test('nothing, a lane only, or a missing item: no context set (top-level tools show)', () {
      expect(ToolSets.forSelection(EditorSelection.empty, project), isNull);
      expect(ToolSets.forSelection(EditorSelection(lane: const TrackId('tr_main')), project), isNull);
      expect(ToolSets.forSelection(item('it_gone'), project), isNull);
      expect(ToolSets.forSelection(item('it_video'), null), isNull);
    });

    test('video "Animation" is reserved and hidden; image has no Duration action', () {
      for (final set in [ToolSets.video, ToolSets.image]) {
        expect(set.map((e) => e.key), isNot(contains(anyOf('animation', 'duration'))));
      }
    });

    test('a locked lane marks the set locked', () {
      expect(ToolSets.forSelection(item('it_locked'), project)!.locked, isTrue);
      expect(ToolSets.forSelection(item('it_audio'), project)!.locked, isFalse);
    });

    test('panel tools open the routes of their item', () {
      final text = ToolSets.forSelection(item('it_text'), project)!;
      final font = text.entries.whereType<PanelToolEntry>().firstWhere((e) => e.key == 'text.font');
      expect(font.route, const TextInspector(ItemId('it_text'), tab: TextPanelTab.font));
      final cue = ToolSets.forSelection(item('it_cue'), project)!;
      final style = cue.entries.whereType<PanelToolEntry>().firstWhere((e) => e.key == 'cue.style');
      expect(style.route, const SubtitlesInspector(track: TrackId('tr_subs'), cue: ItemId('it_cue'), section: SubtitlesPanelSection.style));
    });

    test('the Audio tool opens a tab of sub-tools', () {
      expect(ToolSets.toolTabs[ToolId.audio], [EditorActionId.addMusic, EditorActionId.recordVoiceover, EditorActionId.extractAudio]);
      expect(ToolbarStrings.tool(ToolId.audio), 'Audio');
    });
  });

  group('ToolSets.supports (re-targeting, ux.md §9.3)', () {
    const all = <String, InspectorRoute Function(ItemId)>{
      'transform': TransformInspector.new,
      'crop': CropInspector.new,
      'mask': MaskInspector.new,
      'chroma': ChromaInspector.new,
      'adjust': AdjustInspector.new,
      'filters': FiltersInspector.new,
      'speed': SpeedInspector.new,
      'audio': AudioInspector.new,
      'keyframes': KeyframesInspector.new,
      'text': TextInspector.new,
      'info': ClipInfoInspector.new,
    };
    final expected = <String, Set<String>>{
      'it_video': {'transform', 'crop', 'mask', 'chroma', 'adjust', 'filters', 'speed', 'audio', 'keyframes', 'info'},
      'it_silent': {'transform', 'crop', 'mask', 'chroma', 'adjust', 'filters', 'speed', 'keyframes', 'info'},
      'it_image': {'transform', 'crop', 'mask', 'chroma', 'adjust', 'filters', 'keyframes', 'info'},
      'it_oimage': {'transform', 'crop', 'mask', 'chroma', 'adjust', 'filters', 'keyframes', 'info'},
      'it_audio': {'speed', 'audio', 'keyframes', 'info'},
      'it_text': {'transform', 'keyframes', 'text'},
      'it_cue': <String>{},
    };
    for (final MapEntry(key: id, value: supported) in expected.entries) {
      test(id, () {
        for (final MapEntry(key: name, value: route) in all.entries) {
          expect(ToolSets.supportsItem(route(ItemId(id)), ItemId(id), project), supported.contains(name), reason: '$name on $id');
        }
      });
    }

    test('project panels, subtitles and transitions are always supported; a missing item is not', () {
      expect(ToolSets.supportsItem(const CanvasInspector(), const ItemId('it_cue'), project), isTrue);
      expect(ToolSets.supportsItem(const SubtitlesInspector(), const ItemId('it_video'), project), isTrue);
      expect(ToolSets.supportsItem(const TransformInspector(ItemId('it_gone')), const ItemId('it_gone'), project), isFalse);
    });
  });
}
