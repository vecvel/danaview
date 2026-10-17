// OWNER: UX-33
//
// The audio panel (ux.md §10.4) for an audio clip or a video clip with sound.
//
// * Volume: the CORE-05 metadata row (`InspectorPropertyRow`: 0…200 %, keyframe toggle,
//   keyframe-aware `SetProperty` at the playhead; a drag is one transaction, steps coalesce) with a
//   decibel readout (100 % = 0 dB) of the value at the playhead.
// * Mute: a switch writing `audio.muted` (one entry per change). Lane mute and solo stay on the
//   lane header.
// * Fade in / Fade out: sliders 0…min(10 s, half the clip) writing `audio.fadeIn/fadeOut` (core fits
//   them to whole frames); the timeline's fade handles (UX-13) edit the same values.
// * Keep pitch: mirrors the speed panel's switch (`SetSpeed` with the clip's speed and the new
//   `maintainPitch`), one entry "Keep pitch".
// * Lane role (audio lanes only): Original / Voice / Music / Effects chips, core `SetAudioRole` on the
//   clip's lane (it drives defaults, caption priority and the music exclusion).
// * Extract audio (video clips only): core `ExtractAudio` (non-destructive, linked, same media),
//   then the panel moves to the new audio clip. A video whose audio was already extracted shows a
//   note and "Select audio clip" instead of the rows.
// * Header reset: unity volume, unmuted, no fades, volume keys cleared, as one entry "Reset audio".
// * `AudioPanelFocus.fades` scrolls the fades into view. Trim, split, move, duplicate and delete of
//   audio clips are the timeline's tools (UX-13). The panel owns its scrolling.

import 'dart:math' as math;

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/eval.dart' show evaluate;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show ClearKeyframes, CompositeCommand, EditCommand, SetAudio, SetAudioRole, SetProperty, SetSpeed;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../app/editor_providers.dart';
import '../../app/strings/audio_strings.dart';
import '../actions/bindings/audio_bindings.dart' show AudioOperations;
import '../contracts/inspector_routes.dart';
import '../editor_scope.dart';
import '../inspector/inspector_header.dart';
import '../inspector/inspector_rows.dart';
import '../state/editor_controller.dart';
import '../state/editor_state.dart';
import '../timeline/timeline_semantics.dart' show editorAnnounce;

/// The longest fade the panel offers (the core's `audio.fadeIn/fadeOut` maximum).
const TimeUs maxAudioFade = 10 * microsPerSecond;

/// The fade range of a clip of [duration]: at most 10 s and half the clip.
TimeUs audioFadeLimit(TimeUs duration) => math.max(0, math.min(maxAudioFade, duration ~/ 2));

/// What the panel reads of the project.
typedef _View = ({MediaClip? clip, Track? track, bool hasAudio, bool isVideo, ItemId? extracted});

_View _viewOf(EditorState s, ItemId id) {
  final project = s.project;
  final loc = project?.index.locate(id);
  final item = loc?.item;
  if (project == null || loc == null || item is! MediaClip) {
    return (clip: null, track: null, hasAudio: false, isVideo: false, extracted: null);
  }
  final asset = project.pool[item.media];
  return (
    clip: item,
    track: loc.track,
    hasAudio: asset == null || asset.probe.hasAudio,
    isVideo: item.visual != null,
    extracted: item.detachedAudio ? AudioOperations.extractedPartner(project, id) : null,
  );
}

/// The audio panel (ux.md §10.4).
class AudioPanel extends ConsumerStatefulWidget {
  /// Creates the panel for [route].
  const AudioPanel({super.key, required this.route});

  /// What the panel edits.
  final AudioInspector route;

  @override
  ConsumerState<AudioPanel> createState() => _AudioPanelState();
}

class _AudioPanelState extends ConsumerState<AudioPanel> {
  final GlobalKey _fadesKey = GlobalKey(debugLabel: 'audio.fades');

  ItemId get _item => widget.route.item;

