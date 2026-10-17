// OWNER: UX-11
//
// Track headers (ux.md §8.10, §8.3): the column left of the lanes.
//
// * Compact (44 px): a 44 x lane-height pressable with the kind icon and tiny status glyphs (lock,
//   eye-off, muted, solo "S") in its corner. Tap opens the track menu.
// * Medium and expanded (132 to 220 px): kind icon, name (ellipsis) and inline toggles for lock,
//   visibility, mute and solo. Toggles are 32 px wide with a pointer and 44 px with touch (the hit
//   area is the whole slot and the lane height), so as many as fit next to a minimum name are
//   inline, in priority order per lane kind; the others are reached through the menu and shown as
//   status glyphs while they are on. Tap on the icon or name opens the track menu.
// * Which toggles a lane has follows ux.md §8.3: video and overlay lanes have visibility, lock
//   and (when they hold audio, or the flag is on) mute and solo; audio lanes mute, solo and lock;
//   text and subtitle lanes visibility and lock. Every toggle is a `toggled:` semantics node
//   named after the track.
// * Hit areas (ARCH §17.9, lead decision on QA-08 FIX-UX-11-1): text and subtitle lanes stay 32 px
//   tall (ARCH §17.2), and every header button (name/menu, toggles, the compact pressable) answers
//   taps and screen readers over at least 44×44 through `ExpandedHitArea`, reaching into the
//   neighbouring lanes' headers without growing the lane.
// * Commands are the CORE-17 `SetTrackFlags`, `RenameTrack`, `SetAudioRole`, `MoveTrack`,
//   `AddTrack` and `DeleteTrack`, issued through [TrackActions] (tests pass a recording sink).
// * [TrackHeaders] is presentational (snapshot, viewport and metrics in; callbacks out);
//   [ProjectTrackHeaders] wires it to the providers of the open project for the timeline view.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Icons, Theme;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show AddTrack, DeleteTrack, EditCommand, MoveTrack, RenameTrack, SetAudioRole, SetBurnIn, SetTrackFlags;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../app/editor_providers.dart';
import '../../app/strings/track_strings.dart';
import '../a11y/expanded_hit_area.dart';
import '../layout/editor_layout.dart' show EditorLayoutKind;
import '../layout/editor_layout_scope.dart';
import '../state/editor_controller.dart';
import 'timeline_metrics.dart';
import 'timeline_snapshot.dart';
import 'timeline_viewport.dart';
import 'track_menu_sheet.dart';

// -------------------------------------------------------------------------------------------------
// Flags
// -------------------------------------------------------------------------------------------------

/// One header toggle, in display order.
enum TrackFlag {
  /// Locked lanes can't be edited.
  lock,

  /// Hidden lanes are not drawn in the preview or the export.
  hidden,

  /// Muted lanes are silent.
  muted,

  /// Only soloed lanes are heard while any lane is soloed.
  solo,
}

/// Which flags a lane has and their state (ux.md §8.3).
abstract final class TrackFlags {
  /// The flags [lane] offers, in display order (lock, visibility, mute, solo). Mute and solo of a
  /// video or overlay lane appear when the lane holds audio or the flag is already on.
  static List<TrackFlag> applicable(LaneModel lane) {
    final kind = lane.kind;
    final carriesAudio = switch (kind) {
      TrackKind.audio => true,
      TrackKind.video || TrackKind.overlay => lane.muted || lane.solo || lane.items.any((i) => i.hasAudio),
      TrackKind.text || TrackKind.subtitle => false,
    };
    return [
      TrackFlag.lock,
      if (kind.isVisual) TrackFlag.hidden,
      if (carriesAudio) ...[TrackFlag.muted, TrackFlag.solo],
    ];
  }

  /// Whether [flag] is on for [lane] (hidden, locked, muted or soloed).
  static bool isOn(LaneModel lane, TrackFlag flag) => switch (flag) {
        TrackFlag.lock => lane.locked,
        TrackFlag.hidden => lane.hidden,
        TrackFlag.muted => lane.muted,
        TrackFlag.solo => lane.solo,
      };

