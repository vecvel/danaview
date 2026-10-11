// OWNER: UX-09
//
// TimelineViewportController (ux.md §8.4, ARCH §17.4): timeline zoom (px per second) and scroll
// (time at the left edge, lane offset), outside Riverpod state so per-frame motion never rebuilds
// widgets; layers repaint from it.
//
// * Zoom range: from "whole project + margin" (`width / max(duration + 10 s, 30 s)`) to one frame
//   = 48 px (`fps·48` px/s). Buttons and keys step ×1.5 / ÷1.5; pinch is continuous.
// * Anchor: the focal point in free mode; in centre-locked mode always the playhead at the centre.
// * Centre-locked mode (touch default): the playhead line is fixed at the centre; user scrolling
//   scrubs (`onScrub` with the time under the centre line, `onScrubEnd` when the gesture or fling
//   ends) and otherwise the view follows the playhead. Bounds keep time 0 and the end reachable at
//   the centre: `[-viewport/2, duration + viewport/2]`.
// * Free mode (pointer default): scrolling never moves the playhead; during playback the view
//   pages when the playhead passes 90 % of the width so it sits at 10 %. Bounds:
//   `[-24 px, duration + 30 % viewport]`.
// * Fling: one platform scroll simulation per axis (bouncing on Apple platforms, clamping
//   elsewhere) driven by a Ticker; it always comes to rest inside the bounds.
// * Persistence: zoom, scroll and an explicit follow mode are written to the project's ViewState
//   (`attachViewSink`, usually `EditSession.updateView`) when the view settles (gesture or fling
//   end, discrete zoom/scroll, playback stop, `flushView`), never per frame.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show Velocity, kMinFlingVelocity;
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart' show BouncingScrollSimulation, ClampingScrollSimulation, Size;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vwish_editor_core/model.dart' show FrameRate, PlayheadFollowMode, ProjectId, TimeRange, TimeUs, ViewState, microsPerSecond;

import '../../app/editor_providers.dart' show editorPrefsProvider;
import 'timeline_metrics.dart';

/// Writes a ViewState change into the open project (`EditSession.updateView`).
typedef ViewStateSink = void Function(ViewState Function(ViewState view) update);

/// Timeline zoom and scroll (ux.md §8.4).
///
/// Coordinates: x is local to the lanes area (the ruler and canvas to the right of the track
/// headers), 0 at its left edge; y is content y of the lane stack (0 = top of the first lane).
/// Listeners are notified when zoom, scroll, size, content or mode change; painters repaint from
/// it, nothing rebuilds.
class TimelineViewportController extends ChangeNotifier {
  /// Creates a controller whose follow mode is [defaultMode] until the project or the user chooses
  /// one. [platform] picks the fling physics (default: `defaultTargetPlatform`).
  TimelineViewportController({
    PlayheadFollowMode defaultMode = PlayheadFollowMode.centreLocked,
    TargetPlatform? platform,
    FrameRate frameRate = FrameRate.fps30,
  })  : _defaultMode = defaultMode,
        _mode = defaultMode,
        _platform = platform ?? defaultTargetPlatform,
        _frameRate = frameRate;

  /// The device default follow mode: centre-locked on touch platforms (unless the Editor setting
  /// "Center playhead" is off), free on pointer platforms.
  static PlayheadFollowMode defaultModeFor(TargetPlatform platform, {bool centerPlayheadOnTouch = true}) => switch (platform) {
        TargetPlatform.iOS ||
        TargetPlatform.android ||
        TargetPlatform.fuchsia =>
          centerPlayheadOnTouch ? PlayheadFollowMode.centreLocked : PlayheadFollowMode.free,
        TargetPlatform.macOS || TargetPlatform.windows || TargetPlatform.linux => PlayheadFollowMode.free,
      };

  /// Zoom step of buttons and keys (×1.5 / ÷1.5).
  static const double zoomStep = 1.5;

  /// Largest zoom: one frame is this many px.
  static const double maxPxPerFrame = 48;

