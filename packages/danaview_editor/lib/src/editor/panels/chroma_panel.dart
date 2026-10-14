// OWNER: UX-28
//
// The Chroma key panel (ux.md §10.10) for one video or photo clip (an overlay, typically).
// Constructor contract: `ChromaPanel({Key? key, required ChromaInspector route})` (InspectorHost
// builds panels with it).
//
// * Enable switch: one labelled entry ("Turn on chroma key").
// * Key colour: the swatch (ColorField over DanaviewColorPicker; one gesture is one entry "Change key
//   colour"), the eyedropper (`Icons.colorize_rounded`, ux.md §7.5) and the quick chips Green
//   (#00B140) and Blue (#0047BB). Choosing a colour turns keying on in the same entry.
// * Eyedropper: `PreviewToolController.pickColor` shows UX-23's eyedropper overlay; it samples the
//   pre-key source at ≤ 15 Hz while dragging. The first sample opens an `EditTransaction` ("Pick key
//   colour") that previews the key live; release commits the released colour (one entry), cancel
//   restores. When the playhead is outside the clip it first moves to the clip's start so the
//   picture is on the preview. The matte preview pauses during a pick.
// * Similarity (default 40 %), Smoothness (10 %) and Spill reduction (30 %): rows from the CORE-05
//   metadata (`InspectorPropertyRow`, not keyframable in v1); a drag is one `EditTransaction`.
// * "Show matte": `preview.setEditingMode(MatteMode(item))` while on (white stays, black is
//   removed), normal again when switched off, when keying goes off, and when the panel closes.
//   Re-targeting to another clip keeps the matte on for that clip when it is keyed.
// * The header's reset sets the defaults (off, green, 40/10/30) as one entry "Reset chroma key".

import 'dart:async';

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show CompositeCommand, EditCommand, SetChroma;
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' show MatteMode, PreviewEditingMode, PreviewSession;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../app/editor_providers.dart';
import '../../app/strings/overlay_strings.dart';
import '../contracts/inspector_routes.dart';
import '../editor_scope.dart';
import '../inspector/color_field.dart';
import '../inspector/inspector_header.dart';
import '../inspector/inspector_rows.dart';
import '../preview/crop_overlay.dart' show afterFrame, previewToolProvider;
import '../state/editor_controller.dart';
import 'transform_panel.dart' show PanelNotice;

/// Commands and presets of the Chroma key panel.
abstract final class ChromaCommands {
  /// The green-screen key colour (the model default).
  static const int green = 0x00B140;

  /// The blue-screen key colour.
  static const int blue = 0x0047BB;

  /// The quick chips.
  static const List<(String, int)> presets = [(ChromaStrings.green, green), (ChromaStrings.blue, blue)];

  /// The numeric rows.
  static final List<PropertyKey<Object?>> rows = List.unmodifiable(<PropertyKey<Object?>>[
    PropertyKeys.chromaSimilarity,
    PropertyKeys.chromaSmoothness,
    PropertyKeys.chromaSpill,
  ]);

  /// The labels of [rows].
  static const Map<String, String> labels = {
    'chroma.similarity': ChromaStrings.similarity,
    'chroma.smoothness': ChromaStrings.smoothness,
    'chroma.spill': ChromaStrings.spill,
  };

  /// The chroma key of [clip].
  static ChromaKey of(MediaClip clip) => clip.visual?.chroma ?? ChromaKey.off;

  /// Turns keying on or off.
  static EditCommand enable(MediaClip clip, bool on) =>
      CompositeCommand(ChromaStrings.historyEnable(on), [SetChroma([clip.id], of(clip).copyWith(enabled: on))]);

  /// Sets the key colour to [rgb] (`0xRRGGBB`, alpha ignored) and turns keying on.
  static EditCommand color(MediaClip clip, int rgb, {String label = ChromaStrings.historyColor}) =>
      CompositeCommand(label, [SetChroma([clip.id], of(clip).copyWith(enabled: true, color: rgb & 0xFFFFFF))]);

  /// The defaults (off, green, 40 / 10 / 30 %).
  static EditCommand reset(MediaClip clip) => CompositeCommand(ChromaStrings.historyReset, [SetChroma([clip.id], ChromaKey.off)]);

  /// An opaque [Color] of [rgb].
  static Color colorOf(int rgb) => Color(0xFF000000 | (rgb & 0xFFFFFF));

