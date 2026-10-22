// OWNER: HOM-05
//
// Shared fixtures of the Home shell tests (BUILD_PLAN HOM-05): a deterministic library (fixed
// paths, so goldens never see a temp directory), the 1.2.0 overflow matrix (280–1280 px × text
// scale 0.85–1.35, ARCH v1.2 §1.4) and a pump helper that installs the Home with the
// DANAVIEW_FILES_HOME test override.

import 'package:danaview_domain/danaview_domain.dart';
import 'package:danaview_features/src/flags.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../library_test_utils.dart';

/// A library with history, resume points, playlists and linked folders at fixed paths.
Future<void> seedFixedLibrary(LibraryTestEnv env) async {
  final history = <MediaRef>[
    for (var i = 1; i <= 8; i++) localRef('/Volumes/Media/Season 1/Show.S01E0$i.$longTitle.mkv'),
    remoteRef('https://streaming.example.com/live/channel/master.m3u8'),
  ];
  for (final media in history.reversed) {
    await env.library.recordPlayed(media);
  }
  for (var i = 0; i < 4; i++) {
    await env.session.saveResumePosition(history[i].id, Duration(minutes: 5 + i * 7), const Duration(minutes: 52));
  }
  for (final name in ['Weekend Anime Marathon With An Absurdly Long Playlist Name', 'Docs', 'Empty']) {
    await env.library.createPlaylist(name);
  }
  await env.library.addToPlaylist('Docs', history.take(3).toList());
  await env.library.addFolder('/Volumes/Media/Movies');
  await env.library.addFolder('/Volumes/Media Drive With A Long Name/Collections/$longTitle');
}

/// The 1.2.0 matrix: every width from 280 to 1280 px at text scales 0.85, 1.0 and 1.35.
final List<TestSurface> homeShellSurfaces = [
  for (final scale in [0.85, 1.0, 1.35]) ...[
    TestSurface(const Size(280, 653), scale, padding: const EdgeInsets.only(top: 20)),
    TestSurface(const Size(320, 568), scale, padding: const EdgeInsets.only(top: 20)),
    TestSurface(const Size(402, 874), scale, padding: const EdgeInsets.only(top: 47, bottom: 34)),
    TestSurface(const Size(768, 1024), scale, padding: const EdgeInsets.only(top: 24)),
    TestSurface(const Size(874, 402), scale, padding: const EdgeInsets.only(left: 47, right: 47, bottom: 21)),
    TestSurface(const Size(1280, 800), scale),
  ],
];

/// Sets the DANAVIEW_FILES_HOME override for this test and clears it afterwards.
void useFilesHome(bool on) {
  FeatureFlags.debugFilesHomeOverride = on;
  addTearDown(FeatureFlags.debugReset);
}

/// Unmounts the tree and disposes [env].
Future<void> finishHome(WidgetTester tester, LibraryTestEnv env) async {
  DanaviewToast.dismiss();
  await tester.pumpWidget(const SizedBox());
  await env.dispose();
}