  /// Margin on each side of the project after [zoomToFit], as a fraction of the width.
  static const double fitMargin = 0.05;

  /// Time added to the duration for the smallest zoom.
  static const double minZoomTrailingSec = 10;

  /// The smallest zoom always shows at least this many seconds.
  static const double minZoomSpanSec = 30;

  /// Free mode: how far time 0 can sit right of the left edge.
  static const double freeLeadingPx = 24;

  /// Free mode: how far past the end the view can scroll, as a fraction of the width.
  static const double freeTrailingFraction = 0.3;

  /// Free-mode playback paging: the playhead passing this fraction of the width pages ...
  static const double followPageAt = 0.9;

  /// ... so that it sits at this fraction.
  static const double followPageTo = 0.1;

  /// Default margin of [ensureVisible].
  static const double revealMarginPx = 24;

  final TargetPlatform _platform;

  // Layout.
  double _width = 0, _height = 0, _headerWidth = 0, _rulerHeight = 0;

  // Content.
  TimeUs _duration = 0;
  FrameRate _frameRate;
  double _contentHeight = 0;

  // View.
  double _pps = 0;
  bool _fitPending = true;
  double _scrollSec = 0;
  double _scrollY = 0;
  PlayheadFollowMode _defaultMode;
  PlayheadFollowMode _mode;
  bool _modeExplicit = false;
  bool _restored = false;

  // Interaction.
  bool _inGesture = false;
  bool _scrubbing = false;
  Ticker? _ticker;
  TickerProvider? _vsync;
  Simulation? _simX, _simY;
  bool _simXBounces = false;
  double _flingPps = 0;
  double _lastFlingVelocityX = 0;

  // Playhead link.
  ValueListenable<TimeUs>? _playhead;
  ValueListenable<bool>? _playing;
  ValueChanged<TimeUs>? _onScrub;
  VoidCallback? _onScrubEnd;
  bool _wasPlaying = false;

  // Persistence.
  ViewStateSink? _viewSink;
  (double, int, double, PlayheadFollowMode?)? _flushed;
  bool _disposed = false;

  // ---- State -----------------------------------------------------------------------------------

  /// Zoom in logical px per second (0 until the first layout when the project asked for "fit").
  double get pxPerSecond => _pps;

  /// Time in seconds at the left edge of the lanes area (double for smooth motion; may be
  /// negative).
  double get scrollTimeSec => _scrollSec;

  /// Vertical lane offset in px.
  double get scrollY => _scrollY;

  /// The current follow mode.
  PlayheadFollowMode get mode => _mode;

  /// Whether the playhead is locked at the centre (scrolling scrubs).
  bool get centerLocked => _mode == PlayheadFollowMode.centreLocked;

  /// Whether the mode was chosen by the user or the project (persisted) rather than the device
  /// default.
  bool get modeIsExplicit => _modeExplicit;

  /// Whether [restore] has run since creation (the view adopts the project's ViewState once).
  bool get restored => _restored;

  /// Width of the lanes area (timeline width minus the header column).
  double get lanesWidth => _width;

  /// Height of the lanes area (timeline height minus the ruler).
  double get lanesHeight => _height;

  /// Width of the header column passed to [setViewport].
  double get headerWidth => _headerWidth;

  /// Ruler height passed to [setViewport].
  double get rulerHeight => _rulerHeight;

  /// Whether the viewport has a size to work with.
  bool get hasLayout => _width > 0;

  /// The project's duration.
  TimeUs get duration => _duration;

  /// The project's frame rate.
  FrameRate get frameRate => _frameRate;

  /// Height of the lane stack (content).
  double get contentHeight => _contentHeight;

  /// Smallest zoom: the whole project plus 10 s (at least 30 s) fills the width.
  double get minPxPerSecond {
    if (!hasLayout) return 0;
    final span = math.max(_duration / microsPerSecond + minZoomTrailingSec, minZoomSpanSec);
    return math.min(_width / span, maxPxPerSecond);
  }

  /// Largest zoom: one frame is 48 px.
  double get maxPxPerSecond => _frameRate.fps * maxPxPerFrame;

