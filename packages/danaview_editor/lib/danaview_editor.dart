// OWNER: UX-01
//
// Public entry point of the Danaview video editor UI (ARCH §4.6, §17). The app root (router, main)
// uses only this library. Entry points never change after UX-01 (BUILD_PLAN §2): every file
// exported here is exported whole, so the owner tickets that replace these placeholders add public
// names without editing this barrel.

library;

export 'package:danaview_editor_core/model.dart' show ProjectId, TimeUs;

export 'src/app/adapters/adapters.dart';
export 'src/app/editor_availability.dart';
export 'src/app/editor_bootstrap.dart';
export 'src/app/editor_launcher.dart';
export 'src/app/editor_prefs.dart';
export 'src/app/editor_providers.dart';
export 'src/app/editor_storage_contributor.dart';
export 'src/app/speech_storage_contributor.dart';
export 'src/editor/editor_screen.dart';
export 'src/projects/projects_screen.dart';
export 'src/settings/editor_settings_screen.dart';
