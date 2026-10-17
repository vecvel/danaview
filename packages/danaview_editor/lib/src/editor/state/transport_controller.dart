// OWNER: UX-14
//
// TransportController (ux.md §7.6): play/pause, loop range, frame stepping with press-and-hold
// repeat, ±1 s, previous/next edit point or marker, start/end, and the fullscreen-preview flag.
// It is the policy layer over [PlayheadController], which owns the preview clock, seeks and the
// play state; nothing here changes per playback frame.
//
// * Edit points ([EditPoints]): every item start and end on every lane, every marker, and the
//   project start and end, sorted and de-duplicated; "previous" is the nearest point before the
//   playhead and "next" the nearest after it (a binary search over a list that is rebuilt only
//   when the timeline changes).
// * Frame stepping pauses playback first. The press-and-hold repeat of the transport buttons
//   steps once at once, waits 400 ms, then steps at 8 Hz (ux.md §7.6); the hardware keyboard's
//   own key repeat reaches the actions directly.
// * Fullscreen: `fullscreen` is a request flag. The `F` shortcut, the transport button and the
//   `fullscreenPreview` action toggle it; the preview region (UX-18) pushes or pops the fullscreen
//   route to match and resets the flag when the route is dismissed.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/model.dart' show EditProject, ProjectId, TimeRange, TimeUs, Timeline, microsPerSecond;

import '../../app/editor_providers.dart';
import 'playhead_controller.dart';

/// The edit points of a project: where the transport's previous/next buttons stop.
@immutable
final class EditPoints {
  const EditPoints._(this._times);

  /// No edit points.
  static const EditPoints empty = EditPoints._(<TimeUs>[]);

  final List<TimeUs> _times;

  /// Collects the edit points of [project]: item edges, markers, the project start and end.
  factory EditPoints.of(EditProject project) {
    final set = <TimeUs>{0, project.duration};
    for (final track in project.tracks) {
      for (final item in track.items) {
        set
          ..add(item.start)
          ..add(item.end);
      }
    }
    for (final marker in project.markers) {
      set.add(marker.time);
    }
    final list = Int64List.fromList(set.toList())..sort();
    return EditPoints._(List<TimeUs>.unmodifiable(list));
  }

  /// The points, ascending.
  List<TimeUs> get times => _times;

  /// The nearest point strictly before [t], or null.
  TimeUs? previous(TimeUs t) {
    var lo = 0, hi = _times.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_times[mid] < t) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo == 0 ? null : _times[lo - 1];
  }

  /// The nearest point strictly after [t], or null.
  TimeUs? next(TimeUs t) {
    var lo = 0, hi = _times.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_times[mid] <= t) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo >= _times.length ? null : _times[lo];
  }
}

/// Play state, loop range, stepping and jumps (ux.md §7.6).
class TransportController {
  /// Creates the controller over [playhead]. [project] returns the committed project (edit points
  /// and the end of the project), or null before the editor opened.
  TransportController({
    required this.playhead,
    required EditProject? Function() project,
    this.repeatDelay = const Duration(milliseconds: 400),
    this.repeatInterval = const Duration(milliseconds: 125),
  }) : _project = project;

  /// The playhead this controller drives.
  final PlayheadController playhead;

  /// How long a held step button waits before it repeats.
  final Duration repeatDelay;

  /// Interval of the repeat (8 Hz).
  final Duration repeatInterval;

  final EditProject? Function() _project;
  final ValueNotifier<TimeRange?> _loop = ValueNotifier<TimeRange?>(null);
  final ValueNotifier<bool> _fullscreen = ValueNotifier<bool>(false);

  Timeline? _pointsFor;
  EditPoints _points = EditPoints.empty;
  Timer? _repeatDelayTimer;
  Timer? _repeatTimer;
  bool _disposed = false;

  /// Whether playback is running.
  ValueListenable<bool> get playing => playhead.playing;

  /// The loop range of playback, or null.
  ValueListenable<TimeRange?> get loop => _loop;

  /// Whether the fullscreen preview is requested.
  ValueListenable<bool> get fullscreen => _fullscreen;

  /// Playback rate (1: the preview always plays in real time).
  double get rate => 1;

  /// Whether playback can start: a preview exists and the project has content.
  bool get canPlay => playhead.preview != null && playhead.duration > 0;

  /// Whether the playhead can move (the editor is open).
  bool get canSeek => _project() != null;

  /// The edit points of the committed project.
  EditPoints get editPoints {
    final project = _project();
    if (project == null) return EditPoints.empty;
    final timeline = project.timeline;
    if (!identical(timeline, _pointsFor)) {
      _points = EditPoints.of(project);
      _pointsFor = timeline;
    }
    return _points;
  }

  // ---- Play / pause ----------------------------------------------------------------------------

  /// Starts playback from the playhead (from the start when it rests at the end, from the loop's
  /// start when it is outside the loop range).
  Future<void> play() async {
    if (!canPlay || _disposed) return;
    if (playing.value) return;
    final range = _loop.value;
    var from = playhead.value;
    if (range != null && !range.isEmpty) {
      if (from < range.start || from >= range.end) from = range.start;
    } else if (from >= playhead.duration) {
      from = 0;
    }
    try {
      if (from != playhead.value) await playhead.seekExact(from);
      await playhead.play(loop: range);
    } catch (e) {
      _report(e, 'starting playback');
    }
  }

