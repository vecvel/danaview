// OWNER: UX-17
//
// The marker sheet and the marker operations (ARCH §17.9, ux.md §8.5, BUILD_PLAN UX-17).
//
// * The sheet lists the project's markers by time; tapping a row jumps the playhead to the marker
//   (and selects it) and closes the sheet; the pencil on a row opens the editor of that marker.
// * The editor changes name, colour (one of the six palette colours, named so colour never carries
//   meaning alone) and note, and deletes the marker. The changes are staged and committed as ONE
//   history entry ("Edit marker") by Done, by "All markers" and by dismissing the sheet; Delete is
//   its own entry.
// * `MarkerOperations` runs the commands without widgets (add at the playhead, update, delete); the
//   action bindings (actions/bindings/marker_bindings.dart) and the sheet share it. A marker is
//   never stacked on another at the same frame: adding there selects the existing one.
// * Markers are also snap targets (UX-13) and edit points (UX-14); those read `Timeline.markers`.
//
// Pure parts ([MarkerListModel], [MarkerDraft]) are unit-tested; [MarkerListView] and
// [MarkerEditView] draw them; [MarkerSheet] feeds them from the providers.

import 'dart:async';

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/services.dart' show LengthLimitingTextInputFormatter, TextCapitalization, TextInputAction;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../app/editor_providers.dart';
import '../contracts/contracts.dart';
import '../state/editor_controller.dart';
import '../state/editor_state.dart';
import 'timeline_semantics.dart' show editorAnnounce;
import 'timeline_style.dart';

// -------------------------------------------------------------------------------------------------
// Copy
// -------------------------------------------------------------------------------------------------

/// Plain copy of the marker sheet and the marker actions (ARCH §19).
abstract final class MarkerStrings {
  /// Sheet title and semantics label of the list.
  static const String title = 'Markers';

  /// Title of the editor.
  static const String editTitle = 'Edit marker';

  /// Shown for a marker without a name.
  static const String unnamed = 'Marker';

  /// Empty list title.
  static const String emptyTitle = 'No markers yet';

  /// Empty list explanation.
  static const String emptyBody = 'Markers flag a moment on the timeline. Jump back to them and snap clips to them.';

  /// The add button of the list and the empty state.
  static const String addAtPlayhead = 'Add marker at playhead';

  /// Tooltip and semantics label of a row's edit button.
  static const String editRow = 'Edit marker';

  /// Back to the list from the editor.
  static const String allMarkers = 'All markers';

  /// Name field label.
  static const String nameLabel = 'Name';

  /// Name field hint.
  static const String nameHint = 'Marker name';

  /// Colour section header.
  static const String colorSection = 'Color';

  /// Note field label.
  static const String noteLabel = 'Note';

  /// Note field hint.
  static const String noteHint = 'Add a note';

  /// The editor's jump row.
  static const String goTo = 'Go to marker';

  /// Delete button.
  static const String delete = 'Delete marker';

  /// Done button.
  static const String done = 'Done';

  /// The marker was removed while its editor was open.
  static const String gone = 'This marker no longer exists.';

  /// Add found a marker on that frame.
  static const String alreadyHere = 'There’s already a marker here.';

  /// Announcement after delete.
  static const String deleted = 'Marker deleted';

  /// Disabled reason of Edit marker with no markers.
  static const String noMarkers = 'There are no markers yet. Press M to add one at the playhead.';

  /// Disabled reason of Delete marker without a selected marker.
  static const String selectFirst = 'Select a marker on the ruler first.';

  /// The project can't be edited (not open or closing).
  static const String notEditable = 'This project can’t be edited right now.';

  /// Names of the six palette colours (`Marker.colorIndex`), in palette order.
  static const List<String> colorNames = ['Amber', 'Red', 'Green', 'Cyan', 'Indigo', 'Purple'];

  /// The name of colour [index] (out-of-range indices use the default colour's name).
  static String colorName(int index) => index >= 0 && index < colorNames.length ? colorNames[index] : colorNames.first;

  /// A marker's display name.
  static String displayName(Marker m) => m.name.isEmpty ? unnamed : m.name;

  /// Announcement after add.
  static String added(TimeUs t, FrameRate rate) => 'Marker added at ${Timecode.format(t, rate)}';

