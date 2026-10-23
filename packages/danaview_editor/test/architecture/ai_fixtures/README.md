<!-- OWNER: AIS-01 -->

# AI consent call-site fixtures

Negative and positive fixtures for `../ai_call_sites_test.dart` (AI_STUDIO_PLAN §3.1 rule 13, as
replaced by ARCH v1.2 rule 17). The `.fixture` suffix keeps the analyzer and the UX-01
architecture test (which owns `../fixtures/`) away from them. Each file is scanned as if it lived
at the path the test gives it.

| Fixture | Pretend path | Violations |
|---|---|---|
| `call_outside.dart.fixture` | an editor flow controller | 2 (one per consent kind) |
| `call_outside.dart.fixture` | the allowed send view (`AiSendConsent`) | 1 (`ProviderProbeConsent` is still outside its sheet) |
| `tear_off.dart.fixture` | an editor flow controller | 1 |
| `comment_and_string.dart.fixture` | an editor flow controller | 0 (comments, strings, look-alike names) |
