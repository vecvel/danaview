// OWNER: UX-31
//
// The captions panel (ux.md §10.9) for one subtitle track, optionally focused on one cue.
//
// * Start state (no subtitle track, or the route's track is gone): "Add subtitle track"
//   (CORE-17 `AddTrack`), the existing subtitle tracks, and the Auto captions / Import actions
//   (UX-37 / UX-32 bind them; unbound ones are disabled).
// * Header: the track name and caption count, Add (CORE-15 `AddCue` at the playhead, 2 s), the
//   track menu and the Captions / Style / Position switcher (the route's section).
// * Track menu: the other subtitle tracks, Add subtitle track, Auto captions, Import, Export,
//   "Shift all captions…" (a timecode entry read with `Timecode.parse`, e.g. +2.5s or -10f;
//   one `ShiftCues` for the whole track, or for the selected range when two or more cues of the
//   track are selected; one history entry), "Select all on this lane" (only this track's cues),
//   Burn into video (`SetBurnIn`) and Delete track (confirmed when it has cues).
// * Cue list: a lazily built sliver list (3,000 cues scroll within the frame budget); a row is
//   `start – end` (tabular timecode) above the text (max 3 lines). The cue under the playhead is
//   highlighted (one listener for the whole list; rows rebuild only when the current cue changes)
//   and kept in view while playing. Tapping a row focuses it (the route's cue), selects it and
//   moves the playhead to its start.
// * The focused row expands: the text field (Return inserts a line break, Done commits one
//   `SetCueText`; leaving the field commits too), Start and End fields in timecode with ±1 frame
//   steppers, ±0.1 s buttons and "To playhead" (`SetCueRange`), and Split (`SplitCue` at the
//   playhead, the text split at the cursor when it is placed inside the text), Merge with next
//   (`MergeCues`), Delete (`DeleteCues`) and Go to start.
// * Style (track-wide, `SetSubtitleStyle`): font, size, bold, italic, colour, background box
//   (colour, opacity), outline (colour, width), shadow (colour, blur), lines per caption (1–3),
//   line width and alignment; then the track's language tag (`SetSubtitleLanguage`) and Burn
//   into video. Slider and colour gestures are one history entry each (InspectorEditSession).
// * Position (track-wide, `SetSubtitlePosition`): Bottom / Top / Custom; Custom shows the vertical
//   position slider (the on-preview drag is UX-22's manipulation overlay).
// * A locked track shows a notice and disables every control that edits.
// * Moving and trimming cues on the timeline (with overlap rejections shown) is UX-13's.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter/services.dart' show TextInputAction, TextInputType;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart'
    show
        AddCue,
        AddTrack,
        DeleteCues,
        DeleteTrack,
        EditCommand,
        MergeCues,
        SetBurnIn,
        SetCueRange,
        SetCueText,
        SetSubtitleLanguage,
        SetSubtitlePosition,
        SetSubtitleStyle,
        ShiftCues,
        SplitCue,
        SubtitleNoticeCodes;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../app/editor_providers.dart';
import '../../app/strings/subtitle_strings.dart';
import '../actions/editor_action_registry.dart';
import '../contracts/contracts.dart';
import '../editor_scope.dart';
import '../inspector/inspector_rows.dart';
import '../state/editor_controller.dart';
import '../state/editor_state.dart' show EditorSelection;
import '../text/font_catalog.dart';
import 'font_picker.dart';
import 'transform_panel.dart' show PanelNotice;

// -------------------------------------------------------------------------------------------------
// Model
// -------------------------------------------------------------------------------------------------

/// The arithmetic and lookups of the captions panel (pure; unit-tested).
abstract final class SubtitlesPanelModel {
  /// The subtitle tracks of [project], topmost first.
  static List<Track> subtitleTracks(EditProject project) =>
      [for (final t in project.tracks.reversed) if (t.kind == TrackKind.subtitle) t];

  /// The subtitle track [id] of [project], or null.
  static Track? trackOf(EditProject project, TrackId? id) {
    if (id == null) return null;
    final at = project.index.trackIndexOf(id);
    if (at == null) return null;
    final t = project.tracks[at];
    return t.kind == TrackKind.subtitle ? t : null;
  }

  /// The track [route] shows: its track, else the track of its cue; null when neither exists.
  static Track? trackFor(EditProject project, SubtitlesInspector route) {
    final direct = trackOf(project, route.track);
    if (direct != null) return direct;
    final cue = route.cue;
    if (cue == null) return null;
    final loc = project.index.locate(cue);
    return loc == null ? null : trackOf(project, loc.track.id);
  }

  /// The shown name of [track] in [project] (its name, else "Subtitles N" by position).
  static String nameOf(EditProject project, Track track) {
    if (track.name.trim().isNotEmpty) return track.name.trim();
    var ordinal = 0;
    for (final t in project.tracks) {
      if (t.kind != TrackKind.subtitle) continue;
      ordinal++;
      if (t.id == track.id) break;
    }
    return SubtitleStrings.laneName(ordinal);
  }

  /// The cues of [track] (sorted by start).
  static List<SubtitleCue> cuesOf(Track track) => [for (final i in track.items) if (i is SubtitleCue) i];

  /// The index of the cue of [cues] (sorted, disjoint) that contains [t], or null.
  static int? indexAt(List<SubtitleCue> cues, TimeUs t) {
    var lo = 0;
    var hi = cues.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final c = cues[mid];
      if (t < c.start) {
        hi = mid - 1;
      } else if (t >= c.end) {
        lo = mid + 1;
      } else {
        return mid;
      }
    }
    return null;
  }

  /// The index of [cue] in [cues], or -1.
  static int indexOf(List<SubtitleCue> cues, ItemId cue) {
    for (var i = 0; i < cues.length; i++) {
      if (cues[i].id == cue) return i;
    }
    return -1;
  }

  /// A frame far from 0, so relative entries never stop at the project start while parsing.
  static const int _shiftBaseFrame = 100000000;

  /// The shift typed as [input] on [rate] (`+2.5s`, `-10f`, `2s`, `-0.5 s`), quantized to whole
  /// frames; null when it is not a time. A missing sign means later.
  static TimeUs? shiftDelta(String input, FrameRate rate) {
    var s = input.trim().replaceAll(' ', '').replaceAll('−', '-');
    if (s.isEmpty) return null;
    if (!s.startsWith('+') && !s.startsWith('-')) s = '+$s';
    final base = rate.timeOfFrame(_shiftBaseFrame);
    final t = Timecode.parse(s, rate, base: base);
    if (t == null) return null;
    return t - base;
  }

  /// "+2.50 s" for [delta].
  static String formatDelta(TimeUs delta) {
    final seconds = delta / microsPerSecond;
    return '${seconds >= 0 ? '+' : '−'}${seconds.abs().toStringAsFixed(2)} s';
  }

  /// The range "Shift" applies to on [track] for [selection]: the span of the selected cues of the
  /// track when there are two or more, else null (the whole track).
  static TimeRange? selectedRange(Track track, EditorSelection selection) {
    if (selection.items.length < 2) return null;
    TimeUs? start;
    TimeUs? end;
    var n = 0;
    for (final c in track.items) {
      if (!selection.items.contains(c.id)) continue;
      n++;
      start ??= c.start;
      end = c.end;
    }
    if (n < 2 || start == null || end == null || end <= start) return null;
    return TimeRange(start, end);
  }

  /// How many cues of [track] start inside [range] (all when null).
  static int cuesIn(Track track, TimeRange? range) =>
      range == null ? track.items.length : track.items.where((c) => c.start >= range.start && c.start < range.end).length;

  /// The timeline text of [t] on [rate].
  static String timecode(TimeUs t, FrameRate rate) => Timecode.format(t, rate);

  /// The row timing line of [cue].
  static String timing(SubtitleCue cue, FrameRate rate) => SubtitleStrings.timing(timecode(cue.start, rate), timecode(cue.end, rate));

  /// The UTF-16 index the text splits at for a [selection] in [text]: the cursor when it is
  /// collapsed strictly inside the text, else null (the word boundary nearest the middle).
  static int? textSplitOf(String text, TextSelection selection) {
    if (!selection.isValid || !selection.isCollapsed) return null;
    final o = selection.baseOffset;
    return o > 0 && o < text.length ? o : null;
  }

  /// The ARGB of [c] made opaque.
  static int argb(Color c) => c.toARGB32() | 0xFF000000;

  /// The alignment glyph.
  static IconData alignIcon(TextAlignH a) => switch (a) {
        TextAlignH.left => Icons.format_align_left_rounded,
        TextAlignH.center => Icons.format_align_center_rounded,
        TextAlignH.right => Icons.format_align_right_rounded,
      };

  /// The default custom position (where Bottom sits).
  static const double defaultCustomY = 0.85;
}

