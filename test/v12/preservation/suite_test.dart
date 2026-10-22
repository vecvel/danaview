// OWNER: HOM-15
//
// Player and library regression suite, the merge gate of ARCH v1.2 V2-32 (BUILD_PLAN HOM-15;
// FILES_MEDIA_HOME_PLAN P-1…P-8). One entry point that runs, in one isolate:
//
// * the 1.1 Home tests (`test/home_screen_test.dart`, plus the app-level Home tests of
//   `test/widget_test.dart`: Playlists, Folders, Open link, then Now Playing and Continue watching
//   after playback) with DANAVIEW_FILES_HOME off. They pin the 1.1 widget tree (the first
//   Scrollable is the Home list, "Folders" occurs once, the status-bar backdrop offset), so they
//   are by design flag-off only; with the flag on the same sections live in the `Home` tab and are
//   pinned, behaviour and pixels, by HOM-06…HOM-08 below;
// * the 1.1 player, queue, library and incoming-media tests with the flag off and again with it
//   on (the flag must not change any of them);
// * the HOM-06 (hub), HOM-07 (playlists) and HOM-08 (folders) preservation tests, once: each of
//   their tests already runs under both flag values (and compares the two layouts directly).
//
// Run it with `bash scripts/ci/v12/home_preservation.sh` (or `flutter test
// test/v12/preservation/suite_test.dart`). `home_preservation.sh --self-check` proves the gate
// bites: it plants a changed Continue watching label in a scratch copy of the repo and requires this
// suite to fail there.
//
// The flag is switched through the test-only FeatureFlags override, so one compile covers both
// values; tests that set the flag themselves (HOM-05…HOM-08 helpers) win over the group's value.

import 'package:flutter_test/flutter_test.dart';

import '../../home_screen_test.dart' as home_1_1;
import '../../widget_test.dart' as app_home_1_1;
import '../../incoming_media_test.dart' as incoming_media_1_1;
import '../../library_controller_test.dart' as library_controller_1_1;
import '../../library_repository_test.dart' as library_repository_1_1;
import '../../library_storage_test.dart' as library_storage_1_1;
import '../../media_url_test.dart' as media_url_1_1;
import '../../playback_controllers_test.dart' as queue_1_1;
import '../../player_screen_test.dart' as player_1_1;
import '../../scanner_test.dart' as scanner_1_1;
import '../home_shell/home_shell_support.dart' show useFilesHome;
import 'folders/folders_behaviour_test.dart' as folders_behaviour;
import 'folders/folders_golden_test.dart' as folders_golden;
import 'hub/hub_behaviour_test.dart' as hub_behaviour;
import 'hub/hub_golden_test.dart' as hub_golden;
import 'playlists/playlists_behaviour_test.dart' as playlists_behaviour;
import 'playlists/playlists_golden_test.dart' as playlists_golden;

/// The 1.1 suites that must pass unchanged with the flag off and on, by name.
final Map<String, void Function()> _flagIndependent = {
  'player (test/player_screen_test.dart)': player_1_1.main,
  'queue and playback (test/playback_controllers_test.dart)': queue_1_1.main,
  'library controller (test/library_controller_test.dart)': library_controller_1_1.main,
  'library repository (test/library_repository_test.dart)': library_repository_1_1.main,
  'library storage (test/library_storage_test.dart)': library_storage_1_1.main,
  'folder scanner (test/scanner_test.dart)': scanner_1_1.main,
  'links (test/media_url_test.dart)': media_url_1_1.main,
  'incoming media (test/incoming_media_test.dart)': incoming_media_1_1.main,
};

/// The HOM-06…HOM-08 suites, with the path of the file each golden test resolves against.
final List<({String name, String file, void Function() body})> _preservation = [
  (name: 'HOM-06 hub behaviour', file: 'hub/hub_behaviour_test.dart', body: hub_behaviour.main),
  (name: 'HOM-06 hub goldens', file: 'hub/hub_golden_test.dart', body: hub_golden.main),
  (name: 'HOM-07 playlists behaviour', file: 'playlists/playlists_behaviour_test.dart', body: playlists_behaviour.main),
  (name: 'HOM-07 playlists goldens', file: 'playlists/playlists_golden_test.dart', body: playlists_golden.main),
  (name: 'HOM-08 folders behaviour', file: 'folders/folders_behaviour_test.dart', body: folders_behaviour.main),
  (name: 'HOM-08 folders goldens', file: 'folders/folders_golden_test.dart', body: folders_golden.main),
];

/// Runs every test registered by [body] with DANAVIEW_FILES_HOME = [on] unless a test sets it.
void _withFlag(bool on, void Function() body) {
  setUp(() => useFilesHome(on));
  body();
}

/// Makes `matchesGoldenFile('goldens/…')` in [body] resolve next to [file] (relative to this
/// directory), as it does when that file runs on its own.
void _goldensBesides(String file, void Function() body) {
  late GoldenFileComparator previous;
  setUp(() {
    previous = goldenFileComparator;
    final here = (previous as LocalFileComparator).basedir;
    goldenFileComparator = LocalFileComparator(here.resolve(file));
    addTearDown(() => goldenFileComparator = previous);
  });
  body();
}

void main() {
  group('1.1 Home, flag off', () => _withFlag(false, home_1_1.main));
  group('1.1 app Home, flag off', () => _withFlag(false, app_home_1_1.main));

  for (final on in [false, true]) {
    group('flag ${on ? 'on' : 'off'}', () {
      for (final entry in _flagIndependent.entries) {
        group(entry.key, () => _withFlag(on, entry.value));
      }
    });
  }

  for (final suite in _preservation) {
    group(suite.name, () => _goldensBesides(suite.file, suite.body));
  }
}
