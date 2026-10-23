# AIS-42 · Spike: Genkit Dart 1.0 behind `LlmProvider`

- **Ticket:** AIS-42 (AI_STUDIO_PLAN §7.2 D-70b, §7.9; ARCH V2-203, V2-228, rule 19)
- **Date:** 2026-10-22 · **Machine:** Mac (Dart 3.12.2, Flutter 3.44.2, macOS arm64)
- **Spike host:** `spikes/ais-42-genkit/`, a pure-Dart throwaway package. No product package depends on it, and it is not in any workspace. It stays only as reference evidence until the owner signs (BP §0.1 rule 8) and is deleted afterwards.
- **Network:** every call went to the loopback fake (`127.0.0.1`, `FakeProviderServer`). No real keys were used and no paid calls were made.
- **Outcome:** **NO-GO.** Genkit is not adopted. AIS-08 to AIS-10 build the custom `dart:io` adapters for all five providers, D-47 stands (no vendor SDKs), and `danaview_ai_genkit` is not created. The owner signs the outcome below, and AIS-01's ARCH record notes it.

## 1. Versions tested (V-S16)

| Package | Version | Licence | Notes |
|---|---|---|---|
| `genkit` | 1.0.1 (pub.dev, 2026-10-21) | Apache-2.0 | SDK `^3.12.0`; `experimental.dart` holds agents/sessions, as the owner said |
| `genkit_google_genai` | 1.0.1 | Apache-2.0 | Gemini API via a generated client |
| `genkit_openai` | 1.0.1 | Apache-2.0 | `openAI()`, `xAI()`, `deepSeek()` handles over `openai_dart` |
| `genkit_anthropic` | 1.0.1 | Apache-2.0 | over `anthropic_sdk_dart` |
| `genkit_mcp` | 1.0.1 | (not pulled) | exists; not used (tools/MCP are out of scope in 1.2.0) |

The owner's V-S16 facts are confirmed: Apache-2.0, the four plugins exist, and structured output, tools, streaming and embeddings are present.

## 2. How the spike puts Genkit behind our contract