  /// The order in which flags claim inline room when the header is narrow.
  static List<TrackFlag> priority(TrackKind kind) => switch (kind) {
        TrackKind.audio => const [TrackFlag.muted, TrackFlag.solo, TrackFlag.lock],
        TrackKind.video || TrackKind.overlay => const [TrackFlag.hidden, TrackFlag.muted, TrackFlag.lock, TrackFlag.solo],
        TrackKind.text || TrackKind.subtitle => const [TrackFlag.hidden, TrackFlag.lock],
      };

  /// The command that flips [flag] of [lane].
  static SetTrackFlags toggle(LaneModel lane, TrackFlag flag) => switch (flag) {
        TrackFlag.lock => SetTrackFlags(lane.id, locked: !lane.locked),
        TrackFlag.hidden => SetTrackFlags(lane.id, hidden: !lane.hidden),
        TrackFlag.muted => SetTrackFlags(lane.id, muted: !lane.muted),
        TrackFlag.solo => SetTrackFlags(lane.id, solo: !lane.solo),
      };
}

/// The icon of a lane kind (ux.md §8.10).
IconData trackKindIcon(TrackKind kind) => switch (kind) {
      TrackKind.video => Icons.movie_rounded,
      TrackKind.overlay => Icons.picture_in_picture_alt_rounded,
      TrackKind.audio => Icons.music_note_rounded,
      TrackKind.text => Icons.text_fields_rounded,
      TrackKind.subtitle => Icons.subtitles_rounded,
    };

// -------------------------------------------------------------------------------------------------
// Planner
// -------------------------------------------------------------------------------------------------

/// What one header shows at a given width (pure; unit-tested over the width and scale matrix).
@immutable
final class TrackHeaderPlan {
  /// Creates a plan.
  const TrackHeaderPlan({required this.compact, required this.inline, required this.glyphs, required this.toggleSlot});

  /// The icon-only 44 px header.
  final bool compact;

  /// Toggles drawn inline, in display order.
  final List<TrackFlag> inline;

  /// Flags that are on but not inline, drawn as small glyphs (all active flags when [compact]).
  final List<TrackFlag> glyphs;

  /// Width of one inline toggle (its hit area): 44 with touch, 32 with a pointer.
  final double toggleSlot;

  @override
  bool operator ==(Object other) =>
      other is TrackHeaderPlan &&
      other.compact == compact &&
      other.toggleSlot == toggleSlot &&
      listEquals(other.inline, inline) &&
      listEquals(other.glyphs, glyphs);

  @override
  int get hashCode => Object.hash(compact, toggleSlot, Object.hashAll(inline), Object.hashAll(glyphs));

  @override
  String toString() => 'TrackHeaderPlan(${compact ? 'compact' : 'inline: ${inline.map((f) => f.name).join('+')}'}, glyphs: ${glyphs.map((f) => f.name).join('+')})';
}

/// Decides which toggles fit in a header.
abstract final class TrackHeaderPlanner {
  /// Horizontal padding on each side of an expanded header.
  static const double padding = 4;

  /// Width reserved for the kind icon and the smallest name that still reads (at text scale 1).
  static const double nameMinWidth = 56;

  /// Width of one status glyph.
  static const double glyphWidth = 14;

  /// Toggle hit width with a pointer.
  static const double pointerSlot = 32;

  /// Toggle hit width with touch.
  static const double touchSlot = 44;

  /// The plan for a lane whose applicable flags are [applicable], of [kind], in a header of
  /// [width] px. [active] are the flags that are on. [textScale] widens the reserved name.
  static TrackHeaderPlan plan({
    required TrackKind kind,
    required List<TrackFlag> applicable,
    required Set<TrackFlag> active,
    required double width,
    required bool touch,
    double textScale = 1,
  }) {
    final slot = touch ? touchSlot : pointerSlot;
    final nameMin = nameMinWidth * math.max(1.0, textScale);
    // Under the compact width, or too narrow for a name beside the icon, the header is icon-only.
    if (width <= TimelineMetrics.compactHeaderWidth || width < 2 * padding + nameMin) {
      return TrackHeaderPlan(compact: true, inline: const [], glyphs: [for (final f in applicable) if (active.contains(f)) f], toggleSlot: slot);
    }
    var room = width - 2 * padding - nameMin;
    final chosen = <TrackFlag>{};
    for (final f in TrackFlags.priority(kind)) {
      if (!applicable.contains(f)) continue;
      if (room < slot) break;
      chosen.add(f);
      room -= slot;
    }
    final inline = [for (final f in applicable) if (chosen.contains(f)) f];
    final extra = [for (final f in applicable) if (!chosen.contains(f) && active.contains(f)) f];
    final glyphRoom = math.max(0, (room / glyphWidth).floor());
    return TrackHeaderPlan(compact: false, inline: inline, glyphs: extra.take(glyphRoom).toList(), toggleSlot: slot);
  }
}

