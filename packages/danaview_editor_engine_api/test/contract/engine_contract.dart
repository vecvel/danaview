// OWNER: API-01
//
// BUILD_PLAN API-01 names `test/contract/engine_contract.dart` as the reusable contract kit. The kit
// lives in `lib/src/fake/engine_contract.dart` so other packages can import it through
// `package:danaview_editor_engine_api/testing.dart`; this file re-exports it for tests in this package.

export 'package:danaview_editor_engine_api/testing.dart'
    show checkEngineContract, contractKitGrid, contractKitItem, contractKitPatch, contractKitPlan;