  /// Whether [zoomIn] can zoom further.
  bool get canZoomIn => hasLayout && _effectivePps < maxPxPerSecond - 1e-9;

  /// Whether [zoomOut] can zoom further.
  bool get canZoomOut => hasLayout && _effectivePps > minPxPerSecond + 1e-9;

  /// Time in seconds under the centre line.
  double get centerTimeSec => _scrollSec + _width / 2 / _safePps;

  /// The time range visible in the lanes area.
  TimeRange get visibleRange {
    final start = (_scrollSec * microsPerSecond).floor();
    final end = ((_scrollSec + _width / _safePps) * microsPerSecond).ceil();
    return TimeRange(start, math.max(start, end));
  }

  /// Allowed range of [scrollTimeSec] at the current zoom and mode.
  ({double min, double max}) get scrollBounds {
    final p = _safePps, w = _width, d = _duration / microsPerSecond;
    if (centerLocked) {
      final half = w / 2 / p;
      return (min: -half, max: d - half);
    }
    final min = -freeLeadingPx / p;
    return (min: min, max: math.max(min, d + freeTrailingFraction * w / p - w / p));
  }

  /// Largest [scrollY].
  double get maxScrollY => math.max(0, _contentHeight - _height);

  /// Whether a fling is running.
  bool get isFlinging => _simX != null || _simY != null;

  /// Horizontal scroll velocity of the running fling in px/s (0 when not flinging); thumbnail
  /// loading defers during fast flings (ux.md §17.3).
  double get flingVelocityX => _simX == null ? 0 : _lastFlingVelocityX;

  /// Whether the user is moving the view (gesture in progress or fling).
  bool get isUserScrolling => _inGesture || isFlinging;

  double get _safePps => _pps > 0 ? _pps : 1;

  double get _effectivePps => _pps > 0 ? _pps : minPxPerSecond;

  // ---- Conversions -----------------------------------------------------------------------------

  /// Lanes-area x of [t].
  double xOf(TimeUs t) => TimelineMetrics.xOfTime(t, scrollTimeSec: _scrollSec, pxPerSecond: _safePps);

  /// Time (µs) at lanes-area x [x] (not quantized; callers snap to the frame grid).
  TimeUs timeAt(double x) => TimelineMetrics.timeAtX(x, scrollTimeSec: _scrollSec, pxPerSecond: _safePps);

  /// Lanes-area x of [seconds].
  double xOfSec(double seconds) => (seconds - _scrollSec) * _safePps;

  /// Seconds at lanes-area x [x].
  double secAt(double x) => _scrollSec + x / _safePps;

  // ---- Configuration ---------------------------------------------------------------------------

  /// Sets the timeline region: [size] is the whole timeline (headers + lanes, ruler included),
  /// [headerWidth] the header column and [rulerHeight] the ruler above the lanes. The first layout
  /// applies a pending "fit"; later resizes keep the centre time (centre-locked) or the left edge
  /// (free). Notifies only when something changed.
  void setViewport(Size size, double headerWidth, {double rulerHeight = 0}) {
    final w = math.max(0.0, size.width - headerWidth);
    final h = math.max(0.0, size.height - rulerHeight);
    if (w == _width && h == _height && headerWidth == _headerWidth && rulerHeight == _rulerHeight) return;
    final oldCenter = hasLayout && _pps > 0 ? centerTimeSec : null;
    _width = w;
    _height = h;
    _headerWidth = headerWidth;
    _rulerHeight = rulerHeight;
    _relayout(keepCenterSec: centerLocked ? oldCenter : null);
    _notify();
  }

  /// Sets what the timeline shows: the project [duration], [frameRate] (bounds the zoom) and the
  /// lane stack's [contentHeight]. Zoom and scroll are clamped to the new bounds.
  void setContent({TimeUs? duration, FrameRate? frameRate, double? contentHeight}) {
    final d = duration == null ? _duration : math.max(0, duration);
    final r = frameRate ?? _frameRate;
    final c = contentHeight == null ? _contentHeight : math.max(0.0, contentHeight);
    if (d == _duration && r == _frameRate && c == _contentHeight) return;
    _duration = d;
    _frameRate = r;
    _contentHeight = c;
    _relayout();
    _notify();
  }