// -------------------------------------------------------------------------------------------------
// Commands
// -------------------------------------------------------------------------------------------------

/// Applies one command; `EditorController.apply` in the editor, a recorder in tests.
typedef TrackCommandSink = EditResult Function(EditCommand command);

/// The track operations of the headers and the menu, each one CORE-17 command.
final class TrackActions {
  /// Creates the actions over [apply]. [focusLane], [selectAllOn] and [setLaneHeight] are the
  /// non-history operations (selection and the global lane height).
  TrackActions({
    required TrackCommandSink apply,
    void Function(TrackId lane)? focusLane,
    void Function(TrackId lane)? selectAllOn,
    void Function(LaneHeightPreset height)? setLaneHeight,
  })  : _apply = apply,
        _focusLane = focusLane,
        _selectAllOn = selectAllOn,
        _setLaneHeight = setLaneHeight;

  /// The actions of [controller].
  factory TrackActions.of(EditorController controller) => TrackActions(
        apply: controller.apply,
        focusLane: (lane) => controller.selectAt(lane, -1),
        selectAllOn: (lane) => controller.selectAll(lane: lane),
        setLaneHeight: (h) => controller.setModes((m) => m.copyWith(laneHeight: h)),
      );

  final TrackCommandSink _apply;
  final void Function(TrackId lane)? _focusLane;
  final void Function(TrackId lane)? _selectAllOn;
  final void Function(LaneHeightPreset height)? _setLaneHeight;

  /// Flips [flag] of [lane] (`SetTrackFlags`).
  EditResult toggle(LaneModel lane, TrackFlag flag) => _apply(TrackFlags.toggle(lane, flag));

  /// Renames [lane] (`RenameTrack`; an empty name restores the default).
  EditResult rename(TrackId lane, String name) => _apply(RenameTrack(lane, name));

  /// Sets the role of an audio lane (`SetAudioRole`).
  EditResult setRole(TrackId lane, AudioRole role) => _apply(SetAudioRole(lane, role));

  /// Moves [lane] to index [toIndex] of `Timeline.tracks` (`MoveTrack`).
  EditResult move(TrackId lane, int toIndex) => _apply(MoveTrack(lane, toIndex));

  /// Adds an empty lane of [kind] (`AddTrack`; the audio role defaults to music).
  EditResult add(TrackKind kind) => _apply(AddTrack(kind));

  /// Deletes [lane] with its items (`DeleteTrack`; the caller confirms first).
  EditResult delete(TrackId lane) => _apply(DeleteTrack(lane));

  /// Sets the default burn-in of a subtitle lane (`SetBurnIn`).
  EditResult setBurnIn(TrackId lane, bool on) => _apply(SetBurnIn(lane, on));

  /// Makes [lane] the selected lane (the target of paste and of the subtitle actions).
  void focusLane(TrackId lane) => _focusLane?.call(lane);

  /// Selects every clip of [lane].
  void selectAllOn(TrackId lane) => _selectAllOn?.call(lane);

  /// Sets the height of every lane.
  void setLaneHeight(LaneHeightPreset height) => _setLaneHeight?.call(height);
}

// -------------------------------------------------------------------------------------------------
// Widgets
// -------------------------------------------------------------------------------------------------

/// Opens the track menu of a lane.
typedef TrackMenuOpener = void Function(LaneModel lane);

/// The header column of the lanes area (not the ruler corner): one header per visible lane,
/// positioned like the canvas lanes and scrolled with the viewport. It is as wide as its parent
/// allows (the layout's header width: 44, 132, 168 or 220) and decides compact or expanded by it.
class TrackHeaders extends StatefulWidget {
  /// Creates the column.
  const TrackHeaders({
    super.key,
    required this.snapshot,
    required this.viewport,
    required this.metrics,
    required this.actions,
    this.onOpenMenu,
    this.selectedLane,
    this.enabled = true,
  });

