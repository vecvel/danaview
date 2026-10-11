// OWNER: CORE-17
//
// Project-level commands (ARCH §7.2, domain.md §6.6): `SetCanvas`, `SetFrameRate`,
// `SetBackground`. They change `Timeline.settings`, so they are history entries like any edit.
//
// * `SetCanvas` never rewrites items: positions and sizes are normalized to the canvas, so
//   clips keep their relative size and placement (ux.md shows the "Clips keep their size" toast).
// * `SetFrameRate` re-grids the whole project with `requantize` (ops/requantize.dart): one
//   history entry for every edge, key, marker, transition and fade.
// * `SetBackground` swaps the solid colour or the blurred copy of the main lane.

part of '../edit_command.dart';

/// Sets the canvas: the aspect ratio and/or the base short side (720, 1080 or 2160 px). A null
/// argument keeps the current value. The long side follows (rounded to an even number of
/// pixels). Items are untouched.
///
/// Rejections: `InvalidValue('aspect')` (a ratio outside 1:4 … 4:1), `InvalidValue('baseShortSide')`
/// (not one of `CanvasSpec.supportedShortSides`).
final class SetCanvas extends EditCommand {
  /// Creates the command.
  const SetCanvas({this.aspect, this.baseShortSide});

  /// The aspect ratio, or null to keep it.
  final AspectRatio? aspect;

  /// The short side in px, or null to keep it.
  final int? baseShortSide;

  @override
  String get label => 'Canvas';

  @override
  void _apply(_Draft d) {
    final a = aspect;
    if (a != null && !(a.value >= 0.25 && a.value <= 4)) d.reject(const InvalidValue('aspect'));
    final s = baseShortSide;
    if (s != null && !CanvasSpec.supportedShortSides.contains(s)) d.reject(const InvalidValue('baseShortSide'));
    final next = d.settings.canvas.copyWith(aspect: a, baseShortSide: s);
    if (next == d.settings.canvas) return;
    d.settings = d.settings.copyWith(canvas: next);
  }

  @override
  String toString() => 'SetCanvas(aspect: $aspect, baseShortSide: $baseShortSide)';
}

/// Sets the project frame rate (24, 25, 30, 48, 50 or 60 fps) and moves every edge, key, marker,
/// transition, fade and text animation to the new grid (`requantize`). Setting the current rate
/// is a no-op. The view's playhead is not part of the timeline: the session re-quantizes it
/// (`requantize` on a whole `EditProject` does).
///
/// Rejections: `InvalidValue('frameRate')` (not a supported project rate).
final class SetFrameRate extends EditCommand {
  /// Creates the command.
  const SetFrameRate(this.frameRate);

  /// The new rate.
  final FrameRate frameRate;

  @override
  String get label => 'Frame rate';

  @override
  void _apply(_Draft d) {
    if (!frameRate.isSupportedProjectRate) d.reject(const InvalidValue('frameRate'));
    if (frameRate == d.rate) return;
    final before = d.snapshot();
    final after = requantize(before, frameRate);
    var removed = 0;
    final newById = {for (final t in after.tracks) t.id: t};
    for (final old in List<Track>.of(d.tracks)) {
      final t = newById[old.id]!;
      removed += old.transitions.length - t.transitions.length;
      for (var i = 0; i < t.items.length; i++) {
        d.affected.add(t.items[i].id);
      }
      d.putTrack(t);
    }
    d.settings = after.settings;
    d.markers = after.markers;
    if (removed > 0) d.notices.add(EditNotice(EditNoticeCodes.transitionsRemoved, count: removed));
  }

  @override
  String toString() => 'SetFrameRate($frameRate)';
}

/// Sets what fills the canvas behind the main lane: a solid colour (alpha is ignored; the canvas
/// is opaque) or a blurred copy of each main-lane clip.
///
/// Rejections: `InvalidValue('radius')` (a blur outside [0, 1] or not a number).
final class SetBackground extends EditCommand {
  /// Creates the command.
  const SetBackground(this.background);

  /// The background.
  final BackgroundSpec background;

  @override
  String get label => 'Background';

  @override
  void _apply(_Draft d) {
    final b = background;
    final BackgroundSpec next;
    switch (b) {
      case SolidBackground(:final color):
        next = SolidBackground(color | 0xFF000000);
      case BlurOfMainBackground(:final radius):
        if (!(radius >= 0 && radius <= 1)) d.reject(const InvalidValue('radius'));
        next = b;
    }
    if (next == d.settings.background) return;
    d.settings = d.settings.copyWith(background: next);
  }

  @override
  String toString() => 'SetBackground($background)';
}
