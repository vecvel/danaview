// OWNER: UX-23
//
// Colour sampling with a magnifier (ux.md §7.5). The eyedropper is started by a caller (the chroma
// key panel, a colour field's eyedropper button) through `PreviewToolController.pickColor` /
// `pickPreviewColor`; this overlay covers the preview while it runs:
//
// * A reticle follows the finger with a 40 px swatch of the sampled colour beside it (above the
//   finger, below it near the top of the view), so the finger never hides the colour.
// * The view point maps through the clip's box at the playhead and its crop to a normalized
//   **source** point (`eyedropperSourcePoint`); `preview.sampleColor(item, point)` averages 3×3
//   source pixels before the chroma key (D-08), so the key and the eyedropper agree.
// * Sampling is throttled to 15 Hz while dragging (`EyedropperSampler`: the first move samples at
//   once, later moves wait out the 1/15 s window and the latest point wins); every sample goes to
//   the caller's `onSample` for a live preview. Releasing samples the release point and returns
//   that colour to the caller; points outside the clip are skipped.
// * A banner explains what to do and has Cancel; Esc/back (the cancel-gesture step) cancels too.
//   Assistive technology activates the area to sample the centre of the clip.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/eval.dart' show boxAt;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../app/editor_providers.dart';
import '../../app/strings/transform_strings.dart';
import '../editor_lifecycle.dart';
import '../editor_scope.dart';
import 'canvas_geometry.dart';

/// The normalized, display-oriented source point of [item] under the view point [view] at
/// timeline time [t]: through the clip's box (position, scale, rotation and flips at [t]) and its
/// crop. Null when the point is outside the clip or the clip has no box.
Offset? eyedropperSourcePoint(EditProject project, ItemId item, TimeUs t, CanvasGeometry geometry, Offset view) {
  final clip = project.index.item(item);
  if (clip is! MediaClip || clip.visual == null || geometry.isEmpty) return null;
  final box = boxAt(project, item, t);
  final n = box?.toLocalNormalized(geometry.toCanvas2(view));
  if (n == null) return null;
  const eps = 1e-9;
  if (n.dx < -eps || n.dx > 1 + eps || n.dy < -eps || n.dy > 1 + eps) return null;
  final crop = clip.visual!.crop;
  return Offset(
    crop.left + n.dx.clamp(0.0, 1.0) * (crop.right - crop.left),
    crop.top + n.dy.clamp(0.0, 1.0) * (crop.bottom - crop.top),
  );
}

/// Throttles colour samples to [interval] while dragging (see the file comment).
class EyedropperSampler {
  /// Creates the sampler; [sample] asks the preview, [onColor] receives every colour.
  EyedropperSampler({required this.sample, required this.onColor, this.interval = defaultInterval});

  /// 15 Hz.
  static const Duration defaultInterval = Duration(microseconds: 1000000 ~/ 15);

  /// Samples the source at a normalized source point.
  final Future<Color?> Function(Offset sourcePoint) sample;

  /// Receives each sampled colour.
  final ValueChanged<Color> onColor;

  /// The shortest time between two samples while dragging.
  final Duration interval;

  Timer? _cooldown;
  Offset? _pending;
  Color? _last;
  int _requests = 0;
  int _generation = 0;
  bool _disposed = false;

  /// The latest colour sampled.
  Color? get last => _last;

  /// How many samples were requested.
  int get requests => _requests;

  /// The finger moved to [sourcePoint] (null: outside the clip).
  void move(Offset? sourcePoint) {
    if (_disposed || sourcePoint == null) return;
    if (_cooldown != null) {
      _pending = sourcePoint;
      return;
    }
    _fire(sourcePoint);
    _cooldown = Timer(interval, _onCooldown);
  }

  void _onCooldown() {
    _cooldown = null;
    final p = _pending;
    _pending = null;
    if (p != null && !_disposed) {
      _fire(p);
      _cooldown = Timer(interval, _onCooldown);
    }
  }

  void _fire(Offset p) {
    _requests++;
    final generation = _generation;
    unawaited(_ask(p).then((c) {
      if (c != null && !_disposed && generation == _generation) {
        _last = c;
        onColor(c);
      }
    }));
  }