  @override
  void initState() {
    super.initState();
    _scheduleFocus();
  }

  @override
  void didUpdateWidget(AudioPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.route != widget.route) _scheduleFocus();
  }

  void _scheduleFocus() {
    if (widget.route.focus != AudioPanelFocus.fades) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _fadesKey.currentContext;
      if (!mounted || target == null) return;
      Scrollable.ensureVisible(target, duration: Duration.zero);
    });
  }

  EditorController get _editor => ref.read(editorControllerProvider(EditorScope.idOf(context)).notifier);

  // ---- Edits ---------------------------------------------------------------------------------

  void _reset(MediaClip clip) {
    final animated = KeyframeOps.isAnimated(keyframesOf(clip), PropertyKeys.volume);
    _editor.apply(CompositeCommand(AudioStrings.historyReset, [
      if (animated) ClearKeyframes([clip.id], property: PropertyKeys.volume.id),
      SetAudio([clip.id], AudioProps.unity),
    ]));
  }

  void _extract() {
    final editor = _editor;
    final id = EditorScope.idOf(context);
    final added = AudioOperations.extract(editor, _item, () => ref.read(editorControllerProvider(id)).project);
    if (added == null) return;
    editor.openInspector(AudioInspector(added));
    editorAnnounce(context, AudioStrings.extracted);
  }

  void _selectExtracted(ItemId audio) {
    _editor
      ..select(audio)
      ..openInspector(AudioInspector(audio));
  }

  // ---- Build ---------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final id = EditorScope.idOf(context);
    final view = ref.watch(editorControllerProvider(id).select((s) => _viewOf(s, _item)));
    final ready = ref.watch(editorControllerProvider(id).select((s) => s.isReady));
    final clip = view.clip;
    final track = view.track;
    if (clip == null || track == null) return const _Message(AudioStrings.clipGone);
    final locked = track.locked;
    final enabled = ready && !locked;
    final detached = view.isVideo && clip.detachedAudio;
    final extractBlocker = view.isVideo ? AudioOperations.extractBlocker(ref.read(editorControllerProvider(id)).project!, _item) : null;
    final changed = clip.audio != AudioProps.unity || KeyframeOps.isAnimated(keyframesOf(clip), PropertyKeys.volume);

    final rows = <Widget>[
      if (locked) const _Note(key: ValueKey<String>('audio.lockedNote'), text: AudioStrings.trackLocked, icon: Icons.lock_rounded),
      if (detached) ...[
        const _Note(key: ValueKey<String>('audio.extractedNote'), text: AudioStrings.alreadyExtracted, icon: Icons.call_split_rounded),
        const SizedBox(height: DanaviewSpacing.md),
        if (view.extracted case final audio?)
          Align(
            alignment: Alignment.centerLeft,
            child: DanaviewButton.secondary(
              key: const ValueKey<String>('audio.selectExtracted'),
              label: AudioStrings.selectExtracted,
              icon: Icons.graphic_eq_rounded,
              onPressed: () => _selectExtracted(audio),
            ),
          ),
      ] else ...[
        InspectorPropertyRow(key: const ValueKey<String>('audio.volume'), item: clip.id, property: PropertyKeys.volume, label: AudioStrings.volume),
        _DecibelReadout(clip: clip),
        const SizedBox(height: DanaviewSpacing.xs),
        DanaviewSwitchRow(
          key: const ValueKey<String>('audio.mute'),
          title: AudioStrings.mute,
          subtitle: AudioStrings.muteHint,
          value: clip.audio.muted,
          onChanged: enabled ? (v) => _editor.apply(SetProperty<bool>([clip.id], PropertyKeys.muted, v)) : null,
        ),
        const SizedBox(height: DanaviewSpacing.md),
        _Heading(AudioStrings.fadesHeading, key: _fadesKey),
        _FadeRow(key: const ValueKey<String>('audio.fadeIn'), clip: clip, property: PropertyKeys.fadeIn, label: AudioStrings.fadeIn, enabled: enabled),
        _FadeRow(key: const ValueKey<String>('audio.fadeOut'), clip: clip, property: PropertyKeys.fadeOut, label: AudioStrings.fadeOut, enabled: enabled),
        _Caption(AudioStrings.fadeLimit(audioFadeLimit(clip.duration) / microsPerSecond)),
        const SizedBox(height: DanaviewSpacing.md),
        DanaviewSwitchRow(
          key: const ValueKey<String>('audio.keepPitch'),
          title: AudioStrings.keepPitch,
          subtitle: AudioStrings.keepPitchHint,
          value: clip.maintainPitch,
          onChanged: enabled
              ? (v) => _editor.apply(CompositeCommand(AudioStrings.historyKeepPitch, [SetSpeed(clip.id, clip.speed, maintainPitch: v)]))
              : null,
        ),
        if (track.kind == TrackKind.audio) ...[
          const SizedBox(height: DanaviewSpacing.md),
          const _Heading(AudioStrings.roleHeading),
          DanaviewChipGroup(
            key: const ValueKey<String>('audio.role'),
            children: [
              for (final role in AudioRole.values)
                DanaviewChoiceChip(
                  key: ValueKey<String>('audio.role.${role.name}'),
                  label: AudioStrings.roleName(role),
                  selected: track.audioRole == role,
                  enabled: enabled,
                  onTap: () {
                    if (track.audioRole != role) _editor.apply(SetAudioRole(track.id, role));
                  },
                ),
            ],
          ),
          const SizedBox(height: DanaviewSpacing.xs),
          const _Caption(AudioStrings.roleHint),
        ],
      ],
      if (view.isVideo && view.hasAudio && !detached) ...[
        const SizedBox(height: DanaviewSpacing.lg),
        Align(
          alignment: Alignment.centerLeft,
          child: DanaviewButton.secondary(
            key: const ValueKey<String>('audio.extract'),
            label: AudioStrings.extract,
            icon: Icons.call_split_rounded,
            tooltip: extractBlocker == null ? null : AudioOperations.reasonOf(extractBlocker),
            onPressed: ready && extractBlocker == null ? _extract : null,
          ),
        ),
        const SizedBox(height: DanaviewSpacing.xs),
        const _Caption(AudioStrings.extractHint),
      ],
    ];

    final body = CustomScrollView(
      key: const ValueKey<String>('audio.scroll'),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(DanaviewSpacing.lg, DanaviewSpacing.sm, DanaviewSpacing.lg, DanaviewSpacing.lg),
          sliver: SliverToBoxAdapter(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows)),
        ),
      ],
    );
    return InspectorHeaderActions.publish(
      actions: InspectorHeaderActions(
        onReset: enabled && !detached && changed ? () => _reset(clip) : null,
        resetRemovesKeyframes: KeyframeOps.isAnimated(keyframesOf(clip), PropertyKeys.volume),
      ),
      child: body,
    );
  }
}