  /// Semantics label of a list row: jumps to the marker.
  static String rowLabel(Marker m, FrameRate rate) => 'Jump to ${displayName(m)} at ${Timecode.format(m.time, rate)}';

  /// Semantics label of a colour swatch.
  static String swatch(int index) => '${colorName(index)} marker color';

  /// Characters left hint of the note, or null while far from the limit.
  static String? noteLeft(int left) => left <= 50 ? '$left characters left' : null;
}

// -------------------------------------------------------------------------------------------------
// Operations
// -------------------------------------------------------------------------------------------------

/// What `MarkerOperations.add` did.
sealed class MarkerAddOutcome {
  const MarkerAddOutcome();
}

/// A new marker was added (and selected).
final class MarkerAdded extends MarkerAddOutcome {
  /// Creates the outcome.
  const MarkerAdded(this.marker);

  /// The new marker.
  final Marker marker;
}

/// A marker already sits on that frame; it was selected instead of adding another.
final class MarkerExists extends MarkerAddOutcome {
  /// Creates the outcome.
  const MarkerExists(this.marker);

  /// The marker that was already there.
  final Marker marker;
}

/// Nothing was added: the project is not open, or the command was refused (the controller toasted
/// the reason).
final class MarkerNotAdded extends MarkerAddOutcome {
  /// Creates the outcome.
  const MarkerNotAdded();
}

/// A staged edit of one marker: name, colour and note as typed.
@immutable
final class MarkerDraft {
  /// Creates a draft.
  const MarkerDraft({required this.name, required this.colorIndex, required this.note});

  /// The draft that equals [m].
  factory MarkerDraft.of(Marker m) => MarkerDraft(name: m.name, colorIndex: m.colorIndex, note: m.note ?? '');

  /// The name as typed.
  final String name;

  /// The palette index.
  final int colorIndex;

  /// The note as typed (empty: no note).
  final String note;

  /// A copy with the given fields replaced.
  MarkerDraft copyWith({String? name, int? colorIndex, String? note}) =>
      MarkerDraft(name: name ?? this.name, colorIndex: colorIndex ?? this.colorIndex, note: note ?? this.note);

  /// The command that turns [m] into this draft, or null when nothing changes.
  EditCommand? commandFor(Marker m) {
    final newName = name.trim();
    final newNote = note.trim().isEmpty ? null : note;
    final nameChanged = newName != m.name;
    final colorChanged = colorIndex != m.colorIndex;
    final noteChanged = newNote != m.note;
    if (!nameChanged && !colorChanged && !noteChanged) return null;
    final n = nameChanged ? newName : null;
    final c = colorChanged ? colorIndex : null;
    return noteChanged ? UpdateMarker(m.id, name: n, colorIndex: c, note: newNote) : UpdateMarker(m.id, name: n, colorIndex: c);
  }

  @override
  bool operator ==(Object other) => other is MarkerDraft && other.name == name && other.colorIndex == colorIndex && other.note == note;

  @override
  int get hashCode => Object.hash(name, colorIndex, note);
}

/// The marker commands (add at the playhead, update, delete) over one project's controller; tests
/// drive them without widgets.
final class MarkerOperations {
  /// Creates the operations; [state] reads the current editor state, [playhead] the playhead.
  MarkerOperations({required this.controller, required EditorState Function() state, required TimeUs Function() playhead})
      : _state = state,
        _playhead = playhead;

  /// The operations of the action context's project.
  factory MarkerOperations.of(EditorActionContext ctx) {
    final id = ctx.projectId;
    return MarkerOperations(
      controller: ctx.read(editorControllerProvider(id).notifier),
      state: () => ctx.read(editorControllerProvider(id)),
      playhead: () => ctx.read(playheadProvider(id)).value,
    );
  }

  /// The operations of project [id] read through a widget [ref] (a one-time read, no subscription).
  factory MarkerOperations.ofRef(WidgetRef ref, ProjectId id) => MarkerOperations(
        controller: ref.read(editorControllerProvider(id).notifier),
        state: () => ref.read(editorControllerProvider(id)),
        playhead: () => ref.read(playheadProvider(id)).value,
      );

  /// The project's controller.
  final EditorController controller;