  Future<Color?> _ask(Offset p) async {
    try {
      return await sample(p);
    } catch (_) {
      return null;
    }
  }

  /// The finger lifted at [sourcePoint]: drops pending samples, samples the release point and
  /// returns its colour (the latest colour when it is outside the clip or the sample fails).
  Future<Color?> release(Offset? sourcePoint) async {
    _cooldown?.cancel();
    _cooldown = null;
    _pending = null;
    _generation++;
    if (sourcePoint == null || _disposed) return _last;
    _requests++;
    final c = await _ask(sourcePoint);
    if (c != null) {
      _last = c;
      if (!_disposed) onColor(c);
    }
    return c ?? _last;
  }

  /// Stops sampling.
  void dispose() {
    _disposed = true;
    _cooldown?.cancel();
    _cooldown = null;
    _pending = null;
  }
}

/// Colour sampling with a magnifier (ux.md §7.5).
class EyedropperOverlay extends ConsumerStatefulWidget {
  /// Creates the overlay sampling [item]; [onDone] receives the picked colour (null: cancelled).
  const EyedropperOverlay({super.key, required this.geometry, required this.item, required this.onDone, this.onSample});

  /// The canvas mapping of the preview.
  final CanvasGeometry geometry;

  /// The clip whose source is sampled.
  final ItemId item;

  /// Receives the picked colour, or null when cancelled.
  final ValueChanged<Color?> onDone;

  /// Receives every colour sampled while dragging.
  final ValueChanged<Color>? onSample;

  /// Diameter of the colour swatch.
  static const double swatchSize = 40;

  @override
  ConsumerState<EyedropperOverlay> createState() => EyedropperOverlayState();
}

/// State of [EyedropperOverlay] (public for tests).
class EyedropperOverlayState extends ConsumerState<EyedropperOverlay> {
  /// The throttled sampler of this pick.
  late final EyedropperSampler sampler = EyedropperSampler(sample: _sample, onColor: _onColor);
  Offset? _finger;
  Color? _color;
  bool _done = false;
  VoidCallback? _unregister;
  EditorBackDispatcher? _dispatcher;

  /// Where the reticle is (view px), or null before the first touch.
  Offset? get finger => _finger;

