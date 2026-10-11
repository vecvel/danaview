<!-- Scaffold stub; owners: AI-08 (contracts, catalog, languages, fake), AI-09…AI-13 (subsystems), QA-06 (tuning). -->
# danaview_transcription

Auto captions logic (ARCH §16): pinned model catalog with consent types (download only after a
`UserConsent` built from the exact `ConsentDisclosure` shown; hosts `huggingface.co` and its CDN
`hf.co`), the `TranscriptionService` contract (D-21), the D-28 ports implemented by the editor's
engine adapters, the 99 whisper languages, and `FakeTranscriptionService` in `lib/testing.dart`.
No widgets; never depends on the engine packages, danaview_editor or danaview_features.
