// OWNER: AI-11
//
// Presets and limits (ai.md §9.2): the table of line counts, characters per line, durations,
// reading speeds and gaps, resolved for a preset, a script profile, a canvas shape and the user's
// overrides.

import 'package:meta/meta.dart';
import 'package:danaview_editor_core/model.dart';

import '../catalog/tuning.dart';
import '../languages/languages.dart';

/// The resolved limits one segmentation run uses.
@immutable
final class CaptionLayout {
  /// Creates a layout.
  const CaptionLayout({
    required this.maxLines,
    required this.maxCharsPerLine,
    required this.maxCps,
    required this.minDurationUs,
    required this.maxDurationUs,
    required this.minGapFrames,
    required this.lingerUs,
    required this.chainGapUs,
  });

  /// Resolves the limits of [settings] for [script]. [portrait] selects the 32-character line of
  /// 9:16, 4:5 and 1:1 canvases for space-delimited scripts. A non-zero override in [settings]
  /// wins over the preset.
  factory CaptionLayout.resolve(SegmentationSettings settings, ScriptProfile script, {bool portrait = false}) {
    final preset = settings.preset;
    final short = preset == SegmentationPreset.shortPhrases;

    final int lines = short || preset == SegmentationPreset.singleLine ? 1 : 2;
    final int chars;
    final double cps;
    switch (script) {
      case ScriptProfile.spaceDelimited:
        chars = short ? 20 : (portrait ? 32 : SpeechTuning.standardMaxCharsPerLine);
        cps = short ? 20 : SpeechTuning.standardMaxCps;
      case ScriptProfile.cjk:
        chars = short ? 8 : 16;
        cps = short ? 10 : 9;
      case ScriptProfile.korean:
        chars = short ? 10 : 18;
        cps = short ? 14 : 12;
      case ScriptProfile.noSpace:
        chars = short ? 16 : 35;
        cps = short ? 20 : SpeechTuning.standardMaxCps;
    }
    return CaptionLayout(
      maxLines: settings.maxLines > 0 ? settings.maxLines : lines,
      maxCharsPerLine: settings.maxCharsPerLine > 0 ? settings.maxCharsPerLine : chars,
      maxCps: settings.maxCharsPerSecond > 0 ? settings.maxCharsPerSecond : cps,
      minDurationUs: short ? 400000 : 830000,
      maxDurationUs: switch (preset) {
        SegmentationPreset.standard => 7000000,
        SegmentationPreset.singleLine => 5000000,
        SegmentationPreset.shortPhrases => 2500000,
      },
      minGapFrames: short ? 0 : 2,
      lingerUs: short ? 100000 : 200000,
      chainGapUs: short ? 300000 : 500000,
    );
  }

  /// Lines per cue.
  final int maxLines;

  /// Graphemes per line.
  final int maxCharsPerLine;

  /// Soft reading-speed limit, graphemes per second.
  final double maxCps;

  /// Shortest cue; shorter ones are extended into silence when the next cue allows.
  final TimeUs minDurationUs;

  /// Longest cue (a hard limit of `maxDuration + 0.5 s` applies to the words' span).
  final TimeUs maxDurationUs;

  /// Frames between a cue's end and the next cue's start (0 = back-to-back allowed).
  final int minGapFrames;

  /// How long a cue stays after its last word.
  final TimeUs lingerUs;

  /// Cues closer than this are chained: the earlier one stays until the next begins.
  final TimeUs chainGapUs;

  /// The default preset for a canvas: Standard for 16:9, 4:3 and 21:9; Single line for 9:16, 4:5
  /// and 1:1 (ai.md §9.2).
  static SegmentationPreset defaultPresetFor({required bool portrait}) =>
      portrait ? SegmentationPreset.singleLine : SegmentationPreset.standard;

  @override
  bool operator ==(Object other) =>
      other is CaptionLayout &&
      other.maxLines == maxLines &&
      other.maxCharsPerLine == maxCharsPerLine &&
      other.maxCps == maxCps &&
      other.minDurationUs == minDurationUs &&
      other.maxDurationUs == maxDurationUs &&
      other.minGapFrames == minGapFrames &&
      other.lingerUs == lingerUs &&
      other.chainGapUs == chainGapUs;

  @override
  int get hashCode =>
      Object.hash(maxLines, maxCharsPerLine, maxCps, minDurationUs, maxDurationUs, minGapFrames, lingerUs, chainGapUs);
}
