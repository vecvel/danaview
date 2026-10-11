// OWNER: AI-08
//
// The 99 whisper languages (ids 0-98 of whisper's g_lang; `yue` excluded because only large-v3
// knows it), ai.md §9.4. BCP-47 is identity except `jw` -> `jv`. `qualityHint` (languages where
// Fast and Balanced are weak, so the sheet recommends Accurate) is filled by QA-06 from the
// published per-language WER; it is false for every entry until then.

import 'package:meta/meta.dart';

/// Segmentation script profile (ai.md §9.2).
enum ScriptProfile {
  /// Latin, Cyrillic, Greek, Arabic, Hebrew, Indic and other space-delimited scripts.
  spaceDelimited,

  /// Chinese and Japanese (16 characters per line).
  cjk,

  /// Korean (18 characters per line).
  korean,

  /// Thai, Lao, Khmer, Myanmar, Tibetan (no spaces between words; 35 per line).
  noSpace,
}

/// One selectable spoken language.
@immutable
final class TranscriptionLanguage {
  /// Creates an entry.
  const TranscriptionLanguage(this.whisperCode, this.bcp47, this.englishName, this.nativeName, this.script,
      {this.rtl = false, this.qualityHint = false});

  /// whisper language code.
  final String whisperCode;

  /// BCP-47 tag (stored on subtitle tracks, used in export file names).
  final String bcp47;

  /// English name (sort key in the picker).
  final String englishName;

  /// Name in the language itself (picker subtitle; searchable).
  final String nativeName;

  /// Segmentation profile.
  final ScriptProfile script;

  /// Right-to-left script.
  final bool rtl;

  /// Fast/Balanced are weak for this language: recommend Accurate.
  final bool qualityHint;
}

