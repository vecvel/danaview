// OWNER: AIS-01
//
// Public barrel of danaview_ai_providers (AI_STUDIO_PLAN §3.1, §3.5): provider contracts, consent
// tickets, transport, JSON helpers, token estimates and the provider adapters. Fakes are in
// `testing.dart`. Every file under lib/src/ except lib/src/fake/ is exported here (skeleton test).

library;

export 'src/consent/ai_send_consent.dart';
export 'src/consent/provider_probe_consent.dart';
export 'src/consent/send_ticket.dart';
export 'src/contracts/ai_failure.dart';
export 'src/contracts/capabilities.dart';
export 'src/contracts/llm_provider.dart';
export 'src/contracts/llm_request.dart';
export 'src/contracts/llm_response.dart';
export 'src/contracts/model_info.dart';
export 'src/contracts/provider_id.dart';
export 'src/json/json_extract.dart';
export 'src/json/json_schema_lite.dart';
export 'src/providers/anthropic_provider.dart';
export 'src/providers/gemini_provider.dart';
export 'src/providers/openai_compatible.dart';
export 'src/providers/openai_provider.dart';
export 'src/providers/openrouter_provider.dart';
export 'src/providers/xai_provider.dart';
export 'src/tokens/token_estimator.dart';
export 'src/transport/cancel_token.dart';
export 'src/transport/host_allow_list.dart';
export 'src/transport/http_transport.dart';
export 'src/transport/rate_limiter.dart';
export 'src/transport/retry_policy.dart';
