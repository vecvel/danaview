# Danaview 1.2.0: Speed test provider fallback

> **Release:** Danaview 1.2.0. **Date:** 2026-10-16. **Status:** plan (owner decision 2026-10-16).
> **Today:** `packages/danaview_data/lib/src/network/speed_test.dart` measures latency, jitter, download and upload against Cloudflare's public speed-test endpoints (`https://speed.cloudflare.com/__down?bytes=N`, `/__up`) using only `dart:io`. `packages/danaview_features/lib/src/more/legal_texts.dart` discloses this.
> **Decision:** no paid infrastructure. Keep Cloudflare's public endpoint as the default, add Measurement Lab (M-Lab, NDT7) as a fallback **only with the user's consent**, and show no provider names in the speed-test UI.

---

## 1. Goals

| # | Goal |
|---|---|
| G1 | **$0 running cost:** no servers, accounts or domains |
| G2 | **Resilient:** if the default provider rate-limits (HTTP 429/403), blocks or stalls, the test still completes |
| G3 | **Quiet UI:** the speed-test screen names no provider ("Testing against a nearby server") |
| G4 | **Honest privacy:** the privacy policy names every provider that receives the user's IP; nothing is published about the user without a prompt they accept |
| G5 | **Honest numbers:** a phase's result always comes from one provider; providers are never mixed within a phase |

## 2. Non-goals

- Our own speed-test endpoint. A free Cloudflare Workers endpoint under a vecvel.com subdomain is kept in reserve (free tier 100k requests/day, about 1,500–3,000 tests a day). It needs a check that the free plan's per-request CPU limit handles 25 MB downloads. Revisit only if Cloudflare's public endpoint changes or disappears.
- A silent M-Lab fallback. M-Lab publishes every result, including the client IP, as public open data, and its terms require telling users before a test. It is therefore always behind a prompt (D-ST2).

## 3. Decisions

| ID | Decision |
|---|---|
| **D-ST1** | **Provider chain:** 1) Cloudflare public (default). 2) M-Lab NDT7, only after the consent prompt. A `SpeedTestProvider` interface keeps the order configurable, so the reserved own endpoint can slot in front later without UI changes. |
| **D-ST2** | **M-Lab consent:** a one-time prompt when the default provider is unavailable: *"Our usual test servers are busy right now. Run the test on an open measurement network instead? Results there, including your IP address, are published publicly for research."* Options: **Run on open network** / **Not now**. The answer is remembered; it can be changed in Settings › Privacy. Declining shows a calm "Couldn't reach a test server. Try again in a minute." |
| **D-ST3** | **Switching:** a health check (one zero-byte request, timeout about 1.5 s) runs at the start, folded into the latency phase so it adds no visible step. On 429, 403, a connection failure or a transfer stall (existing stall timeout), only the failing phase restarts on the next provider. A provider that failed is skipped for 10 minutes (in memory and in prefs). |
| **D-ST4** | **Results:** each phase records the provider that measured it, kept internally for diagnostics and never shown by brand. If download and upload came from different providers, the result notes "measured on two servers" in the details row only. NDT7 measures a single TCP stream (Cloudflare uses parallel HTTP requests), so a result taken on M-Lab is labelled "open network" in the details row. |
| **D-ST5** | **UI copy:** no provider names on the speed-test screen or in results. The neutral wording is "Testing against a nearby server". |
| **D-ST6** | **Privacy policy:** `legal_texts.dart` names both providers: Cloudflare (default; it sees the connection details, such as the IP) and M-Lab (only if you agree; results including the IP are published publicly). The data-safety and App Privacy answers are updated if needed. |

## 4. Tickets

| Ticket | Scope | Depends on |
|---|---|---|
| **ST-01** | `SpeedTestProvider` interface; refactor the current Cloudflare code into `CloudflareSpeedProvider` with no behaviour change; existing `network_test.dart` stays green | — |
| **ST-02** | `MLabNdt7Provider`: NDT7 client over WebSocket (`dart:io`). It uses the M-Lab locate API to find the nearest server, then runs download and upload with NDT7 measurement messages. It has no third-party dependency, or a small vetted one if needed, with licence noted. Unit tests against a local fake NDT7 server | ST-01 |
| **ST-03** | `SpeedTestCoordinator`: health check, per-phase failover, a 10-minute skip memory, per-phase provider attribution (D-ST3, D-ST4). Tests inject 429, 403, stalls and connection errors at every phase | ST-01, ST-02 |
| **ST-04** | Consent prompt and Settings › Privacy toggle (D-ST2), neutral UI copy (D-ST5) and the details-row notes. Custom components, Figtree, no overflow at 280–1280 px and text scale 0.85–1.35 | ST-03 |
| **ST-05** | Privacy text and store privacy answers (D-ST6); the owner reviews the wording | ST-04 |

**Effort:** about 1.5–2 days. **Cost:** $0.
