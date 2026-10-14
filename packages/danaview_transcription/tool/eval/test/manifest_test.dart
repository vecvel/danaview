// OWNER: QA-06
//
// The eval set manifest: the committed eval_set.json is valid and the validator rejects clips that
// break the licence and pinning rules (tool/eval/src/manifest.dart).

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../src/manifest.dart';

String _doc(List<Map<String, Object?>> clips) => jsonEncode({'schema': 1, 'clips': clips});

Map<String, Object?> _synth(String id) => {
      'id': id,
      'language': 'en',
      'kind': 'silence',
      'source': 'synthetic',
      'licence': 'in-house',
      'synth': {'type': 'silence', 'seconds': 5},
    };

void main() {
  final evalDir = p.join(Directory.current.path, 'tool', 'eval');

  test('the committed eval set parses, and every repo clip matches its pinned sha256', () {
    final m = EvalManifest.load(p.join(evalDir, 'eval_set.json'));
    expect(m.clips, isNotEmpty);
    expect(m.clips.where((c) => c.kind == ClipKind.speech), isNotEmpty);
    expect(m.clips.where((c) => c.kind.isNonSpeech).map((c) => c.kind).toSet(),
        containsAll([ClipKind.silence, ClipKind.noise, ClipKind.music]));
    for (final c in m.clips.where((c) => c.source == ClipSource.repo)) {
      final f = File(p.join(m.directory, c.path));
      expect(f.existsSync(), isTrue, reason: c.id);
      expect(sha256.convert(f.readAsBytesSync()).toString(), c.sha256, reason: c.id);
    }
    expect(m.speechLanguages, contains('en'));
  });

  test('valid remote CC-BY clip with attribution', () {
    final m = EvalManifest.parse(
        _doc([
          {
            'id': 'es-fleurs-1',
            'language': 'es',
            'kind': 'speech',
            'source': 'remote',
            'url': 'https://example.org/a.wav',
            'bytes': 1000,
            'sha256': 'a' * 64,
            'licence': 'CC-BY-4.0',
            'attribution': 'FLEURS (Conneau et al., 2022), CC BY 4.0',
            'reference': {'text': 'hola', 'cues': [{'start': 0, 'end': 900, 'text': 'hola'}]},
          },
        ]),
        directory: evalDir);
    expect(m.clips.single.reference!.cues.single.endMs, 900);
  });

  group('rejects', () {
    void bad(Map<String, Object?> clip, String why) {
      expect(() => EvalManifest.parse(_doc([clip]), directory: evalDir), throwsFormatException, reason: why);
    }

    test('licences outside the allow list and CC-BY without attribution', () {
      bad({..._synth('a1'), 'licence': 'CC-BY-NC-4.0'}, 'non-commercial licence');
      bad({
        'id': 'a2', 'language': 'en', 'kind': 'speech', 'source': 'remote', 'url': 'https://x/a.wav', 'bytes': 1,
        'sha256': 'b' * 64, 'licence': 'CC-BY-4.0', 'reference': {'text': 'x'},
      }, 'attribution missing');
    });

    test('unpinned remote clips and plain http', () {
      final base = {
        'id': 'a3', 'language': 'en', 'kind': 'speech', 'source': 'remote', 'url': 'https://x/a.wav', 'bytes': 1,
        'sha256': 'c' * 64, 'licence': 'CC0-1.0', 'reference': {'text': 'x'},
      };
      bad({...base}..remove('sha256'), 'no sha256');
      bad({...base}..remove('bytes'), 'no bytes');
      bad({...base, 'sha256': 'C' * 64}, 'upper-case sha');
      bad({...base, 'url': 'http://x/a.wav'}, 'http');
    });

    test('speech without a reference, synthetic speech, unknown language, bad ids and duplicates', () {
      bad({..._synth('a4'), 'kind': 'speech'}, 'synthetic speech');
      bad({..._synth('a5'), 'language': 'xx'}, 'unknown language');
      bad({..._synth('A B')}, 'bad id');
      expect(() => EvalManifest.parse(_doc([_synth('dup'), _synth('dup')]), directory: evalDir), throwsFormatException);
      expect(() => EvalManifest.parse('{"schema": 2, "clips": []}', directory: evalDir), throwsFormatException);
    });
  });
}