  final EditorState Function() _state;
  final TimeUs Function() _playhead;

  /// The current project, or null when it is not open.
  EditProject? get project => _state().project;

  /// Whether the project accepts edits.
  bool get canEdit => controller.canEdit && project != null;

  /// The project's markers, sorted by time.
  List<Marker> get markers => project?.markers ?? const [];

  /// The selected marker if it still exists.
  Marker? get selected {
    final id = _state().selection.marker;
    if (id == null) return null;
    for (final m in markers) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// The marker [id], or null.
  Marker? byId(MarkerId id) {
    for (final m in markers) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// The marker on the frame of [t], or null.
  Marker? markerAt(TimeUs t) {
    final p = project;
    if (p == null) return null;
    final q = p.settings.frameRate.quantizeNearest(t);
    for (final m in p.markers) {
      if (m.time == q) return m;
    }
    return null;
  }

  /// Adds a marker at [at] (default: the playhead) on the frame grid and selects it. A marker
  /// already on that frame is selected instead (no history entry).
  MarkerAddOutcome add({TimeUs? at}) {
    final p = project;
    if (p == null || !canEdit) return const MarkerNotAdded();
    var t = p.settings.frameRate.quantizeNearest(at ?? _playhead());
    if (t < 0) t = 0;
    final existing = markerAt(t);
    if (existing != null) {
      controller.selectMarker(existing.id);
      return MarkerExists(existing);
    }
    final before = {for (final m in p.markers) m.id};
    final result = controller.apply(AddMarker(t));
    if (result is! EditApplied) return const MarkerNotAdded();
    for (final m in markers) {
      if (!before.contains(m.id)) {
        controller.selectMarker(m.id);
        return MarkerAdded(m);
      }
    }
    return const MarkerNotAdded();
  }

  /// Applies [draft] to the marker [id] as one history entry; null when nothing changes.
  EditResult? update(MarkerId id, MarkerDraft draft) {
    final m = byId(id);
    if (m == null) return null;
    final command = draft.commandFor(m);
    return command == null ? null : controller.apply(command);
  }

  /// Deletes the marker [id].
  EditResult? delete(MarkerId id) => byId(id) == null ? null : controller.apply(DeleteMarker(id));
}

// -------------------------------------------------------------------------------------------------
// Model
// -------------------------------------------------------------------------------------------------

/// One row of the marker list.
@immutable
final class MarkerRow {
  /// Creates a row.
  const MarkerRow({required this.marker, required this.title, required this.time, required this.note, required this.selected});

  /// The marker.
  final Marker marker;

  /// The name, or "Marker".
  final String title;

  /// The timecode.
  final String time;

  /// The first line of the note, or null.
  final String? note;

  /// Whether the marker is the selected one.
  final bool selected;

  /// The subtitle: timecode and the note's first line.
  String get subtitle => note == null ? time : '$time · $note';

  @override
  bool operator ==(Object other) => other is MarkerRow && other.marker == marker && other.selected == selected && other.time == time;

  @override
  int get hashCode => Object.hash(marker, selected, time);
}

/// What the list shows (pure).
@immutable
final class MarkerListModel {
  /// Creates a model.
  const MarkerListModel({required this.rows, required this.frameRate});

  /// The model of [markers] on [rate].
  factory MarkerListModel.of(List<Marker> markers, FrameRate rate, {MarkerId? selected}) => MarkerListModel(
        rows: [
          for (final m in markers)
            MarkerRow(
              marker: m,
              title: MarkerStrings.displayName(m),
              time: Timecode.format(m.time, rate),
              note: _firstLine(m.note),
              selected: m.id == selected,
            ),
        ],
        frameRate: rate,
      );

  /// The rows, by time.
  final List<MarkerRow> rows;

  /// The project's frame rate.
  final FrameRate frameRate;

  /// Whether there is no marker.
  bool get isEmpty => rows.isEmpty;

  static String? _firstLine(String? note) {
    if (note == null) return null;
    for (final line in note.split('\n')) {
      final t = line.trim();
      if (t.isNotEmpty) return t;
    }
    return null;
  }
}

// -------------------------------------------------------------------------------------------------
// Views
// -------------------------------------------------------------------------------------------------

TextStyle _font(TextStyle style) => style.copyWith(fontFamily: DanaviewFonts.family);

/// The flag glyph of a marker in its colour.
class MarkerFlag extends StatelessWidget {
  /// Creates the flag of palette colour [colorIndex].
  const MarkerFlag({super.key, required this.colorIndex, this.size = 22});

  /// The palette index.
  final int colorIndex;

  /// The glyph size.
  final double size;

  @override
  Widget build(BuildContext context) =>
      ExcludeSemantics(child: Icon(Icons.bookmark_rounded, size: size, color: TimelineStyle.standard.markerColor(colorIndex)));
}

/// The list of markers: pure, driven by [model].
class MarkerListView extends StatelessWidget {
  /// Creates the list.
  const MarkerListView(
      {super.key, required this.model, required this.canEdit, required this.onJump, required this.onEdit, required this.onAdd});

  /// What to show.
  final MarkerListModel model;

  /// Whether the project accepts edits (Add and the edit buttons).
  final bool canEdit;

  /// A row was tapped: jump to the marker.
  final ValueChanged<Marker> onJump;

  /// A row's edit button was tapped.
  final ValueChanged<Marker> onEdit;

  /// Add a marker at the playhead.
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    if (model.isEmpty) {
      return DanaviewEmptyState(
        key: const ValueKey('markers-empty'),
        icon: Icons.bookmark_add_outlined,
        title: MarkerStrings.emptyTitle,
        message: MarkerStrings.emptyBody,
        actions: [
          DanaviewButton.primary(
            key: const ValueKey('marker-add'),
            label: MarkerStrings.addAtPlayhead,
            icon: Icons.bookmark_add_rounded,
            onPressed: canEdit ? onAdd : null,
          ),
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final row in model.rows)
          DanaviewListTile(
            key: ValueKey('marker-row-${row.marker.id.value}'),
            title: row.title,
            subtitle: row.subtitle,
            subtitleMaxLines: 2,
            selected: row.selected,
            leading: MarkerFlag(colorIndex: row.marker.colorIndex),
            semanticLabel: MarkerStrings.rowLabel(row.marker, model.frameRate),
            trailing: DanaviewIconButton(
              key: ValueKey('marker-edit-${row.marker.id.value}'),
              icon: Icons.edit_rounded,
              iconSize: 18,
              size: 36,
              tooltip: MarkerStrings.editRow,
              semanticLabel: '${MarkerStrings.editRow} ${row.title}',
              onPressed: canEdit ? () => onEdit(row.marker) : null,
            ),
            onTap: () => onJump(row.marker),
          ),
        const SizedBox(height: 8),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: DanaviewButton.tonal(
            key: const ValueKey('marker-add'),
            label: MarkerStrings.addAtPlayhead,
            icon: Icons.bookmark_add_rounded,
            onPressed: canEdit ? onAdd : null,
          ),
        ),
      ],
    );
  }
}

