// OWNER: UX-27
//
// The transitions panel (ux.md §10.12) for one cut, addressed by its `TransitionRef`.
//
// * Tiles: None, Fade, Cross dissolve, Dip to black, Dip to white, Slide, Wipe, Zoom (glyph and
//   text label each). A tile runs `SetTransition(ref, spec, clamp: true)`: one history entry; the
//   duration and a direction of the same family are kept, a too-long duration is shortened to the
//   kind's limit. A kind that cannot take a single frame at this cut (overlap kinds without
//   handles) is disabled with an explanation. None removes the transition.
// * Duration slider: 0.1 s up to `min(2.0 s, TransitionLimits.of(kind))`, in whole frames. A drag
//   is one transaction (one entry); arrow-key steps coalesce; a typed value is one entry. When the
//   limit is below 2 s the panel says "Longer transitions need more video on both sides of the
//   cut."
// * Direction: Left/Right/Up/Down for Slide and Wipe, In/Out for Zoom (one entry per change).
// * Loop preview: opening the panel saves the transport's play state, loop range and playhead,
//   loops `cut ± (duration/2 + 0.75 s)` and plays it; "Stop preview" pauses it and "Play preview"
//   resumes it. The loop follows duration changes. Leaving the panel restores what was saved
//   (paused or playing, the old loop range, the old playhead).
// * "Apply to all cuts" runs one `ApplyTransitionToAll` on the cut's lane (the main lane for the
//   timeline's "+" buttons): one history entry; each cut is clamped to its own limit. With None
//   selected it removes every transition of the lane.
// * A locked lane or a cut that no longer exists shows a notice and disables the controls.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/eval.dart' show TransitionLimits;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show ApplyTransitionToAll, EditCommand, SetTransition, TransitionSpec;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../app/editor_providers.dart';
import '../../app/strings/transition_strings.dart';
import '../contracts/inspector_routes.dart';
import '../editor_scope.dart';
import '../inspector/inspector_rows.dart';
import '../state/transport_controller.dart';
import 'transform_panel.dart' show PanelNotice;

/// The arithmetic of the transitions panel (frames, seconds, slider range, loop window).
abstract final class TransitionPanelModel {
  /// Shortest duration offered by the slider.
  static const TimeUs minDuration = microsPerSecond ~/ 10;

  /// Longest duration offered by the slider.
  static const TimeUs maxDuration = 2 * microsPerSecond;

  /// Duration of a new transition.
  static const TimeUs defaultDuration = microsPerSecond ~/ 2;

  /// Extra time the loop preview shows on each side of the transition window.
  static const TimeUs loopPadding = 750000;

  /// The tile order (null is None).
  static const List<TransitionKind?> tiles = [
    null,
    TransitionKind.fade,
    TransitionKind.crossDissolve,
    TransitionKind.dipToBlack,
    TransitionKind.dipToWhite,
    TransitionKind.slide,
    TransitionKind.wipe,
    TransitionKind.zoom,
  ];

  /// The glyph of a tile (ux.md §10.12).
  static IconData iconOf(TransitionKind? kind) => switch (kind) {
        null => Icons.block_rounded,
        TransitionKind.fade => Icons.gradient_rounded,
        TransitionKind.crossDissolve => Icons.join_inner_rounded,
        TransitionKind.dipToBlack => Icons.contrast_rounded,
        TransitionKind.dipToWhite => Icons.wb_sunny_rounded,
        TransitionKind.slide => Icons.swap_horiz_rounded,
        TransitionKind.wipe => Icons.vertical_split_rounded,
        TransitionKind.zoom => Icons.zoom_in_rounded,
      };

  /// The glyph of a direction.
  static IconData directionIcon(TransitionDirection d) => switch (d) {
        TransitionDirection.left => Icons.arrow_back_rounded,
        TransitionDirection.right => Icons.arrow_forward_rounded,
        TransitionDirection.up => Icons.arrow_upward_rounded,
        TransitionDirection.down => Icons.arrow_downward_rounded,
        TransitionDirection.zoomIn => Icons.zoom_in_rounded,
        TransitionDirection.zoomOut => Icons.zoom_out_rounded,
      };