  /// Chooses the follow mode (timeline options "Center playhead"); persisted with the project.
  /// Switching to centre-locked brings the playhead to the centre line.
  void setMode(PlayheadFollowMode mode) {
    _modeExplicit = true;
    _applyMode(mode);
    _dirtyFlush();
  }

  /// Toggles between centre-locked and free mode.
  void toggleCenterLocked() => setMode(centerLocked ? PlayheadFollowMode.free : PlayheadFollowMode.centreLocked);

  /// Updates the device default mode (Editor setting changed); applies unless the mode is
  /// explicit.
  void setDefaultMode(PlayheadFollowMode mode) {
    _defaultMode = mode;
    if (!_modeExplicit) _applyMode(mode);
  }

  /// The device default mode.
  PlayheadFollowMode get defaultMode => _defaultMode;

  /// Uses [vsync] for the fling ticker (so `TickerMode` mutes it); null uses a plain Ticker.
  void attachVsync(TickerProvider? vsync) {
    if (identical(vsync, _vsync)) return;
    final flinging = isFlinging;
    _stopFling();
    _ticker?.dispose();
    _ticker = null;
    _vsync = vsync;
    if (flinging) _settle();
  }

  void _applyMode(PlayheadFollowMode mode) {
    if (mode == _mode) return;
    _stopFling();
    _mode = mode;
    if (hasLayout && _pps > 0) {
      if (centerLocked) {
        final anchor = _playhead != null ? _clampSec(_playhead!.value / microsPerSecond) : centerTimeSec;
        _scrollSec = anchor - _width / 2 / _pps;
      }
      _scrollSec = _clampScroll(_scrollSec);
    }
    _notify();
  }

  // ---- Playhead link ---------------------------------------------------------------------------

  /// Links the playhead: the view follows [playhead] (each change, per mode) and, in centre-locked
  /// mode, user scrolling calls [onScrub] with the time under the centre line and [onScrubEnd] when
  /// the gesture or fling ends. [playing] enables free-mode paging and flushes the view when
  /// playback stops. [onScrub] is expected to move the playhead (to that frame) synchronously.
  void attachPlayhead(
    ValueListenable<TimeUs> playhead, {
    ValueListenable<bool>? playing,
    ValueChanged<TimeUs>? onScrub,
    VoidCallback? onScrubEnd,
  }) {
    detachPlayhead();
    _playhead = playhead..addListener(_onPlayheadChanged);
    _playing = playing?..addListener(_onPlayingChanged);
    _wasPlaying = playing?.value ?? false;
    _onScrub = onScrub;
    _onScrubEnd = onScrubEnd;
    _onPlayheadChanged();
  }

  /// Unlinks the playhead.
  void detachPlayhead() {
    _playhead?.removeListener(_onPlayheadChanged);
    _playing?.removeListener(_onPlayingChanged);
    _playhead = null;
    _playing = null;
    _onScrub = null;
    _onScrubEnd = null;
  }

  void _onPlayheadChanged() {
    final p = _playhead;
    if (p != null) followPlayhead(p.value, playing: _playing?.value ?? false);
  }

  void _onPlayingChanged() {
    final playing = _playing?.value ?? false;
    if (_wasPlaying && !playing) flushView();
    _wasPlaying = playing;
  }

  /// Moves the view for the playhead at [t]: centre-locked keeps it on the centre line (unless the
  /// user is scrolling, which drives the playhead instead); free mode pages during playback when it
  /// passes 90 % of the width (or leaves the view) and otherwise reveals it only when it is out of
  /// view.
  void followPlayhead(TimeUs t, {bool playing = false}) {
    if (!hasLayout || _pps <= 0 || isUserScrolling) return;
    final sec = t / microsPerSecond;
    if (centerLocked) {
      if (_setScroll(sec - _width / 2 / _pps)) _notify();
      return;
    }
    final x = xOfSec(sec);
    if (playing) {
      if (x > _width * followPageAt || x < 0) {
        if (_setScroll(sec - _width * followPageTo / _pps)) _notify();
      }
    } else if (x < 0 || x > _width) {
      ensureVisible(TimeRange(t, t));
    }
  }