/// The keys of the panel's controls (tests and semantics).
abstract final class SubtitlesPanelKeys {
  /// The scroll view.
  static const ValueKey<String> scroll = ValueKey<String>('subtitles.scroll');

  /// The empty/start state.
  static const ValueKey<String> start = ValueKey<String>('subtitles.start');

  /// "Add subtitle track".
  static const ValueKey<String> addTrack = ValueKey<String>('subtitles.addTrack');

  /// Add (cue at the playhead).
  static const ValueKey<String> add = ValueKey<String>('subtitles.add');

  /// The track menu button.
  static const ValueKey<String> menu = ValueKey<String>('subtitles.menu');

  /// The section switcher.
  static const ValueKey<String> sections = ValueKey<String>('subtitles.sections');

  /// The locked notice.
  static const ValueKey<String> locked = ValueKey<String>('subtitles.locked');

  /// The row of [cue].
  static ValueKey<String> row(ItemId cue) => ValueKey<String>('subtitles.cue.$cue');

  /// The expanded editor of the focused cue.
  static const ValueKey<String> editor = ValueKey<String>('subtitles.editor');

  /// The text field.
  static const ValueKey<String> text = ValueKey<String>('subtitles.text');

  /// Done.
  static const ValueKey<String> done = ValueKey<String>('subtitles.done');

  /// Start / end field of [edge] ('start' | 'end').
  static ValueKey<String> field(String edge) => ValueKey<String>('subtitles.$edge');

  /// −0.1 s of [edge].
  static ValueKey<String> minus100(String edge) => ValueKey<String>('subtitles.$edge.minus100');

  /// +0.1 s of [edge].
  static ValueKey<String> plus100(String edge) => ValueKey<String>('subtitles.$edge.plus100');

  /// "To playhead" of [edge].
  static ValueKey<String> toPlayhead(String edge) => ValueKey<String>('subtitles.$edge.playhead');

  /// Split.
  static const ValueKey<String> split = ValueKey<String>('subtitles.split');

  /// Merge with next.
  static const ValueKey<String> merge = ValueKey<String>('subtitles.merge');

  /// Delete.
  static const ValueKey<String> delete = ValueKey<String>('subtitles.delete');

  /// Go to start.
  static const ValueKey<String> jump = ValueKey<String>('subtitles.jump');

  /// A style or position control by [name].
  static ValueKey<String> style(String name) => ValueKey<String>('subtitles.style.$name');
}

// -------------------------------------------------------------------------------------------------
// Panel
// -------------------------------------------------------------------------------------------------

/// The captions panel (ux.md §10.9).
class SubtitlesPanel extends ConsumerStatefulWidget {
  /// Creates the panel.
  const SubtitlesPanel({super.key, required this.route});

  /// What the panel edits.
  final SubtitlesInspector route;

  @override
  ConsumerState<SubtitlesPanel> createState() => _SubtitlesPanelState();
}

class _SubtitlesPanelState extends ConsumerState<SubtitlesPanel> {
  final ScrollController _scroll = ScrollController();

  /// The index of the cue under the playhead in [_cues].
  final ValueNotifier<int?> _current = ValueNotifier<int?>(null);

  /// The built rows by index (for revealing one).
  final Map<int, BuildContext> _rows = {};

