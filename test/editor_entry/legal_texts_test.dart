import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_features/src/more/legal_texts.dart';

Iterable<String> _allText(LegalDocumentText doc) sync* {
  yield doc.summary;
  for (final section in doc.sections) {
    yield section.heading;
    for (final block in section.blocks) {
      if (block.text != null) yield block.text!;
      for (final bullet in block.bullets ?? const <LegalBullet>[]) {
        if (bullet.lead != null) yield bullet.lead!;
        yield bullet.text;
      }
    }
  }
}

Iterable<String> _bullets(LegalDocumentText doc) sync* {
  for (final section in doc.sections) {
    for (final block in section.blocks) {
      for (final bullet in block.bullets ?? const <LegalBullet>[]) {
        yield bullet.text;
      }
    }
  }
}

void main() {
  final policy = _allText(privacyPolicyText).join('\n');
  final terms = _allText(termsOfUseText).join('\n');

  test('the effective date moved past the player-only policy', () {
    expect(legalEffectiveDate, isNot('3 October 2026'));
  });

  test('the policy names the speech model hosts', () {
    expect(policy, contains('huggingface.co'));
    expect(policy, contains('hf.co'));
  });

  test('the summary mentions the only extra download and never an automatic one', () {
    expect(privacyPolicyText.summary, contains('The only extra download is the optional speech model'));
    expect(privacyPolicyText.summary, isNot(contains('starts on its own')));
  });

  test('every editor and Auto captions bullet is limited to iPhone, iPad and Android', () {
    final editorBullets = _bullets(privacyPolicyText)
        .where((text) => RegExp('editor|editing|project|Auto captions|speech').hasMatch(text));
    expect(editorBullets, isNotEmpty);
    for (final text in editorBullets) {
      expect(text, startsWith('On iPhone, iPad and Android'), reason: text);
    }
  });

  test('the terms cover editing, exports and captions without naming app components', () {
    expect(terms, contains('Editing and exports'));
    expect(terms, contains('Auto captions'));
    expect(terms, contains('YouTube, Instagram and TikTok are trademarks'));
    for (final text in [policy, terms]) {
      expect(text, isNot(contains('Flutter')));
      expect(text, isNot(contains('whisper')));
      expect(text, isNot(contains('open-source licen')));
    }
  });
}