  // ---- Zoom ------------------------------------------------------------------------------------

  /// Multiplies the zoom by [factor], keeping the time under [anchorX] fixed (free mode) or the
  /// playhead on the centre line (centre-locked: [anchorX] is ignored). Clamped to the zoom range.
  void zoomBy(double factor, {required double anchorX}) {
    if (!hasLayout || !factor.isFinite || factor <= 0) return;
    _zoomTo(_effectivePps * factor, anchorX: anchorX);
  }

  /// Sets the zoom to [pxPerSecond] (clamped), anchored like [zoomBy] (default anchor: the
  /// playhead when visible, else the centre).
  void setPxPerSecond(double pxPerSecond, {double? anchorX}) {
    if (!hasLayout || !pxPerSecond.isFinite || pxPerSecond <= 0) return;
    _zoomTo(pxPerSecond, anchorX: anchorX ?? _defaultAnchorX());
  }

  /// Zooms in one step (×1.5).
  void zoomIn() => setPxPerSecond(_effectivePps * zoomStep);

  /// Zooms out one step (÷1.5).
  void zoomOut() => setPxPerSecond(_effectivePps / zoomStep);

  /// Fits the whole project with a 5 % margin on each side (clamped to the zoom range; long
  /// projects get the smallest zoom, which shows them plus 10 s). Free mode centres the project;
  /// centre-locked mode keeps the playhead on the centre line. Before the first layout the fit is
  /// applied when the size is known.
  void zoomToFit() {
    if (!hasLayout) {
      _fitPending = true;
      return;
    }
    _stopFling();
    _fit();
    _notify();
    _dirtyFlush();
  }

  void _zoomTo(double target, {required double anchorX}) {
    final pps = target.clamp(minPxPerSecond, maxPxPerSecond);
    if (_pps > 0 && (pps - _pps).abs() < 1e-12) return;
    if (_pps <= 0) _fit();
    final ax = centerLocked ? _width / 2 : anchorX;
    final anchorSec = centerLocked ? _centerAnchorSec() : secAt(ax);
    _stopFlingKeepScrub();
    _pps = pps;
    _fitPending = false;
    _scrollSec = _clampScroll(anchorSec - ax / _pps);
    _notify();
    _dirtyFlush();
  }

  double _defaultAnchorX() {
    if (centerLocked) return _width / 2;
    final p = _playhead;
    if (p != null) {
      final x = xOf(p.value);
      if (x >= 0 && x <= _width) return x;
    }
    return _width / 2;
  }

  double _centerAnchorSec() {
    final p = _playhead;
    if (p != null && !isUserScrolling) return _clampSec(p.value / microsPerSecond);
    return centerTimeSec;
  }

  void _fit() {
    final d = _duration / microsPerSecond;
    final target = d > 0 ? _width * (1 - 2 * fitMargin) / d : minPxPerSecond;
    _pps = target.clamp(minPxPerSecond, maxPxPerSecond);
    _fitPending = false;
    if (centerLocked) {
      final anchor = _playhead != null ? _clampSec(_playhead!.value / microsPerSecond) : _clampSec(_scrollSec);
      _scrollSec = _clampScroll(anchor - _width / 2 / _pps);
    } else if (d > 0) {
      // Centre the project: a 5 % margin each side, or half of the smallest zoom's 10 s for long
      // projects (where the 5 % margins would need a zoom below the smallest).
      _scrollSec = _clampScroll(d / 2 - _width / 2 / _pps);
    } else {
      _scrollSec = _clampScroll(-fitMargin * _width / _pps);
    }
  }

  // ---- Scroll ----------------------------------------------------------------------------------