  /// The tile key of [kind].
  static String tileKey(TransitionKind? kind) => 'transitions.kind.${kind?.name ?? 'none'}';

  /// Whole frames of [t] on [rate] (rounded, at least 1).
  static int framesOf(TimeUs t, FrameRate rate) => math.max(1, (t * rate.num / (rate.den * microsPerSecond)).round());

  /// Seconds of [frames] on [rate].
  static double secondsOf(int frames, FrameRate rate) => frames * rate.den / rate.num;

  /// Duration of [frames] on [rate].
  static TimeUs timeOf(int frames, FrameRate rate) => rate.timeOfFrame(frames);

  /// The largest slider value (frames) for a kind whose limit is [limit].
  static int sliderMaxFrames(int limit, FrameRate rate) => math.min(framesOf(maxDuration, rate), limit);

  /// The smallest slider value (frames) when the largest is [max].
  static int sliderMinFrames(int max, FrameRate rate) => math.min(framesOf(minDuration, rate), max);

  /// Whether a kind whose limit is [limit] is capped below the 2 s maximum.
  static bool isLimited(int limit, FrameRate rate) => limit < framesOf(maxDuration, rate);

  /// The default duration (frames) of a new transition, within [limit].
  static int defaultFrames(int limit, FrameRate rate) => math.min(framesOf(defaultDuration, rate), limit);

  /// The direction [kind] keeps from [previous] (same family), else its default.
  static TransitionDirection? directionFor(TransitionKind kind, TransitionDirection? previous) {
    final allowed = TransitionSpec.directionsOf(kind);
    if (allowed.isEmpty) return null;
    return previous != null && allowed.contains(previous) ? previous : allowed.first;
  }

  /// The loop range of the preview: `cut ± (duration/2 + 0.75 s)` on the frame grid, inside
  /// `[0, projectDuration)`. [frames] 0 previews the bare cut.
  static TimeRange loopRange({required TimeUs cut, required int frames, required FrameRate rate, required TimeUs projectDuration}) {
    final half = timeOf(frames, rate) ~/ 2 + loopPadding;
    var start = rate.quantize(cut - half);
    var end = rate.quantize(cut + half);
    if (start < 0) start = 0;
    if (end > projectDuration) end = projectDuration;
    if (end < start) end = start;
    return TimeRange(start, end);
  }
}

/// What the panel reads of the project for its cut.
@immutable
final class TransitionPanelView {
  /// Reads [project] at [ref].
  factory TransitionPanelView.of(EditProject project, TransitionRef ref) {
    final rate = project.settings.frameRate;
    final loc = project.index.trackIndexOf(ref.track);
    final track = loc == null ? null : project.tracks[loc];
    final isCut = TransitionLimits.isCut(project, ref);
    TimeUs cut = 0;
    if (isCut && track != null) {
      for (final item in track.items) {
        if (item.id == ref.left) {
          cut = item.end;
          break;
        }
      }
    }
    return TransitionPanelView._(
      isCut: isCut,
      locked: track?.locked ?? false,
      current: isCut ? TransitionLimits.at(project, ref) : null,
      limits: isCut ? TransitionLimits.ofAll(project, ref) : const {},
      rate: rate,
      cut: cut,
      projectDuration: project.duration,
    );
  }

  const TransitionPanelView._({
    required this.isCut,
    required this.locked,
    required this.current,
    required this.limits,
    required this.rate,
    required this.cut,
    required this.projectDuration,
  });

  /// Whether the ref still names touching neighbours on a video or overlay lane.
  final bool isCut;

  /// Whether the lane is locked.
  final bool locked;

  /// The transition at the cut, if any.
  final Transition? current;

  /// The limit (frames) of every kind at the cut.
  final Map<TransitionKind, int> limits;

  /// The project frame rate.
  final FrameRate rate;

  /// Time of the cut.
  final TimeUs cut;

