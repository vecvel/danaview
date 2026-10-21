// OWNER: AIS-01
//
// Registry metadata (label, icon, shortcuts) of the 1.2.0 actions (AI_STUDIO_PLAN §4.4). The
// registry's exhaustive `editorActionMeta` (UX-15) delegates every 1.2.0 id here, so the feature
// tickets that bind them (AIS-17…AIS-35) change copy through their bindings' `label`/`icon`
// overrides and never edit the registry.
//
// Shortcuts (AI_STUDIO_PLAN §4.4): T opens the transcript view (outside text fields, the UX-15
// focus guard), ⌘/Ctrl+Enter splits the cue at the cursor, ⌘⇧A asks AI about the selection only
// while `DANAVIEW_AI_STUDIO` is on. ⌘B/⌘I/⌘U belong to the rich cue editor itself (AIS-18), not to
// the registry, because they apply only inside that editor.
//
// The skeleton attaches no shortcut: an unbound action with a shortcut would show in the shortcuts
// sheet as "Not available yet", and slice S1 must look exactly like 1.1. The combos are declared
// below; the ticket that binds the action attaches its combo here (AIS-17 [transcriptViewCombo],
// AIS-19 [splitCueAtCursorCombo], AIS-34 [askAiCombo], the latter only when
// `EditorFlags.aiStudioEnabled`) and adds it to UX-15's shortcut table test.

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/services.dart' show LogicalKeyboardKey;

import '../contracts/contracts.dart';
import 'editor_action_registry.dart' show EditorActionMeta, EditorKeyCombo;

/// ⌘⇧A: Ask AI on the selection (only with AI Studio on).
const EditorKeyCombo askAiCombo = EditorKeyCombo(LogicalKeyboardKey.keyA, command: true, shift: true);

/// ⌘/Ctrl+Enter: split the cue at the text cursor.
const EditorKeyCombo splitCueAtCursorCombo = EditorKeyCombo(LogicalKeyboardKey.enter, command: true);

/// T: the transcript view.
const EditorKeyCombo transcriptViewCombo = EditorKeyCombo(LogicalKeyboardKey.keyT);

/// The registry metadata of a 1.2.0 action ([EditorActionId.v12Additions]).
///
/// Throws an [ArgumentError] for a 1.1 action (those are in `editorActionMeta`).
EditorActionMeta aisActionMeta(EditorActionId id) {
  return switch (id) {
    // Editing.
    EditorActionId.cueStyleBold => const EditorActionMeta('Bold', Icons.format_bold_rounded),
    EditorActionId.cueStyleItalic => const EditorActionMeta('Italic', Icons.format_italic_rounded),
    EditorActionId.cueStyleUnderline => const EditorActionMeta('Underline', Icons.format_underlined_rounded),
    EditorActionId.cueStyleClear => const EditorActionMeta('Clear styles', Icons.format_clear_rounded),
    EditorActionId.cuePlacement => const EditorActionMeta('Caption position', Icons.picture_in_picture_alt_rounded),
    EditorActionId.splitCueAtCursor => const EditorActionMeta('Split at cursor', Icons.call_split_rounded),
    EditorActionId.mergeCueWithPrevious => const EditorActionMeta('Merge with previous', Icons.merge_rounded),
    EditorActionId.snapCueToSpeech => const EditorActionMeta('Snap to speech', Icons.graphic_eq_rounded),
    EditorActionId.estimateWordTimings => const EditorActionMeta('Estimate word timings', Icons.timer_outlined),
    EditorActionId.removeEmojis => const EditorActionMeta('Remove emojis', Icons.backspace_outlined),
    // Tools.
    EditorActionId.aiStudio => const EditorActionMeta('AI Studio', Icons.auto_fix_high_rounded),
    EditorActionId.askAi => const EditorActionMeta('Ask AI', Icons.question_answer_rounded),
    EditorActionId.translateTrack => const EditorActionMeta('Translate', Icons.translate_rounded),
    EditorActionId.reviewAiChanges => const EditorActionMeta('Review suggestions', Icons.rule_rounded),
    EditorActionId.transcriptView => const EditorActionMeta('Transcript', Icons.article_rounded),
    EditorActionId.karaokeSettings => const EditorActionMeta('Karaoke', Icons.queue_music_rounded),
    EditorActionId.speakers => const EditorActionMeta('Speakers', Icons.record_voice_over_rounded),
    EditorActionId.reviewEmojis => const EditorActionMeta('Review emojis', Icons.emoji_emotions_rounded),
    EditorActionId.subtitlePresets => const EditorActionMeta('Caption presets', Icons.style_rounded),
    EditorActionId.importFont => const EditorActionMeta('Import font', Icons.font_download_rounded),
    _ => throw ArgumentError.value(id, 'id', 'not a 1.2.0 action; see editorActionMeta'),
  };
}
