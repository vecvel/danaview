// OWNER: UX-30
//
// The text panel (ux.md §10.8, ARCH §17.7) for one text item, addressed by its `TextInspector`.
//
// * Tabs: Edit · Font · Style · Background · Stroke · Shadow · Animation, as a horizontally
//   scrolling chip row (it never overflows at 280 px / 1.35×). The route's tab opens first; the
//   tool tiles (UX-14) open the panel on Font, Style or Animation.
// * Edit: a multi-line DanaviewTextField. Every keystroke dispatches `SetText` (live preview);
//   typing coalesces into one history entry ("Edit text") per run: the key is SetText's
//   `text:<id>` plus a run number that changes after 1 s without typing or when the field loses
//   focus ([TextTypingRun]). A blank field is never sent (the command would refuse it); the item
//   keeps its last text and the field shows why, and losing focus restores it. Undo while typing
//   updates the field. Duration is a `TrimItem` of the tail (clamped).
//   While the keyboard is up and the layout hid the preview (degrade step 5, EditorLayoutSpec),
//   a one-line chip with the live text in its font sits above the field.
// * Font: FontPicker (search; each family drawn in itself) -> `SetTextStyle(fontFamily)`; size
//   8–200 pt; Bold and Italic switches.
// * Style: colour, opacity (the layer's keyframable `transform.opacity` through the generic
//   InspectorPropertyRow), alignment, letter spacing (−20…100), line spacing (0.6…3).
// * Background / Stroke / Shadow: a switch (`SetTextStyle(background: BoxStyle())` /
//   `removeBackground`…) and, when on, the values of the PropertyKeys ranges (CORE-14).
// * Animation: In (None/Fade/Slide/Scale/Typewriter) and Out (None/Fade/Slide/Scale), slide
//   direction, durations 0.1–2 s -> `SetTextAnimation` (the command fits in + out into the
//   item). "Preview" loops the item's range and plays; leaving the panel (or "Stop preview")
//   restores the play state, the loop range and the playhead.
// * Slider and colour gestures go through InspectorEditSession: one history entry per drag.
// * A locked lane shows a notice and disables every control; a missing item shows a notice.

import 'dart:math' as math;

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/services.dart' show TextCapitalization, TextInputAction;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../app/editor_providers.dart';
import '../../app/strings/text_strings.dart';
import '../contracts/content_text.dart';
import '../contracts/inspector_routes.dart';
import '../editor_scope.dart';
import '../inspector/inspector_rows.dart';
import '../layout/editor_layout_scope.dart';
import '../state/editor_controller.dart';
import '../state/transport_controller.dart';
import '../text/font_catalog.dart';
import 'font_picker.dart';
import 'transform_panel.dart' show PanelNotice;

/// Typing runs of one text field: the coalesce key of the next `SetText` (ux.md §10.8: one
/// history entry per 1 s idle or blur).
class TextTypingRun {
  /// Creates the run tracker; [clock] defaults to [TextTypingRun.now].
  TextTypingRun({DateTime Function()? clock}) : _clock = clock;

  /// Idle time that ends a run.
  static const Duration idle = Duration(seconds: 1);

  /// The default clock (tests replace it).
  static DateTime Function() now = DateTime.now;

  final DateTime Function()? _clock;
  DateTime? _last;
  int _serial = 0;

  /// The current run number.
  int get serial => _serial;

  /// The coalesce key of [command]: its own key plus the run number, which changes after [idle].
  String keyFor(SetText command) {
    final now = (_clock ?? TextTypingRun.now)();
    final last = _last;
    if (last == null || now.difference(last) >= idle) _serial++;
    _last = now;
    return '${command.coalesceKey}#$_serial';
  }

  /// Ends the run (the field lost focus): the next keystroke starts a new history entry.
  void end() => _last = null;
}

/// The arithmetic of the text panel.
abstract final class TextPanelModel {
  /// Shortest animation duration offered.
  static const TimeUs minAnimation = microsPerSecond ~/ 10;