/// The editor of one marker: name, colour, note, jump and delete. Staged: every change reports the
/// whole [MarkerDraft] through [onChanged]; the owner commits it.
class MarkerEditView extends StatefulWidget {
  /// Creates the editor of [marker] starting from [draft].
  const MarkerEditView({
    super.key,
    required this.marker,
    required this.draft,
    required this.frameRate,
    required this.canEdit,
    required this.onChanged,
    required this.onJump,
    required this.onDelete,
    required this.onDone,
    required this.onBack,
  });

  /// The marker as committed.
  final Marker marker;

  /// The staged values to show first.
  final MarkerDraft draft;

  /// The project's frame rate.
  final FrameRate frameRate;

  /// Whether the project accepts edits.
  final bool canEdit;

  /// The staged values changed.
  final ValueChanged<MarkerDraft> onChanged;

  /// Jump to the marker.
  final VoidCallback onJump;

  /// Delete the marker.
  final VoidCallback onDelete;

  /// Done: commit and close.
  final VoidCallback onDone;

  /// Back to the list (commits).
  final VoidCallback onBack;

  @override
  State<MarkerEditView> createState() => _MarkerEditViewState();
}

class _MarkerEditViewState extends State<MarkerEditView> {
  late final TextEditingController _name = TextEditingController(text: widget.draft.name);
  late final TextEditingController _note = TextEditingController(text: widget.draft.note);
  late int _color = widget.draft.colorIndex;