  /// `0xRRGGBB` of [color].
  static int rgbOf(Color color) => color.toARGB32() & 0xFFFFFF;
}

/// The chroma key panel (ux.md §10.10).
class ChromaPanel extends ConsumerStatefulWidget {
  /// Creates the panel.
  const ChromaPanel({super.key, required this.route});

  /// What the panel edits.
  final ChromaInspector route;

  @override
  ConsumerState<ChromaPanel> createState() => ChromaPanelState();
}

/// State of [ChromaPanel] (public for tests: [matte], [picking]).
class ChromaPanelState extends ConsumerState<ChromaPanel> {
  bool _matte = false;
  bool _picking = false;
  Color? _live;
  PreviewSession? _matteSession;
  InspectorEditSession? _colorSession;

  /// Whether the matte switch is on.
  bool get matte => _matte;

  /// Whether an eyedropper pick is running.
  bool get picking => _picking;

  ProjectId get _id => EditorScope.idOf(context);

  EditorController get _editor => ref.read(editorControllerProvider(_id).notifier);

  MediaClip? _clip() {
    final item = ref.read(editorControllerProvider(_id)).project?.index.item(widget.route.item);
    return item is MediaClip && item.visual != null ? item : null;
  }

  @override
  void didUpdateWidget(ChromaPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.route.item != widget.route.item && _matte && !_picking) _showMatte(widget.route.item);
  }

  @override
  void dispose() {
    _colorSession?.dispose();
    _hideMatte();
    super.dispose();
  }

  // ---- Matte -----------------------------------------------------------------------------------

  void _showMatte(ItemId item) {
    final session = ref.read(editorSessionProvider(_id)).preview;
    _matteSession = session;
    _send(session, MatteMode(item));
  }

  void _hideMatte() {
    final session = _matteSession;
    _matteSession = null;
    _send(session, PreviewEditingMode.normal);
  }

  static void _send(PreviewSession? session, PreviewEditingMode mode) {
    if (session == null) return;
    unawaited(session.setEditingMode(mode).then<void>((_) {}, onError: (Object _) {}));
  }

  void _setMatte(bool on) {
    if (!mounted || on == _matte) return;
    setState(() => _matte = on);
    if (on) {
      _showMatte(widget.route.item);
    } else {
      _hideMatte();
    }
  }

  // ---- Eyedropper ------------------------------------------------------------------------------

  Future<void> _pick() async {
    final clip = _clip();
    if (clip == null || _picking) return;
    final id = _id;
    final editor = _editor;
    final tools = ref.read(previewToolProvider(id));
    final playhead = ref.read(playheadProvider(id));
    if (!clip.range.contains(playhead.value)) {
      playhead.seekExact(clip.start).ignore();
      DanaviewToast.show(context, ChromaStrings.pickMoved);
    }
    final matte = _matte;
    if (matte) _hideMatte();
    setState(() => _picking = true);
    EditTransaction? tx;
    EditCommand command(Color c) => ChromaCommands.color(clip, ChromaCommands.rgbOf(c), label: ChromaStrings.historyPick);
    Color? picked;
    try {
      picked = await tools.pickColor(clip.id, onSample: (c) {
        if (mounted) setState(() => _live = c);
        (tx ??= editor.beginTransaction(ChromaStrings.historyPick)).update(command(c));
      });
    } finally {
      final open = tx;
      if (picked != null) {
        if (open != null && open.isOpen) {
          open
            ..update(command(picked))
            ..commit();
        } else {
          editor.apply(command(picked));
        }
      } else if (open != null && open.isOpen) {
        open.cancel();
      }
      if (mounted) {
        setState(() {
          _picking = false;
          _live = null;
        });
        if (matte && _matte) _showMatte(widget.route.item);
      }
    }
  }

  // ---- Build -----------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final id = _id;
    final item = ref.watch(editorControllerProvider(id).select((s) => s.project?.index.item(widget.route.item)));
    if (item is! MediaClip || item.visual == null) return const SizedBox.shrink();
    final locked = ref.watch(editorControllerProvider(id).select((s) => s.project?.index.locate(widget.route.item)?.track.locked ?? false));
    final ready = ref.watch(editorControllerProvider(id).select((s) => s.isReady)) && !locked;
    final chroma = ChromaCommands.of(item);
    if (_matte && !chroma.enabled && !_picking) afterFrame(() => _setMatte(false));
    final editor = _editor;
    void reset() => editor.apply(ChromaCommands.reset(item));
    return InspectorHeaderActions.publish(
      actions: InspectorHeaderActions(onReset: ready && chroma != ChromaKey.off ? reset : null),
      child: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(DanaviewSpacing.lg, DanaviewSpacing.sm, DanaviewSpacing.lg, DanaviewSpacing.lg),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (locked) const PanelNotice(OverlayStrings.trackLocked),
                  InspectorToggleRow(
                    key: const ValueKey<String>('chroma.enabled'),
                    label: ChromaStrings.enable,
                    subtitle: ChromaStrings.enableHint,
                    value: chroma.enabled,
                    onChanged: ready ? (v) => editor.apply(ChromaCommands.enable(item, v)) : null,
                  ),
                  _keyColorRow(item, chroma, ready),
                  Padding(
                    padding: const EdgeInsets.only(bottom: DanaviewSpacing.xs),
                    child: DanaviewChipGroup(
                      children: [
                        for (final (label, rgb) in ChromaCommands.presets)
                          DanaviewChoiceChip(
                            key: ValueKey<String>('chroma.preset.${label.toLowerCase()}'),
                            label: label,
                            selected: chroma.color == rgb,
                            enabled: ready,
                            onTap: () {
                              if (chroma.color != rgb || !chroma.enabled) {
                                editor.apply(ChromaCommands.color(item, rgb, label: ChromaStrings.historyPreset(label)));
                              }
                            },
                          ),
                      ],
                    ),
                  ),
                  if (!chroma.enabled) const PanelNotice(ChromaStrings.offHint, color: DanaviewColors.textMuted),
                  for (final k in ChromaCommands.rows)
                    InspectorPropertyRow(key: ValueKey<String>('row.${k.id}'), item: item.id, property: k, label: ChromaCommands.labels[k.id]),
                  InspectorToggleRow(
                    key: const ValueKey<String>('chroma.matte'),
                    label: ChromaStrings.showMatte,
                    subtitle: chroma.enabled ? ChromaStrings.showMatteHint : ChromaStrings.matteNeedsKey,
                    value: _matte && chroma.enabled,
                    onChanged: chroma.enabled && !_picking ? _setMatte : null,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _keyColorRow(MediaClip item, ChromaKey chroma, bool ready) {
    final shown = _live ?? ChromaCommands.colorOf(chroma.color);
    final session = _colorSession ??=
        InspectorEditSession(editor: _editor, label: ChromaStrings.historyColor, coalesceKey: '${item.id}:chroma.color');
    session
      ..editor = _editor
      ..coalesceKey = '${item.id}:chroma.color';
    EditCommand command(Color c) => ChromaCommands.color(_clip() ?? item, ChromaCommands.rgbOf(c));
    final style = DanaviewTextStyles.body.copyWith(fontFamily: DanaviewFonts.family);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: DanaviewSpacing.xxs),
      child: Row(
        children: [
          Expanded(child: Text(ChromaStrings.keyColor, maxLines: 1, overflow: TextOverflow.ellipsis, style: style)),
          Flexible(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: DanaviewSpacing.xs),
              child: Text(
                ChromaStrings.hex(ChromaCommands.rgbOf(shown)),
                key: const ValueKey<String>('chroma.hex'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: DanaviewTextStyles.caption.copyWith(
                  fontFamily: DanaviewFonts.family,
                  color: DanaviewColors.textSecondary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
          DanaviewIconButton(
            key: const ValueKey<String>('chroma.eyedropper'),
            icon: Icons.colorize_rounded,
            variant: DanaviewIconButtonVariant.filled,
            selected: _picking,
            size: 40,
            tooltip: ChromaStrings.eyedropper,
            semanticLabel: ChromaStrings.eyedropper,
            onPressed: ready && !_picking ? _pick : null,
          ),
          const SizedBox(width: DanaviewSpacing.xs),
          ColorField(
            key: const ValueKey<String>('chroma.color'),
            color: shown,
            label: ChromaStrings.keyColor,
            enabled: ready && !_picking,
            onChangeStart: (_) => session.start(),
            onChanged: (c) {
              if (!session.active) {
                session.apply(command(c));
                return;
              }
              setState(() => _live = c);
              session.change(command(c));
            },
            onChangeEnd: (_) {
              session.end();
              if (mounted) setState(() => _live = null);
            },
          ),
        ],
      ),
    );
  }
}
