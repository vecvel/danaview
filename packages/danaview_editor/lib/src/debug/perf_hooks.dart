// OWNER: UX-01
//
// Performance hooks for QA-04 (ARCH §18.2): named spans that go to the `dart:developer` timeline
// (DevTools, `flutter drive --profile` timelines) and, when enabled, to an in-memory sample buffer
// and a listener the perf integration tests read. No-ops in release builds; disabled by default.
// Samples carry names and numbers only (never media paths or user content).

import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

/// Well-known span names measured by QA-04 (ARCH §18.2 rows owned by the UI).
///
/// See ARCH §18.2, BUILD_PLAN QA-04.
abstract final class EditorPerfMarks {
  /// Projects screen route push → first frame with content (UX-05).
  static const String projectsFirstPaint = 'editor.projects.firstPaint';

  /// Editor open → first preview frame (UX-07/UX-08).
  static const String editorOpenToFirstFrame = 'editor.open.firstFrame';

  /// `EditorController.apply` commit → preview patch acknowledged (UX-08).
  static const String commitToPreview = 'editor.commit.preview';

  /// Main-isolate time blocked by an autosave request (UX-08).
  static const String autosaveBlock = 'editor.autosave.block';

  /// Scrub input → displayed frame (UX-14).
  static const String scrubLag = 'editor.scrub.lag';

  /// Thumbnail request miss → painted strip (UX-20).
  static const String thumbnailMiss = 'editor.thumbnail.miss';

  /// One timeline canvas paint (UX-10).
  static const String timelinePaint = 'editor.timeline.paint';

  /// One `dryRun` during a drag (UX-13).
  static const String dragDryRun = 'editor.drag.dryRun';

  /// Every mark above.
  static const List<String> all = [
    projectsFirstPaint,
    editorOpenToFirstFrame,
    commitToPreview,
    autosaveBlock,
    scrubLag,
    thumbnailMiss,
    timelinePaint,
    dragDryRun,
  ];
}

/// One measured span.
///
/// See ARCH §18.2.
@immutable
final class EditorPerfSample {
  /// Creates a sample.
  const EditorPerfSample(this.name, this.elapsed, {this.args = const {}});

  /// Span name (see [EditorPerfMarks]).
  final String name;

  /// Duration.
  final Duration elapsed;

  /// Numeric or short enum-like details (item counts, frame index); never paths or content.
  final Map<String, Object?> args;

  @override
  String toString() => '$name ${elapsed.inMicroseconds}µs $args';
}

/// An open span returned by [EditorPerfHooks.begin].
///
/// See ARCH §18.2.
final class EditorPerfSpan {
  EditorPerfSpan._(this.name, this._task, this._watch);

  /// Span name.
  final String name;

  final developer.TimelineTask? _task;
  final Stopwatch? _watch;
  bool _ended = false;

  /// Ends the span (once; later calls are ignored) and records it.
  void end({Map<String, Object?> args = const {}}) {
    if (_ended) return;
    _ended = true;
    _task?.finish(arguments: args.isEmpty ? null : args);
    final watch = _watch;
    if (watch != null) EditorPerfHooks.record(EditorPerfSample(name, watch.elapsed, args: args));
  }
}

/// Entry points for perf measurement.
///
/// See ARCH §18.2, BUILD_PLAN QA-04.
abstract final class EditorPerfHooks {
  /// Whether hooks can run in this build mode (debug and profile).
  static const bool available = !kReleaseMode;

  /// Whether samples are recorded (timeline events are emitted whenever [available]).
  static bool enabled = false;

  /// Called for every recorded sample while [enabled].
  static void Function(EditorPerfSample sample)? listener;

  /// Maximum buffered samples (oldest dropped first).
  static const int capacity = 4096;

  static final List<EditorPerfSample> _samples = <EditorPerfSample>[];

  /// Buffered samples, oldest first.
  static List<EditorPerfSample> get samples => List.unmodifiable(_samples);

  /// Buffered samples named [name].
  static List<EditorPerfSample> samplesOf(String name) => _samples.where((s) => s.name == name).toList(growable: false);

  /// Clears the buffer.
  static void clear() => _samples.clear();

  /// Records an externally measured sample (e.g. a native `applyMs`).
  static void record(EditorPerfSample sample) {
    if (!available || !enabled) return;
    if (_samples.length >= capacity) _samples.removeAt(0);
    _samples.add(sample);
    listener?.call(sample);
  }

  /// Times [body] synchronously.
  static T timeSync<T>(String name, T Function() body, {Map<String, Object?> args = const {}}) {
    if (!available) return body();
    final watch = enabled ? (Stopwatch()..start()) : null;
    developer.Timeline.startSync(name, arguments: args.isEmpty ? null : args);
    try {
      return body();
    } finally {
      developer.Timeline.finishSync();
      if (watch != null) record(EditorPerfSample(name, watch.elapsed, args: args));
    }
  }

  /// Times an asynchronous [body].
  static Future<T> timeAsync<T>(String name, Future<T> Function() body, {Map<String, Object?> args = const {}}) async {
    final span = begin(name);
    try {
      return await body();
    } finally {
      span.end(args: args);
    }
  }

  /// Opens a span that ends later (e.g. open → first frame across callbacks).
  static EditorPerfSpan begin(String name) {
    if (!available) return EditorPerfSpan._(name, null, null);
    final task = developer.TimelineTask()..start(name);
    return EditorPerfSpan._(name, task, enabled ? (Stopwatch()..start()) : null);
  }
}