  @override
  void initState() {
    super.initState();
    _name.addListener(_changed);
    _note.addListener(_changed);
  }

  @override
  void dispose() {
    _name.dispose();
    _note.dispose();
    super.dispose();
  }

  void _changed() {
    widget.onChanged(MarkerDraft(name: _name.text, colorIndex: _color, note: _note.text));
    setState(() {});
  }

  void _pick(int index) {
    _color = index;
    _changed();
  }

  @override
  Widget build(BuildContext context) {
    final edit = widget.canEdit;
    final left = maxMarkerNoteLength - _note.text.characters.length;
    final leftText = MarkerStrings.noteLeft(left);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            DanaviewIconButton(
              key: const ValueKey('marker-back'),
              icon: Icons.arrow_back_rounded,
              tooltip: MarkerStrings.allMarkers,
              onPressed: widget.onBack,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Semantics(
                header: true,
                child: Text(MarkerStrings.editTitle, maxLines: 2, overflow: TextOverflow.ellipsis, style: _font(DanaviewTextStyles.title)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        DanaviewListTile(
          key: const ValueKey('marker-go-to'),
          title: MarkerStrings.goTo,
          subtitle: Timecode.format(widget.marker.time, widget.frameRate),
          leading: MarkerFlag(colorIndex: _color),
          onTap: widget.onJump,
        ),
        const DanaviewSectionHeader(MarkerStrings.nameLabel),
        DanaviewTextField(
          key: const ValueKey('marker-name'),
          controller: _name,
          hint: MarkerStrings.nameHint,
          semanticLabel: MarkerStrings.nameLabel,
          enabled: edit,
          textInputAction: TextInputAction.done,
          textCapitalization: TextCapitalization.sentences,
          inputFormatters: [LengthLimitingTextInputFormatter(maxMarkerNameLength)],
        ),
        const DanaviewSectionHeader(MarkerStrings.colorSection),
        Wrap(
          key: const ValueKey('marker-colors'),
          spacing: 4,
          runSpacing: 4,
          children: [
            for (var i = 0; i < markerPaletteSize; i++) _Swatch(index: i, selected: _color == i, onTap: edit ? () => _pick(i) : null),
          ],
        ),
        const DanaviewSectionHeader(MarkerStrings.noteLabel),
        DanaviewTextField(
          key: const ValueKey('marker-note'),
          controller: _note,
          hint: MarkerStrings.noteHint,
          semanticLabel: MarkerStrings.noteLabel,
          enabled: edit,
          minLines: 2,
          maxLines: 5,
          keyboardType: TextInputType.multiline,
          textCapitalization: TextCapitalization.sentences,
          inputFormatters: [LengthLimitingTextInputFormatter(maxMarkerNoteLength)],
        ),
        if (leftText != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
            child: Text(leftText, style: _font(DanaviewTextStyles.caption)),
          ),
        const SizedBox(height: 16),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 8,
          runSpacing: 8,
          children: [
            DanaviewButton(
              key: const ValueKey('marker-delete'),
              variant: DanaviewButtonVariant.destructive,
              label: MarkerStrings.delete,
              icon: Icons.delete_outline_rounded,
              onPressed: edit ? widget.onDelete : null,
            ),
            DanaviewButton.primary(key: const ValueKey('marker-done'), label: MarkerStrings.done, onPressed: widget.onDone),
          ],
        ),
      ],
    );
  }
}

/// A colour choice: a 28 px disc in a 44 px target, with a check when chosen.
class _Swatch extends StatelessWidget {
  const _Swatch({required this.index, required this.selected, required this.onTap});

  final int index;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final style = TimelineStyle.standard;
    return DanaviewPressable(
      key: ValueKey('marker-color-$index'),
      onTap: onTap,
      circle: true,
      selected: selected,
      semanticLabel: MarkerStrings.swatch(index),
      child: SizedBox(
        width: 44,
        height: 44,
        child: Center(
          child: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: style.markerColor(index),
              border: Border.all(color: selected ? DanaviewColors.textPrimary : DanaviewColors.border, width: selected ? 2 : 1),
            ),
            child: selected ? Icon(Icons.check_rounded, size: 18, color: style.markerForeground(index)) : null,
          ),
        ),
      ),
    );
  }
}

