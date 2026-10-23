// OWNER: AIS-01
//
// Public barrel of danaview_ai_studio (AI_STUDIO_PLAN §3.1, §3.6): the AI Studio service contract
// and its off state, action contracts and translation. Fakes are in `testing.dart`. Every file
// under lib/src/ is exported here (skeleton test).

library;

export 'src/actions/common/contract_registry.dart';
export 'src/actions/common/emotion_tables.dart';
export 'src/actions/common/prompt_kit.dart';
export 'src/contracts/ai_studio_service.dart';
export 'src/translation/aligner.dart';
export 'src/translation/languages.dart';
export 'src/translation/sentence_groups.dart';
