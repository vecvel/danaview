import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:danaview_data/danaview_data.dart';
import 'package:danaview_domain/danaview_domain.dart';
import 'package:danaview_engine/danaview_engine.dart';
import 'package:danaview_features/danaview_features.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

const String longTitle =
    'An Extraordinarily Long Episode Title That Keeps Going Well Past Any Reasonable Width '
    '[2160p HDR10+ Dolby Vision Atmos]';

String joinPath(List<String> parts) => parts.join(Platform.pathSeparator);

class LibraryTestEnv {
  LibraryTestEnv._(this.prefs, this.session, this.library, this.engine);

  final SharedPreferences prefs;
  final SessionRepository session;
  final LibraryRepository library;
  final FakePlaybackEngine engine;

  static Future<LibraryTestEnv> create({LibraryStorage? storage}) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final engine = FakePlaybackEngine();
    await engine.initialize();
    return LibraryTestEnv._(
      prefs,
      SessionRepository(prefs),
      LibraryRepository(prefs, storage: storage ?? LibraryStorage(isMobile: false)),
      engine,
    );
  }

  List<Override> get overrides => [
        playbackEngineProvider.overrideWithValue(engine),
        sessionRepositoryProvider.overrideWithValue(session),
        libraryRepositoryProvider.overrideWithValue(library),
      ];

  Future<void> dispose() => engine.dispose();
}

class TestSurface {
  const TestSurface(this.size, this.textScale, {this.padding = EdgeInsets.zero});

  final Size size;
  final double textScale;

  /// Simulated safe-area insets (notch / home indicator), in logical pixels.
  final EdgeInsets padding;

  @override
  String toString() => '${size.width.toInt()}x${size.height.toInt()} @${textScale}x';
}

const _phonePortrait = EdgeInsets.only(top: 47, bottom: 34);
const _phoneLandscape = EdgeInsets.only(left: 47, right: 47, bottom: 21);

final List<TestSurface> librarySurfaces = [
  for (final scale in [1.0, 1.35]) ...[
    TestSurface(const Size(320, 568), scale, padding: const EdgeInsets.only(top: 20)),
    TestSurface(const Size(375, 667), scale, padding: const EdgeInsets.only(top: 20)),
    TestSurface(const Size(402, 874), scale, padding: _phonePortrait),
    TestSurface(const Size(874, 402), scale, padding: _phoneLandscape),
    TestSurface(const Size(1280, 800), scale),
  ],
];

void useSurface(WidgetTester tester, TestSurface surface) {
  tester.view.physicalSize = surface.size;
  tester.view.devicePixelRatio = 1.0;
  tester.view.padding = FakeViewPadding(
    left: surface.padding.left,
    top: surface.padding.top,
    right: surface.padding.right,
    bottom: surface.padding.bottom,
  );
  tester.view.viewPadding = tester.view.padding;
  addTearDown(tester.view.reset);
}

Widget libraryTestApp(
  LibraryTestEnv env,
  Widget home, {
  double textScale = 1.0,
  TargetPlatform platform = TargetPlatform.iOS,
  List<Override> overrides = const [],
}) {
  return ProviderScope(
    overrides: [...env.overrides, ...overrides],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: DanaviewTheme.darkTheme.copyWith(platform: platform),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: home,
    ),
  );
}

/// Pumps frames without settling (spinners animate forever).
Future<void> pumpFrames(WidgetTester tester, {int count = 6}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

MediaRef localRef(String path) => LibraryRepository.mediaRefForFile(path);

MediaRef remoteRef(String url) => MediaUrl.tryParse(url)!;

/// History, resume points, playlists and folders full of very long names.
Future<void> seedLibrary(LibraryTestEnv env, {required String existingDir}) async {
  final history = <MediaRef>[
    for (var i = 1; i <= 9; i++)
      localRef(joinPath([existingDir, 'Season 1', 'Show.S01E0$i.$longTitle.mkv'])),
    remoteRef('https://streaming.example-video-host-with-a-very-long-domain-name.com/live/channel/master.m3u8'),
    localRef(joinPath(['/Volumes', 'Gone', 'Missing Movie $longTitle.mp4'])),
  ];
  for (final media in history.reversed) {
    await env.library.recordPlayed(media);
  }
  for (var i = 0; i < 6; i++) {
    await env.session.saveResumePosition(
      history[i].id,
      Duration(minutes: 5 + i * 7),
      const Duration(minutes: 52),
    );
  }
  for (final name in ['Weekend Anime Marathon With An Absurdly Long Playlist Name That Never Ends', 'Docs', 'Empty']) {
    await env.library.createPlaylist(name);
  }
  await env.library.addToPlaylist('Docs', history.take(4).toList());
  await env.library.addToPlaylist(
    'Weekend Anime Marathon With An Absurdly Long Playlist Name That Never Ends',
    history,
  );
  await env.library.addFolder(existingDir);
  await env.library.addFolder(joinPath(['/Volumes', 'Media Drive With A Long Name', 'Movies', 'Collections', longTitle]));
}

/// A folder tree with nested folders and long-named videos.
Directory createMediaTree() {
  final root = Directory.systemTemp.createTempSync('danaview_library_test_');
  final season = Directory(joinPath([root.path, 'Season 1']))..createSync();
  Directory(joinPath([root.path, 'Extras With A Folder Name That Is Far Too Long To Fit On Any Phone Screen']))
      .createSync();
  Directory(joinPath([root.path, 'Empty Folder'])).createSync();
  for (var i = 1; i <= 9; i++) {
    File(joinPath([season.path, 'Show.S01E0$i.$longTitle.mkv'])).writeAsStringSync('x');
  }
  for (var i = 1; i <= 24; i++) {
    File(joinPath([root.path, 'Movie $i - $longTitle.mp4'])).writeAsStringSync('x');
  }
  return root;
}