  /// Moves the view by ([dx], [dy]) px: positive dx shows later times, positive dy lower lanes (a
  /// drag passes the negated finger delta, a mouse wheel its `scrollDelta`). In centre-locked mode
  /// horizontal scrolling scrubs. Outside a gesture the move settles at once.
  void scrollByPx(double dx, double dy) {
    if (!hasLayout) return;
    if (!_inGesture) _stopFlingKeepScrub();
    var changed = false;
    if (dx != 0 && dx.isFinite) changed = _setScroll(_scrollSec + dx / _safePps, user: true);
    if (dy != 0 && dy.isFinite) changed = _setScrollY(_scrollY + dy) || changed;
    if (changed) _notify();
    if (!isUserScrolling) _settle();
  }

  /// Puts [scrollTimeSec] and/or [scrollY] at the given values (clamped) without scrubbing.
  void jumpTo({double? scrollTimeSec, double? scrollY}) {
    if (!hasLayout) return;
    _stopFling();
    var changed = false;
    if (scrollTimeSec != null) changed = _setScroll(scrollTimeSec);
    if (scrollY != null) changed = _setScrollY(scrollY) || changed;
    if (changed) {
      _notify();
      _dirtyFlush();
    }
  }

  /// Starts a user gesture (pan or pinch): stops a running fling and suspends playhead following
  /// until [endGesture].
  void beginGesture() {
    _stopFlingKeepScrub();
    _inGesture = true;
  }

  /// Ends the user gesture; with a fast enough [velocity] (the finger's, as in
  /// `ScaleEndDetails.velocity`) the view flings, otherwise it settles (scrub end, ViewState).
  void endGesture({Velocity velocity = Velocity.zero}) {
    _inGesture = false;
    fling(velocity);
  }

  /// Flings with the finger [velocity] of the ending drag (content follows the finger): one
  /// platform scroll simulation per axis, driven by a Ticker, always ending inside the bounds.
  void fling(Velocity velocity) {
    _stopFlingKeepScrub();
    if (!hasLayout) {
      if (!_inGesture) _settle();
      return;
    }
    final vx = -velocity.pixelsPerSecond.dx, vy = -velocity.pixelsPerSecond.dy;
    final b = scrollBounds;
    final p = _safePps;
    if (vx.abs() >= kMinFlingVelocity && b.max > b.min) {
      _simX = _simulation(_scrollSec * p, vx, b.min * p, b.max * p);
      _simXBounces = _platformBounces;
      _flingPps = p;
      _lastFlingVelocityX = vx;
    }
    if (vy.abs() >= kMinFlingVelocity && maxScrollY > 0) {
      _simY = _simulation(_scrollY, vy, 0, maxScrollY);
    }
    if (!isFlinging) {
      if (!_inGesture) _settle();
      return;
    }
    _ticker ??= _vsync?.createTicker(_onTick) ?? Ticker(_onTick, debugLabel: 'TimelineViewport.fling');
    _ticker!.start();
    _notify();
  }

  /// Stops a running fling and settles.
  void stopFling() {
    if (!isFlinging) return;
    _stopFlingKeepScrub();
    if (!_inGesture) _settle();
    _notify();
  }

  bool get _platformBounces => _platform == TargetPlatform.iOS || _platform == TargetPlatform.macOS;

  Simulation _simulation(double position, double velocity, double min, double max) {
    const tolerance = Tolerance(distance: 0.25, velocity: 5);
    if (_platformBounces) {
      return BouncingScrollSimulation(
        position: position,
        velocity: velocity,
        leadingExtent: min,
        trailingExtent: math.max(min, max),
        spring: SpringDescription.withDampingRatio(mass: 0.5, stiffness: 100, ratio: 1.1),
        tolerance: tolerance,
      );
    }
    return ClampingScrollSimulation(position: position, velocity: velocity, tolerance: tolerance);
  }