  /// The lanes.
  final TimelineSnapshot snapshot;

  /// Supplies the vertical scroll.
  final TimelineViewportController viewport;

  /// Lane heights and the header width.
  final TimelineMetrics metrics;

  /// Where flag toggles go.
  final TrackActions actions;

  /// Opens the track menu (a tap on a header's icon or name).
  final TrackMenuOpener? onOpenMenu;

  /// The selected lane, drawn highlighted.
  final TrackId? selectedLane;

  /// False in a read-only project: toggles are disabled.
  final bool enabled;

  @override
  State<TrackHeaders> createState() => _TrackHeadersState();
}

class _TrackHeadersState extends State<TrackHeaders> {
  double _scrollY = 0;

  @override
  void initState() {
    super.initState();
    _scrollY = widget.viewport.scrollY;
    widget.viewport.addListener(_onViewport);
  }

  @override
  void didUpdateWidget(TrackHeaders oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.viewport, widget.viewport)) {
      oldWidget.viewport.removeListener(_onViewport);
      widget.viewport.addListener(_onViewport);
      _scrollY = widget.viewport.scrollY;
    }
  }

  @override
  void dispose() {
    widget.viewport.removeListener(_onViewport);
    super.dispose();
  }

  void _onViewport() {
    final y = widget.viewport.scrollY;
    if (y != _scrollY) setState(() => _scrollY = y);
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.snapshot;
    final metrics = widget.metrics;
    final stack = TimelineLaneStack.of(snapshot.laneKinds, metrics, presets: snapshot.laneHeights);
    return ColoredBox(
      color: DanaviewColors.surface,
      child: LayoutBuilder(builder: (context, constraints) {
        // The column is as wide as its parent makes it (the timeline gives it the layout's header
        // width); without a bound the metrics' header width applies.
        final width = constraints.hasBoundedWidth ? constraints.maxWidth : metrics.headerWidth;
        final viewportHeight = constraints.hasBoundedHeight ? constraints.maxHeight : stack.contentHeight;
        final (first, last) = stack.visibleRange(_scrollY, viewportHeight);
        return SizedBox(
          width: width,
          child: ClipRect(
            child: Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                for (var i = first; i < last; i++)
                  Positioned(
                    key: ValueKey(snapshot.lanes[i].id),
                    left: 0,
                    top: stack.tops[i] - _scrollY,
                    width: width,
                    height: stack.heights[i],
                    child: TrackHeaderCell(
                      lane: snapshot.lanes[i],
                      width: width,
                      metrics: metrics,
                      actions: widget.actions,
                      onOpenMenu: widget.onOpenMenu,
                      selected: snapshot.lanes[i].id == widget.selectedLane,
                      enabled: widget.enabled,
                    ),
                  ),
              ],
            ),
          ),
        );
      }),
    );
  }
}

/// One lane's header: compact or expanded by [width].
class TrackHeaderCell extends StatelessWidget {
  /// Creates the header of [lane].
  const TrackHeaderCell({
    super.key,
    required this.lane,
    required this.width,
    required this.metrics,
    required this.actions,
    this.onOpenMenu,
    this.selected = false,
    this.enabled = true,
  });

  /// The lane.
  final LaneModel lane;

  /// The header width.
  final double width;

  /// Text scale and input type.
  final TimelineMetrics metrics;

  /// Where flag toggles go.
  final TrackActions actions;

  /// Opens the track menu.
  final TrackMenuOpener? onOpenMenu;

  /// Whether the lane is the selected lane.
  final bool selected;

  /// False in a read-only project.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final applicable = TrackFlags.applicable(lane);
    final active = {for (final f in applicable) if (TrackFlags.isOn(lane, f)) f};
    final plan = TrackHeaderPlanner.plan(
      kind: lane.kind,
      applicable: applicable,
      active: active,
      width: width,
      touch: metrics.touch,
      textScale: metrics.textScale,
    );
    final label = TrackStrings.headerLabel(
      lane.displayName,
      lane.kind,
      isMain: lane.isMain,
      locked: lane.locked,
      hidden: lane.hidden,
      muted: lane.muted,
      solo: lane.solo,
    );
    void open() {
      actions.focusLane(lane.id);
      onOpenMenu?.call(lane);
    }

