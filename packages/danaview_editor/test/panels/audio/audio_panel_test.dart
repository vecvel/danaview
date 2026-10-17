// OWNER: UX-33
//
// The audio panel (ux.md §10.4): every control dispatches the right core command with one labelled
// history entry (volume with its keyframe toggle and dB readout, mute, fade in/out limited to
// min(10 s, half the clip), keep pitch, the lane role), Extract audio produces a linked clip on an
// "original" lane and moves the panel to it, the extracted video's note, the header reset, the
// fades focus, locked lanes and the surface matrix.

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/strings/audio_strings.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/inspector/inspector_header.dart';
import 'package:danaview_editor/src/editor/inspector/inspector_rows.dart';
import 'package:danaview_editor/src/editor/inspector/keyframe_toggle.dart';
import 'package:danaview_editor/src/editor/panels/audio_panel.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../support/support.dart';
import 'audio_rig.dart';

Finder key(String k) => find.byKey(ValueKey<String>(k));

Finder sliderRow(String k) => find.descendant(of: key(k), matching: find.byType(InspectorSliderRow));

Finder slider(String k) => find.descendant(of: key(k), matching: find.byType(DanaviewSlider));

InspectorSliderRow rowOf(WidgetTester tester, String k) => tester.widget<InspectorSliderRow>(sliderRow(k).first);

Future<void> drag(WidgetTester tester, String k, double dx) async {
  await tester.ensureVisible(slider(k));
  await tester.pump();
  final g = await tester.startGesture(tester.getCenter(slider(k)));
  for (var i = 0; i < 6; i++) {
    await g.moveBy(Offset(dx / 6, 0));
    await tester.pump();
  }
  await g.up();
  await tester.pump();
  await tester.pump();
}

Future<void> tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
  await tester.pump();
}

/// A widget test that lets the throttled announcement timer run out before the framework checks for timers.
void testAudio(String description, Future<void> Function(WidgetTester tester) body) => testWidgets(description, (tester) async {
      await body(tester);
      await tester.pump(const Duration(seconds: 1));
    });

void testAudioSurfaces(String description, Future<void> Function(WidgetTester tester, EditorSurface surface) body) =>
    testSurfaces(description, (tester, surface) async {
      await body(tester, surface);
      await tester.pump(const Duration(seconds: 1));
    });

String headerTitle(WidgetTester tester) => tester.widget<InspectorHeader>(find.byType(InspectorHeader)).title;