  void _onTick(Duration elapsed) {
    final t = elapsed.inMicroseconds / microsPerSecond;
    var changed = false;
    final sx = _simX;
    if (sx != null) {
      final done = sx.isDone(t);
      final sec = sx.x(t) / _flingPps;
      _lastFlingVelocityX = sx.dx(t);
      if (_simXBounces && !done) {
        changed = _setScroll(sec, user: true, clamp: false) || changed;
      } else {
        final b = scrollBounds;
        changed = _setScroll(sec, user: true) || changed;
        if (done || sec < b.min || sec > b.max) _simX = null;
      }
      if (done) _simX = null;
    }
    final sy = _simY;
    if (sy != null) {
      final done = sy.isDone(t);
      final y = sy.x(t);
      changed = _setScrollY(y) || changed;
      if (done || y < 0 || y > maxScrollY) _simY = null;
    }
    if (!isFlinging) {
      _ticker?.stop();
      // A bouncing simulation may stop a hair outside; rest inside the bounds.
      _scrollSec = _clampScroll(_scrollSec);
      _lastFlingVelocityX = 0;
      if (!_inGesture) _settle();
      changed = true;
    }
    if (changed) _notify();
  }

  void _stopFlingKeepScrub() {
    if (_ticker?.isActive ?? false) _ticker!.stop();
    if (_simX != null || _simY != null) {
      _simX = null;
      _simY = null;
      _lastFlingVelocityX = 0;
      _scrollSec = _clampScroll(_scrollSec);
    }
  }

  void _stopFling() {
    final was = isFlinging;
    _stopFlingKeepScrub();
    if (was && !_inGesture) _settle();
  }

  /// Scrolls the least so [range] is visible with [margin] px (free mode; when wider than the view,
  /// its start is shown). Centre-locked mode never moves away from the playhead: returns false.
  bool ensureVisible(TimeRange range, {double margin = revealMarginPx}) {
    if (!hasLayout || _pps <= 0 || centerLocked) return false;
    final m = math.min(margin, _width / 4);
    final xs = xOf(range.start), xe = xOf(range.end);
    double? target;
    if (xs < m || xe - xs > _width - 2 * m) {
      target = range.start / microsPerSecond - m / _pps;
    } else if (xe > _width - m) {
      target = range.end / microsPerSecond - (_width - m) / _pps;
    }
    if (target == null) return false;
    _stopFling();
    final changed = _setScroll(target);
    if (changed) {
      _notify();
      _dirtyFlush();
    }
    return changed;
  }

  /// Scrolls the lanes the least so content band [top]…[bottom] is visible (its top when taller
  /// than the lanes area).
  bool ensureVisibleY(double top, double bottom) {
    if (_height <= 0) return false;
    double? target;
    if (top < _scrollY || bottom - top > _height) {
      target = top;
    } else if (bottom > _scrollY + _height) {
      target = bottom - _height;
    }
    if (target == null) return false;
    final changed = _setScrollY(target);
    if (changed) {
      _notify();
      _dirtyFlush();
    }
    return changed;
  }

  bool _setScroll(double sec, {bool user = false, bool clamp = true}) {
    if (!sec.isFinite) return false;
    final v = clamp ? _clampScroll(sec) : sec;
    if (v == _scrollSec) return false;
    _scrollSec = v;
    if (user && centerLocked) {
      _scrubbing = true;
      _onScrub?.call((_clampSec(centerTimeSec) * microsPerSecond).round());
    }
    return true;
  }

  bool _setScrollY(double y) {
    final v = y.clamp(0.0, maxScrollY);
    if (v == _scrollY) return false;
    _scrollY = v;
    return true;
  }

  double _clampScroll(double sec) {
    final b = scrollBounds;
    return sec.clamp(b.min, b.max);
  }

  double _clampSec(double sec) => sec.clamp(0.0, _duration / microsPerSecond);

  void _relayout({double? keepCenterSec}) {
    if (hasLayout) {
      if (_fitPending || _pps <= 0) {
        _fit();
      } else {
        _pps = _pps.clamp(minPxPerSecond, maxPxPerSecond);
        if (keepCenterSec != null) _scrollSec = keepCenterSec - _width / 2 / _pps;
        _scrollSec = _clampScroll(_scrollSec);
      }
    }
    _scrollY = _scrollY.clamp(0.0, maxScrollY);
  }

