// OWNER: AI-11
//
// Golden fixtures in 9 languages (en, es, de, ja, zh, ko, ar, hi, th). Each golden file holds the
// cues (`startMs-endMs|line 1 / line 2`) the segmenter must produce for a fixed word stream. A
// deliberate change is reviewed and re-recorded with `UPDATE_GOLDENS=1 flutter test`.

import 'dart:io';

import 'package:characters/characters.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_transcription/danaview_transcription.dart';

import 'segmentation_fixtures.dart';

class _Fixture {
  const _Fixture(this.code, this.text, {this.tokenizer = Tokenizer.spaces, this.phrasePauseMs = 0, this.msPerGrapheme = 70});
  final String code;
  final String text;
  final Tokenizer tokenizer;
  final int phrasePauseMs;
  final int msPerGrapheme;
}

const _fixtures = [
  _Fixture(
    'en',
    "Hello everyone and welcome back to the channel. Today we are going to talk about something really important, because it changes how we work every single day. First, let's look at the basics. Then we will dive deeper into the details, step by step. Thanks!",
  ),
  _Fixture(
    'es',
    'Hola a todos y bienvenidos de nuevo al canal. Hoy vamos a hablar de algo muy importante, porque cambia la forma en que trabajamos cada día. Primero, veamos lo básico. Después profundizaremos en los detalles, paso a paso. ¡Gracias!',
  ),
  _Fixture(
    'de',
    'Hallo zusammen und willkommen zurück auf dem Kanal. Heute sprechen wir über etwas wirklich Wichtiges, weil es verändert, wie wir jeden einzelnen Tag arbeiten. Zuerst schauen wir uns die Grundlagen an. Danach gehen wir Schritt für Schritt tiefer in die Details. Danke!',
  ),
  _Fixture(
    'ja',
    '今日は皆さんに、とても大切なお知らせがあります。来週から新しいサービスを始めることになりました。詳しくは公式サイトをご覧ください。まずは基本から、順番に説明していきます。ありがとうございました。',
    tokenizer: Tokenizer.pairs,
    msPerGrapheme: 130,
  ),
  _Fixture(
    'zh',
    '大家好，欢迎回到我们的频道。今天我们要讨论一件非常重要的事情，因为它改变了我们每天工作的方式。首先，让我们来看看基础知识。然后，我们会一步一步深入了解细节。谢谢大家！',
    tokenizer: Tokenizer.pairs,
    msPerGrapheme: 130,
  ),
  _Fixture(
    'ko',
    '여러분 안녕하세요, 채널에 다시 오신 것을 환영합니다. 오늘은 정말 중요한 이야기를 해 보려고 합니다, 왜냐하면 우리가 매일 일하는 방식을 바꾸기 때문입니다. 먼저 기본부터 살펴보겠습니다. 그다음에 하나씩 자세히 들어가 보겠습니다. 감사합니다!',
    msPerGrapheme: 150,
  ),
  _Fixture(
    'ar',
    'مرحبا بكم جميعا وأهلا بكم من جديد في القناة. اليوم سنتحدث عن شيء مهم جدا، لأنه يغير طريقة عملنا كل يوم. أولا، دعونا ننظر إلى الأساسيات. ثم سنتعمق في التفاصيل خطوة بخطوة. شكرا لكم!',
  ),
  _Fixture(
    'hi',
    'सभी को नमस्कार और चैनल पर वापसी पर आपका स्वागत है। आज हम एक बहुत महत्वपूर्ण विषय पर बात करेंगे, क्योंकि यह हमारे रोज़ काम करने के तरीके को बदल देता है। सबसे पहले, आइए बुनियादी बातें देखें। फिर हम विस्तार से, कदम दर कदम, समझेंगे। धन्यवाद!',
    msPerGrapheme: 110,
  ),
  _Fixture(
    'th',
    'สวัสดีทุกคนและยินดีต้อนรับกลับสู่ช่องของเรา วันนี้เราจะพูดถึงเรื่องสำคัญมาก เพราะมันเปลี่ยนวิธีที่เราทำงานทุกวัน ก่อนอื่นมาดูพื้นฐานกันก่อน จากนั้นเราจะลงรายละเอียดทีละขั้นตอน ขอบคุณครับ',
    tokenizer: Tokenizer.triples,
    phrasePauseMs: 300,
    msPerGrapheme: 90,
  ),
];

void main() {
  final update = Platform.environment['UPDATE_GOLDENS'] == '1';
  final dir = Directory.current.path.endsWith('danaview_transcription') ? 'test/segmentation/goldens' : 'packages/danaview_transcription/test/segmentation/goldens';

  for (final f in _fixtures) {
    group('golden ${f.code}', () {
      final words = wordsFromText(f.text, tokenizer: f.tokenizer, phrasePauseMs: f.phrasePauseMs, msPerGrapheme: f.msPerGrapheme);
      final ctx = context(language: f.code);
      final cues = const DpCaptionSegmenter().segment(words, ctx);

      test('cues match the golden file', () {
        final actual = '${render(cues).join('\n')}\n';
        final file = File('$dir/${f.code}.txt');
        if (update) {
          file.writeAsStringSync(actual);
        }
        expect(file.existsSync(), isTrue, reason: 'record it with UPDATE_GOLDENS=1');
        expect(actual, file.readAsStringSync());
      });

      test('limits are respected and no word is lost', () {
        final layout = CaptionLayout.resolve(ctx.settings, ctx.script);
        expect(cues, isNotEmpty);
        for (final c in cues) {
          final lines = c.text.split('\n');
          expect(lines.length, lessThanOrEqualTo(layout.maxLines), reason: c.text);
          for (final line in lines) {
            expect(line.characters.length, lessThanOrEqualTo(layout.maxCharsPerLine), reason: line);
          }
          expect(ctx.frameRate.isOnGrid(c.range.start), isTrue);
          expect(ctx.frameRate.isOnGrid(c.range.end), isTrue);
        }
        String squash(String s) => s.replaceAll(RegExp(r'\s+'), '');
        expect(squash(cues.map((c) => c.text).join()), squash(words.map((w) => w.text).join()));
        for (var i = 1; i < cues.length; i++) {
          expect(ctx.frameRate.frameIndexOf(cues[i].range.start) - ctx.frameRate.frameIndexOf(cues[i - 1].range.end), greaterThanOrEqualTo(2));
        }
      });

      test('is deterministic', () {
        expect(render(const DpCaptionSegmenter().segment(words, ctx)), render(cues));
        expect(render(const DpCaptionSegmenter().segment(words.reversed.toList(), ctx)), render(cues));
      });
    });
  }
}
