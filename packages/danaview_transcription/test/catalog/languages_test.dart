// OWNER: AI-08

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_transcription/danaview_transcription.dart';

void main() {
  test('99 languages with unique whisper codes and non-empty names', () {
    expect(whisperLanguages, hasLength(99));
    expect(whisperLanguages.map((l) => l.whisperCode).toSet(), hasLength(99));
    expect(whisperLanguages.map((l) => l.englishName).toSet(), hasLength(99));
    for (final l in whisperLanguages) {
      expect(l.englishName.trim(), isNotEmpty, reason: l.whisperCode);
      expect(l.nativeName.trim(), isNotEmpty, reason: l.whisperCode);
    }
  });

  test('yue (Cantonese) is excluded: only large-v3 knows it', () {
    expect(languageForWhisperCode('yue'), isNull);
    expect(languageForLocale('yue'), isNull);
  });

  test('BCP-47 tags are well formed, unique, and identical to the whisper code except jw -> jv', () {
    final tags = whisperLanguages.map((l) => l.bcp47).toList();
    expect(tags.toSet(), hasLength(99));
    for (final l in whisperLanguages) {
      expect(l.bcp47, matches(RegExp(r'^[a-z]{2,3}$')), reason: l.whisperCode);
      if (l.whisperCode != 'jw') expect(l.bcp47, l.whisperCode);
    }
    expect(languageForWhisperCode('jw')!.bcp47, 'jv');
    expect(languageForWhisperCode('jw')!.englishName, 'Javanese');
  });

  test('order and codes equal whisper.cpp g_lang ids 0-98 (checked against the vendored source when present)', () {
    final src = File('../danaview_whisper/third_party/whisper.cpp/src/whisper.cpp');
    if (!src.existsSync()) return; // AI-01's vendored tree may not be present
    final text = src.readAsStringSync();
    final table = text.substring(text.indexOf('g_lang = {'), text.indexOf('};', text.indexOf('g_lang = {')));
    final entries = RegExp(r'\{\s*"(\w+)",\s*\{\s*(\d+),\s*"([^"]+)"').allMatches(table).map((m) => (m.group(1)!, int.parse(m.group(2)!), m.group(3)!)).toList();
    final withoutYue = entries.where((e) => e.$1 != 'yue').toList();
    expect(withoutYue, hasLength(99));
    for (var i = 0; i < 99; i++) {
      expect(whisperLanguages[i].whisperCode, withoutYue[i].$1, reason: 'id $i');
      expect(withoutYue[i].$2, i);
      expect(whisperLanguages[i].englishName.toLowerCase(), withoutYue[i].$3, reason: 'id $i');
    }
  });

  test('script profiles', () {
    Set<String> codes(ScriptProfile p) => whisperLanguages.where((l) => l.script == p).map((l) => l.whisperCode).toSet();
    expect(codes(ScriptProfile.cjk), {'zh', 'ja'});
    expect(codes(ScriptProfile.korean), {'ko'});
    expect(codes(ScriptProfile.noSpace), {'th', 'lo', 'km', 'my', 'bo'});
    expect(codes(ScriptProfile.spaceDelimited), hasLength(99 - 2 - 1 - 5));
  });

  test('right-to-left languages', () {
    expect(whisperLanguages.where((l) => l.rtl).map((l) => l.whisperCode).toSet(), {'ar', 'fa', 'ur', 'he', 'yi', 'ps', 'sd'});
  });

  test('native names for scripts that matter to the picker', () {
    expect(languageForWhisperCode('ja')!.nativeName, '日本語');
    expect(languageForWhisperCode('ar')!.nativeName, 'العربية');
    expect(languageForWhisperCode('hi')!.nativeName, 'हिन्दी');
    expect(languageForWhisperCode('ko')!.nativeName, '한국어');
    expect(languageForWhisperCode('ru')!.nativeName, 'Русский');
  });

  test('qualityHint is false until QA-06 fills it', () {
    expect(whisperLanguages.where((l) => l.qualityHint), isEmpty);
  });

  test('device locale mapping', () {
    expect(languageForLocale('en')!.whisperCode, 'en');
    expect(languageForLocale('en-US')!.whisperCode, 'en');
    expect(languageForLocale('pt_BR')!.whisperCode, 'pt');
    expect(languageForLocale('zh-Hans-CN')!.whisperCode, 'zh');
    expect(languageForLocale('ZH_tw')!.whisperCode, 'zh');
    expect(languageForLocale('jv')!.whisperCode, 'jw');
    expect(languageForLocale('iw')!.whisperCode, 'he');
    expect(languageForLocale('in')!.whisperCode, 'id');
    expect(languageForLocale('nb-NO')!.whisperCode, 'no');
    expect(languageForLocale('nn-NO')!.whisperCode, 'nn');
    expect(languageForLocale('fil-PH')!.whisperCode, 'tl');
    expect(languageForLocale('haw')!.whisperCode, 'haw');
    expect(languageForLocale(' fr-CA ')!.whisperCode, 'fr');
    expect(languageForLocale(''), isNull);
    expect(languageForLocale('xx'), isNull);
    expect(languageForLocale('-'), isNull);
  });

  test('every language round-trips through its own BCP-47 tag', () {
    for (final l in whisperLanguages) {
      expect(languageForLocale(l.bcp47), same(l));
      expect(languageForLocale('${l.bcp47}-XX'), same(l));
    }
  });
}