  /// Ends a scrub (if one ran) and writes the ViewState.
  void _settle() {
    if (_scrubbing) {
      _scrubbing = false;
      _onScrubEnd?.call();
    }
    flushView();
  }

  void _dirtyFlush() {
    if (!isUserScrolling) flushView();
  }

  // ---- Persistence (ViewState) -----------------------------------------------------------------

  /// Adopts the project's saved [view]: zoom (0 = fit on the next layout), scroll and an explicit
  /// follow mode. Does not write back.
  void restore(ViewState view) {
    _stopFlingKeepScrub();
    _restored = true;
    if (view.followMode != null) {
      _modeExplicit = true;
      _mode = view.followMode!;
    }
    if (view.pixelsPerSecond > 0 && view.pixelsPerSecond.isFinite) {
      _pps = view.pixelsPerSecond;
      _fitPending = false;
    } else {
      _pps = 0;
      _fitPending = true;
    }
    _scrollSec = view.scrollTimeUs / microsPerSecond;
    _scrollY = view.scrollLanePx.isFinite ? math.max(0.0, view.scrollLanePx) : 0;
    _relayout();
    _flushed = _key(view.pixelsPerSecond, view.scrollTimeUs, view.scrollLanePx, view.followMode);
    _notify();
    // Centre-locked: the playhead, not the saved scroll, decides what is under the centre line.
    _onPlayheadChanged();
  }

  /// [view] with this viewport's zoom, scroll and (when explicit) follow mode.
  ViewState writeTo(ViewState view) => view.copyWith(
        pixelsPerSecond: _pps,
        scrollTimeUs: (_scrollSec * microsPerSecond).round(),
        scrollLanePx: _scrollY,
        followMode: _modeExplicit ? _mode : null,
      );

  /// Sends settled changes to [sink] (usually `EditSession.updateView`); null detaches.
  void attachViewSink(ViewStateSink? sink) => _viewSink = sink;

  /// Writes the current view to the sink if it changed since the last write (call before saving,
  /// on hide and on close).
  void flushView() {
    final sink = _viewSink;
    if (sink == null || _disposed) return;
    final key = _key(_pps, (_scrollSec * microsPerSecond).round(), _scrollY, _modeExplicit ? _mode : null);
    if (key == _flushed) return;
    _flushed = key;
    sink(writeTo);
  }

  static (double, int, double, PlayheadFollowMode?) _key(double pps, int scrollUs, double y, PlayheadFollowMode? mode) =>
      (pps, scrollUs, y, mode);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    detachPlayhead();
    _ticker?.dispose();
    _ticker = null;
    _simX = null;
    _simY = null;
    _viewSink = null;
    super.dispose();
  }
}

/// Builds the value of `viewportProvider` for [id]: a controller in the device default follow
/// mode (Editor setting "Center playhead" on touch devices), kept in step with that setting.
///
/// It is not kept alive on its own: zoom and scroll live in the project's ViewState, so the view is
/// written there when the last listener goes away and restored (`restore`) by the timeline when a
/// new controller is created.
TimelineViewportController createViewportController(Ref<Object?> ref, ProjectId id) {
  final prefs = ref.read(editorPrefsProvider);
  PlayheadFollowMode deviceDefault() =>
      TimelineViewportController.defaultModeFor(defaultTargetPlatform, centerPlayheadOnTouch: prefs.centerPlayheadOnTouch);
  final controller = TimelineViewportController(defaultMode: deviceDefault());
  void onPrefs() => controller.setDefaultMode(deviceDefault());
  prefs.addListener(onPrefs);
  // The last listener left (the timeline unmounted): write the view while the session is open.
  ref.onCancel(controller.flushView);
  ref.onDispose(() {
    prefs.removeListener(onPrefs);
    controller.dispose();
  });
  return controller;
}
