<!-- OWNER: API-01 (API-02 plan sync/transport, API-03 math + reference renderer, API-04 render prep own their directories). -->
# danaview_editor_engine_api

The editor's engine contract (ARCH §12): `EditorEngine`, preview sessions, media services and
jobs, export (incl. `whenDetached`, `resume`, `consumeJobRecord`; D-22, D-39), recorder,
platform services, capabilities (`tier`, `maxVisualSequences`, `maxTextureSize`) and typed
failures. Pure Flutter, no native code, no `dart:io`; depends only on `flutter`, `meta`,
`collection` and `danaview_editor_core` (ARCH §4.2 rule 3).

`package:danaview_editor_engine_api/testing.dart` exports:

- `FakeEditorEngine`: deterministic, in-memory. The preview clock moves only through
  `FakePreviewSession.advanceFrames`; plans are validated like a native engine (`planInvalid`);
  patches check `from` (`planOutOfSync`) and classify structural changes; jobs and exports are
  scriptable (`FakeMediaJob.report/complete/fail`, `FakeExportJob`, `exporter.records`);
  `failNext['preview.seek']` etc. inject one failure per method name (see `FakeCallLog`); every
  call is logged in `calls`.
- `checkEngineContract(engine, {settle, exportOutputPath})`: the framework-free contract kit
  (clock `seq` rules, exact-seek acks on the frame grid, patch revision semantics, transients never
  touching the revision, job cancel semantics, export reattach, one-shot records). It returns the
  list of violations; run it against the fake, a mocked-channel `MobileEditorEngine` and the real
  plugin (ENG-09).
- `FakeTexturePlaceholder`: stands in for `Texture` in widget tests.

D-33 placeholders (`// OWNER:` headers, members throw `UnimplementedError`): `plan_sync.dart`,
`plan_transport.dart` (API-02), `math/`, `reference/` (API-03), `render_prep/` (API-04).
