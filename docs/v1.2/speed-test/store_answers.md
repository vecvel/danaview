# Speed test: privacy text and store answers (ST-05)

Ticket ST-05 (V2-406, ST plan D-ST6). These are the notes for AIS-41, which ships the 1.2.0 store
declarations (ARCH §9.5). The owner reviews the wording (Q-S1); until then the text below is the
working default.

## 1. What changed for the speed test in 1.2.0

| | Default provider | Fallback provider |
|---|---|---|
| Who | Cloudflare | Measurement Lab (M-Lab) |
| Hosts | `speed.cloudflare.com` (ARCH §9.1 N-6) | `locate.measurementlab.net`, then the returned `*.measurement-lab.org` NDT7 server (N-7) |
| When | The user taps Start | Only when the default provider fails (429, 403, unreachable, stalled) **and** the user has accepted the one-time open-network prompt (V2-402). Declining never contacts M-Lab |
| What it sends | Test bytes only; the connection itself reveals the IP address | Test bytes and the client name/version (`danaview`, `1.2.0`) M-Lab asks for; the connection reveals the IP address |
| What happens to it | Cloudflare sees the connection details under its own policies | **M-Lab publishes every test result publicly for research, including the IP address** |
| User control | Not starting a test | The answer is remembered and changeable in Settings › Privacy ("Open network speed tests") |

No account, profile field, viewing history, device identifier or file content is sent to either
provider. The in-app speed-test UI names no provider (D-ST5); the privacy policy names both.

## 2. Privacy policy text (`legal_texts.dart`)

Section **When Danaview uses the internet** (`privacyPolicyText`):

- **Speed test** names Cloudflare as the default and `speed.cloudflare.com`, and says Cloudflare sees
  the connection details such as the IP address.
- **Speed test on the open measurement network** names Measurement Lab (M-Lab),
  `locate.measurementlab.net` and `measurement-lab.org`, says it runs only when the usual servers are
  busy and only if the user agrees, says M-Lab publishes results including the IP address publicly,
  and points to Settings › Privacy.

Also edited: **What Danaview doesn't do** (the "no sharing" bullet names the M-Lab exception) and
**Your choices** (Settings › Privacy). Checked by `test/v12/legal/speed_test_text_test.dart`; the hosts
come from the provider code (`CloudflareSpeedProvider.defaultBase`, `MLabLocateClient.defaultEndpoint`,
`MLabLocateClient.isMLabServerUrl`), so a host change fails the test. The hosted policy page
(v1.1 release checklist §5.1) must be regenerated from `privacyPolicyText` at release.

## 3. App Store App Privacy label (notes for AIS-41)

The 1.1.0 label was **Data Not Collected**. Apple counts data as collected when it leaves the device
in a way that the developer or its third-party partners can access beyond what is needed to serve
the request in real time.

- **Cloudflare (default):** unchanged since 1.0. The connection is used only to serve the test, and
  vecvel receives nothing. No label change.
- **M-Lab (fallback, after consent):** M-Lab keeps and publishes the result together with the IP
  address. vecvel has no agreement with M-Lab and receives nothing, and the user chooses M-Lab in a
  prompt that states the publication. Two readings, for the owner and legal to choose (with AIS D-63,
  Q-A9):
  - **A (recommended, conservative):** declare the measurement under **Diagnostics › Other
    Diagnostic Data** (performance data), and, if legal treats the published IP as location data,
    **Location › Coarse Location**; both **not linked to the user**, **not used for tracking**,
    purpose **App Functionality**.
  - **B:** keep **Data Not Collected**, because M-Lab is an independent service the user explicitly
    opts into and is not a partner of vecvel.
  - Record the choice in the open items below.
- **Tracking:** No (no linking with third-party data, no ads, no data brokers).
- AIS D-63 adds the AI Studio rows; AIS-41 merges both into one label.

## 4. Google Play Data safety (notes for AIS-41)

Play counts data sent off the device to a third party as **shared**. The form's exemptions (for
example, a transfer the user initiates and reasonably expects, after a prominent disclosure) may
cover the M-Lab fallback; legal confirms.

- **Cloudflare (default):** no change; "No data collected, no data shared" still holds for it.
- **M-Lab (fallback, after consent):** recommended conservative answer:
  - **Data collected:** No (vecvel receives nothing).
  - **Data shared:** Yes, unless legal applies the exemption: **App info and performance › Other app
    performance data** (the speed measurement) and, if legal treats the published IP that way,
    **Location › Approximate location**. Purpose **App functionality**; optional (only after the user
    accepts the prompt).
  - Encrypted in transit: Yes (HTTPS and `wss://`).
  - Deletion requests: not applicable to vecvel (nothing collected); M-Lab's own policy governs the
    published data.
- Optional explanation field text (append to the 1.1 text):

```text
The speed test measures your connection against Cloudflare's speed test servers. If they are busy, and only if you agree when asked, it runs on Measurement Lab (M-Lab), an open research network that publishes test results, including your IP address. You can change this in Settings › Privacy. Danaview sends no personal data to either service.
```

## 5. App Review note (iOS, optional line)

```text
The built-in speed test uses Cloudflare. If Cloudflare is unavailable, the app asks once before using Measurement Lab (M-Lab), which publishes results including the IP address; the answer can be changed in Settings › Privacy.
```

## 6. Open items

| Item | Owner | Status |
|---|---|---|
| Wording of the two policy bullets (Q-S1) | owner | review pending |
| App Privacy and Data safety choice for M-Lab (§3, §4), merged with AIS D-63 (Q-A9) | owner, AIS-41 | recommendation recorded |
| Regenerate and republish the hosted privacy page | AIS-41 | at release |