  /// Pauses playback.
  Future<void> pause() async {
    if (_disposed || !playing.value) return;
    try {
      await playhead.pause();
    } catch (e) {
      _report(e, 'pausing playback');
    }
  }

  /// Plays when paused, pauses when playing.
  Future<void> togglePlay() => playing.value ? pause() : play();

  /// Sets (or clears) the loop range. While playing, playback restarts inside the new range.
  Future<void> setLoop(TimeRange? range) async {
    if (_disposed) return;
    final next = range == null || range.isEmpty ? null : range;
    if (next == _loop.value) return;
    _loop.value = next;
    if (playing.value) {
      try {
        if (next != null && !next.contains(playhead.value)) await playhead.seekExact(next.start);
        await playhead.play(loop: next);
      } catch (e) {
        _report(e, 'changing the loop');
      }
    }
  }

  // ---- Seeking ---------------------------------------------------------------------------------

  /// Moves the playhead to [t] (clamped to the project, quantized to the frame grid).
  Future<void> seekTo(TimeUs t) async {
    if (!canSeek || _disposed) return;
    try {
      await playhead.seekExact(t);
    } catch (e) {
      _report(e, 'seeking');
    }
  }

  /// Steps [frames] frames (negative: back) after pausing; stops at the project start and end.
  Future<void> stepFrames(int frames) async {
    if (!canSeek || _disposed || frames == 0) return;
    final rate = playhead.frameRate;
    final last = rate.frameIndexOf(playhead.duration);
    var k = rate.frameIndexOf(playhead.value) + frames;
    if (k < 0) k = 0;
    if (k > last) k = last;
    final target = rate.timeOfFrame(k);
    if (playing.value) await pause();
    if (target == playhead.value) return;
    await seekTo(target);
  }

  /// Moves [seconds] seconds (negative: back) after pausing.
  Future<void> stepSeconds(int seconds) async {
    if (!canSeek || _disposed || seconds == 0) return;
    if (playing.value) await pause();
    final target = playhead.value + seconds * microsPerSecond;
    await seekTo(target);
  }

  /// Jumps to the previous edit point or marker (the project start when there is none).
  Future<void> previousEditPoint() async {
    if (!canSeek || _disposed) return;
    if (playing.value) await pause();
    final t = editPoints.previous(playhead.value);
    if (t != null) await seekTo(t);
  }

  /// Jumps to the next edit point or marker.
  Future<void> nextEditPoint() async {
    if (!canSeek || _disposed) return;
    if (playing.value) await pause();
    final t = editPoints.next(playhead.value);
    if (t != null) await seekTo(t);
  }

  /// Jumps to the start of the project.
  Future<void> goStart() async {
    if (!canSeek || _disposed) return;
    if (playing.value) await pause();
    await seekTo(0);
  }

  /// Jumps to the end of the project.
  Future<void> goEnd() async {
    if (!canSeek || _disposed) return;
    if (playing.value) await pause();
    await seekTo(playhead.duration);
  }

  // ---- Press and hold --------------------------------------------------------------------------

  /// A step button went down: steps [direction] frames at once, then repeats after
  /// [repeatDelay] every [repeatInterval] until [stopStepRepeat].
  void startStepRepeat(int direction) {
    if (_disposed) return;
    stopStepRepeat();
    final step = direction < 0 ? -1 : 1;
    unawaited(stepFrames(step));
    _repeatDelayTimer = Timer(repeatDelay, () {
      _repeatDelayTimer = null;
      _repeatTimer = Timer.periodic(repeatInterval, (_) => unawaited(stepFrames(step)));
    });
  }

  /// The step button was released.
  void stopStepRepeat() {
    _repeatDelayTimer?.cancel();
    _repeatDelayTimer = null;
    _repeatTimer?.cancel();
    _repeatTimer = null;
  }

  /// Whether a held step button is repeating.
  bool get isRepeating => _repeatDelayTimer != null || _repeatTimer != null;

  // ---- Fullscreen ------------------------------------------------------------------------------

  /// Requests (or dismisses) the fullscreen preview.
  void setFullscreen(bool on) {
    if (_disposed) return;
    _fullscreen.value = on;
  }

  /// Toggles the fullscreen preview.
  void toggleFullscreen() => setFullscreen(!_fullscreen.value);

  // ---- Plumbing --------------------------------------------------------------------------------

  void _report(Object e, String what) {
    // Logging only (ARCH §19 rule 3): never media paths or user text. A failing preview is
    // reported by the engine's events; the transport just stays where it is.
    debugPrint('danaview_editor: error while $what: ${e.runtimeType}');
  }

  /// Releases timers and notifiers.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    stopStepRepeat();
    _loop.dispose();
    _fullscreen.dispose();
  }
}

/// Builds the value of `transportProvider` for [id]. Kept alive until the editor has closed.
TransportController createTransportController(Ref<Object?> ref, ProjectId id) {
  final playhead = ref.watch(playheadProvider(id));
  final session = ref.watch(editorSessionProvider(id));
  final controller = TransportController(playhead: playhead, project: () => session.committedProject);
  final link = ref.keepAlive();
  var wasOpen = session.isOpen;
  void onAttached() {
    final open = session.isOpen;
    if (wasOpen && !open) link.close();
    wasOpen = open;
  }

  session.attached.addListener(onAttached);
  ref.onDispose(() {
    session.attached.removeListener(onAttached);
    controller.dispose();
  });
  return controller;
}