  /// Longest animation duration offered.
  static const TimeUs maxAnimation = 2 * microsPerSecond;

  /// Duration of an animation that is switched on.
  static const TimeUs defaultAnimation = microsPerSecond ~/ 2;

  /// Longest item duration typed in the Duration field (seconds).
  static const double maxDurationSeconds = 3600;

  /// The "In" choices.
  static const List<TextAnimKind> inKinds = TextAnimKind.values;

  /// The "Out" choices (typewriter is an in animation only).
  static const List<TextAnimKind> outKinds = [TextAnimKind.none, TextAnimKind.fade, TextAnimKind.slide, TextAnimKind.scale];

  /// The slide directions in display order.
  static const List<TextSlideDirection> directions = [
    TextSlideDirection.left,
    TextSlideDirection.up,
    TextSlideDirection.right,
    TextSlideDirection.down,
  ];

  /// The glyph of a slide direction.
  static IconData directionIcon(TextSlideDirection d) => switch (d) {
        TextSlideDirection.left => Icons.arrow_back_rounded,
        TextSlideDirection.right => Icons.arrow_forward_rounded,
        TextSlideDirection.up => Icons.arrow_upward_rounded,
        TextSlideDirection.down => Icons.arrow_downward_rounded,
      };

  /// The glyph of an alignment.
  static IconData alignIcon(TextAlignH a) => switch (a) {
        TextAlignH.left => Icons.format_align_left_rounded,
        TextAlignH.center => Icons.format_align_center_rounded,
        TextAlignH.right => Icons.format_align_right_rounded,
      };

  /// Seconds of [t].
  static double seconds(TimeUs t) => t / microsPerSecond;

  /// [s] seconds as microseconds.
  static TimeUs micros(double s) => (s * microsPerSecond).round();

  /// The key of a tab chip.
  static String tabKey(TextPanelTab tab) => 'text.tab.${tab.name}';

  /// ARGB of [c].
  static int argb(Color c) => c.toARGB32();
}

/// The text panel (ux.md §10.8).
class TextPanel extends ConsumerStatefulWidget {
  /// Creates the panel.
  const TextPanel({super.key, required this.route});

  /// What the panel edits.
  final TextInspector route;

  /// The item whose panel should focus its text field when it opens (set by "Add text", so the
  /// keyboard comes up, ux.md §10.8). Consumed by the panel.
  static final ValueNotifier<ItemId?> focusRequest = ValueNotifier<ItemId?>(null);

  @override
  ConsumerState<TextPanel> createState() => _TextPanelState();
}

typedef _SavedTransport = ({bool playing, TimeRange? loop, TimeUs position});

class _TextPanelState extends ConsumerState<TextPanel> {
  late TextPanelTab _tab = widget.route.tab;
  final TextEditingController _text = TextEditingController();
  final FocusNode _focus = FocusNode(debugLabel: 'TextPanel.text');
  final TextTypingRun _run = TextTypingRun();
  final Map<String, InspectorEditSession> _sessions = {};
  final Map<String, double> _live = {};
  Color? _liveColor;
  String? _liveColorKey;
  bool _blank = false;
  String? _lastSent;
  ItemId? _syncedItem;

  TransportController? _transport;
  _SavedTransport? _saved;
  bool _previewing = false;
  Future<void> _queue = Future<void>.value();

