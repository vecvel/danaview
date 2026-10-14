// OWNER: AI-13
//
// Logs never contain transcript text or paths (ARCH §16.5). Two checks: the events a full run
// logs carry no fixture word, path or URI; and a grep over the pipeline and governor sources
// finds no logging call that passes text, partial text, words, paths, URIs or file names.

import 'dart:io';

import 'package:danaview_transcription/danaview_transcription.dart';
import 'package:danaview_whisper/danaview_whisper.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/pipeline_fakes.dart';

void main() {
  test('a full run (detect, checkpoint, resume, skip) logs codes and numbers only', () async {
    final h = await Harness.create();
    addTearDown(h.dispose);
    h.project = twoClipProject();
    h.extractor.failures['file:///media/m2.mp4'] = SpeechAudioFailureKind.unsupportedCodec;
    h.runtime.detectScript = (j) => j.succeed(languages: const [WhisperLanguageProbability('en', 0.9)]);
    await h.start(h.request(language: const AutoLanguage())).$1.result;
    h.runtime.transcribeScript = (j) => j.fail(WhisperErrorKind.inference);
    await expectLater(h.start(h.request(language: const FixedLanguage('de'))).$1.result, throwsA(isA<InferenceFailure>()));

    expect(h.logs, isNotEmpty);
    // Distinctive fixture words (short or common ones such as "to" or "start" occur in codes).
    const words = {'Welcome', 'harbour', 'tour', 'lighthouse'};
    expect(fixtureSegments.map((s) => s.text).join(' '), allOf([for (final w in words) contains(w)]));
    for (final (event, fields) in h.logs) {
      final line = '$event $fields';
      for (final w in words) {
        expect(RegExp('\\b$w\\b', caseSensitive: false).hasMatch(line), isFalse, reason: 'log "$line" contains transcript text');
      }
      expect(line.contains('/'), isFalse, reason: 'log "$line" contains a path');
      expect(line.contains('file:'), isFalse);
      expect(line.contains(h.dir.path), isFalse);
      for (final v in fields.values) {
        expect(v is num || v is bool || RegExp(r'^[A-Za-z0-9_.-]*$').hasMatch('$v'), isTrue, reason: 'field $v of $event');
      }
    }
  });

  test('grep: no logging call in pipeline/ or governor/ passes text or paths', () {
    final root = Directory.current.path.endsWith('danaview_transcription') ? Directory.current : Directory('packages/danaview_transcription');
    final files = [
      ...Directory('${root.path}/lib/src/pipeline').listSync(recursive: true),
      ...Directory('${root.path}/lib/src/governor').listSync(recursive: true),
    ].whereType<File>().where((f) => f.path.endsWith('.dart'));
    expect(files, isNotEmpty);
    final call = RegExp(r'(_log|\.log|developer\.log|print|debugPrint)\(');
    final forbidden = RegExp(r'\btext\b|partialText|\bwords?\b|[pP]ath|\buri\b|\bwav\b|fileName|\.segments\b');
    for (final f in files) {
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (line.trimLeft().startsWith('//') || line.trimLeft().startsWith('///')) continue;
        if (!call.hasMatch(line)) continue;
        if (line.contains('void _log(') || line.contains('TranscriptionLogSink')) continue;
        // A logging call may continue on the next lines until the closing parenthesis.
        final statement = StringBuffer(line);
        var j = i;
        while (!statement.toString().contains(');') && j + 1 < lines.length) {
          statement.write(lines[++j]);
        }
        final s = statement.toString().replaceAll("'words'", '');
        expect(forbidden.hasMatch(s.substring(s.indexOf(call.firstMatch(s)!.group(0)!))), isFalse,
            reason: '${f.path}:${i + 1} logs something that may hold text or a path: $s');
      }
    }
    // print/debugPrint are not used at all.
    for (final f in files) {
      expect(RegExp(r'\b(print|debugPrint)\(').hasMatch(f.readAsStringSync()), isFalse, reason: f.path);
    }
  });
}