  /// Length of the project.
  final TimeUs projectDuration;

  /// The limit (frames) of [kind].
  int limitOf(TransitionKind kind) => limits[kind] ?? 0;

  /// Whether no kind fits at all.
  bool get noneFits => isCut && limits.values.every((l) => l < 1);

  /// Whether some kinds are disabled (but not all).
  bool get someDisabled => isCut && !noneFits && limits.values.any((l) => l < 1);

  /// The loop range the preview plays.
  TimeRange get loop =>
      TransitionPanelModel.loopRange(cut: cut, frames: current?.durationFrames ?? 0, rate: rate, projectDuration: projectDuration);

  @override
  bool operator ==(Object other) =>
      other is TransitionPanelView &&
      other.isCut == isCut &&
      other.locked == locked &&
      other.current == current &&
      other.rate == rate &&
      other.cut == cut &&
      other.projectDuration == projectDuration &&
      _sameLimits(other.limits, limits);

  static bool _sameLimits(Map<TransitionKind, int> a, Map<TransitionKind, int> b) =>
      a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

  @override
  int get hashCode => Object.hash(isCut, locked, current, rate, cut, projectDuration, Object.hashAllUnordered(limits.values));
}

/// The transport state saved when the loop preview starts.
typedef _SavedTransport = ({bool playing, TimeRange? loop, TimeUs position});

/// The transitions panel (ux.md §10.12).
class TransitionsPanel extends ConsumerStatefulWidget {
  /// Creates the panel.
  const TransitionsPanel({super.key, required this.route});

  /// What the panel edits.
  final TransitionInspector route;

  @override
  ConsumerState<TransitionsPanel> createState() => _TransitionsPanelState();
}

class _TransitionsPanelState extends ConsumerState<TransitionsPanel> {
  TransportController? _transport;
  _SavedTransport? _saved;
  bool _previewing = false;
  /// Transport operations of every transitions panel run in order (a panel that closes restores
  /// the transport before the next one saves it).
  static Future<void> _ops = Future<void>.value();
  InspectorEditSession? _session;
  double? _liveSeconds;