// -------------------------------------------------------------------------------------------------
// Sheet
// -------------------------------------------------------------------------------------------------

/// Add, edit, delete and jump to markers: the list, and the editor of one marker.
class MarkerSheet extends ConsumerStatefulWidget {
  /// Creates the sheet of project [projectId]; with [marker] it starts in that marker's editor.
  const MarkerSheet({super.key, required this.projectId, this.marker});

  /// The open project.
  final ProjectId projectId;

  /// The marker to edit first, or null for the list.
  final MarkerId? marker;

  /// Shows the sheet (the list, or the editor of [marker]).
  static Future<void> show(BuildContext context, {required ProjectId projectId, MarkerId? marker}) =>
      showDanaviewSheet<void>(context, title: null, builder: (_) => MarkerSheet(projectId: projectId, marker: marker));

  @override
  ConsumerState<MarkerSheet> createState() => _MarkerSheetState();
}

class _MarkerSheetState extends ConsumerState<MarkerSheet> {
  late final MarkerOperations _ops = MarkerOperations.ofRef(ref, widget.projectId);
  MarkerId? _editing;
  MarkerDraft? _draft;

  @override
  void initState() {
    super.initState();
    _editing = widget.marker;
  }

  /// Commits the staged edit (one history entry) and forgets it.
  void _commit() {
    final id = _editing;
    final draft = _draft;
    _draft = null;
    if (id == null || draft == null) return;
    _ops.update(id, draft);
  }

  void _edit(Marker m) => setState(() {
        _commit();
        _editing = m.id;
        _draft = MarkerDraft.of(m);
      });

  void _back() => setState(() {
        _commit();
        _editing = null;
      });

  void _close() => Navigator.of(context).maybePop();

  Future<void> _jump(Marker m) async {
    _commit();
    _ops.controller.selectMarker(m.id);
    final transport = ref.read(transportProvider(widget.projectId));
    _close();
    if (transport.playing.value) await transport.pause();
    await transport.seekTo(m.time);
  }

  void _add() {
    final outcome = _ops.add();
    if (outcome is MarkerAdded) _edit(outcome.marker);
    if (outcome is MarkerExists) _edit(outcome.marker);
  }

  void _delete(Marker m) {
    _draft = null;
    if (_ops.delete(m.id) != null) editorAnnounce(context, MarkerStrings.deleted);
    setState(() => _editing = null);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(editorControllerProvider(widget.projectId));
    final project = state.project;
    final rate = project?.settings.frameRate ?? FrameRate.fps30;
    final markers = project?.markers ?? const <Marker>[];
    final canEdit = _ops.canEdit;
    final editing = _editing == null ? null : markers.where((m) => m.id == _editing).firstOrNull;
    if (editing == null) {
      _editing = null;
      _draft = null;
    }
    // The marker an open editor was showing is gone (undo, or removed elsewhere): back to the list.
    final Widget body;
    if (editing != null) {
      final draft = _draft ??= MarkerDraft.of(editing);
      body = MarkerEditView(
        key: ValueKey('marker-edit-view-${editing.id.value}'),
        marker: editing,
        draft: draft,
        frameRate: rate,
        canEdit: canEdit,
        onChanged: (d) => _draft = d,
        onJump: () => _jump(editing),
        onDelete: () => _delete(editing),
        onDone: _close,
        onBack: _back,
      );
    } else {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Row(
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(MarkerStrings.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: _font(DanaviewTextStyles.title)),
                  ),
                ),
                DanaviewIconButton(
                  icon: Icons.close_rounded,
                  size: 32,
                  iconSize: 18,
                  variant: DanaviewIconButtonVariant.filled,
                  tooltip: 'Close',
                  onPressed: _close,
                ),
              ],
            ),
          ),
          MarkerListView(
            model: MarkerListModel.of(markers, rate, selected: state.selection.marker),
            canEdit: canEdit,
            onJump: _jump,
            onEdit: _edit,
            onAdd: _add,
          ),
        ],
      );
    }
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _commit();
      },
      child: Semantics(container: true, label: editing != null ? MarkerStrings.editTitle : MarkerStrings.title, child: body),
    );
  }
}