- **`GuardedClient`** (`lib/src/guarded_client.dart`) stands in for AIS-08's `HttpTransport`. It is an `http.BaseClient` handed to each plugin, and every byte that Genkit or the SDKs want to send passes through it. Before any socket opens it checks:
  - the URL is HTTPS;
  - the host is exactly that provider's D-66 host;
  - the URL has no `?key=`;
  - the body's SHA-256 is in the `AiSendTicket`;
  - the number of attempts per hash is at most 3 (1 + D-48's 2 retries).

  It then drops every SDK header except `content-type`, `accept` and `anthropic-version`/`-beta`, sets `User-Agent: Danaview/…` and the provider's key header itself, and optionally reroutes to the loopback fake (D-66 `DANAVIEW_AI_FAKE_HOST`).
- **Keys never enter Genkit.** Plugins get a placeholder key (`dv-placeholder-not-a-key`) so that they never fall back to `OPENAI_API_KEY`, `XAI_API_KEY`, `GEMINI_API_KEY` or `GOOGLE_API_KEY`. The guard strips the placeholder and writes `ApiKey.reveal()` into the header at send time.
- **`prepare` by capture.** D-48's `prepare` is pure and returns the body bytes before consent, but Genkit builds the bytes inside `generate`. The spike therefore runs `generate` once through a capturing guard, which records the bytes and throws `CaptureAbort` before connecting. `send` reruns the same `generate` through a sending guard that refuses any hash outside the ticket. This works only because Genkit's bodies are deterministic. They were, for every provider tested (two captures gave identical hashes; test `c1`).
- **One Genkit instance per operation:** `Genkit(plugins: [...], isDevEnv: false, promptDir: null)`, shut down afterwards.

## 3. Results per criterion and provider

Legend: **PASS** · **FAIL** · **N/A** (the provider itself has no such API, so no adapter, Genkit or custom, could offer it).

| # | Criterion | Gemini | OpenAI | Anthropic | OpenRouter | xAI |
|---|---|---|---|---|---|---|
| 1 | Guarded client injectable; exact bytes seen and hashed; changed byte refused | **FAIL** (public API has no `httpClient`; see C1) | PASS | PASS | PASS | PASS |
| 2 | User keys client-side only, per call; never in env, files, logs | PASS | PASS | PASS | PASS | PASS |
| 3 | OpenRouter and xAI through the OpenAI plugin, base URL fixed by us | — | — | — | PASS | PASS |
| 4 | Dependency weight: transitive deps, licences, Flutter-free, AOT delta, no telemetry/reflection in release | **FAIL** for all (shared: vendor SDKs + 2.1 MB; see C4) | | | | |
| 5a | Structured output in schema mode | PASS | **FAIL** (`strict: false` hard-coded) | PASS (some keywords dropped) | **FAIL** (same) | **FAIL** (same) |
| 5b | Image input | PASS | PASS | PASS | PASS | PASS |
| 5c | Audio input (WAV clips, D-50) | PASS | **FAIL** (`file` part, not `input_audio`) | N/A (no audio input) | **FAIL** (same) | **FAIL** (same) |
| 5d | Text embeddings | PASS | PASS | N/A | PASS | N/A in Genkit (no xAI embedder) |
| 5e | Image embeddings | PASS | N/A (text-only API) | N/A | N/A | N/A |

**All or nothing (owner, 2026-10-16):** Gemini fails C1, and OpenAI, OpenRouter and xAI fail C5. The result is a no-go for all five providers.

### C1 · Transport injection and hash check

**Evidence: `test/c1_transport_hash_test.dart`.** For each provider:
- prepare captures exactly one request and the fake sees zero hits;
- two prepares give the same hash;
- after send, the fake's body SHA-256 equals both the captured hash and the ticket hash;
- a one-character change to the caption text is refused with `hashNotInTicket`, zero requests are sent and the fake sees zero hits.

The guard also refuses a non-allow-listed host, another provider's host, `http://` and `?key=` before connecting.

**Hash evidence** (OpenAI text request, captured, then sent through the guard):

```
captured  POST https://api.openai.com/v1/chat/completions  sha256 = X
ticket    {X}
fake hit  /api.openai.com/v1/chat/completions             sha256 = X   → 200
changed   caption "…7f3a" → "…7f3ax"                       sha256 = Y ∉ ticket → TransportRefused(hashNotInTicket), 0 hits
```

(`X` and `Y` are computed per run. The test asserts `fake.hits.single.sha256Hex == call.requests.single.sha256Hex` and `ticket.hashes.contains(...)`.)

**Gemini fails.** `googleAI({String? apiKey})` exposes no `httpClient`, and its base URL is hard-coded (`https://generativelanguage.googleapis.com/`). The only injection points are:
- **`GoogleGenAiPluginImpl(httpClient:)`** from `package:genkit_google_genai/src/google_api_client.dart`. This is an implementation import marked `@visibleForTesting`, documented as a "test-only HTTP transport", and the analyzer flags it (`implementation_imports`, `invalid_use_of_visible_for_testing_member`). A product package cannot rely on it, because it can change in any patch release.
- **`http.runWithClient` zone override** around the public `googleAI()`. It works in the spike (test "the public googleAI() works only through a zone override"). However, it depends on the plugin constructing `http.Client()` lazily inside our zone, which is an undocumented property. On that path the plugin also stamps `X-Goog-Api-Client: genkit-dart/1.0.1 gl-dart/<sdk>` and the key header before our guard sees the request. The guard strips both, but the plugin is building identifying headers we must undo.

Neither path is "our guarded client can be injected" in a form we can freeze in AIS-08.

**Transport control issues that are not separate criteria but count against "our transport stays in control"** (test `failures_test.dart`):
- **Retries are owned by the SDKs.** `openai_dart` and `anthropic_sdk_dart` retry 429 up to 3 times with their own backoff (about 7 s in total). Genkit does not let us configure `RetryPolicy`. The guard can only cap attempts (the 4th identical attempt is refused with `tooManyAttempts`). The SDKs do not retry 503 on POST, whereas D-48 wants 2 retries on 500/502/503/504 with 2 s and 4 s ±25% jitter and `Retry-After` honoured up to 60 s.
- **Errors are folded into strings.** Every provider returns a 4xx/5xx as `finishReason: failed` plus a message string (`"OpenAI API error: InternalServerException: … (status: 503)"`), not as an exception with a status. The typed `AiFailure` (`quotaExceeded` vs `rateLimited`, etc.) could only be rebuilt from the guard's own copy of the response, which the spike records in `GuardedClient.responses`. That means re-implementing the error half of each adapter anyway.
- **`prepare` becomes async and runs the whole Genkit pipeline twice** (capture, then send), so D-48's pure `prepare(model, request) → bytes` cannot be implemented as specified.

### C2 · Keys

**Evidence: `test/c2_keys_test.dart`.** For each provider:
- the key appears in exactly one wire header: `x-goog-api-key` (Gemini), `x-api-key` (Anthropic) or `authorization: Bearer` (the three OpenAI-compatible providers);
- it never appears in the URL or the body;
- Genkit and the SDKs never see it (only the placeholder);
- `X-Request-ID` (added by both SDKs) and the placeholder never leave the device.

With `Logger.root.level = ALL` and a log spy, the SDKs do log (request lines, and errors at fine level), but no record contains the key, the caption text or the placeholder. No provider key environment variable is set or read. `ApiKey.toString` is redacted.

**PASS for all five**, with one condition. The env fallback exists in every plugin when `apiKey` is null (`getConfigVar` → `Platform.environment`), so a Genkit adapter would need the placeholder rule plus an architecture test for it.

### C3 · OpenRouter and xAI base URLs

**Evidence: `test/c3_base_url_test.dart`.**
- **OpenRouter:** `openAI(name: 'openrouter', baseUrl: 'https://openrouter.ai/api/v1')` → `https://openrouter.ai/api/v1/chat/completions`, with no `HTTP-Referer`/`X-Title` attribution headers.
- **xAI:** `genkit_openai`'s `xAI()` handle defaults to `https://api.x.ai/v1/chat/completions`.
- **Base URL is ours.** The URL comes from our code, never from the user. A plugin built with another base URL (`https://proxy.example/...`) is refused by the guard (`hostNotAllowed`, zero hits).

**PASS.**

### C4 · Dependency weight

**Evidence:** `tool/aot_size.sh` (reproducible) and `test/c4_weight_test.dart`.

- **Flutter-free:** yes. No package resolves to Flutter or `sky_engine`.
- **Runtime packages:** 35 resolve in the spike, counting `crypto`, `http` and `logging`, which the spike adds itself. **16 are new to the app's lockfile:**
  - the plugins themselves: `genkit`, `genkit_google_genai`, `genkit_openai`, `genkit_anthropic`;
  - Genkit's support packages: `schemantic`, `json_schema_builder`, `dotprompt`, `handlebars_dart`, `decimal`, `rational`, `email_validator`, `intl`, `web_socket`, `web_socket_channel`;
  - the two vendor SDKs **`openai_dart` 8.1.0** and **`anthropic_sdk_dart` 8.0.0**.
- **Licences:** Apache-2.0 (genkit family, schemantic, dotprompt, handlebars_dart, decimal, rational, clock), MIT (openai_dart, anthropic_sdk_dart, email_validator, yaml), BSD-3-Clause (dart-lang packages, json_schema_builder). All are permissive; no copyleft.
- **AOT size** (Dart AOT snapshot, macOS arm64; iOS arm64 uses the same gen_snapshot tree shaking):

  | Snapshot | Bytes |
  |---|---|
  | custom adapters (same 5 chat + 3 embedding calls over `dart:io`) | 1,679,456 |
  | Genkit adapters (`bin/aot_genkit.dart`) | 3,779,056 |
  | **delta** | **+2,099,600 (≈ 2.0 MiB)** |

- **Telemetry, tracing exporter, reflection server:**
  - **Default `Genkit()`:** the AOT snapshot keeps the developer reflection server (`/api/runAction`, `/api/__quitquitquit`, `GENKIT_RUNTIME_ID`), the `GENKIT_ENV` lookup (an env var or `--dart-define` can switch it on at run time) and the `CollectorHttpSink` telemetry exporter.
  - **With `isDevEnv: false` as a literal at every construction site:** the compiler drops all of them (0 hits for each probe string), and no instrumentation is configured.

  So this part is controllable, but only by a rule ("every `Genkit(` call passes `isDevEnv: false, promptDir: null`"). The spike pins that rule in a test.

**FAIL (shared by all five).** The binary carries two vendor SDKs, which is exactly what D-47 rules out, and grows by about 2 MB for code that does what the custom adapters of AIS-08 to AIS-10 do directly over `dart:io`. The reflection server and telemetry criterion on its own would pass, with the rule above.

### C5 · Embeddings, multimodal, structured output

**Evidence: `test/c5_capabilities_test.dart`.** Wire shapes as Genkit hands them to the guard:

- **Schema mode:**
  - **Gemini:** `responseMimeType: application/json` plus `responseJsonSchema`. PASS.
  - **Anthropic:** native `output_config.format: {type: json_schema}`. PASS, but the plugin silently drops unsupported keywords (`maxLength` is gone). Our validator still enforces them (D-51).
  - **OpenAI, OpenRouter, xAI:** `response_format: json_schema` with **`strict: false` hard-coded** (`genkit_openai` `buildOpenAIResponseFormat`, no option). ARCH §7.3 requires a strict JSON Schema, and D-48 names `strict: true`. FAIL. The only workaround is for our transport to rewrite Genkit's body bytes, which defeats the point of adopting it.
- **Images:** native shape for all five (`inlineData`; Anthropic `image`/`base64`; `image_url` data URL). PASS.
- **Audio (WAV clips):**
  - **Gemini:** `inlineData audio/wav`. PASS.
  - **OpenAI-compatible (OpenAI, OpenRouter, xAI):** the plugin maps every non-image media part to a `file` content part (`file_data` data URL, `filename: document.wav`). It has no mapping to Chat Completions' `input_audio {data, format: wav}`, the part audio-capable models take for D-50 voice-tone clips. FAIL. **[VERIFY: AIS-40 live]** the exact provider error; the missing mapping itself is in `converters.dart`.
  - **Anthropic:** Genkit sends nothing (the provider has no audio input). N/A.
- **Embeddings:**
  - **Gemini:** text and image (`embedContent` with `inlineData`). PASS.
  - **OpenAI and OpenRouter:** text via `/embeddings` (text-only, by the API's design). PASS.
  - **Anthropic:** no embeddings API. N/A.
  - **xAI:** the `xAI()` handle registers no embedder; whether `api.x.ai` offers one is outside Genkit. N/A.

## 4. Go/no-go

**NO-GO.** Under the all-or-nothing rule, Genkit is not adopted:

1. **C1 fails for Gemini.** There is no supported way to inject our transport; only a test-only `src/` constructor or a zone override.
2. **C5 fails for OpenAI, OpenRouter and xAI.** Strict schemas cannot be requested, and WAV audio is sent in the wrong part type.
3. **C4 fails for all five.** Two vendor SDKs and about 2 MB AOT, against D-47.
4. **Transport control is partial even where C1 passes.** SDK-owned retries, string-folded errors, and a `prepare` that cannot be pure.

**Consequences (no change to any other ticket's spec):**
- AIS-08 to AIS-10 are built custom for all five providers, exactly as written. D-47 (pure `dart:io`, no vendor SDKs) and V2-203 stay final. V2-228 resolves to "not adopted". Rule 19 has no package to apply to, and `danaview_ai_genkit` is not created.
- Useful carry-overs for AIS-08:
  - The **guard pattern** used here maps directly onto `HttpTransport` and its acceptance tests: allow-list per provider, hash ticket, header whitelist with transport-set key header, attempt cap, recorded responses for typed failures.
  - The wire shapes in §3 C5 are a cross-check for AIS-09/AIS-10's hand-written golden fixtures. Gemini uses `responseJsonSchema`, Anthropic uses `output_config.format`, and OpenRouter takes OpenAI's body at `/api/v1`.
- **Revisit** when `genkit_google_genai` exposes `httpClient` publicly and `genkit_openai` offers `strict` and `input_audio`. The spike can be re-run in about 10 minutes (`dart test` and `tool/aot_size.sh`), but C4's vendor-SDK point would still need an owner decision on D-47.

## 5. How to reproduce

```
cd spikes/ais-42-genkit
dart pub get
dart analyze --fatal-infos        # clean (two documented ignores for the Gemini src import)
dart test                         # 63 tests, loopback only
./tool/aot_size.sh                # AOT sizes and release-binary string probes
dart run bin/probe.dart           # prints every captured request body and header set
```

## 6. Sign-off

| Role | Name | Decision | Date |
|---|---|---|---|
| Owner | | ☐ accept no-go (custom adapters AIS-08 to AIS-10) | |

After sign-off: AIS-01's ARCH record notes the outcome (V2-228: not adopted), and `spikes/ais-42-genkit/` is deleted.
