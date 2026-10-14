// OWNER: AI-13
//
// Steps 7-8 of the job (ARCH §16.4): map the units' words onto a FRESH timeline view (edits made
// during the job are honoured) and segment them into frame-quantized cue drafts. Shared by the
// job and by the instant "Regenerate -> re-split" (`resegment`). Segmentation of more than
// [CaptionAssembler.isolateWordThreshold] words runs in `Isolate.run` (ai.md §3.3).

import 'dart:isolate';

import 'package:meta/meta.dart';
import 'package:danaview_editor_core/model.dart';

import '../contracts/timeline_view.dart';
import '../segmentation/caption_segmenter.dart';
import '../segmentation/timed_word.dart' show SegmentationContext;
import '../timeline/word_mapper.dart';

/// Mapped and segmented captions.
@immutable
final class AssembledCaptions {
  /// Creates the result.
  AssembledCaptions({required List<SubtitleCueDraft> drafts, required this.words, required this.mapped})
      : drafts = List.unmodifiable(drafts);

  /// Cue drafts in timeline time.
  final List<SubtitleCueDraft> drafts;

  /// Words that made it onto the timeline.
  final int words;

  /// The mapping result (diagnostics: dropped counts, missing clips).
  final MappedWords mapped;
}

/// Maps and segments.
final class CaptionAssembler {
  /// Creates the assembler.
  const CaptionAssembler({
    this.mapper = const WordMapper(),
    this.segmenter = const DpCaptionSegmenter(),
    this.isolateWordThreshold = 4000,
  });

  /// Word mapper.
  final WordMapper mapper;

  /// Segmenter.
  final CaptionSegmenter segmenter;

  /// Above this many words segmentation runs in a background isolate.
  final int isolateWordThreshold;

  /// Maps [transcripts] through [timeline] (limited to [window]) and segments them for the
  /// spoken [languageCode] (whisper code) with [settings].
  Future<AssembledCaptions> assemble({
    required TimelineView timeline,
    required List<UnitWords> transcripts,
    required String languageCode,
    required SegmentationSettings settings,
    TimeRange? window,
  }) async {
    final mapped = mapper.map(timeline: timeline, transcripts: transcripts, window: window);
    if (mapped.words.isEmpty) return AssembledCaptions(drafts: const [], words: 0, mapped: mapped);
    final context = SegmentationContext.forProject(
      languageCode: languageCode,
      settings: settings,
      frameRate: timeline.frameRate,
      cutPoints: mapped.cutPoints,
      canvasSize: timeline.canvasSize,
    );
    final words = mapped.words;
    final seg = segmenter;
    final drafts = words.length > isolateWordThreshold
        ? await Isolate.run(() => seg.segment(words, context))
        : seg.segment(words, context);
    return AssembledCaptions(drafts: drafts, words: words.length, mapped: mapped);
  }
}