  ItemId get _item => widget.route.item;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
    TextPanel.focusRequest.addListener(_onFocusRequest);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onFocusRequest());
  }

  @override
  void didUpdateWidget(TextPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.route.tab != widget.route.tab) _tab = widget.route.tab;
    if (oldWidget.route.item != widget.route.item) {
      for (final s in _sessions.values) {
        s.dispose();
      }
      _sessions.clear();
      _live.clear();
      _run.end();
      _blank = false;
      _lastSent = null;
      _syncedItem = null;
      if (_previewing) _stopPreview();
      WidgetsBinding.instance.addPostFrameCallback((_) => _onFocusRequest());
    }
  }

  @override
  void dispose() {
    TextPanel.focusRequest.removeListener(_onFocusRequest);
    for (final s in _sessions.values) {
      s.dispose();
    }
    _restore();
    _focus
      ..removeListener(_onFocus)
      ..dispose();
    _text.dispose();
    super.dispose();
  }

  // ---- Edit -----------------------------------------------------------------------------------

  void _onFocusRequest() {
    if (!mounted || TextPanel.focusRequest.value != _item) return;
    TextPanel.focusRequest.value = null;
    if (_tab != TextPanelTab.edit) setState(() => _tab = TextPanelTab.edit);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focus.requestFocus();
      _text.selection = TextSelection(baseOffset: 0, extentOffset: _text.text.length);
    });
  }

  void _onFocus() {
    if (_focus.hasFocus) return;
    _run.end();
    if (_blank) {
      final item = _textItem();
      if (item != null) _setField(item.text);
      setState(() => _blank = false);
    }
  }

  void _setField(String text) {
    if (_text.text == text) return;
    _text.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
  }

  void _onTyped(String value) {
    final blank = value.trim().isEmpty;
    if (blank != _blank) setState(() => _blank = blank);
    if (blank) return;
    final item = _textItem();
    if (item == null || item.text == value) return;
    final command = SetText(_item, value);
    _lastSent = value;
    _editor.apply(command, coalesceKey: _run.keyFor(command));
  }

  /// Keeps the field on the item's text when it changes from elsewhere (undo, another panel).
  void _syncField(TextItem item) {
    if (_syncedItem != item.id) {
      _syncedItem = item.id;
      _lastSent = item.text;
      _setField(item.text);
      return;
    }
    if (item.text == _lastSent) return;
    _lastSent = item.text;
    if (_text.text != item.text) {
      _setField(item.text);
      if (_blank) _blank = false;
    }
  }

  // ---- Commands -------------------------------------------------------------------------------

  EditorController get _editor => ref.read(editorControllerProvider(EditorScope.idOf(context)).notifier);

  void _apply(EditCommand command) => _editor.apply(command);

  TextItem? _textItem() {
    final project = ref.read(editorControllerProvider(EditorScope.idOf(context))).project;
    final item = project?.index.item(_item);
    return item is TextItem ? item : null;
  }

  InspectorEditSession _session(String key, String label) {
    final editor = _editor;
    final s = _sessions[key] ??= InspectorEditSession(editor: editor, label: label, coalesceKey: 'text:$_item:$key');
    s.editor = editor;
    return s;
  }

  // ---- Loop preview ---------------------------------------------------------------------------

  void _enqueue(Future<void> Function() op) {
    _queue = _queue.then((_) => op()).catchError((Object _) {});
  }

  TransportController _transportOf() {
    final transport = _transport ?? ref.read<TransportController>(transportProvider(EditorScope.idOf(context)));
    _transport = transport;
    return transport;
  }

  void _startPreview(TextItem item) {
    final transport = _transportOf();
    if (!transport.canPlay) return;
    setState(() => _previewing = true);
    final range = TimeRange(item.start, item.end);
    _enqueue(() async {
      _saved ??= (playing: transport.playing.value, loop: transport.loop.value, position: transport.playhead.value);
      await transport.setLoop(range);
      await transport.play();
    });
  }

  void _stopPreview() {
    setState(() => _previewing = false);
    _restore();
  }

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

  /// Keeps the loop on the item while previewing (its range changed).
  void _followLoop(TextItem item) {
    if (!_previewing) return;
    final transport = _transport;
    if (transport == null) return;
    final range = TimeRange(item.start, item.end);
    if (transport.loop.value == range) return;
    _enqueue(() => transport.setLoop(range));
  }

  // ---- Build ----------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final id = EditorScope.idOf(context);
    final loc = ref.watch(editorControllerProvider(id).select((s) => s.project?.index.locate(_item)));
    final isReady = ref.watch(editorControllerProvider(id).select((s) => s.isReady));
    final item = loc?.item;
    final children = <Widget>[];
    var ready = false;
    if (item is! TextItem) {
      children.add(const PanelNotice(TextStrings.missing, key: ValueKey<String>('text.missing')));
    } else {
      _syncField(item);
      final locked = loc!.track.locked;
      ready = isReady && !locked && ref.read(editorControllerProvider(id).notifier).canEdit;
      if (_previewing) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _followLoop(item);
        });
      }
      if (locked) children.add(const PanelNotice(TextStrings.locked, key: ValueKey<String>('text.locked')));
      children
        ..add(_tabs())
        ..add(const SizedBox(height: DanaviewSpacing.sm))
        ..addAll(switch (_tab) {
          TextPanelTab.edit => _editTab(item, ready),
          TextPanelTab.font => _fontTab(item, ready),
          TextPanelTab.style => _styleTab(item, ready),
          TextPanelTab.background => _backgroundTab(item, ready),
          TextPanelTab.stroke => _strokeTab(item, ready),
          TextPanelTab.shadow => _shadowTab(item, ready),
          TextPanelTab.animation => _animationTab(item, ready),
        });
    }
    return CustomScrollView(
      key: const ValueKey<String>('text.scroll'),
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

  Widget _tabs() => Semantics(
        container: true,
        label: TextStrings.tabs,
        child: SingleChildScrollView(
          key: const ValueKey<String>('text.tabs'),
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final tab in TextPanelTab.values)
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: DanaviewSpacing.xs),
                  child: DanaviewChoiceChip(
                    key: ValueKey<String>(TextPanelModel.tabKey(tab)),
                    label: TextStrings.tab(tab),
                    selected: _tab == tab,
                    onTap: () => setState(() => _tab = tab),
                  ),
                ),
            ],
          ),
        ),
      );

  // ---- Edit tab -------------------------------------------------------------------------------

  List<Widget> _editTab(TextItem item, bool ready) {
    final spec = EditorLayoutScope.maybeOf(context);
    final rate = ref.read(editorControllerProvider(EditorScope.idOf(context))).project!.settings.frameRate;
    final frameSeconds = TextPanelModel.seconds(rate.timeOfFrame(1));
    return [
      if (spec != null && spec.previewHidden && spec.keyboardVisible) _LiveTextChip(item: item, catalog: ref.watch(fontCatalogProvider)),
      DanaviewTextField(
        key: const ValueKey<String>('text.field'),
        controller: _text,
        focusNode: _focus,
        hint: TextStrings.textHint,
        semanticLabel: TextStrings.textField,
        enabled: ready,
        showClearButton: false,
        keyboardType: TextInputType.multiline,
        textInputAction: TextInputAction.newline,
        textCapitalization: TextCapitalization.sentences,
        minLines: 2,
        maxLines: 5,
        errorText: _blank ? TextStrings.emptyText : null,
        onChanged: _onTyped,
      ),
      const SizedBox(height: DanaviewSpacing.sm),
      InspectorNumberRow(
        key: const ValueKey<String>('text.duration'),
        label: TextStrings.duration,
        value: TextPanelModel.seconds(item.duration),
        min: frameSeconds,
        max: TextPanelModel.maxDurationSeconds,
        step: 0.1,
        fractionDigits: 2,
        unit: TextStrings.secondsUnit,
        enabled: ready,
        onChanged: (v) {
          final end = item.start + TextPanelModel.micros(math.max(v, frameSeconds));
          if (end == item.end) return;
          _apply(TrimItem(_item, TrimEdge.end, end, clamp: true));
        },
      ),
    ];
  }

  // ---- Font tab -------------------------------------------------------------------------------

  List<Widget> _fontTab(TextItem item, bool ready) {
    final style = item.style;
    final catalog = ref.watch(fontCatalogProvider);
    return [
      _slider(
        'size',
        PropertyKeys.fontSize,
        TextStrings.size,
        style.fontSizePt,
        ready,
        (v) => SetTextStyle([_item], fontSizePt: v),
      ),
      _toggle('bold', TextStrings.bold, style.bold, ready, (v) => SetTextStyle([_item], bold: v)),
      _toggle('italic', TextStrings.italic, style.italic, ready, (v) => SetTextStyle([_item], italic: v)),
      const SizedBox(height: DanaviewSpacing.sm),
      FontPicker(
        key: const ValueKey<String>('text.fontPicker'),
        catalog: catalog,
        selectedId: catalog.familyFor(style.fontFamily).id,
        enabled: ready,
        onSelected: (fontId) {
          if (fontId == style.fontFamily) return;
          _apply(SetTextStyle([_item], fontFamily: fontId));
        },
      ),
    ];
  }

  // ---- Style tab ------------------------------------------------------------------------------

  List<Widget> _styleTab(TextItem item, bool ready) {
    final style = item.style;
    return [
      _color('color', TextStrings.color, style.color, ready, (c) => SetTextStyle([_item], color: c)),
      InspectorPropertyRow(
        key: const ValueKey<String>('text.opacity'),
        item: _item,
        property: PropertyKeys.opacity,
        label: TextStrings.opacity,
      ),
      InspectorChoiceRow<TextAlignH>(
        key: const ValueKey<String>('text.align'),
        label: TextStrings.alignment,
        value: style.align,
        enabled: ready,
        options: [
          for (final a in TextAlignH.values)
            DanaviewOption<TextAlignH>(value: a, label: TextStrings.align(a), icon: TextPanelModel.alignIcon(a)),
        ],
        onChanged: (a) {
          if (a != style.align) _apply(SetTextStyle([_item], align: a));
        },
      ),
      _slider(
        'letterSpacing',
        PropertyKeys.letterSpacing,
        TextStrings.letterSpacing,
        style.letterSpacing,
        ready,
        (v) => SetTextStyle([_item], letterSpacing: v),
        unit: '',
      ),
      _slider(
        'lineHeight',
        PropertyKeys.lineHeight,
        TextStrings.lineSpacing,
        style.lineHeight,
        ready,
        (v) => SetTextStyle([_item], lineHeight: v),
      ),
    ];
  }

  // ---- Background / stroke / shadow -------------------------------------------------------------

  List<Widget> _backgroundTab(TextItem item, bool ready) {
    final box = item.style.background;
    return [
      _toggle(
        'background',
        TextStrings.background,
        box != null,
        ready,
        (on) => on ? SetTextStyle([_item], background: const BoxStyle()) : SetTextStyle([_item], removeBackground: true),
      ),
      if (box == null)
        const PanelNotice(TextStrings.offHint, key: ValueKey<String>('text.background.off'), color: DanaviewColors.textSecondary)
      else ...[
        _color('background.color', TextStrings.color, box.color, ready,
            (c) => SetTextStyle([_item], background: _boxOf(c: c))),
        _slider('background.opacity', PropertyKeys.backgroundOpacity, TextStrings.opacity, box.opacity, ready,
            (v) => SetTextStyle([_item], background: _boxOf(opacity: v))),
        _slider('background.padding', PropertyKeys.backgroundPadding, TextStrings.padding, box.paddingPt, ready,
            (v) => SetTextStyle([_item], background: _boxOf(padding: v))),
        _slider('background.cornerRadius', PropertyKeys.backgroundCornerRadius, TextStrings.cornerRadius, box.cornerRadiusPt, ready,
            (v) => SetTextStyle([_item], background: _boxOf(radius: v))),
      ],
    ];
  }

  /// The current box with one value replaced (read at dispatch time, so a gesture never resets
  /// another value).
  BoxStyle _boxOf({int? c, double? opacity, double? padding, double? radius}) =>
      (_textItem()?.style.background ?? const BoxStyle()).copyWith(color: c, opacity: opacity, paddingPt: padding, cornerRadiusPt: radius);

  StrokeStyle _strokeOf({int? c, double? width}) =>
      (_textItem()?.style.stroke ?? const StrokeStyle()).copyWith(color: c, widthPt: width);

  ShadowStyle _shadowOf({int? c, double? opacity, double? blur, double? distance, double? angle}) =>
      (_textItem()?.style.shadow ?? const ShadowStyle())
          .copyWith(color: c, opacity: opacity, blurPt: blur, distancePt: distance, angleDeg: angle);

  List<Widget> _strokeTab(TextItem item, bool ready) {
    final stroke = item.style.stroke;
    return [
      _toggle(
        'stroke',
        TextStrings.stroke,
        stroke != null,
        ready,
        (on) => on ? SetTextStyle([_item], stroke: const StrokeStyle()) : SetTextStyle([_item], removeStroke: true),
      ),
      if (stroke == null)
        const PanelNotice(TextStrings.offHint, key: ValueKey<String>('text.stroke.off'), color: DanaviewColors.textSecondary)
      else ...[
        _color('stroke.color', TextStrings.color, stroke.color, ready, (c) => SetTextStyle([_item], stroke: _strokeOf(c: c))),
        _slider('stroke.width', PropertyKeys.strokeWidth, TextStrings.width, stroke.widthPt, ready,
            (v) => SetTextStyle([_item], stroke: _strokeOf(width: v))),
      ],
    ];
  }

  List<Widget> _shadowTab(TextItem item, bool ready) {
    final shadow = item.style.shadow;
    return [
      _toggle(
        'shadow',
        TextStrings.shadow,
        shadow != null,
        ready,
        (on) => on ? SetTextStyle([_item], shadow: const ShadowStyle()) : SetTextStyle([_item], removeShadow: true),
      ),
      if (shadow == null)
        const PanelNotice(TextStrings.offHint, key: ValueKey<String>('text.shadow.off'), color: DanaviewColors.textSecondary)
      else ...[
        _color('shadow.color', TextStrings.color, shadow.color, ready, (c) => SetTextStyle([_item], shadow: _shadowOf(c: c))),
        _slider('shadow.opacity', PropertyKeys.shadowOpacity, TextStrings.opacity, shadow.opacity, ready,
            (v) => SetTextStyle([_item], shadow: _shadowOf(opacity: v))),
        _slider('shadow.blur', PropertyKeys.shadowBlur, TextStrings.blur, shadow.blurPt, ready,
            (v) => SetTextStyle([_item], shadow: _shadowOf(blur: v))),
        _slider('shadow.distance', PropertyKeys.shadowDistance, TextStrings.distance, shadow.distancePt, ready,
            (v) => SetTextStyle([_item], shadow: _shadowOf(distance: v))),
        _slider('shadow.angle', PropertyKeys.shadowAngle, TextStrings.angle, shadow.angleDeg, ready,
            (v) => SetTextStyle([_item], shadow: _shadowOf(angle: v)),
            unit: TextStrings.degreesUnit),
      ],
    ];
  }

  // ---- Animation tab --------------------------------------------------------------------------

  List<Widget> _animationTab(TextItem item, bool ready) {
    final a = item.animation;
    final shortened = a.inKind != TextAnimKind.none && a.outKind != TextAnimKind.none && a.inDuration + a.outDuration >= item.duration;
    return [
      ..._animSide(item, ready, isIn: true),
      const SizedBox(height: DanaviewSpacing.sm),
      ..._animSide(item, ready, isIn: false),
      if (shortened)
        const PanelNotice(TextStrings.animShortened, key: ValueKey<String>('text.anim.shortened'), color: DanaviewColors.textSecondary),
      const SizedBox(height: DanaviewSpacing.md),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: ValueListenableBuilder<bool>(
          valueListenable: _transportOf().playing,
          builder: (context, playing, _) {
            final running = _previewing && playing;
            return DanaviewButton.secondary(
              key: const ValueKey<String>('text.preview'),
              label: running ? TextStrings.stopPreview : TextStrings.playPreview,
              icon: running ? Icons.stop_rounded : Icons.play_arrow_rounded,
              onPressed: running ? _stopPreview : () => _startPreview(item),
            );
          },
        ),
      ),
    ];
  }

  List<Widget> _animSide(TextItem item, bool ready, {required bool isIn}) {
    final a = item.animation;
    final side = isIn ? 'in' : 'out';
    final kind = isIn ? a.inKind : a.outKind;
    final direction = isIn ? a.inDirection : a.outDirection;
    final duration = isIn ? a.inDuration : a.outDuration;
    final kinds = isIn ? TextPanelModel.inKinds : TextPanelModel.outKinds;

    TextAnimation withKind(TextAnimKind k) {
      final d = k == TextAnimKind.none ? 0 : (duration > 0 ? duration : TextPanelModel.defaultAnimation);
      return isIn ? a.copyWith(inKind: k, inDuration: d) : a.copyWith(outKind: k, outDuration: d);
    }

    TextAnimation withDuration(double seconds) {
      final d = TextPanelModel.micros(seconds).clamp(TextPanelModel.minAnimation, TextPanelModel.maxAnimation);
      final cur = _textItem()?.animation ?? a;
      return isIn ? cur.copyWith(inDuration: d) : cur.copyWith(outDuration: d);
    }

    final sessionKey = 'anim.$side';
    final session = _session(sessionKey, TextStrings.historyAnimation);
    return [
      _Heading(isIn ? TextStrings.animIn : TextStrings.animOut),
      DanaviewChipGroup(
        key: ValueKey<String>('text.anim.$side'),
        children: [
          for (final k in kinds)
            DanaviewChoiceChip(
              key: ValueKey<String>('text.anim.$side.${k.name}'),
              label: TextStrings.animKind(k),
              selected: kind == k,
              enabled: ready,
              onTap: () {
                if (k != kind) _apply(SetTextAnimation([_item], withKind(k)));
              },
            ),
        ],
      ),
      if (kind == TextAnimKind.slide)
        InspectorChoiceRow<TextSlideDirection>(
          key: ValueKey<String>('text.anim.$side.direction'),
          label: TextStrings.direction,
          value: direction,
          enabled: ready,
          options: [
            for (final d in TextPanelModel.directions)
              DanaviewOption<TextSlideDirection>(value: d, label: TextStrings.slideDirection(d), icon: TextPanelModel.directionIcon(d)),
          ],
          onChanged: (d) {
            if (d == direction) return;
            _apply(SetTextAnimation([_item], isIn ? a.copyWith(inDirection: d) : a.copyWith(outDirection: d)));
          },
        ),
      if (kind != TextAnimKind.none)
        InspectorSliderRow(
          key: ValueKey<String>('text.anim.$side.duration'),
          label: TextStrings.animDuration,
          value: _live[sessionKey] ?? TextPanelModel.seconds(duration).clamp(0.1, 2.0),
          min: 0.1,
          max: 2.0,
          step: 0.1,
          fractionDigits: 1,
          unit: TextStrings.secondsUnit,
          enabled: ready,
          onChangeStart: (_) => session.start(),
          onChanged: (v) {
            setState(() => _live[sessionKey] = v);
            session.change(SetTextAnimation([_item], withDuration(v)));
          },
          onChangeEnd: (_) {
            session.end();
            setState(() => _live.remove(sessionKey));
          },
          onSubmitted: (v) => session.apply(SetTextAnimation([_item], withDuration(v))),
        ),
    ];
  }

  // ---- Row helpers ----------------------------------------------------------------------------

  Widget _slider(
    String key,
    PropertyKey<double> property,
    String label,
    double value,
    bool ready,
    EditCommand Function(double v) command, {
    String? unit,
  }) {
    final session = _session(key, TextStrings.historyStyle);
    double clamp(double v) => property.clamp(v);
    return InspectorSliderRow(
      key: ValueKey<String>('text.$key'),
      label: label,
      value: _live[key] ?? value.clamp(property.min, property.max).toDouble(),
      min: property.min,
      max: property.max,
      step: property.step,
      displayScale: property.displayScale,
      unit: unit ?? property.unit,
      defaultValue: property.defaultValue,
      enabled: ready,
      onChangeStart: (_) => session.start(),
      onChanged: (v) {
        setState(() => _live[key] = v);
        session.change(command(clamp(v)));
      },
      onChangeEnd: (_) {
        session.end();
        setState(() => _live.remove(key));
      },
      onSubmitted: (v) => session.apply(command(clamp(v))),
    );
  }

  Widget _toggle(String key, String label, bool value, bool ready, EditCommand Function(bool v) command) => KeyedSubtree(
        key: ValueKey<String>('text.$key'),
        child: InspectorToggleRow(
          label: label,
          value: value,
          onChanged: ready ? (v) => _apply(command(v)) : null,
        ),
      );

  Widget _color(String key, String label, int argb, bool ready, EditCommand Function(int c) command) {
    final session = _session(key, TextStrings.historyStyle);
    final shown = _liveColorKey == key && _liveColor != null ? _liveColor! : Color(argb);
    return InspectorColorRow(
      key: ValueKey<String>('text.$key'),
      label: label,
      color: shown,
      enabled: ready,
      onChangeStart: (_) => session.start(),
      onChanged: (c) {
        setState(() {
          _liveColor = c;
          _liveColorKey = key;
        });
        if (session.active) {
          session.change(command(TextPanelModel.argb(c)));
        } else {
          session.apply(command(TextPanelModel.argb(c)));
        }
      },
      onChangeEnd: (_) {
        session.end();
        setState(() {
          _liveColor = null;
          _liveColorKey = null;
        });
      },
    );
  }
}

