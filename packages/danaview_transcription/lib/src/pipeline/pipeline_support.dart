// OWNER: AI-13
//
// Small pieces the orchestrator shares: the speech folder layout (ai.md §5.2), the privacy-safe
// log sink, the serializable request (job records, ai.md §8.6), scope conversions and the
// result-to-command helper (ARCH §16.4 step 9).
//
// Logs carry event codes and numbers only: never transcript text, language candidates' words,
// file paths or media URIs (ARCH §16.5; the grep test in test/pipeline/ enforces it).

import 'dart:developer' as developer;

import 'package:path/path.dart' as p;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';

import '../contracts/transcription_service.dart';
import '../languages/languages.dart';

/// `<support>/danaview/speech/` and its folders (ai.md §5.2).
final class SpeechPaths {
  /// The layout under [supportDirectory].
  SpeechPaths(String supportDirectory) : root = p.join(supportDirectory, 'danaview', 'speech');

  /// `<support>/danaview/speech`.
  final String root;

  /// Transcript cache and checkpoints.
  String get transcripts => p.join(root, 'transcripts');

  /// Job records.
  String get jobs => p.join(root, 'jobs');

  /// Extracted WAVs, one folder per job.
  String get work => p.join(root, 'work');

  /// The work folder of [jobId].
  String workOf(String jobId) => p.join(work, jobId);

  /// The WAV of unit [unitIndex] of [jobId].
  String wavOf(String jobId, int unitIndex) => p.join(workOf(jobId), 'u$unitIndex.wav');
}

/// Receives log events: an event code and numeric or code-valued fields. Never text or paths.
typedef TranscriptionLogSink = void Function(String event, Map<String, Object> fields);

/// The default sink (`dart:developer` log, name `danaview.transcription`).
void developerTranscriptionLog(String event, Map<String, Object> fields) =>
    developer.log(fields.isEmpty ? event : '$event $fields', name: 'danaview.transcription');

/// The JSON form of [r] stored in job records; equal requests encode equally (resume matching).
/// The timeline callback is not part of it.
Map<String, Object?> encodeTranscriptionRequest(TranscriptionRequest r) => {
      'project': r.project.value,
      'scope': _encodeScope(r.scope),
      'language': switch (r.language) {
        AutoLanguage() => 'auto',
        FixedLanguage(:final code) => code,
      },
      'model': r.modelId,
      'segmentation': {
        'preset': r.segmentation.preset.name,
        'maxLines': r.segmentation.maxLines,
        'maxCharsPerLine': r.segmentation.maxCharsPerLine,
        'maxCps': r.segmentation.maxCharsPerSecond,
      },
      'target': switch (r.target) {
        NewTrackTarget() => {'kind': 'new'},
        ReplaceTrackTarget(:final track) => {'kind': 'replace', 'track': track.value},
        ReplaceInRangeTarget(:final track, :final range) => {
            'kind': 'replaceInRange',
            'track': track.value,
            'startUs': range.start,
            'endUs': range.end,
          },
      },
      'sounds': r.includeSoundDescriptions,
    };

Map<String, Object?> _encodeScope(TranscriptionScope s) => switch (s) {
      ClipScope(:final item) => {'kind': 'clip', 'item': item.value},
      ItemsScope(:final items) => {
          'kind': 'items',
          'items': ([for (final i in items) i.value]..sort()),
        },
      TimelineScope(:final tracks, :final range) => {
          'kind': 'timeline',
          if (tracks != null) 'tracks': ([for (final t in tracks) t.value]..sort()),
          if (range != null) 'startUs': range.start,
          if (range != null) 'endUs': range.end,
        },
    };

/// The provenance form of [scope].
CaptionScopeData captionScopeDataOf(TranscriptionScope scope) => switch (scope) {
      ClipScope(:final item) => CaptionScopeData(clips: [item]),
      ItemsScope(:final items) => CaptionScopeData(clips: (items.toList()..sort((a, b) => a.value.compareTo(b.value)))),
      TimelineScope(:final tracks, :final range) =>
        CaptionScopeData(tracks: tracks == null ? const [] : (tracks.toList()..sort((a, b) => a.value.compareTo(b.value))), range: range),
    };

/// The scope recorded in [data] (re-split replans with it).
TranscriptionScope transcriptionScopeOf(CaptionScopeData data) {
  if (data.clips.length == 1) return ClipScope(data.clips.single);
  if (data.clips.isNotEmpty) return ItemsScope(data.clips.toSet());
  return TimelineScope(tracks: data.tracks.isEmpty ? null : data.tracks.toSet(), range: data.range);
}

/// The timeline window of [scope] (the scope range), or null.
TimeRange? scopeWindow(TranscriptionScope scope) => scope is TimelineScope ? scope.range : null;

/// BCP-47 tag of a whisper language code (`jw` -> `jv`; unknown codes pass through).
String bcp47OfWhisperCode(String code) => languageForWhisperCode(code)?.bcp47 ?? code;

/// whisper code of a BCP-47 tag stored in provenance (`jv` -> `jw`; unknown tags pass through).
String whisperCodeOfBcp47(String tag) => languageForLocale(tag)?.whisperCode ?? tag;

/// The default name of a generated track: `Captions (<native language name>)` (ai.md §10.2).
String captionTrackNameFor(String bcp47) {
  final lang = languageForLocale(bcp47);
  return 'Captions (${lang?.nativeName ?? bcp47})';
}

/// The core command that applies a [TranscriptionResult] as one history entry (ARCH §16.4 step 9).
extension TranscriptionResultCommand on TranscriptionResult {
  /// [AddGeneratedCaptionTrack] for [NewTrackTarget] (named [trackName], or
  /// [captionTrackNameFor] the language), [ReplaceGeneratedCaptions] otherwise.
  EditCommand toCommand({String? trackName}) => switch (target) {
        NewTrackTarget() => AddGeneratedCaptionTrack(
            trackName: trackName ?? captionTrackNameFor(provenance.language),
            language: provenance.language,
            provenance: provenance,
            cues: drafts,
          ),
        ReplaceTrackTarget(:final track) => ReplaceGeneratedCaptions(track: track, provenance: provenance, cues: drafts),
        ReplaceInRangeTarget(:final track, :final range) =>
          ReplaceGeneratedCaptions(track: track, range: range, provenance: provenance, cues: drafts),
      };
}

/// "Regenerate -> re-split" found no cached transcript for some units (evicted, or the media
/// changed): the caller falls back to "Transcribe again" (ai.md §10.3).
final class CachedTranscriptsMissing implements Exception {
  /// Creates the exception.
  const CachedTranscriptsMissing(this.units);

  /// Units without a cached transcript.
  final int units;

  @override
  String toString() => 'CachedTranscriptsMissing($units units)';
}