void main() {
  late DateTime now;
  setUp(() {
    now = DateTime.utc(2026, 10, 14, 9);
    InspectorRows.clock = () => now;
  });
  tearDown(() => InspectorRows.clock = DateTime.now);

  group('rows (ux.md §10.4)', () {
    testAudio('a video with sound: volume with keyframe toggle and dB, mute, fades, keep pitch, extract; no lane role', (tester) async {
      await AudioRig.pump(tester);
      expect(find.byType(AudioPanel), findsOneWidget);
      expect(headerTitle(tester), 'Volume');
      final volume = rowOf(tester, 'audio.volume');
      expect((volume.label, volume.min, volume.max, volume.displayScale, volume.defaultValue), ('Volume', 0, 2, 100, 1));
      expect(find.descendant(of: key('audio.volume'), matching: find.byType(PropertyKeyframeToggle)), findsOneWidget);
      expect(tester.widget<Text>(key('audio.db')).data, '0.0 dB');
      expect(tester.widget<DanaviewSwitchRow>(key('audio.mute')).value, isFalse);
      expect(rowOf(tester, 'audio.fadeIn').label, AudioStrings.fadeIn);
      expect(rowOf(tester, 'audio.fadeOut').label, AudioStrings.fadeOut);
      expect(tester.widget<DanaviewSwitchRow>(key('audio.keepPitch')).value, isTrue);
      expect(key('audio.extract'), findsOneWidget);
      expect(key('audio.role'), findsNothing, reason: 'the role belongs to audio lanes');
    });

    testAudio('a music clip: lane role chips with Music selected; no extract', (tester) async {
      await AudioRig.pump(tester, open: AudioIds.music);
      for (final role in AudioRole.values) {
        final chip = tester.widget<DanaviewChoiceChip>(key('audio.role.${role.name}'));
        expect(chip.selected, role == AudioRole.music, reason: role.name);
        expect(chip.label, AudioStrings.roleName(role));
      }
      expect(key('audio.extract'), findsNothing);
    });

    testAudio('fade sliders run 0…min(10 s, half the clip)', (tester) async {
      await AudioRig.pump(tester);
      expect(rowOf(tester, 'audio.fadeIn').max, 6 * s, reason: '12 s clip');
      expect(rowOf(tester, 'audio.fadeOut').max, 6 * s);
      expect(rowOf(tester, 'audio.fadeIn').displayScale, 1e-6);
      expect(find.text(AudioStrings.fadeLimit(6)), findsOneWidget);
      expect(audioFadeLimit(30 * s), 10 * s);
      expect(audioFadeLimit(3 * s), 1500000);
    });

    testAudio('the fades focus titles the panel Fades and shows the fade rows', (tester) async {
      await AudioRig.pump(tester, focus: AudioPanelFocus.fades, surface: const EditorSurface(Size(390, 640)));
      await tester.pump();
      expect(headerTitle(tester), 'Fades');
      final row = tester.getRect(sliderRow('audio.fadeIn'));
      final view = tester.getRect(key('audio.scroll'));
      expect(row.top, greaterThanOrEqualTo(view.top - 1));
      expect(row.bottom, lessThanOrEqualTo(view.bottom + 1), reason: 'scrolled into view');
    });

    test('the dB readout: 100 % = 0 dB, 200 % ≈ +6 dB, silence is −∞', () {
      expect(AudioStrings.decibels(1), '0.0 dB');
      expect(AudioStrings.decibels(2), '+6.0 dB');
      expect(AudioStrings.decibels(0.5), '−6.0 dB');
      expect(AudioStrings.decibels(0), '−∞ dB');
      expect(AudioStrings.decibelsSemantics(0.5), 'Volume level minus 6.0 dB');
    });
  });

  group('commands', () {
    testAudio('a volume drag is one "Change volume" entry; the dB readout follows', (tester) async {
      final rig = await AudioRig.pump(tester);
      final before = rig.entries;
      await drag(tester, 'audio.volume', 120);
      expect(rig.entries, before + 1);
      expect(rig.undoLabel, 'Change volume');
      final v = rig.clip(AudioIds.video).audio.volume;
      expect(v, greaterThan(1));
      expect(v, lessThanOrEqualTo(2));
      expect(tester.widget<Text>(key('audio.db')).data, AudioStrings.decibels(v));
      expect(tester.widget<Text>(key('audio.db')).data, startsWith('+'));
    });

    testAudio('the volume keyframe toggle keys the volume at the playhead; drags then write keys', (tester) async {
      final rig = await AudioRig.pump(tester, open: AudioIds.music);
      await rig.seek(rate(30));
      await tap(tester, find.descendant(of: key('audio.volume'), matching: find.byIcon(Icons.diamond_outlined)));
      var keys = keyframesOf(rig.clip(AudioIds.music));
      expect(KeyframeOps.isAnimated(keys, PropertyKeys.volume), isTrue);
      expect(KeyframeOps.hasKeyAt(keys, PropertyKeys.volume, rate(30)), isTrue);
      await rig.seek(rate(90));
      await drag(tester, 'audio.volume', -150);
      keys = keyframesOf(rig.clip(AudioIds.music));
      expect(KeyframeOps.hasKeyAt(keys, PropertyKeys.volume, rate(90)), isTrue);
      expect(rig.clip(AudioIds.music).audio.volume, 1, reason: 'the static value stays');
      expect(tester.widget<Text>(key('audio.db')).data, startsWith('−'), reason: 'the readout is the keyed value at the playhead');
    });

    testAudio('mute is one "Change mute" entry each way', (tester) async {
      final rig = await AudioRig.pump(tester, open: AudioIds.music);
      await tap(tester, key('audio.mute'));
      expect(rig.clip(AudioIds.music).audio.muted, isTrue);
      expect(rig.undoLabel, 'Change mute');
      expect(tester.widget<DanaviewSwitchRow>(key('audio.mute')).value, isTrue);
      await tap(tester, key('audio.mute'));
      expect(rig.clip(AudioIds.music).audio.muted, isFalse);
      expect(rig.entries, 2);
    });

    testAudio('fade in and fade out drags write whole-frame fades within half the clip', (tester) async {
      final rig = await AudioRig.pump(tester, open: AudioIds.music);
      await drag(tester, 'audio.fadeIn', 60);
      final a = rig.clip(AudioIds.music).audio;
      expect(a.fadeIn, greaterThan(0));
      expect(a.fadeIn, lessThanOrEqualTo(5 * s));
      expect(FrameRate.fps30.quantizeNearest(a.fadeIn), a.fadeIn, reason: 'on the frame grid');
      expect(rig.undoLabel, AudioStrings.historyFade);
      await drag(tester, 'audio.fadeOut', 2000);
      expect(rig.clip(AudioIds.music).audio.fadeOut, 5 * s, reason: 'the end of the slider is half the clip');
      expect(rig.entries, 2);
    });

    testAudio('keep pitch is one "Keep pitch" entry and keeps the speed', (tester) async {
      final rig = await AudioRig.pump(tester);
      await tap(tester, key('audio.keepPitch'));
      expect(rig.clip(AudioIds.video).maintainPitch, isFalse);
      expect(rig.clip(AudioIds.video).speed, SpeedSpec.normal);
      expect(rig.clip(AudioIds.video).duration, 12 * s);
      expect(rig.undoLabel, AudioStrings.historyKeepPitch);
    });

    testAudio('a role chip sets the lane role (SetAudioRole)', (tester) async {
      final rig = await AudioRig.pump(tester, open: AudioIds.music);
      await tap(tester, key('audio.role.voice'));
      expect(rig.track(AudioIds.musicLane).audioRole, AudioRole.voice);
      expect(rig.undoLabel, 'Set audio role');
      expect(tester.widget<DanaviewChoiceChip>(key('audio.role.voice')).selected, isTrue);
      await tap(tester, key('audio.role.voice'));
      expect(rig.entries, 1, reason: 'the current role is not re-applied');
    });

    testAudio('header reset: unity, unmuted, no fades and no volume keys, after a confirmation, as one entry', (tester) async {
      final rig = await AudioRig.pump(tester, open: AudioIds.music);
      expect(find.byIcon(Icons.settings_backup_restore_rounded), findsNothing, reason: 'nothing to reset');
      await rig.seek(rate(30));
      await tap(tester, find.descendant(of: key('audio.volume'), matching: find.byIcon(Icons.diamond_outlined)));
      await tap(tester, key('audio.mute'));
      await drag(tester, 'audio.fadeIn', 60);
      final before = rig.entries;
      await tap(tester, find.byIcon(Icons.settings_backup_restore_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reset').last);
      await tester.pumpAndSettle();
      final clip = rig.clip(AudioIds.music);
      expect(clip.audio, AudioProps.unity);
      expect(KeyframeOps.isAnimated(keyframesOf(clip), PropertyKeys.volume), isFalse);
      expect(rig.entries, before + 1);
      expect(rig.undoLabel, AudioStrings.historyReset);
    });
  });

  group('extract audio', () {
    testAudio('produces a linked audio clip on an "original" lane; the video stops playing its audio; the panel follows',
        (tester) async {
      final rig = await AudioRig.pump(tester);
      final lanes = rig.project.timeline.tracks.length;
      await tap(tester, key('audio.extract'));
      final video = rig.clip(AudioIds.video);
      expect(video.detachedAudio, isTrue);
      expect(video.link, isNotNull);
      final audio = rig.project.timeline.tracks
          .expand((t) => t.items)
          .whereType<MediaClip>()
          .singleWhere((c) => c.link == video.link && c.id != video.id);
      final lane = rig.project.timeline.tracks.singleWhere((t) => t.items.contains(audio));
      expect(lane.kind, TrackKind.audio);
      expect(lane.audioRole, AudioRole.original);
      expect(rig.project.timeline.tracks.length, lanes + 1, reason: 'a new lane for the original audio');
      expect((audio.media, audio.start, audio.duration, audio.sourceIn, audio.visual), (video.media, video.start, video.duration, video.sourceIn, null));
      expect(rig.undoLabel, 'Extract audio');
      expect(rig.entries, 1);
      expect(rig.state.inspector, AudioInspector(audio.id));
      expect(key('audio.extract'), findsNothing);
      // Non-destructive: undo restores the video's own audio.
      rig.editor.undo();
      await tester.pump();
      expect(rig.clip(AudioIds.video).detachedAudio, isFalse);
      expect(rig.project.timeline.tracks.length, lanes);
    });

    testAudio('an extracted video says where its audio is and selects it', (tester) async {
      final rig = await AudioRig.pump(tester);
      await tap(tester, key('audio.extract'));
      rig.editor
        ..select(AudioIds.video)
        ..openInspector(const AudioInspector(AudioIds.video));
      await tester.pump();
      await tester.pump();
      expect(find.text(AudioStrings.alreadyExtracted), findsOneWidget);
      expect(key('audio.volume'), findsNothing);
      expect(key('audio.extract'), findsNothing);
      await tap(tester, key('audio.selectExtracted'));
      final primary = rig.state.selection.primary!;
      expect(primary, isNot(AudioIds.video));
      expect(rig.clip(primary).visual, isNull);
      expect(rig.state.inspector, AudioInspector(primary));
    });
  });

  group('locked lanes', () {
    testAudio('a locked lane says so and disables the switches, chips and fades', (tester) async {
      final rig = await AudioRig.pump(tester, open: AudioIds.locked, selectOpen: false);
      expect(find.text(AudioStrings.trackLocked), findsOneWidget);
      expect(tester.widget<DanaviewSwitchRow>(key('audio.mute')).onChanged, isNull);
      expect(tester.widget<DanaviewSwitchRow>(key('audio.keepPitch')).onChanged, isNull);
      expect(tester.widget<DanaviewChoiceChip>(key('audio.role.music')).enabled, isFalse);
      expect(rowOf(tester, 'audio.fadeIn').enabled, isFalse);
      expect(find.byIcon(Icons.settings_backup_restore_rounded), findsNothing);
      expect(rig.entries, 0);
    });
  });

  group('matrix (no overflow, owner UI rules)', () {
    testAudioSurfaces('a video clip', (tester, surface) async {
      await AudioRig.pump(tester, surface: surface);
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
      for (final k in ['audio.mute', 'audio.keepPitch', 'audio.extract']) {
        await tester.ensureVisible(key(k));
        await tester.pump();
        final r = tester.getRect(key(k));
        expect(r.left, greaterThanOrEqualTo(0), reason: k);
        expect(r.right, lessThanOrEqualTo(surface.size.width), reason: k);
      }
      expectNoOverflow(tester);
    });

    testAudioSurfaces('a music clip with role chips', (tester, surface) async {
      await AudioRig.pump(tester, surface: surface, open: AudioIds.music);
      await tester.ensureVisible(key('audio.role.effects'));
      await tester.pump();
      final r = tester.getRect(key('audio.role.effects'));
      expect(r.right, lessThanOrEqualTo(surface.size.width));
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
    });

    testAudioSurfaces('an extracted video and a locked lane', (tester, surface) async {
      final rig = await AudioRig.pump(tester, surface: surface);
      await tap(tester, key('audio.extract'));
      rig.editor.openInspector(const AudioInspector(AudioIds.video));
      await tester.pump();
      await tester.pump();
      expect(find.text(AudioStrings.alreadyExtracted), findsOneWidget);
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
      rig.editor.openInspector(const AudioInspector(AudioIds.locked));
      await tester.pump();
      await tester.pump();
      expect(find.text(AudioStrings.trackLocked), findsOneWidget);
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
    });
  });
}

/// Frame [n] on the rig's 30 fps grid.
TimeUs rate(int n) => FrameRate.fps30.timeOfFrame(n);