/// One line of the live text in its own font, shown above the field while the keyboard hides the
/// preview (ux.md §10.8, degrade step 5).
class _LiveTextChip extends StatelessWidget {
  const _LiveTextChip({required this.item, required this.catalog});

  final TextItem item;
  final FontCatalog catalog;

  @override
  Widget build(BuildContext context) {
    final family = catalog.familyFor(item.style.fontFamily);
    final color = Color(item.style.color | 0xFF000000);
    // A dark text colour gets a light chip and a light one a dark chip (computed, ARCH §1.3).
    final fill = DanaviewColors.foregroundOn(color) == DanaviewColors.textPrimary ? DanaviewColors.textSecondary : DanaviewColors.surfaceElevatedHigher;
    return Padding(
      key: const ValueKey<String>('text.liveChip'),
      padding: const EdgeInsets.only(bottom: DanaviewSpacing.sm),
      child: Semantics(
        label: '${TextStrings.livePreview}: ${item.text}',
        excludeSemantics: true,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: DanaviewSpacing.md, vertical: DanaviewSpacing.xs),
          decoration: BoxDecoration(color: fill, borderRadius: DanaviewRadius.smAll),
          child: EditorContentTextRegion(
            child: Text(
              item.text.replaceAll('\n', ' '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: family.packagedFamily,
                fontSize: 16,
                height: 1.3,
                color: color,
                fontWeight: item.style.bold ? FontWeight.w700 : FontWeight.w400,
                fontStyle: item.style.italic ? FontStyle.italic : FontStyle.normal,
              ),
            ),
          ),
        ),
      ),
    );
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
