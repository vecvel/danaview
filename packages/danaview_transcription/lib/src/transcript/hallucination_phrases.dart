// OWNER: AI-10
//
// Per-language phrases whisper invents on silence or music (ai.md §8.3). A segment matching one is
// dropped only when the no-speech probability is above 0.3, or when it is shorter than 1.2 s and
// ends the unit. Heuristic and tuned by AI-19 / QA-06; matching ignores case and punctuation.

/// Phrases that appear in every language (credits and watermarks).
const List<String> universalHallucinationPhrases = [
  'amara.org',
  'subtitles by the amara.org community',
  'transcribed by',
  'www.mooji.org',
];

/// Known hallucinated phrases by whisper language code.
const Map<String, List<String>> hallucinationPhrases = {
  'en': [
    'thank you for watching',
    'thanks for watching',
    'thank you so much for watching',
    'please subscribe',
    'subscribe to my channel',
    'like and subscribe',
    'see you in the next video',
    'see you next time',
    'bye',
    'thank you',
    'thanks',
    'you',
  ],
  'es': [
    'gracias por ver el video',
    'gracias por ver',
    'subtítulos realizados por la comunidad de amara.org',
    'suscríbete',
    'hasta la próxima',
    'gracias',
  ],
  'de': [
    'untertitel der amara.org-community',
    'untertitel im auftrag des zdf',
    'vielen dank fürs zuschauen',
    'danke fürs zuschauen',
    'tschüss',
    'vielen dank',
  ],
  'fr': [
    "sous-titres réalisés par la communauté d'amara.org",
    "merci d'avoir regardé cette vidéo",
    'abonnez-vous',
    'merci',
  ],
  'it': [
    "sottotitoli creati dalla comunità amara.org",
    'grazie per la visione',
    'grazie per aver guardato il video',
    'iscriviti al canale',
    'grazie',
  ],
  'pt': [
    'legendas pela comunidade amara.org',
    'obrigado por assistir',
    'inscreva-se no canal',
    'obrigado',
  ],
  'nl': ['ondertitels ingediend door de amara.org gemeenschap', 'bedankt voor het kijken', 'tot de volgende keer'],
  'ru': [
    'субтитры сделал dimatorzok',
    'субтитры создавал dimatorzok',
    'продолжение следует',
    'спасибо за просмотр',
    'подписывайтесь на канал',
  ],
  'pl': ['napisy stworzone przez społeczność amara.org', 'dziękuję za uwagę', 'dziękuję za oglądanie'],
  'tr': ['altyazı m.k.', 'izlediğiniz için teşekkürler', 'abone olun'],
  'ja': [
    'ご視聴ありがとうございました',
    'ご視聴ありがとうございます',
    'チャンネル登録をお願いします',
    'チャンネル登録よろしくお願いします',
    'おやすみなさい',
  ],
  'zh': ['请不吝点赞 订阅 转发 打赏支持明镜与点点栏目', '谢谢观看', '感谢收看', '字幕由amara.org社区提供', '订阅我的频道'],
  'ko': ['시청해주셔서 감사합니다', '구독과 좋아요 부탁드립니다', '한국어 자막 제공 배달의민족'],
  'ar': ['اشتركوا في القناة', 'ترجمة نانسي قنقر', 'شكرا للمشاهدة'],
  'hi': ['देखने के लिए धन्यवाद', 'सब्सक्राइब करें'],
  'th': ['ขอบคุณที่ติดตามชม', 'อย่าลืมกดติดตาม'],
  'id': ['terima kasih telah menonton', 'jangan lupa subscribe'],
  'vi': ['hãy subscribe cho kênh ghiền mì gõ để không bỏ lỡ những video hấp dẫn', 'cảm ơn các bạn đã theo dõi'],
};

/// All phrases for [language] (a whisper code), including the universal ones.
List<String> hallucinationPhrasesFor(String language) => [
      ...universalHallucinationPhrases,
      ...?hallucinationPhrases[language],
    ];