    final body = plan.compact ? _compact(label, plan, open) : _expanded(context, label, plan, open);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: selected ? const Color(0xFF1B1F33) : DanaviewColors.surfaceElevated,
        border: const Border(right: DanaviewBorders.hairline, bottom: DanaviewBorders.subtle),
      ),
      child: body,
    );
  }

  Widget _compact(String label, TrackHeaderPlan plan, VoidCallback open) {
    return ExpandedHitArea(child: DanaviewPressable.builder(
      onTap: onOpenMenu == null ? null : open,
      semanticLabel: label,
      selected: selected ? true : null,
      builder: (context, state) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(trackKindIcon(lane.kind), size: 18, color: lane.hidden ? DanaviewColors.textMuted : DanaviewColors.textPrimary),
            if (plan.glyphs.isNotEmpty) ...[
              const SizedBox(height: 1),
              _Glyphs(flags: plan.glyphs, size: 9),
            ],
          ],
        ),
      ),
    ));
  }

  Widget _expanded(BuildContext context, String label, TrackHeaderPlan plan, VoidCallback open) {
    return Padding(
      padding: const EdgeInsets.only(left: TrackHeaderPlanner.padding, right: TrackHeaderPlanner.padding),
      child: Row(
        children: [
          Expanded(
            child: ExpandedHitArea(child: DanaviewPressable.builder(
              onTap: onOpenMenu == null ? null : open,
              semanticLabel: label,
              selected: selected ? true : null,
              builder: (context, state) => ExcludeSemantics(
                child: SizedBox(
                  height: double.infinity,
                  child: Row(
                    children: [
                      const SizedBox(width: 4),
                      Icon(trackKindIcon(lane.kind), size: 18, color: lane.hidden ? DanaviewColors.textMuted : DanaviewColors.textPrimary),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          lane.displayName,
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: DanaviewFonts.family,
                            fontSize: 12,
                            height: 1.2,
                            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                            color: lane.hidden ? DanaviewColors.textMuted : DanaviewColors.textPrimary,
                          ),
                        ),
                      ),
                      if (plan.glyphs.isNotEmpty) ...[
                        const SizedBox(width: 2),
                        _Glyphs(flags: plan.glyphs, size: 12),
                      ],
                    ],
                  ),
                ),
              ),
            )),
          ),
          for (final flag in plan.inline)
            TrackToggle(
              key: ValueKey(flag),
              lane: lane,
              flag: flag,
              slot: plan.toggleSlot,
              onTap: enabled ? () => actions.toggle(lane, flag) : null,
            ),
        ],
      ),
    );
  }
}

/// Small status glyphs of the flags that are on.
class _Glyphs extends StatelessWidget {
  const _Glyphs({required this.flags, required this.size});

  final List<TrackFlag> flags;
  final double size;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [for (final f in flags) _glyph(f)],
      ),
    );
  }

  Widget _glyph(TrackFlag f) {
    const color = DanaviewColors.primaryLight;
    return switch (f) {
      TrackFlag.lock => Icon(Icons.lock_rounded, size: size, color: color),
      TrackFlag.hidden => Icon(Icons.visibility_off_rounded, size: size, color: color),
      TrackFlag.muted => Icon(Icons.volume_off_rounded, size: size, color: color),
      TrackFlag.solo => SizedBox(
          width: size,
          child: Text(
            TrackStrings.soloGlyph,
            textAlign: TextAlign.center,
            maxLines: 1,
            softWrap: false,
            style: TextStyle(fontFamily: DanaviewFonts.family, fontSize: size, height: 1, fontWeight: FontWeight.w700, color: color),
          ),
        ),
    };
  }
}

/// One header toggle: a round 26 px button in a [slot]-wide, lane-high hit area.
class TrackToggle extends StatelessWidget {
  /// Creates the toggle of [flag] for [lane].
  const TrackToggle({super.key, required this.lane, required this.flag, required this.slot, required this.onTap});

  /// The lane.
  final LaneModel lane;

  /// The flag.
  final TrackFlag flag;

  /// The width of the hit area.
  final double slot;

  /// Flips the flag; null disables the toggle.
  final VoidCallback? onTap;