  ValueListenable<TimeUs>? _playhead;
  ValueListenable<bool>? _playing;
  List<SubtitleCue> _cues = const [];
  ItemId? _revealed;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final id = EditorScope.idOf(context);
    final playhead = ref.read(playheadProvider(id));
    if (!identical(playhead, _playhead)) {
      _playhead?.removeListener(_onPlayhead);
      _playhead = playhead..addListener(_onPlayhead);
      _playing = playhead.playing;
    }
  }

  @override
  void dispose() {
    _playhead?.removeListener(_onPlayhead);
    _scroll.dispose();
    _current.dispose();
    super.dispose();
  }

  EditorController get _editor => ref.read(editorControllerProvider(EditorScope.idOf(context)).notifier);

  // ---- Playhead -------------------------------------------------------------------------------

  void _onPlayhead() {
    final playhead = _playhead;
    if (playhead == null) return;
    final index = SubtitlesPanelModel.indexAt(_cues, playhead.value);
    if (index == _current.value) return;
    _current.value = index;
    if (index != null && (_playing?.value ?? false)) _reveal(index);
  }

  /// Scrolls the row [index] into view (estimating the offset when it is not built).
  void _reveal(int index, {double alignment = 0.3}) {
    if (!_scroll.hasClients) return;
    final ctx = _rows[index];
    if (ctx != null && ctx.mounted) {
      final box = ctx.findRenderObject();
      if (box is RenderBox && box.hasSize && _isVisible(box)) return;
      Scrollable.ensureVisible(ctx, alignment: alignment);
      return;
    }
    if (_rows.isEmpty) return;
    final built = _rows.keys.toList()..sort();
    var extent = 0.0;
    var counted = 0;
    double? firstOffset;
    for (final i in built) {
      final box = _rows[i]?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) continue;
      extent += box.size.height;
      counted++;
      if (firstOffset == null) {
        final viewport = RenderAbstractViewport.maybeOf(box);
        firstOffset = viewport?.getOffsetToReveal(box, 0).offset;
      }
    }
    if (counted == 0 || firstOffset == null) return;
    final average = extent / counted;
    final target = firstOffset + (index - built.first) * average - _scroll.position.viewportDimension * alignment;
    _scroll.jumpTo(target.clamp(_scroll.position.minScrollExtent, _scroll.position.maxScrollExtent));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final c = _rows[index];
      if (mounted && c != null && c.mounted) Scrollable.ensureVisible(c, alignment: alignment);
    });
  }

  bool _isVisible(RenderBox box) {
    final viewport = RenderAbstractViewport.maybeOf(box);
    if (viewport == null || !_scroll.hasClients) return false;
    final top = viewport.getOffsetToReveal(box, 0).offset;
    final p = _scroll.position;
    return top >= p.pixels && top + box.size.height <= p.pixels + p.viewportDimension;
  }

  // ---- Route ----------------------------------------------------------------------------------

  void _openRoute(SubtitlesInspector route) => _editor.openInspector(route);

  /// Drops the route's cue so selection changes and deletes keep the panel open.
  void _unfocus(Track track) {
    final r = widget.route;
    if (r.cue == null && r.track == track.id) return;
    _openRoute(SubtitlesInspector(track: track.id, section: r.section));
  }

  void _focusCue(Track track, SubtitleCue cue, {bool seek = true}) {
    final editor = _editor;
    editor
      ..openInspector(SubtitlesInspector(track: track.id, cue: cue.id, section: SubtitlesPanelSection.cues))
      ..select(cue.id);
    if (seek) ref.read(playheadProvider(EditorScope.idOf(context))).seekExact(cue.start);
  }

  EditResult _apply(EditCommand command, {String? coalesceKey}) => _editor.apply(command, coalesceKey: coalesceKey);

  void _toast(String message, {IconData icon = Icons.check_circle_outline_rounded}) {
    if (mounted) DanaviewToast.show(context, message, icon: icon);
  }

  // ---- Header actions -------------------------------------------------------------------------

  void _addCue(Track track) {
    final t = ref.read(playheadProvider(EditorScope.idOf(context))).value;
    final result = _apply(AddCue(t, SubtitleStrings.newCueText, track: track.id));
    if (result is! EditApplied) return;
    final project = ref.read(editorControllerProvider(EditorScope.idOf(context))).project;
    final cue = result.affected.isEmpty ? null : result.affected.first;
    final loc = cue == null ? null : project?.index.locate(cue);
    if (loc == null || loc.item is! SubtitleCue) return;
    _focusCue(track, loc.item as SubtitleCue, seek: false);
  }

  void _addTrack() {
    final before = {for (final t in ref.read(editorControllerProvider(EditorScope.idOf(context))).project?.tracks ?? const <Track>[]) t.id};
    final result = _apply(const AddTrack(TrackKind.subtitle));
    if (result is! EditApplied) return;
    final project = ref.read(editorControllerProvider(EditorScope.idOf(context))).project;
    if (project == null) return;
    for (final t in project.tracks) {
      if (t.kind == TrackKind.subtitle && !before.contains(t.id)) {
        _openRoute(SubtitlesInspector(track: t.id));
        return;
      }
    }
  }

  Future<void> _shift(EditProject project, Track track) async {
    final selection = ref.read(editorControllerProvider(EditorScope.idOf(context))).selection;
    final range = SubtitlesPanelModel.selectedRange(track, selection);
    final rate = project.settings.frameRate;
    final count = SubtitlesPanelModel.cuesIn(track, range);
    final input = await showDanaviewPrompt(
      context,
      title: SubtitleStrings.shiftTitle,
      message: range == null ? SubtitleStrings.shiftAllMessage(count) : SubtitleStrings.shiftRangeMessage(count),
      hint: SubtitleStrings.shiftHint,
      confirmLabel: SubtitleStrings.shiftConfirm,
      cancelLabel: SubtitleStrings.cancel,
      validator: (v) {
        final d = SubtitlesPanelModel.shiftDelta(v, rate);
        if (d == null) return SubtitleStrings.shiftInvalid;
        if (d == 0) return SubtitleStrings.shiftZero;
        return null;
      },
    );
    if (input == null || !mounted) return;
    final delta = SubtitlesPanelModel.shiftDelta(input, rate);
    if (delta == null || delta == 0) return;
    final result = _apply(ShiftCues(track.id, delta, range: range));
    if (result is! EditApplied) return;
    final clamped = result.notices.any((n) => n.code == SubtitleNoticeCodes.shiftClampedAtZero);
    _toast(clamped ? SubtitleStrings.shiftClamped : SubtitleStrings.shifted(SubtitlesPanelModel.formatDelta(delta)));
  }

  void _selectAll(Track track) {
    _unfocus(track);
    _editor.selectAll(lane: track.id);
  }

  Future<void> _deleteTrack(EditProject project, Track track) async {
    final n = track.items.length;
    if (n > 0) {
      final ok = await showDanaviewConfirm(
        context,
        title: SubtitleStrings.deleteTitle(SubtitlesPanelModel.nameOf(project, track)),
        message: SubtitleStrings.deleteMessage(n),
        confirmLabel: SubtitleStrings.deleteConfirm,
        cancelLabel: SubtitleStrings.cancel,
        destructive: true,
      );
      if (!ok || !mounted) return;
    }
    _unfocus(track);
    final result = _apply(DeleteTrack(track.id));
    if (result is EditApplied && mounted) _openRoute(const SubtitlesInspector());
  }

  /// Runs a registry action (Auto captions, Import, Export) with [track]'s lane selected.
  void _runAction(EditorActionId action, Track? track) {
    final id = EditorScope.idOf(context);
    if (track != null) {
      _unfocus(track);
      _editor.selectAt(track.id, -1);
    }
    ref.read(editorActionRegistryProvider).invoke(action, WidgetActionContext(projectId: id, context: context, ref: ref));
  }

  bool _actionEnabled(EditorActionId action) {
    final id = EditorScope.idOf(context);
    final spec = ref.read(editorActionRegistryProvider).spec(action);
    final ctx = WidgetActionContext(projectId: id, context: context, ref: ref);
    return spec.isBound && spec.isVisible(ctx) && spec.isEnabled(ctx);
  }

  // ---- Build ----------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final id = EditorScope.idOf(context);
    final project = ref.watch(editorControllerProvider(id).select((s) => s.project));
    final canEdit = ref.watch(editorControllerProvider(id).select((s) => s.isReady)) && _editor.canEdit;
    if (project == null) return const SizedBox.shrink();
    final route = widget.route;
    final track = SubtitlesPanelModel.trackFor(project, route);
    if (track == null) {
      _cues = const [];
      _current.value = null;
      return _StartState(
        tracks: SubtitlesPanelModel.subtitleTracks(project),
        nameOf: (t) => SubtitlesPanelModel.nameOf(project, t),
        gone: route.track != null,
        canEdit: canEdit,
        autoCaptions: _actionEnabled(EditorActionId.autoCaptions) ? () => _runAction(EditorActionId.autoCaptions, null) : null,
        importFile: _actionEnabled(EditorActionId.importSubtitles) ? () => _runAction(EditorActionId.importSubtitles, null) : null,
        onAddTrack: _addTrack,
        onOpen: (t) => _openRoute(SubtitlesInspector(track: t.id)),
      );
    }
    final cues = SubtitlesPanelModel.cuesOf(track);
    if (!identical(cues, _cues)) {
      _cues = cues;
      final playhead = _playhead;
      _current.value = playhead == null ? null : SubtitlesPanelModel.indexAt(cues, playhead.value);
    }
    final ready = canEdit && !track.locked;
    final rate = project.settings.frameRate;
    final focused = route.cue;
    if (focused != null && focused != _revealed) {
      _revealed = focused;
      final index = SubtitlesPanelModel.indexOf(cues, focused);
      if (index >= 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _reveal(index, alignment: 0.1);
        });
      }
    } else if (focused == null) {
      _revealed = null;
    }

    final header = _header(project, track, cues.length, ready, canEdit);
    final section = route.section;
    return CustomScrollView(
      key: SubtitlesPanelKeys.scroll,
      controller: _scroll,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(DanaviewSpacing.lg, DanaviewSpacing.sm, DanaviewSpacing.lg, DanaviewSpacing.sm),
          sliver: SliverToBoxAdapter(child: header),
        ),
        if (section == SubtitlesPanelSection.cues)
          if (cues.isEmpty)
            const SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: DanaviewSpacing.lg),
              sliver: SliverToBoxAdapter(child: PanelNotice(SubtitleStrings.noCues, color: DanaviewColors.textSecondary)),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(DanaviewSpacing.sm, 0, DanaviewSpacing.sm, DanaviewSpacing.lg),
              sliver: SliverList.builder(
                itemCount: cues.length,
                itemBuilder: (context, i) {
                  final cue = cues[i];
                  return _CueRow(
                    key: SubtitlesPanelKeys.row(cue.id),
                    index: i,
                    cue: cue,
                    next: i + 1 < cues.length ? cues[i + 1] : null,
                    rate: rate,
                    current: _current,
                    expanded: cue.id == focused,
                    ready: ready,
                    rows: _rows,
                    onTap: () => _focusCue(track, cue),
                    onDeleting: () => _unfocus(track),
                  );
                },
              ),
            )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(DanaviewSpacing.lg, 0, DanaviewSpacing.lg, DanaviewSpacing.lg),
            sliver: SliverToBoxAdapter(
              child: section == SubtitlesPanelSection.style
                  ? _StyleSection(track: track, ready: ready, canEdit: canEdit)
                  : _PositionSection(track: track, ready: ready),
            ),
          ),
      ],
    );
  }

  Widget _header(EditProject project, Track track, int count, bool ready, bool canEdit) {
    final name = SubtitlesPanelModel.nameOf(project, track);
    final route = widget.route;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: DanaviewTextStyles.headline.copyWith(fontFamily: DanaviewFonts.family, color: DanaviewColors.textPrimary),
                  ),
                  Text(
                    SubtitleStrings.cueCount(count),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: DanaviewTextStyles.caption.copyWith(fontFamily: DanaviewFonts.family, color: DanaviewColors.textSecondary),
                  ),
                ],
              ),
            ),
            const SizedBox(width: DanaviewSpacing.sm),
            DanaviewButton.primary(
              key: SubtitlesPanelKeys.add,
              label: SubtitleStrings.add,
              icon: Icons.add_rounded,
              size: DanaviewButtonSize.sm,
              semanticLabel: SubtitleStrings.addSemantics,
              onPressed: ready ? () => _addCue(track) : null,
            ),
            const SizedBox(width: DanaviewSpacing.xs),
            _menu(project, track, ready, canEdit),
          ],
        ),
        if (track.locked) ...[
          const SizedBox(height: DanaviewSpacing.sm),
          const PanelNotice(SubtitleStrings.locked, key: SubtitlesPanelKeys.locked),
        ],
        const SizedBox(height: DanaviewSpacing.sm),
        Semantics(
          container: true,
          label: SubtitleStrings.sections,
          child: DanaviewSegmentedControl<SubtitlesPanelSection>(
            key: SubtitlesPanelKeys.sections,
            value: route.section,
            options: [
              for (final s in SubtitlesPanelSection.values) DanaviewOption<SubtitlesPanelSection>(value: s, label: SubtitleStrings.section(s)),
            ],
            onChanged: (s) {
              if (s == route.section) return;
              _openRoute(SubtitlesInspector(track: track.id, cue: route.cue, section: s));
            },
          ),
        ),
      ],
    );
  }

  Widget _menu(EditProject project, Track track, bool ready, bool canEdit) {
    final others = [for (final t in SubtitlesPanelModel.subtitleTracks(project)) if (t.id != track.id) t];
    final burnIn = track.subtitle?.burnIn ?? true;
    final selection = ref.read(editorControllerProvider(EditorScope.idOf(context))).selection;
    final range = SubtitlesPanelModel.selectedRange(track, selection);
    final entries = <DanaviewMenuEntry>[
      if (others.isNotEmpty) ...[
        const DanaviewMenuHeader(SubtitleStrings.showTrack),
        for (final t in others)
          DanaviewMenuItem(
            label: SubtitlesPanelModel.nameOf(project, t),
            icon: Icons.closed_caption_outlined,
            onTap: () => _openRoute(SubtitlesInspector(track: t.id, section: widget.route.section)),
          ),
        const DanaviewMenuDivider(),
      ],
      DanaviewMenuItem(label: SubtitleStrings.addTrack, icon: Icons.playlist_add_rounded, enabled: canEdit, onTap: _addTrack),
      _actionItem(EditorActionId.autoCaptions, SubtitleStrings.autoCaptions, Icons.auto_awesome_rounded, track),
      _actionItem(EditorActionId.importSubtitles, SubtitleStrings.importFile, Icons.file_download_outlined, track),
      _actionItem(EditorActionId.exportSubtitles, SubtitleStrings.exportFile, Icons.ios_share_rounded, track),
      const DanaviewMenuDivider(),
      DanaviewMenuItem(
        label: range == null ? SubtitleStrings.shiftAll : SubtitleStrings.shiftSelected,
        icon: Icons.swap_horiz_rounded,
        enabled: ready && track.items.isNotEmpty,
        onTap: () => _shift(project, track),
      ),
      DanaviewMenuItem(
        label: SubtitleStrings.selectAll,
        icon: Icons.select_all_rounded,
        enabled: !track.locked && track.items.isNotEmpty,
        onTap: () => _selectAll(track),
      ),
      DanaviewMenuItem(
        label: SubtitleStrings.burnIn,
        icon: Icons.local_fire_department_outlined,
        selected: burnIn,
        trailing: burnIn ? const Icon(Icons.check_rounded, size: 18, color: DanaviewColors.primaryLight) : null,
        enabled: ready,
        onTap: () => _apply(SetBurnIn(track.id, !burnIn)),
      ),
      const DanaviewMenuDivider(),
      DanaviewMenuItem(
        label: SubtitleStrings.deleteTrack,
        icon: Icons.delete_outline_rounded,
        destructive: true,
        enabled: ready,
        onTap: () => _deleteTrack(project, track),
      ),
    ];
    return DanaviewMenuAnchor(
      key: SubtitlesPanelKeys.menu,
      width: 260,
      alignment: DanaviewMenuAlignment.end,
      entries: entries,
      builder: (context, open, isOpen) => DanaviewIconButton(
        icon: Icons.more_vert_rounded,
        semanticLabel: SubtitleStrings.menu,
        tooltip: SubtitleStrings.menu,
        selected: isOpen,
        onPressed: open,
      ),
    );
  }

  DanaviewMenuItem _actionItem(EditorActionId action, String label, IconData icon, Track track) {
    final enabled = _actionEnabled(action);
    return DanaviewMenuItem(
      label: label,
      icon: icon,
      enabled: enabled,
      subtitle: enabled ? null : SubtitleStrings.notAvailable,
      onTap: () => _runAction(action, track),
    );
  }
}