// -------------------------------------------------------------------------------------------------
// Rows
// -------------------------------------------------------------------------------------------------

/// The volume in decibels at the playhead (keyed volume follows the playhead).
class _DecibelReadout extends ConsumerWidget {
  const _DecibelReadout({required this.clip});

  final MediaClip clip;

  double _gainAt(TimeUs t) {
    final local = (t - clip.start).clamp(0, math.max(0, clip.duration - 1)).toInt();
    final v = evaluate<Object?>(clip, PropertyKeys.volume, local);
    return v is num ? v.toDouble() : clip.audio.volume;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playhead = ref.watch(playheadProvider(EditorScope.idOf(context)));
    Widget text(double gain) => Semantics(
          label: AudioStrings.decibelsSemantics(gain),
          excludeSemantics: true,
          child: Align(
            alignment: Alignment.centerRight,
            child: Text(
              AudioStrings.decibels(gain),
              key: const ValueKey<String>('audio.db'),
              style: _captionStyle.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          ),
        );
    if (!KeyframeOps.isAnimated(keyframesOf(clip), PropertyKeys.volume)) return text(clip.audio.volume);
    return ValueListenableBuilder<TimeUs>(valueListenable: playhead, builder: (context, t, _) => text(_gainAt(t)));
  }
}

/// A fade length slider: 0…min(10 s, half the clip), in seconds.
class _FadeRow extends ConsumerStatefulWidget {
  const _FadeRow({super.key, required this.clip, required this.property, required this.label, required this.enabled});

