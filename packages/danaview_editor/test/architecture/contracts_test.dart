// OWNER: UX-01
//
// The editor contracts match ARCH: EditorActionId is the complete ARCH §17.6 list with its groups,
// ToolId is the ux.md §9.1 strip, InspectorRoute equality and re-targeting, and the binding merge
// rejects an id bound by two features.

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/wiring/action_bindings.dart';
import 'package:danaview_editor_core/model.dart';

import 'arch_scan.dart';

void main() {
  group('EditorActionId', () {
    test('is exactly the ARCH §17.6 list, in order and by group', () {
      final arch = File('${findRepoRoot().path}/docs/v1.1/editor/ARCHITECTURE.md').readAsStringSync();
      final line = arch.split('\n').firstWhere((l) => l.startsWith('`EditorActionId` (complete list, UX-01)'));
      final groups = {
        for (final m in RegExp(r'(playback|editing|timeline|markers|tools) `([^`]+)`').allMatches(line))
          m[1]!: m[2]!.split(',').map((s) => s.trim()).toList(),
      };
      expect(groups.keys, ['playback', 'editing', 'timeline', 'markers', 'tools']);
      final expected = [
        for (final g in groups.entries)
          for (final name in g.value) (g.key, name)
      ];
      final actual = [for (final a in EditorActionId.values) (a.group.name, a.name)];
      expect(actual, expected);
      expect(EditorActionId.values, hasLength(76));
    });

    test('byName and inGroup', () {
      expect(EditorActionId.byName('rippleDelete'), EditorActionId.rippleDelete);
      expect(EditorActionId.byName('nope'), isNull);
      expect(EditorActionId.inGroup(EditorActionGroup.markers),
          [EditorActionId.addMarker, EditorActionId.editMarker, EditorActionId.deleteMarker]);
    });
  });

  test('ToolId is the ux.md §9.1 strip and each tool has a primary action', () {
    expect(ToolId.stripOrder.map((t) => t.name),
        ['media', 'audio', 'text', 'captions', 'overlay', 'effects', 'filters', 'transitions', 'format']);
    expect(ToolId.effects.primaryAction, EditorActionId.adjust);
    expect(ToolId.values.map((t) => t.primaryAction).toSet(), hasLength(ToolId.values.length));
  });

  group('InspectorRoute', () {
    const a = ItemId('it_a'), b = ItemId('it_b');

    test('value equality', () {
      expect(const TransformInspector(a), const TransformInspector(a));
      expect(const TransformInspector(a), isNot(const CropInspector(a)));
      expect(const TextInspector(a, tab: TextPanelTab.font), isNot(const TextInspector(a)));
      expect(
          const AudioInspector(a, focus: AudioPanelFocus.fades).hashCode, const AudioInspector(a, focus: AudioPanelFocus.fades).hashCode);
      expect(const MediaInspector(), const MediaInspector());
      expect(const MediaInspector(), isNot(const CanvasInspector()));
    });

    test('item panels re-target, project panels stay, transitions and subtitles close', () {
      expect(const TransformInspector(a).retarget(b), const TransformInspector(b));
      expect(const TextInspector(a, tab: TextPanelTab.style).retarget(b), const TextInspector(b, tab: TextPanelTab.style));
      expect(const AudioInspector(a, focus: AudioPanelFocus.fades).retarget(b), const AudioInspector(b, focus: AudioPanelFocus.fades));
      expect(const CanvasInspector().retarget(b), const CanvasInspector());
      expect(const TransitionInspector(TransitionRef(TrackId('tr_main'), a, b)).retarget(a), isNull);
      expect(const SubtitlesInspector(track: TrackId('tr_sub'), cue: a).retarget(b), isNull);
      expect(const SubtitlesInspector(track: TrackId('tr_sub'), cue: a).retarget(a), isNotNull);
    });

    test('targets', () {
      expect(const KeyframesInspector(a).target, a);
      expect(const OverlayInspector().target, isNull);
      expect(const SubtitlesInspector(cue: b).target, b);
      expect(const TransitionInspector(TransitionRef(TrackId('tr_main'), a, b)).target, isNull);
    });

    test('every route kind maps to one panel (exhaustive switch)', () {
      String panelOf(InspectorRoute r) => switch (r) {
            MediaInspector() => 'media',
            VoiceoverInspector() => 'voiceover',
            OverlayInspector() => 'overlay',
            CanvasInspector() => 'canvas',
            TransformInspector() => 'transform',
            CropInspector() => 'crop',
            MaskInspector() => 'mask',
            SpeedInspector() => 'speed',
            AudioInspector() => 'audio',
            AdjustInspector() => 'adjust',
            FiltersInspector() => 'filters',
            ChromaInspector() => 'chroma',
            KeyframesInspector() => 'keyframes',
            TextInspector() => 'text',
            ClipInfoInspector() => 'clipInfo',
            SubtitlesInspector() => 'subtitles',
            TransitionInspector() => 'transitions',
          };
      expect(panelOf(const ChromaInspector(a)), 'chroma');
    });
  });

  group('action bindings wiring', () {
    EditorActionBinding bind(EditorActionId id) => EditorActionBinding(id: id, handler: (_) {});

    test('merges sources and rejects an id bound twice', () {
      final merged = mergeEditorActionBindings([
        EditorBindingSource('a_bindings', 'UX-90', () => [bind(EditorActionId.split)]),
        EditorBindingSource('b_bindings', 'UX-91', () => [bind(EditorActionId.undo), bind(EditorActionId.redo)]),
      ]);
      expect(merged.keys, unorderedEquals([EditorActionId.split, EditorActionId.undo, EditorActionId.redo]));
      expect(
        () => mergeEditorActionBindings([
          EditorBindingSource('a_bindings', 'UX-90', () => [bind(EditorActionId.split)]),
          EditorBindingSource('b_bindings', 'UX-91', () => [bind(EditorActionId.split)]),
        ]),
        throwsA(isA<DuplicateActionBindingError>()
            .having((e) => e.id, 'id', EditorActionId.split)
            .having((e) => e.message, 'message', allOf(contains('a_bindings'), contains('b_bindings')))),
      );
    });

    test('the provider exposes the merged real bindings', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final merged = c.read(editorActionBindingsProvider);
      expect(merged, mergeEditorActionBindings());
      for (final entry in merged.entries) {
        expect(entry.value.id, entry.key);
      }
    });
  });
}