  TransitionRef get _ref => widget.route.cut;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _startPreview();
    });
  }

  @override
  void dispose() {
    _session?.dispose();
    _restore();
    super.dispose();
  }

  /// Runs [op] after the previous transport operation.
  void _enqueue(Future<void> Function() op) {
    _ops = _ops.then((_) => op()).catchError((Object _) {});
  }

  TransportController _transportOf() {
    final id = EditorScope.idOf(context);
    final TransportController transport = _transport ?? ref.read<TransportController>(transportProvider(id));
    _transport = transport;
    return transport;
  }

  TransitionPanelView? _viewNow() {
    final id = EditorScope.idOf(context);
    final project = ref.read(editorControllerProvider(id)).project;
    return project == null ? null : TransitionPanelView.of(project, _ref);
  }

  void _startPreview() {
    final view = _viewNow();
    if (view == null || !view.isCut) return;
    final transport = _transportOf();
    if (!transport.canPlay) return;
    setState(() => _previewing = true);
    final range = view.loop;
    _enqueue(() async {
      if (!mounted) return;
      _saved ??= (playing: transport.playing.value, loop: transport.loop.value, position: transport.playhead.value);
      await transport.setLoop(range);
      await transport.play();
    });
  }

  void _stopPreview() {
    final transport = _transport;
    setState(() => _previewing = false);
    if (transport == null) return;
    final saved = _saved;
    _enqueue(() async {
      await transport.pause();
      await transport.setLoop(saved?.loop);
    });
  }

  /// Leaving the panel: the play state, loop and playhead saved when the preview started.
  void _restore() {
    final transport = _transport;
    final saved = _saved;
    _saved = null;
    _previewing = false;
    if (transport == null || saved == null) return;
    _enqueue(() async {
      await transport.pause();
      await transport.setLoop(saved.loop);
      await transport.seekTo(saved.position);
      if (saved.playing) await transport.play();
    });
  }

  /// Keeps the loop on the transition window while previewing.
  void _followLoop(TransitionPanelView view) {
    if (!_previewing || !view.isCut) return;
    final transport = _transport;
    if (transport == null) return;
    final range = view.loop;
    if (transport.loop.value == range) return;
    _enqueue(() => transport.setLoop(range));
  }

  @override
  void didUpdateWidget(TransitionsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.route.cut != widget.route.cut) {
      _liveSeconds = null;
      _session?.dispose();
      _session = null;
    }
  }

  void _apply(EditCommand command) {
    final id = EditorScope.idOf(context);
    ref.read(editorControllerProvider(id).notifier).apply(command);
  }

  InspectorEditSession _sessionFor() {
    final id = EditorScope.idOf(context);
    final editor = ref.read(editorControllerProvider(id).notifier);
    final key = 'transition:${_ref.track}:${_ref.left}|${_ref.right}';
    final s = _session ??= InspectorEditSession(editor: editor, label: TransitionStrings.historyDuration, coalesceKey: key);
    s
      ..editor = editor
      ..coalesceKey = key;
    return s;
  }

  void _pickKind(TransitionPanelView view, TransitionKind? kind) {
    if (kind == null) {
      if (view.current != null) _apply(SetTransition(_ref, null));
      return;
    }
    final current = view.current;
    if (current?.kind == kind) return;
    final limit = view.limitOf(kind);
    if (limit < 1) return;
    final frames = current?.durationFrames ?? TransitionPanelModel.defaultFrames(limit, view.rate);
    _apply(SetTransition(
      _ref,
      TransitionSpec(kind, frames, direction: TransitionPanelModel.directionFor(kind, current?.direction)),
      clamp: true,
    ));
  }

  EditCommand _durationCommand(Transition current, double seconds, FrameRate rate) => SetTransition(
        _ref,
        TransitionSpec(current.kind, TransitionPanelModel.framesOf((seconds * microsPerSecond).round(), rate), direction: current.direction),
        clamp: true,
      );

  void _applyAll(TransitionPanelView view) {
    final current = view.current;
    _apply(ApplyTransitionToAll(
      current == null ? null : TransitionSpec(current.kind, current.durationFrames, direction: current.direction),
      track: _ref.track,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final id = EditorScope.idOf(context);
    final project = ref.watch(editorControllerProvider(id).select((s) => s.project));
    final isReady = ref.watch(editorControllerProvider(id).select((s) => s.isReady));
    if (project == null) return const SizedBox.shrink();
    final view = TransitionPanelView.of(project, _ref);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _followLoop(view);
    });
    final ready = isReady && view.isCut && !view.locked && ref.read(editorControllerProvider(id).notifier).canEdit;
    final current = view.current;
    final rate = view.rate;

    final children = <Widget>[
      if (!view.isCut) const PanelNotice(TransitionStrings.noCut, key: ValueKey<String>('transitions.noCut')),
      if (view.isCut && view.locked) const PanelNotice(TransitionStrings.trackLocked, key: ValueKey<String>('transitions.locked')),
      if (view.noneFits) const PanelNotice(TransitionStrings.noneFits, key: ValueKey<String>('transitions.noneFits')),
      _Heading(TransitionStrings.typeHeading),
      DanaviewChipGroup(
        children: [
          for (final kind in TransitionPanelModel.tiles)
            DanaviewChoiceChip(
              key: ValueKey<String>(TransitionPanelModel.tileKey(kind)),
              label: kind == null ? TransitionStrings.none : TransitionStrings.kindName(kind),
              icon: TransitionPanelModel.iconOf(kind),
              selected: current?.kind == kind && view.isCut,
              enabled: ready && (kind == null || view.limitOf(kind) >= 1),
              onTap: () => _pickKind(view, kind),
            ),
        ],
      ),
      if (view.someDisabled)
        const PanelNotice(TransitionStrings.needsHandles, key: ValueKey<String>('transitions.needsHandles'), color: DanaviewColors.textSecondary),
      if (current != null) ..._settings(view, current, rate, ready),
      const SizedBox(height: DanaviewSpacing.md),
      Wrap(
        spacing: DanaviewSpacing.sm,
        runSpacing: DanaviewSpacing.sm,
        children: [
          ValueListenableBuilder<bool>(
            valueListenable: _transportOf().playing,
            builder: (context, playing, _) {
              final running = _previewing && playing;
              return DanaviewButton.secondary(
                key: const ValueKey<String>('transitions.preview'),
                label: running ? TransitionStrings.stopPreview : TransitionStrings.playPreview,
                icon: running ? Icons.stop_rounded : Icons.play_arrow_rounded,
                onPressed: view.isCut ? (running ? _stopPreview : _startPreview) : null,
              );
            },
          ),
          DanaviewButton.secondary(
            key: const ValueKey<String>('transitions.applyAll'),
            label: current == null ? TransitionStrings.removeAll : TransitionStrings.applyAll,
            icon: Icons.done_all_rounded,
            onPressed: ready ? () => _applyAll(view) : null,
          ),
        ],
      ),
    ];

    return CustomScrollView(
      key: const ValueKey<String>('transitions.scroll'),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(DanaviewSpacing.lg, DanaviewSpacing.sm, DanaviewSpacing.lg, DanaviewSpacing.lg),
          sliver: SliverToBoxAdapter(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
          ),
        ),
      ],
    );
  }

  List<Widget> _settings(TransitionPanelView view, Transition current, FrameRate rate, bool ready) {
    final limit = view.limitOf(current.kind);
    final maxFrames = TransitionPanelModel.sliderMaxFrames(math.max(limit, 1), rate);
    final minFrames = TransitionPanelModel.sliderMinFrames(maxFrames, rate);
    final session = _sessionFor();
    final shown = _liveSeconds ?? TransitionPanelModel.secondsOf(current.durationFrames, rate);
    final directions = TransitionSpec.directionsOf(current.kind);
    return [
      const SizedBox(height: DanaviewSpacing.sm),
      InspectorSliderRow(
        key: const ValueKey<String>('transitions.duration'),
        label: TransitionStrings.duration,
        value: shown,
        min: TransitionPanelModel.secondsOf(minFrames, rate),
        max: TransitionPanelModel.secondsOf(maxFrames, rate),
        step: TransitionPanelModel.secondsOf(1, rate),
        fractionDigits: 2,
        unit: TransitionStrings.secondsUnit,
        enabled: ready,
        onChangeStart: (_) => session.start(),
        onChanged: (v) {
          setState(() => _liveSeconds = v);
          session.change(_durationCommand(current, v, rate));
        },
        onChangeEnd: (_) {
          session.end();
          setState(() => _liveSeconds = null);
        },
        onSubmitted: (v) => session.apply(_durationCommand(current, v, rate)),
      ),
      if (TransitionPanelModel.isLimited(limit, rate))
        const PanelNotice(TransitionStrings.limited, key: ValueKey<String>('transitions.limited'), color: DanaviewColors.textSecondary),
      if (directions.isNotEmpty)
        InspectorChoiceRow<TransitionDirection>(
          key: const ValueKey<String>('transitions.direction'),
          label: TransitionStrings.direction,
          value: current.direction ?? directions.first,
          enabled: ready,
          options: [
            for (final d in directions)
              DanaviewOption<TransitionDirection>(
                value: d,
                label: TransitionStrings.directionLabel(d),
                icon: TransitionPanelModel.directionIcon(d),
              ),
          ],
          onChanged: (d) {
            if (d == current.direction) return;
            _apply(SetTransition(_ref, TransitionSpec(current.kind, current.durationFrames, direction: d), clamp: true));
          },
        ),
    ];
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: DanaviewSpacing.xs, bottom: DanaviewSpacing.sm),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: DanaviewTextStyles.caption.copyWith(fontFamily: DanaviewFonts.family, color: DanaviewColors.textSecondary),
        ),
      );
}