  final MediaClip clip;
  final PropertyKey<int> property;
  final String label;
  final bool enabled;

  @override
  ConsumerState<_FadeRow> createState() => _FadeRowState();
}

class _FadeRowState extends ConsumerState<_FadeRow> {
  InspectorEditSession? _session;
  double? _live;

  @override
  void dispose() {
    _session?.dispose();
    super.dispose();
  }

  InspectorEditSession _sessionFor(EditorController editor) {
    final key = 'fade:${widget.clip.id}:${widget.property.id}';
    final s = _session ??= InspectorEditSession(editor: editor, label: AudioStrings.historyFade, coalesceKey: key);
    s
      ..editor = editor
      ..coalesceKey = key;
    return s;
  }

  EditCommand _command(double v, TimeUs limit) =>
      SetProperty<int>([widget.clip.id], widget.property, v.round().clamp(0, limit).toInt());

  @override
  Widget build(BuildContext context) {
    final editor = ref.read(editorControllerProvider(EditorScope.idOf(context)).notifier);
    final session = _sessionFor(editor);
    final limit = audioFadeLimit(widget.clip.duration);
    final current = widget.property.read(widget.clip).clamp(0, limit).toDouble();
    return InspectorSliderRow(
      label: widget.label,
      value: (_live ?? current).clamp(0, limit.toDouble()).toDouble(),
      min: 0,
      max: math.max(1, limit).toDouble(),
      step: 100000,
      displayScale: 1e-6,
      unit: 's',
      fractionDigits: 1,
      defaultValue: 0,
      enabled: widget.enabled && limit > 0,
      onChangeStart: (_) => session.start(),
      onChanged: (v) {
        setState(() => _live = v);
        session.change(_command(v, limit));
      },
      onChangeEnd: (_) {
        session.end();
        setState(() => _live = null);
      },
      onSubmitted: (v) => session.apply(_command(v, limit)),
    );
  }
}

// -------------------------------------------------------------------------------------------------
// Small parts
// -------------------------------------------------------------------------------------------------

TextStyle get _captionStyle => DanaviewTextStyles.caption.copyWith(fontFamily: DanaviewFonts.family, color: DanaviewColors.textSecondary);

class _Heading extends StatelessWidget {
  const _Heading(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: DanaviewSpacing.xs),
        child: Semantics(
          header: true,
          child: Text(
            text,
            style: DanaviewTextStyles.body
                .copyWith(fontFamily: DanaviewFonts.family, fontWeight: FontWeight.w600, color: DanaviewColors.textSecondary, fontSize: 13),
          ),
        ),
      );
}

class _Caption extends StatelessWidget {
  const _Caption(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(text, style: _captionStyle);
}

class _Message extends StatelessWidget {
  const _Message(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(DanaviewSpacing.lg),
        child: Align(alignment: Alignment.topLeft, child: Text(text, style: _captionStyle)),
      );
}

/// A quiet explanation with an icon (locked lane, extracted audio).
class _Note extends StatelessWidget {
  const _Note({super.key, required this.text, required this.icon});

  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: DanaviewSpacing.xs),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: DanaviewColors.surfaceElevatedHigher,
            borderRadius: DanaviewRadius.smAll,
            border: Border.fromBorderSide(DanaviewBorders.hairline),
          ),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 16, color: DanaviewColors.warning)),
              const SizedBox(width: 8),
              Expanded(child: Text(text, style: _captionStyle.copyWith(color: DanaviewColors.textPrimary))),
            ]),
          ),
        ),
      );
}
