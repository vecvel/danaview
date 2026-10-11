// OWNER: AI-11
//
// Caption segmentation (ai.md §9): the deterministic DP segmenter, presets and script profiles,
// kinsoku and function-word rules, frame-grid edges.

library;

export 'caption_layout.dart';
export 'caption_segmenter.dart';
export 'caption_text.dart'
    show
        FunctionWords,
        endsClauseText,
        endsSentenceText,
        functionWordsByLanguage,
        functionWordsFor,
        isKinsokuNoEnd,
        isKinsokuNoStart,
        kinsokuNoLineEnd,
        kinsokuNoLineStart;
export 'timed_word.dart';