/// The language list in whisper id order.
const List<TranscriptionLanguage> whisperLanguages = [
  TranscriptionLanguage('en', 'en', 'English', 'English', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('zh', 'zh', 'Chinese', '中文', ScriptProfile.cjk),
  TranscriptionLanguage('de', 'de', 'German', 'Deutsch', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('es', 'es', 'Spanish', 'Español', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('ru', 'ru', 'Russian', 'Русский', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('ko', 'ko', 'Korean', '한국어', ScriptProfile.korean),
  TranscriptionLanguage('fr', 'fr', 'French', 'Français', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('ja', 'ja', 'Japanese', '日本語', ScriptProfile.cjk),
  TranscriptionLanguage('pt', 'pt', 'Portuguese', 'Português', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('tr', 'tr', 'Turkish', 'Türkçe', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('pl', 'pl', 'Polish', 'Polski', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('ca', 'ca', 'Catalan', 'Català', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('nl', 'nl', 'Dutch', 'Nederlands', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('ar', 'ar', 'Arabic', 'العربية', ScriptProfile.spaceDelimited, rtl: true),
  TranscriptionLanguage('sv', 'sv', 'Swedish', 'Svenska', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('it', 'it', 'Italian', 'Italiano', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('id', 'id', 'Indonesian', 'Bahasa Indonesia', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('hi', 'hi', 'Hindi', 'हिन्दी', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('fi', 'fi', 'Finnish', 'Suomi', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('vi', 'vi', 'Vietnamese', 'Tiếng Việt', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('he', 'he', 'Hebrew', 'עברית', ScriptProfile.spaceDelimited, rtl: true),
  TranscriptionLanguage('uk', 'uk', 'Ukrainian', 'Українська', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('el', 'el', 'Greek', 'Ελληνικά', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('ms', 'ms', 'Malay', 'Bahasa Melayu', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('cs', 'cs', 'Czech', 'Čeština', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('ro', 'ro', 'Romanian', 'Română', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('da', 'da', 'Danish', 'Dansk', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('hu', 'hu', 'Hungarian', 'Magyar', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('ta', 'ta', 'Tamil', 'தமிழ்', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('no', 'no', 'Norwegian', 'Norsk', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('th', 'th', 'Thai', 'ไทย', ScriptProfile.noSpace),
  TranscriptionLanguage('ur', 'ur', 'Urdu', 'اردو', ScriptProfile.spaceDelimited, rtl: true),
  TranscriptionLanguage('hr', 'hr', 'Croatian', 'Hrvatski', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('bg', 'bg', 'Bulgarian', 'Български', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('lt', 'lt', 'Lithuanian', 'Lietuvių', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('la', 'la', 'Latin', 'Latina', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('mi', 'mi', 'Maori', 'Māori', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('ml', 'ml', 'Malayalam', 'മലയാളം', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('cy', 'cy', 'Welsh', 'Cymraeg', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('sk', 'sk', 'Slovak', 'Slovenčina', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('te', 'te', 'Telugu', 'తెలుగు', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('fa', 'fa', 'Persian', 'فارسی', ScriptProfile.spaceDelimited, rtl: true),
  TranscriptionLanguage('lv', 'lv', 'Latvian', 'Latviešu', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('bn', 'bn', 'Bengali', 'বাংলা', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('sr', 'sr', 'Serbian', 'Српски', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('az', 'az', 'Azerbaijani', 'Azərbaycan', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('sl', 'sl', 'Slovenian', 'Slovenščina', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('kn', 'kn', 'Kannada', 'ಕನ್ನಡ', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('et', 'et', 'Estonian', 'Eesti', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('mk', 'mk', 'Macedonian', 'Македонски', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('br', 'br', 'Breton', 'Brezhoneg', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('eu', 'eu', 'Basque', 'Euskara', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('is', 'is', 'Icelandic', 'Íslenska', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('hy', 'hy', 'Armenian', 'Հայերեն', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('ne', 'ne', 'Nepali', 'नेपाली', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('mn', 'mn', 'Mongolian', 'Монгол', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('bs', 'bs', 'Bosnian', 'Bosanski', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('kk', 'kk', 'Kazakh', 'Қазақ', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('sq', 'sq', 'Albanian', 'Shqip', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('sw', 'sw', 'Swahili', 'Kiswahili', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('gl', 'gl', 'Galician', 'Galego', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('mr', 'mr', 'Marathi', 'मराठी', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('pa', 'pa', 'Punjabi', 'ਪੰਜਾਬੀ', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('si', 'si', 'Sinhala', 'සිංහල', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('km', 'km', 'Khmer', 'ខ្មែរ', ScriptProfile.noSpace),
  TranscriptionLanguage('sn', 'sn', 'Shona', 'chiShona', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('yo', 'yo', 'Yoruba', 'Yorùbá', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('so', 'so', 'Somali', 'Soomaali', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('af', 'af', 'Afrikaans', 'Afrikaans', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('oc', 'oc', 'Occitan', 'Occitan', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('ka', 'ka', 'Georgian', 'ქართული', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('be', 'be', 'Belarusian', 'Беларуская', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('tg', 'tg', 'Tajik', 'Тоҷикӣ', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('sd', 'sd', 'Sindhi', 'سنڌي', ScriptProfile.spaceDelimited, rtl: true),
  TranscriptionLanguage('gu', 'gu', 'Gujarati', 'ગુજરાતી', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('am', 'am', 'Amharic', 'አማርኛ', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('yi', 'yi', 'Yiddish', 'ייִדיש', ScriptProfile.spaceDelimited, rtl: true),
  TranscriptionLanguage('lo', 'lo', 'Lao', 'ລາວ', ScriptProfile.noSpace),
  TranscriptionLanguage('uz', 'uz', 'Uzbek', 'Oʻzbek', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('fo', 'fo', 'Faroese', 'Føroyskt', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('ht', 'ht', 'Haitian Creole', 'Kreyòl ayisyen', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('ps', 'ps', 'Pashto', 'پښتو', ScriptProfile.spaceDelimited, rtl: true),
  TranscriptionLanguage('tk', 'tk', 'Turkmen', 'Türkmen', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('nn', 'nn', 'Nynorsk', 'Nynorsk', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('mt', 'mt', 'Maltese', 'Malti', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('sa', 'sa', 'Sanskrit', 'संस्कृतम्', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('lb', 'lb', 'Luxembourgish', 'Lëtzebuergesch', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('my', 'my', 'Myanmar', 'မြန်မာ', ScriptProfile.noSpace),
  TranscriptionLanguage('bo', 'bo', 'Tibetan', 'བོད་སྐད་', ScriptProfile.noSpace),
  TranscriptionLanguage('tl', 'tl', 'Tagalog', 'Tagalog', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('mg', 'mg', 'Malagasy', 'Malagasy', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('as', 'as', 'Assamese', 'অসমীয়া', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('tt', 'tt', 'Tatar', 'Татар', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('haw', 'haw', 'Hawaiian', 'ʻŌlelo Hawaiʻi', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('ln', 'ln', 'Lingala', 'Lingála', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('ha', 'ha', 'Hausa', 'Hausa', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('ba', 'ba', 'Bashkir', 'Башҡорт', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('jw', 'jv', 'Javanese', 'Basa Jawa', ScriptProfile.spaceDelimited),
  TranscriptionLanguage('su', 'su', 'Sundanese', 'Basa Sunda', ScriptProfile.spaceDelimited),
];

/// The language with whisper [code], or null.
TranscriptionLanguage? languageForWhisperCode(String code) {
  for (final l in whisperLanguages) {
    if (l.whisperCode == code) return l;
  }
  return null;
}

/// Legacy and regional primary subtags mapped to the whisper code of the same language.
const Map<String, String> _localeAliases = {
  'iw': 'he', // legacy Hebrew
  'in': 'id', // legacy Indonesian
  'ji': 'yi', // legacy Yiddish
  'nb': 'no', // Norwegian Bokmal
  'fil': 'tl', // Filipino
  'jv': 'jw', // Javanese (whisper still uses its legacy code)
};

/// The language for a BCP-47 tag or device locale (`pt-BR` -> Portuguese, `zh_Hans_CN` ->
/// Chinese, legacy `iw` -> Hebrew), or null when whisper does not know the primary language.
TranscriptionLanguage? languageForLocale(String tag) {
  final primary = tag.trim().split(RegExp('[-_]')).first.toLowerCase();
  if (primary.isEmpty) return null;
  final code = _localeAliases[primary] ?? primary;
  for (final l in whisperLanguages) {
    if (l.whisperCode == code || l.bcp47 == code) return l;
  }
  return null;
}