  /// The colour shown in the swatch.
  Color? get color => _color;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final d = EditorBackDispatcher.maybeOf(context);
    if (!identical(d, _dispatcher)) {
      _unregister?.call();
      _dispatcher = d;
      _unregister = d?.register(EditorBackStep.cancelGesture, _cancelForBack);
    }
  }

  @override
  void dispose() {
    _unregister?.call();
    sampler.dispose();
    super.dispose();
  }

  Future<Color?> _sample(Offset sourcePoint) async {
    final preview = ref.read(editorSessionProvider(EditorScope.idOf(context))).preview;
    if (preview == null) return null;
    return preview.sampleColor(widget.item, sourcePoint);
  }

  void _onColor(Color c) {
    widget.onSample?.call(c);
    if (mounted) setState(() => _color = c);
  }

  Offset? _sourceAt(Offset view) {
    final id = EditorScope.idOf(context);
    final project = ref.read(editorControllerProvider(id)).project;
    if (project == null) return null;
    return eyedropperSourcePoint(project, widget.item, ref.read(playheadProvider(id)).value, widget.geometry, view);
  }

  void _down(Offset p) {
    if (_done) return;
    setState(() => _finger = p);
    sampler.move(_sourceAt(p));
  }

  void _move(Offset p) {
    if (_done) return;
    setState(() => _finger = p);
    sampler.move(_sourceAt(p));
  }

  Future<void> _up() async {
    final p = _finger;
    if (_done || p == null) return;
    _done = true;
    final c = await sampler.release(_sourceAt(p));
    widget.onDone(c);
  }

  Future<void> _sampleCentre() async {
    if (_done) return;
    final id = EditorScope.idOf(context);
    final project = ref.read(editorControllerProvider(id)).project;
    final box = project == null ? null : boxAt(project, widget.item, ref.read(playheadProvider(id)).value);
    if (box == null) return;
    _finger = widget.geometry.toView2(box.center);
    await _up();
  }

  void _cancel() {
    if (_done) return;
    _done = true;
    sampler.dispose();
    widget.onDone(null);
  }

  bool _cancelForBack() {
    if (_done) return false;
    _cancel();
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final finger = _finger;
    final color = _color;
    return Stack(
      fit: StackFit.expand,
      children: [
        Semantics(
          container: true,
          label: TransformStrings.eyedropperArea,
          hint: TransformStrings.eyedropperHint,
          value: color == null ? null : TransformStrings.eyedropperValue(color.toARGB32()),
          onTap: () => unawaited(_sampleCentre()),
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (e) => _down(e.localPosition),
            onPointerMove: (e) => _move(e.localPosition),
            onPointerUp: (_) => unawaited(_up()),
            onPointerCancel: (_) => _cancel(),
            child: CustomPaint(
              size: Size.infinite,
              painter: finger == null ? null : EyedropperPainter(finger: finger, color: color),
            ),
          ),
        ),
        Positioned(
          left: DanaviewSpacing.sm,
          right: DanaviewSpacing.sm,
          top: DanaviewSpacing.sm,
          child: _Banner(onCancel: _cancel),
        ),
      ],
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.onCancel});

  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: DanaviewColors.overlayDark,
            borderRadius: DanaviewRadius.controlAll,
            border: const Border.fromBorderSide(DanaviewBorders.hairline),
            boxShadow: DanaviewShadows.subtle,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(DanaviewSpacing.md, DanaviewSpacing.xxs, DanaviewSpacing.xxs, DanaviewSpacing.xxs),
            child: Row(
              children: [
                const Icon(Icons.colorize_rounded, size: 18, color: DanaviewColors.textPrimary),
                const SizedBox(width: DanaviewSpacing.sm),
                Expanded(
                  child: Text(
                    TransformStrings.eyedropperHint,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: DanaviewTextStyles.caption.copyWith(fontFamily: DanaviewFonts.family, color: DanaviewColors.textPrimary),
                  ),
                ),
                DanaviewButton.ghost(
                  key: const ValueKey<String>('eyedropper.cancel'),
                  label: TransformStrings.eyedropperCancel,
                  size: DanaviewButtonSize.sm,
                  onPressed: onCancel,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Paints the reticle at [finger] and the swatch of [color] beside it.
class EyedropperPainter extends CustomPainter {
  /// Creates the painter.
  const EyedropperPainter({required this.finger, this.color});

  /// The finger (view px).
  final Offset finger;

  /// The sampled colour, or null before the first sample.
  final Color? color;

  /// Where the swatch centre sits for [finger] in a view of [size]: above the finger, or below it
  /// when there is no room above; kept inside the view horizontally.
  static Offset swatchCenter(Offset finger, Size size) {
    const r = EyedropperOverlay.swatchSize / 2;
    const gap = 36.0;
    final above = finger.dy - gap - r;
    final y = above - r >= 0 ? above : finger.dy + gap + r;
    final x = finger.dx.clamp(r, math.max(r, size.width - r)).toDouble();
    return Offset(x, y);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = DanaviewColors.textPrimary;
    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..color = const Color(0x99000000);
    canvas.drawCircle(finger, 12, outline);
    canvas.drawCircle(finger, 12, ring);
    canvas.drawLine(finger - const Offset(4, 0), finger + const Offset(4, 0), ring..strokeWidth = 1);
    canvas.drawLine(finger - const Offset(0, 4), finger + const Offset(0, 4), ring);
    final c = swatchCenter(finger, size);
    const r = EyedropperOverlay.swatchSize / 2;
    canvas.drawCircle(
      c,
      r + 2,
      Paint()
        ..color = const Color(0x66000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.drawCircle(c, r, Paint()..color = color ?? DanaviewColors.surfaceElevatedHigher);
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = DanaviewColors.textPrimary,
    );
  }

  @override
  bool shouldRepaint(EyedropperPainter old) => old.finger != finger || old.color != color;
}