  /// Diameter of the drawn button.
  static const double diameter = 26;

  @override
  Widget build(BuildContext context) {
    final name = lane.displayName;
    final on = TrackFlags.isOn(lane, flag);
    // The visibility toggle reads "shown" when on; the others read "locked", "muted", "solo".
    final toggled = flag == TrackFlag.hidden ? !on : on;
    final label = switch (flag) {
      TrackFlag.lock => TrackStrings.lockToggle(name),
      TrackFlag.hidden => TrackStrings.visibleToggle(name),
      TrackFlag.muted => TrackStrings.muteToggle(name),
      TrackFlag.solo => TrackStrings.soloToggle(name),
    };
    final tooltip = switch (flag) {
      TrackFlag.lock => TrackStrings.lockTooltip(on),
      TrackFlag.hidden => TrackStrings.visibleTooltip(!on),
      TrackFlag.muted => TrackStrings.muteTooltip(on),
      TrackFlag.solo => TrackStrings.soloTooltip(on),
    };
    final highlighted = on; // the flag's active state drives the fill
    final fg = highlighted ? DanaviewColors.primaryLight : DanaviewColors.textSecondary;
    return ExpandedHitArea(child: DanaviewPressable.builder(
      onTap: onTap,
      enabled: onTap != null,
      toggled: toggled,
      semanticLabel: label,
      tooltip: tooltip,
      builder: (context, state) => SizedBox(
        width: slot,
        height: double.infinity,
        child: Center(
          child: AnimatedContainer(
            duration: DanaviewMotion.fast,
            curve: DanaviewMotion.curve,
            width: diameter,
            height: diameter,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: highlighted
                  ? DanaviewColors.primaryTonal
                  : (state.hovered || state.pressed)
                      ? DanaviewColors.hover
                      : const Color(0x00FFFFFF),
              border: Border.fromBorderSide(state.focused ? DanaviewBorders.focus : DanaviewBorders.focus.copyWith(color: const Color(0x00000000))),
            ),
            child: ExcludeSemantics(child: _icon(on, fg)),
          ),
        ),
      ),
    ));
  }

  Widget _icon(bool on, Color color) => switch (flag) {
        TrackFlag.lock => Icon(on ? Icons.lock_rounded : Icons.lock_open_rounded, size: 16, color: color),
        TrackFlag.hidden => Icon(on ? Icons.visibility_off_rounded : Icons.visibility_rounded, size: 16, color: color),
        TrackFlag.muted => Icon(on ? Icons.volume_off_rounded : Icons.volume_up_rounded, size: 16, color: color),
        TrackFlag.solo => Icon(Icons.headphones_rounded, size: 16, color: color),
      };
}

/// [TrackHeaders] wired to the open project: snapshot, viewport, selection and the controller.
class ProjectTrackHeaders extends ConsumerWidget {
  /// Creates the headers of project [projectId].
  const ProjectTrackHeaders({super.key, required this.projectId});

  /// The open project.
  final ProjectId projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(timelineSnapshotProvider(projectId));
    final viewport = ref.watch(viewportProvider(projectId));
    final modes = ref.watch(editorControllerProvider(projectId).select((s) => s.modes));
    final selectedLane = ref.watch(editorControllerProvider(projectId).select((s) => s.selection.lane));
    final controller = ref.read(editorControllerProvider(projectId).notifier);
    final layout = EditorLayoutScope.maybeOf(context);
    final platform = Theme.of(context).platform;
    final touch = layout?.touch ?? (platform == TargetPlatform.iOS || platform == TargetPlatform.android || platform == TargetPlatform.fuchsia);
    final metrics = TimelineMetrics.resolve(
      textScaler: MediaQuery.textScalerOf(context),
      kind: layout?.kind ?? EditorLayoutKind.compactPortrait,
      touch: touch,
      laneHeight: modes.laneHeight,
    );
    return TrackHeaders(
      snapshot: snapshot,
      viewport: viewport,
      metrics: metrics,
      actions: TrackActions.of(controller),
      selectedLane: selectedLane,
      enabled: !controller.readOnly,
      onOpenMenu: (lane) => TrackMenuSheet.show(context, projectId: projectId, track: lane.id),
    );
  }
}
