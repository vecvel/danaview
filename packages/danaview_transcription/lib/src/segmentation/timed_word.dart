// OWNER: AI-11
//
// Inputs of the caption segmenter (ai.md §9.1): timed words on the TIMELINE and the context.

import 'dart:ui' show Size, TextDirection;

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';
import 'package:danaview_editor_core/model.dart';

import '../languages/languages.dart';
import 'caption_text.dart';

/// One recognized word on the timeline.
@immutable
final class TimedWord {
  /// Creates a word. [clip] feeds the cut-point penalty (a cue spanning two clips).
  const TimedWord(
      {required this.text, required this.start, required this.end, this.p = 1, this.clip = const ItemId('')});

  /// Word text (trimmed by the segmenter).
  final String text;

  /// Start, timeline µs.
  final TimeUs start;

  /// End, timeline µs.
  final TimeUs end;

  /// Recognition probability, 0..1.
  final double p;

  /// The clip the word came from.
  final ItemId clip;

  /// Ends a sentence: `. ? ! …` and the CJK, Arabic and Devanagari equivalents, ignoring closing
  /// quotes and brackets after it.
  bool get endsSentence => endsSentenceText(text);

  /// Ends a clause: `, ; : — 、 ， ؛`.
  bool get endsClause => endsClauseText(text);

  /// A copy with the given fields replaced.
  TimedWord copyWith({String? text, TimeUs? start, TimeUs? end, double? p, ItemId? clip}) => TimedWord(
      text: text ?? this.text,
      start: start ?? this.start,
      end: end ?? this.end,
      p: p ?? this.p,
      clip: clip ?? this.clip);

  @override
  bool operator ==(Object other) =>
      other is TimedWord &&
      other.text == text &&
      other.start == start &&
      other.end == end &&
      other.p == p &&
      other.clip == clip;

  @override
  int get hashCode => Object.hash(text, start, end, p, clip);

  @override
  String toString() => 'TimedWord($start..$end)';
}

/// Everything the segmenter needs besides the words.
@immutable
final class SegmentationContext {
  /// Creates a context.
  SegmentationContext({
    required this.script,
    required this.settings,
    required this.frameRate,
    Iterable<TimeUs> cutPoints = const [],
    this.direction = TextDirection.ltr,
    this.portrait = false,
    this.language,
  }) : cutPoints = List.unmodifiable((cutPoints.toSet().toList())..sort());

  /// Builds the context of a project: the script profile and direction come from the spoken
  /// [languageCode] (a whisper code; unknown codes fall back to space-delimited LTR), 9:16, 4:5
  /// and 1:1 canvases use the narrow defaults.
  factory SegmentationContext.forProject({
    required String languageCode,
    required SegmentationSettings settings,
    required FrameRate frameRate,
    Iterable<TimeUs> cutPoints = const [],
    Size? canvasSize,
  }) {
    final lang = languageForWhisperCode(languageCode);
    return SegmentationContext(
      script: lang?.script ?? ScriptProfile.spaceDelimited,
      settings: settings,
      frameRate: frameRate,
      cutPoints: cutPoints,
      direction: (lang?.rtl ?? false) ? TextDirection.rtl : TextDirection.ltr,
      portrait: canvasSize != null && canvasSize.width <= canvasSize.height,
      language: languageCode,
    );
  }

  /// Script profile (limits, atoms).
  final ScriptProfile script;

  /// Preset and overrides.
  final SegmentationSettings settings;

  /// Project frame rate: cue edges snap to its grid.
  final FrameRate frameRate;

  /// Clip boundaries (timeline µs), sorted and unique; cues avoid straddling them.
  final List<TimeUs> cutPoints;

  /// Paragraph direction (text keeps logical order; the renderer decides).
  final TextDirection direction;

  /// Whether the canvas is 9:16, 4:5 or 1:1 (narrow defaults: 32 characters per line).
  final bool portrait;

  /// Spoken language (whisper code) for the function-word lists; null = none.
  final String? language;

  @override
  bool operator ==(Object other) =>
      other is SegmentationContext &&
      other.script == script &&
      other.settings == settings &&
      other.frameRate == frameRate &&
      const ListEquality<TimeUs>().equals(other.cutPoints, cutPoints) &&
      other.direction == direction &&
      other.portrait == portrait &&
      other.language == language;

  @override
  int get hashCode =>
      Object.hash(script, settings, frameRate, Object.hashAll(cutPoints), direction, portrait, language);
}