// -------------------------------------------------------------------------------------------------
// Start state
// -------------------------------------------------------------------------------------------------

class _StartState extends StatelessWidget {
  const _StartState({
    required this.tracks,
    required this.nameOf,
    required this.gone,
    required this.canEdit,
    required this.autoCaptions,
    required this.importFile,
    required this.onAddTrack,
    required this.onOpen,
  });

  final List<Track> tracks;
  final String Function(Track) nameOf;
  final bool gone;
  final bool canEdit;
  final VoidCallback? autoCaptions;
  final VoidCallback? importFile;
  final VoidCallback onAddTrack;
  final ValueChanged<Track> onOpen;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      key: SubtitlesPanelKeys.start,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(DanaviewSpacing.lg),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (gone) const PanelNotice(SubtitleStrings.trackGone),
                if (tracks.isEmpty) ...[
                  Text(
                    SubtitleStrings.emptyTitle,
                    style: DanaviewTextStyles.headline.copyWith(fontFamily: DanaviewFonts.family, color: DanaviewColors.textPrimary),
                  ),
                  const SizedBox(height: DanaviewSpacing.xs),
                  Text(
                    SubtitleStrings.emptyMessage,
                    style: DanaviewTextStyles.bodySecondary.copyWith(fontFamily: DanaviewFonts.family, color: DanaviewColors.textSecondary),
                  ),
                ] else ...[
                  Text(
                    SubtitleStrings.tracksHeading,
                    style: DanaviewTextStyles.caption.copyWith(fontFamily: DanaviewFonts.family, color: DanaviewColors.textSecondary),
                  ),
                  const SizedBox(height: DanaviewSpacing.xs),
                  for (final t in tracks)
                    DanaviewListTile(
                      key: ValueKey<String>('subtitles.track.${t.id}'),
                      leading: const Icon(Icons.closed_caption_outlined, color: DanaviewColors.textSecondary),
                      title: nameOf(t),
                      subtitle: SubtitleStrings.cueCount(t.items.length),
                      onTap: () => onOpen(t),
                    ),
                ],
                const SizedBox(height: DanaviewSpacing.md),
                Wrap(
                  spacing: DanaviewSpacing.sm,
                  runSpacing: DanaviewSpacing.sm,
                  children: [
                    DanaviewButton.primary(
                      key: SubtitlesPanelKeys.addTrack,
                      label: SubtitleStrings.addTrack,
                      icon: Icons.playlist_add_rounded,
                      onPressed: canEdit ? onAddTrack : null,
                    ),
                    if (autoCaptions != null)
                      DanaviewButton.secondary(label: SubtitleStrings.autoCaptions, icon: Icons.auto_awesome_rounded, onPressed: autoCaptions),
                    if (importFile != null)
                      DanaviewButton.secondary(label: SubtitleStrings.importFile, icon: Icons.file_download_outlined, onPressed: importFile),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// -------------------------------------------------------------------------------------------------
// Cue rows
// -------------------------------------------------------------------------------------------------

TextStyle get _timingStyle => DanaviewTextStyles.caption.copyWith(
      fontFamily: DanaviewFonts.family,
      color: DanaviewColors.textSecondary,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

TextStyle get _cueTextStyle => DanaviewTextStyles.body.copyWith(fontFamily: DanaviewFonts.family, color: DanaviewColors.textPrimary);

/// One cue of the list; the focused one expands into the editor.
class _CueRow extends StatefulWidget {
  const _CueRow({
    super.key,
    required this.index,
    required this.cue,
    required this.next,
    required this.rate,
    required this.current,
    required this.expanded,
    required this.ready,
    required this.rows,
    required this.onTap,
    required this.onDeleting,
  });

  final int index;
  final SubtitleCue cue;
  final SubtitleCue? next;
  final FrameRate rate;
  final ValueListenable<int?> current;
  final bool expanded;
  final bool ready;
  final Map<int, BuildContext> rows;
  final VoidCallback onTap;
  final VoidCallback onDeleting;

  @override
  State<_CueRow> createState() => _CueRowState();
}

class _CueRowState extends State<_CueRow> {
  @override
  void initState() {
    super.initState();
    widget.rows[widget.index] = context;
  }

  @override
  void didUpdateWidget(_CueRow old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index) {
      if (identical(old.rows[old.index], context)) old.rows.remove(old.index);
      widget.rows[widget.index] = context;
    }
  }

  @override
  void dispose() {
    if (identical(widget.rows[widget.index], context)) widget.rows.remove(widget.index);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cue = widget.cue;
    final timing = SubtitlesPanelModel.timing(cue, widget.rate);
    return ValueListenableBuilder<int?>(
      valueListenable: widget.current,
      builder: (context, current, _) {
        final isCurrent = current == widget.index;
        final background = widget.expanded
            ? DanaviewColors.surfaceElevated
            : isCurrent
                ? DanaviewColors.primarySoft
                : null;
        final summary = DanaviewPressable(
          onTap: widget.onTap,
          borderRadius: DanaviewRadius.smAll,
          selected: widget.expanded,
          semanticLabel: SubtitleStrings.rowLabel(
            SubtitlesPanelModel.timecode(cue.start, widget.rate),
            SubtitlesPanelModel.timecode(cue.end, widget.rate),
            cue.text,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: DanaviewSpacing.sm, vertical: DanaviewSpacing.xs + 2),
            child: ExcludeSemantics(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 3,
                    height: 16,
                    margin: const EdgeInsets.only(top: 2, right: DanaviewSpacing.sm),
                    decoration: BoxDecoration(
                      color: isCurrent ? DanaviewColors.primaryLight : DanaviewColors.hairline,
                      borderRadius: DanaviewRadius.xsAll,
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(timing, maxLines: 1, overflow: TextOverflow.ellipsis, style: _timingStyle),
                        const SizedBox(height: DanaviewSpacing.xxs),
                        Text(cue.text, maxLines: 3, overflow: TextOverflow.ellipsis, style: _cueTextStyle),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        return Semantics(
          value: isCurrent ? SubtitleStrings.current : null,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 1),
            decoration: BoxDecoration(color: background, borderRadius: DanaviewRadius.smAll),
            child: widget.expanded
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      summary,
                      _CueEditor(
                        key: SubtitlesPanelKeys.editor,
                        cue: cue,
                        next: widget.next,
                        rate: widget.rate,
                        ready: widget.ready,
                        onDeleting: widget.onDeleting,
                      ),
                    ],
                  )
                : summary,
          ),
        );
      },
    );
  }
}

/// The expanded editor of the focused cue: text, timing and row actions.
class _CueEditor extends ConsumerStatefulWidget {
  const _CueEditor({super.key, required this.cue, required this.next, required this.rate, required this.ready, required this.onDeleting});

  final SubtitleCue cue;
  final SubtitleCue? next;
  final FrameRate rate;
  final bool ready;
  final VoidCallback onDeleting;

  @override
  ConsumerState<_CueEditor> createState() => _CueEditorState();
}

class _CueEditorState extends ConsumerState<_CueEditor> {
  late final TextEditingController _text = TextEditingController(text: widget.cue.text);
  final FocusNode _focus = FocusNode(debugLabel: 'SubtitlesPanel.text');
  EditorController? _editorRef;
  String? _error;

  /// The cursor the user placed (kept when the field loses focus to the Split button).
  TextSelection _cursor = const TextSelection.collapsed(offset: -1);

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
    _text.addListener(_onText);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _editorRef = ref.read(editorControllerProvider(EditorScope.idOf(context)).notifier);
  }

  @override
  void didUpdateWidget(_CueEditor old) {
    super.didUpdateWidget(old);
    if (old.cue.id != widget.cue.id) {
      _commit(old.cue);
      _set(widget.cue.text);
    } else if (old.cue.text != widget.cue.text && !_focus.hasFocus) {
      _set(widget.cue.text);
    }
  }

  @override
  void dispose() {
    _commit(widget.cue);
    _focus.removeListener(_onFocus);
    _text.removeListener(_onText);
    _focus.dispose();
    _text.dispose();
    super.dispose();
  }

  void _set(String text) {
    _text.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
    _cursor = const TextSelection.collapsed(offset: -1);
    _error = null;
  }

  void _onText() {
    final s = _text.selection;
    if (_focus.hasFocus && s.isValid) _cursor = s;
    if (_error != null && _text.text.trim().isNotEmpty) setState(() => _error = null);
  }

  void _onFocus() {
    if (!_focus.hasFocus) _commit(widget.cue);
  }

  /// Commits the field's text to [cue] when it changed; false when the text is blank.
  bool _commit(SubtitleCue cue) {
    final editor = _editorRef;
    final text = _text.text;
    if (editor == null || !widget.ready || text == cue.text) return true;
    if (text.trim().isEmpty) {
      if (mounted) setState(() => _error = SubtitleStrings.emptyText);
      return false;
    }
    editor.apply(SetCueText(cue.id, text), coalesceKey: SetCueText.coalesceKey(cue.id));
    return true;
  }

  void _done() {
    if (_commit(widget.cue)) _focus.unfocus();
  }

  TimeUs get _playhead => ref.read(playheadProvider(EditorScope.idOf(context))).value;

  void _range(TimeUs start, TimeUs end) => _editorRef?.apply(SetCueRange(widget.cue.id, start, end));

  void _setEdge(String edge, TimeUs t) {
    final cue = widget.cue;
    if (edge == 'start') {
      _range(t, cue.end);
    } else {
      _range(cue.start, t);
    }
  }

  TimeUs _edge(String edge) => edge == 'start' ? widget.cue.start : widget.cue.end;

  void _split() {
    final cue = widget.cue;
    if (!_commit(cue)) return;
    final split = SubtitlesPanelModel.textSplitOf(_text.text, _cursor);
    _editorRef?.apply(SplitCue(cue.id, _playhead, textSplit: split));
  }

  void _merge() {
    final next = widget.next;
    if (next == null || !_commit(widget.cue)) return;
    _editorRef?.apply(MergeCues({widget.cue.id, next.id}));
  }

  void _delete() {
    final editor = _editorRef;
    if (editor == null) return;
    final id = widget.cue.id;
    _text.text = widget.cue.text; // nothing to commit for a deleted cue
    widget.onDeleting();
    editor.apply(DeleteCues({id}));
  }

  void _jump() => ref.read(playheadProvider(EditorScope.idOf(context))).seekExact(widget.cue.start);

  @override
  Widget build(BuildContext context) {
    final cue = widget.cue;
    final ready = widget.ready;
    final playhead = ref.watch(playheadProvider(EditorScope.idOf(context)));
    return Padding(
      padding: const EdgeInsets.fromLTRB(DanaviewSpacing.sm, 0, DanaviewSpacing.sm, DanaviewSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DanaviewTextField(
            key: SubtitlesPanelKeys.text,
            controller: _text,
            focusNode: _focus,
            hint: SubtitleStrings.textHint,
            semanticLabel: SubtitleStrings.textField,
            enabled: ready,
            showClearButton: false,
            errorText: _error,
            keyboardType: TextInputType.multiline,
            textInputAction: TextInputAction.newline,
            minLines: 1,
            maxLines: 4,
          ),
          const SizedBox(height: DanaviewSpacing.xs),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: DanaviewButton.secondary(
              key: SubtitlesPanelKeys.done,
              label: SubtitleStrings.done,
              size: DanaviewButtonSize.sm,
              onPressed: ready ? _done : null,
            ),
          ),
          _edgeRow('start', SubtitleStrings.start, ready),
          _edgeRow('end', SubtitleStrings.end, ready),
          const SizedBox(height: DanaviewSpacing.xs),
          ValueListenableBuilder<TimeUs>(
            valueListenable: playhead,
            builder: (context, t, _) {
              final canSplit = ready && cue.start < t && t < cue.end;
              return Wrap(
                spacing: DanaviewSpacing.sm,
                runSpacing: DanaviewSpacing.sm,
                children: [
                  DanaviewButton.secondary(
                    key: SubtitlesPanelKeys.split,
                    label: SubtitleStrings.split,
                    icon: Icons.content_cut_rounded,
                    size: DanaviewButtonSize.sm,
                    tooltip: canSplit ? null : SubtitleStrings.splitNeedsPlayhead,
                    onPressed: canSplit ? _split : null,
                  ),
                  DanaviewButton.secondary(
                    key: SubtitlesPanelKeys.merge,
                    label: SubtitleStrings.merge,
                    icon: Icons.merge_rounded,
                    size: DanaviewButtonSize.sm,
                    tooltip: widget.next == null ? SubtitleStrings.mergeNeedsNext : null,
                    onPressed: ready && widget.next != null ? _merge : null,
                  ),
                  DanaviewButton.secondary(
                    key: SubtitlesPanelKeys.jump,
                    label: SubtitleStrings.jump,
                    icon: Icons.first_page_rounded,
                    size: DanaviewButtonSize.sm,
                    onPressed: _jump,
                  ),
                  DanaviewButton.destructive(
                    key: SubtitlesPanelKeys.delete,
                    label: SubtitleStrings.delete,
                    icon: Icons.delete_outline_rounded,
                    size: DanaviewButtonSize.sm,
                    onPressed: ready ? _delete : null,
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _edgeRow(String edge, String label, bool ready) {
    final rate = widget.rate;
    final cue = widget.cue;
    final frame = rate.frameIndexOf(_edge(edge)).toDouble();
    final min = edge == 'start' ? 0.0 : rate.frameIndexOf(cue.start) + 1.0;
    final max = edge == 'start' ? rate.frameIndexOf(cue.end) - 1.0 : double.infinity;
    return Padding(
      padding: const EdgeInsets.only(top: DanaviewSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final fieldWidth = math.min(DanaviewNumberField.minWidthForSteppers + 30, constraints.maxWidth * 0.66);
              return Row(
                children: [
                  Expanded(
                    child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: _cueTextStyle),
                  ),
                  SizedBox(
                    width: fieldWidth,
                    child: DanaviewNumberField(
                      key: SubtitlesPanelKeys.field(edge),
                      value: frame,
                      min: min,
                      max: math.max(min, max),
                      step: 1,
                      fractionDigits: 0,
                      semanticLabel: label,
                      showSteppers: fieldWidth >= DanaviewNumberField.minWidthForSteppers,
                      enabled: ready,
                      formatter: (v) => SubtitlesPanelModel.timecode(rate.timeOfFrame(v.round()), rate),
                      parser: (s) {
                        final t = Timecode.parse(s, rate, base: _edge(edge));
                        return t == null ? null : rate.frameIndexOf(t).toDouble();
                      },
                      onChanged: ready
                          ? (v) {
                              final t = rate.timeOfFrame(v.round());
                              if (t != _edge(edge)) _setEdge(edge, t);
                            }
                          : null,
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: DanaviewSpacing.xs),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: DanaviewSpacing.xs,
            runSpacing: DanaviewSpacing.xs,
            children: [
              DanaviewButton.ghost(
                key: SubtitlesPanelKeys.minus100(edge),
                label: SubtitleStrings.minus100,
                size: DanaviewButtonSize.sm,
                semanticLabel: SubtitleStrings.minus100Semantics(label),
                onPressed: ready ? () => _setEdge(edge, _edge(edge) - 100000) : null,
              ),
              DanaviewButton.ghost(
                key: SubtitlesPanelKeys.plus100(edge),
                label: SubtitleStrings.plus100,
                size: DanaviewButtonSize.sm,
                semanticLabel: SubtitleStrings.plus100Semantics(label),
                onPressed: ready ? () => _setEdge(edge, _edge(edge) + 100000) : null,
              ),
              DanaviewButton.ghost(
                key: SubtitlesPanelKeys.toPlayhead(edge),
                label: SubtitleStrings.toPlayhead,
                icon: Icons.vertical_align_center_rounded,
                size: DanaviewButtonSize.sm,
                semanticLabel: SubtitleStrings.toPlayheadSemantics(label.toLowerCase()),
                onPressed: ready ? () => _setEdge(edge, _playhead) : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// -------------------------------------------------------------------------------------------------
// Style and position
// -------------------------------------------------------------------------------------------------

/// Slider and colour gestures of the track-wide sections (one history entry per gesture).
mixin _TrackEdits<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  final Map<String, InspectorEditSession> _sessions = {};
  final Map<String, double> _live = {};
  final Map<String, Color> _liveColors = {};

  TrackId get trackId;

  EditorController get editor => ref.read(editorControllerProvider(EditorScope.idOf(context)).notifier);

  @override
  void dispose() {
    for (final s in _sessions.values) {
      s.dispose();
    }
    super.dispose();
  }

  InspectorEditSession session(String key, String label) {
    final s = _sessions[key] ??= InspectorEditSession(editor: editor, label: label, coalesceKey: 'subtitle:$trackId:$key');
    s
      ..editor = editor
      ..coalesceKey = 'subtitle:$trackId:$key';
    return s;
  }

  Widget slider(
    String key, {
    required String label,
    required String history,
    required double value,
    required double min,
    required double max,
    required double step,
    required bool ready,
    required EditCommand Function(double v) command,
    double displayScale = 1,
    String unit = '',
    int? fractionDigits,
    double? defaultValue,
  }) {
    final s = session(key, history);
    double clamp(double v) => v.clamp(min, max).toDouble();
    return InspectorSliderRow(
      key: SubtitlesPanelKeys.style(key),
      label: label,
      value: _live[key] ?? clamp(value),
      min: min,
      max: max,
      step: step,
      displayScale: displayScale,
      unit: unit,
      fractionDigits: fractionDigits,
      defaultValue: defaultValue,
      enabled: ready,
      onChangeStart: (_) => s.start(),
      onChanged: (v) {
        setState(() => _live[key] = v);
        s.change(command(clamp(v)));
      },
      onChangeEnd: (_) {
        s.end();
        setState(() => _live.remove(key));
      },
      onSubmitted: (v) => s.apply(command(clamp(v))),
    );
  }

  Widget color(String key, {required String label, required String history, required int argb, required bool ready, required EditCommand Function(int c) command}) {
    final s = session(key, history);
    return InspectorColorRow(
      key: SubtitlesPanelKeys.style(key),
      label: label,
      color: _liveColors[key] ?? Color(argb | 0xFF000000),
      enabled: ready,
      onChangeStart: (_) => s.start(),
      onChanged: (c) {
        setState(() => _liveColors[key] = c);
        if (s.active) {
          s.change(command(SubtitlesPanelModel.argb(c)));
        } else {
          s.apply(command(SubtitlesPanelModel.argb(c)));
        }
      },
      onChangeEnd: (_) {
        s.end();
        setState(() => _liveColors.remove(key));
      },
    );
  }

  Widget toggle(String key, {required String label, required bool value, required bool ready, required EditCommand Function(bool v) command, String? subtitle}) =>
      KeyedSubtree(
        key: SubtitlesPanelKeys.style(key),
        child: InspectorToggleRow(label: label, subtitle: subtitle, value: value, onChanged: ready ? (v) => editor.apply(command(v)) : null),
      );
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: DanaviewSpacing.md, bottom: DanaviewSpacing.xs),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: DanaviewTextStyles.caption.copyWith(fontFamily: DanaviewFonts.family, color: DanaviewColors.textSecondary),
        ),
      );
}

/// The track-wide style (ux.md §10.9), the language tag and Burn into video.
class _StyleSection extends ConsumerStatefulWidget {
  const _StyleSection({required this.track, required this.ready, required this.canEdit});

  final Track track;
  final bool ready;
  final bool canEdit;

  @override
  ConsumerState<_StyleSection> createState() => _StyleSectionState();
}

class _StyleSectionState extends ConsumerState<_StyleSection> with _TrackEdits<_StyleSection> {
  final TextEditingController _language = TextEditingController();
  final FocusNode _languageFocus = FocusNode(debugLabel: 'SubtitlesPanel.language');
  bool _fonts = false;
  String? _languageError;

  @override
  TrackId get trackId => widget.track.id;

  SubtitleTrackData get _data => widget.track.subtitle ?? const SubtitleTrackData();

  @override
  void initState() {
    super.initState();
    _language.text = _data.language ?? '';
    _languageFocus.addListener(() {
      if (!_languageFocus.hasFocus) _commitLanguage();
    });
  }

  @override
  void didUpdateWidget(_StyleSection old) {
    super.didUpdateWidget(old);
    final language = _data.language ?? '';
    if (!_languageFocus.hasFocus && _language.text != language && (old.track.subtitle?.language ?? '') != language) {
      _language.text = language;
    } else if (old.track.id != widget.track.id) {
      _language.text = language;
      _languageError = null;
    }
  }

  @override
  void dispose() {
    _language.dispose();
    _languageFocus.dispose();
    super.dispose();
  }

  void _commitLanguage() {
    final text = _language.text.trim();
    if (text == (_data.language ?? '') || !widget.ready) return;
    final result = editor.apply(SetSubtitleLanguage(widget.track.id, text.isEmpty ? null : text));
    if (mounted) setState(() => _languageError = result is EditRejected ? SubtitleStrings.languageInvalid : null);
  }

  SetSubtitleStyle _style(SubtitleStyle Function(SubtitleStyle s) edit) => SetSubtitleStyle(widget.track.id, edit(_data.style));

  @override
  Widget build(BuildContext context) {
    final ready = widget.ready;
    final style = _data.style;
    final catalog = ref.watch(fontCatalogProvider);
    final box = style.background;
    final outline = style.outline;
    final shadow = style.shadow;
    const h = SubtitleStrings.historyStyle;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Font.
        Padding(
          padding: const EdgeInsets.symmetric(vertical: DanaviewSpacing.xs),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${SubtitleStrings.font}: ${catalog.displayName(style.fontFamily)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _cueTextStyle,
                ),
              ),
              DanaviewButton.ghost(
                key: SubtitlesPanelKeys.style('fontToggle'),
                label: _fonts ? SubtitleStrings.closeFonts : SubtitleStrings.changeFont,
                size: DanaviewButtonSize.sm,
                onPressed: () => setState(() => _fonts = !_fonts),
              ),
            ],
          ),
        ),
        if (_fonts)
          FontPicker(
            key: SubtitlesPanelKeys.style('fonts'),
            catalog: catalog,
            selectedId: catalog.familyFor(style.fontFamily).id,
            enabled: ready,
            onSelected: (fontId) {
              if (fontId != style.fontFamily) editor.apply(_style((s) => s.copyWith(fontFamily: fontId)));
            },
          ),
        slider('size',
            label: SubtitleStrings.size,
            history: h,
            value: style.fontSizePt,
            min: 8,
            max: 200,
            step: 1,
            unit: SubtitleStrings.pt,
            defaultValue: 42,
            ready: ready,
            command: (v) => _style((s) => s.copyWith(fontSizePt: v.roundToDouble()))),
        toggle('bold', label: SubtitleStrings.bold, value: style.bold, ready: ready, command: (v) => _style((s) => s.copyWith(bold: v))),
        toggle('italic', label: SubtitleStrings.italic, value: style.italic, ready: ready, command: (v) => _style((s) => s.copyWith(italic: v))),
        color('color', label: SubtitleStrings.color, history: h, argb: style.color, ready: ready, command: (c) => _style((s) => s.copyWith(color: c))),
        // Box.
        toggle('box',
            label: SubtitleStrings.box,
            value: box != null,
            ready: ready,
            command: (v) => _style((s) => s.copyWith(background: v ? const BoxStyle() : null))),
        if (box != null) ...[
          color('boxColor',
              label: SubtitleStrings.boxColor,
              history: h,
              argb: box.color,
              ready: ready,
              command: (c) => _style((s) => s.copyWith(background: (s.background ?? const BoxStyle()).copyWith(color: c)))),
          slider('boxOpacity',
              label: SubtitleStrings.boxOpacity,
              history: h,
              value: box.opacity,
              min: 0,
              max: 1,
              step: 0.01,
              displayScale: 100,
              unit: SubtitleStrings.percent,
              defaultValue: 0.6,
              ready: ready,
              command: (v) => _style((s) => s.copyWith(background: (s.background ?? const BoxStyle()).copyWith(opacity: v)))),
        ],
        // Outline.
        toggle('outline',
            label: SubtitleStrings.outline,
            value: outline != null,
            ready: ready,
            command: (v) => _style((s) => s.copyWith(outline: v ? const StrokeStyle() : null))),
        if (outline != null) ...[
          color('outlineColor',
              label: SubtitleStrings.outlineColor,
              history: h,
              argb: outline.color,
              ready: ready,
              command: (c) => _style((s) => s.copyWith(outline: (s.outline ?? const StrokeStyle()).copyWith(color: c)))),
          slider('outlineWidth',
              label: SubtitleStrings.outlineWidth,
              history: h,
              value: outline.widthPt,
              min: 0,
              max: 20,
              step: 0.5,
              fractionDigits: 1,
              unit: SubtitleStrings.pt,
              defaultValue: 2,
              ready: ready,
              command: (v) => _style((s) => s.copyWith(outline: (s.outline ?? const StrokeStyle()).copyWith(widthPt: v)))),
        ],
        // Shadow.
        toggle('shadow',
            label: SubtitleStrings.shadow,
            value: shadow != null,
            ready: ready,
            command: (v) => _style((s) => s.copyWith(shadow: v ? const ShadowStyle() : null))),
        if (shadow != null) ...[
          color('shadowColor',
              label: SubtitleStrings.shadowColor,
              history: h,
              argb: shadow.color,
              ready: ready,
              command: (c) => _style((s) => s.copyWith(shadow: (s.shadow ?? const ShadowStyle()).copyWith(color: c)))),
          slider('shadowBlur',
              label: SubtitleStrings.shadowBlur,
              history: h,
              value: shadow.blurPt,
              min: 0,
              max: 40,
              step: 1,
              unit: SubtitleStrings.pt,
              defaultValue: 6,
              ready: ready,
              command: (v) => _style((s) => s.copyWith(shadow: (s.shadow ?? const ShadowStyle()).copyWith(blurPt: v)))),
        ],
        // Layout.
        InspectorChoiceRow<int>(
          key: SubtitlesPanelKeys.style('maxLines'),
          label: SubtitleStrings.maxLines,
          value: style.maxLines.clamp(1, 3),
          enabled: ready,
          options: [for (final n in const [1, 2, 3]) DanaviewOption<int>(value: n, label: '$n')],
          onChanged: (n) {
            if (n != style.maxLines) editor.apply(_style((s) => s.copyWith(maxLines: n)));
          },
        ),
        slider('maxWidth',
            label: SubtitleStrings.maxWidth,
            history: h,
            value: style.maxWidth,
            min: 0.2,
            max: 1,
            step: 0.01,
            displayScale: 100,
            unit: SubtitleStrings.percent,
            defaultValue: 0.9,
            ready: ready,
            command: (v) => _style((s) => s.copyWith(maxWidth: v))),
        InspectorChoiceRow<TextAlignH>(
          key: SubtitlesPanelKeys.style('align'),
          label: SubtitleStrings.alignment,
          value: style.align,
          enabled: ready,
          options: [
            for (final a in TextAlignH.values)
              DanaviewOption<TextAlignH>(value: a, label: SubtitleStrings.align(a), icon: SubtitlesPanelModel.alignIcon(a)),
          ],
          onChanged: (a) {
            if (a != style.align) editor.apply(_style((s) => s.copyWith(align: a)));
          },
        ),
        // Track.
        const _Heading(SubtitleStrings.trackHeading),
        Text(SubtitleStrings.language, maxLines: 1, overflow: TextOverflow.ellipsis, style: _cueTextStyle),
        const SizedBox(height: DanaviewSpacing.xs),
        DanaviewTextField(
          key: SubtitlesPanelKeys.style('language'),
          controller: _language,
          focusNode: _languageFocus,
          hint: SubtitleStrings.languageHint,
          semanticLabel: SubtitleStrings.language,
          errorText: _languageError,
          enabled: ready,
          showClearButton: false,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _commitLanguage(),
        ),
        const SizedBox(height: DanaviewSpacing.xs),
        toggle('burnIn',
            label: SubtitleStrings.burnIn,
            subtitle: SubtitleStrings.burnInHint,
            value: _data.burnIn,
            ready: ready,
            command: (v) => SetBurnIn(widget.track.id, v)),
      ],
    );
  }
}

/// The placement kinds of the position section.
enum _Placement { bottom, top, custom }

/// The track-wide position (ux.md §10.9).
class _PositionSection extends ConsumerStatefulWidget {
  const _PositionSection({required this.track, required this.ready});

  final Track track;
  final bool ready;

  @override
  ConsumerState<_PositionSection> createState() => _PositionSectionState();
}

class _PositionSectionState extends ConsumerState<_PositionSection> with _TrackEdits<_PositionSection> {
  @override
  TrackId get trackId => widget.track.id;

  @override
  Widget build(BuildContext context) {
    final position = widget.track.subtitle?.position ?? SubtitlePosition.bottom;
    final placement = switch (position) {
      BottomSubtitlePosition() => _Placement.bottom,
      TopSubtitlePosition() => _Placement.top,
      CustomSubtitlePosition() => _Placement.custom,
    };
    final ready = widget.ready;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InspectorChoiceRow<_Placement>(
          key: SubtitlesPanelKeys.style('placement'),
          label: SubtitleStrings.placement,
          value: placement,
          enabled: ready,
          options: const [
            DanaviewOption<_Placement>(value: _Placement.bottom, label: SubtitleStrings.bottom, icon: Icons.vertical_align_bottom_rounded),
            DanaviewOption<_Placement>(value: _Placement.top, label: SubtitleStrings.top, icon: Icons.vertical_align_top_rounded),
            DanaviewOption<_Placement>(value: _Placement.custom, label: SubtitleStrings.custom, icon: Icons.height_rounded),
          ],
          onChanged: (p) {
            if (p == placement) return;
            final next = switch (p) {
              _Placement.bottom => SubtitlePosition.bottom,
              _Placement.top => SubtitlePosition.top,
              _Placement.custom => const CustomSubtitlePosition(SubtitlesPanelModel.defaultCustomY),
            };
            editor.apply(SetSubtitlePosition(widget.track.id, next));
          },
        ),
        if (position is CustomSubtitlePosition) ...[
          slider('offset',
              label: SubtitleStrings.offset,
              history: SubtitleStrings.historyPosition,
              value: position.yFraction,
              min: 0,
              max: 1,
              step: 0.01,
              displayScale: 100,
              unit: SubtitleStrings.percent,
              defaultValue: SubtitlesPanelModel.defaultCustomY,
              ready: ready,
              command: (v) => SetSubtitlePosition(widget.track.id, CustomSubtitlePosition(v))),
          const PanelNotice(SubtitleStrings.dragHint, color: DanaviewColors.textSecondary),
        ],
      ],
    );
  }
}
