// OWNER: S3-Q
//
// S3-Q flag-off check of the native declarations S3 ships unconditionally (INT-104: Info.plist
// CFBundleDocumentTypes for images, PDF, Office and text at rank Alternate; the DanaviewShare
// extension). With DANAVIEW_FILES_HOME off, `lib/main.dart` still calls S3-W's
// `installIncomingDocumentOpen`, which on iOS and macOS installs only a guard: photos and documents
// get a neutral toast and never reach the 1.1 player; videos and streams keep the 1.1 path
// (FIX-S3Q-6, fixed by S3-W, re-check 2026-10-23). Each test installs it as main.dart does, for
// iOS and for macOS.
//
// All skip themselves when built with DANAVIEW_FILES_HOME=true (the interceptor's job, covered by
// test/v12/wiring/s3_wiring_test.dart).

import 'package:danaview/app.dart';
import 'package:danaview/router/app_router.dart' show appNavigatorKey;
import 'package:danaview/wiring/documents_wiring.dart' show incomingNotSupportedMessage, installIncomingDocumentOpen;
import 'package:danaview_data/danaview_data.dart';
import 'package:danaview_domain/danaview_domain.dart';
import 'package:danaview_engine/danaview_engine.dart';
import 'package:danaview_features/danaview_features.dart';
import 'package:danaview_platform/danaview_platform.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../library_test_utils.dart';

const bool _filesHome = bool.fromEnvironment('DANAVIEW_FILES_HOME');

Future<FakePlaybackEngine> _pumpApp(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final engine = FakePlaybackEngine();
  await engine.initialize();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        playbackEngineProvider.overrideWithValue(engine),
        sessionRepositoryProvider.overrideWithValue(SessionRepository(prefs)),
        libraryRepositoryProvider.overrideWithValue(
          LibraryRepository(prefs, storage: LibraryStorage(isMobile: false)),
        ),
      ],
      child: const DanaviewApp(),
    ),
  );
  await pumpFrames(tester);
  return engine;
}

Future<void> _tearDown(WidgetTester tester, FakePlaybackEngine engine) async {
  DanaviewToast.dismiss();
  await tester.pumpWidget(const SizedBox());
  await engine.dispose();
}

/// The non-video types the S3 Info.plists declare (one per CFBundleDocumentTypes entry).
const List<String> _declaredNonVideo = [
  '/private/var/mobile/Containers/Data/Application/X/Documents/Inbox/report.pdf',
  '/private/var/mobile/Containers/Data/Application/X/Documents/Inbox/photo.jpg',
  '/private/var/mobile/Containers/Data/Application/X/Documents/Inbox/notes.docx',
  '/private/var/mobile/Containers/Data/Application/X/Documents/Inbox/readme.txt',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    IncomingMediaBridge.interceptor = null;
    IncomingMediaBridge.mockInitialMedia = null;
  });

  for (final os in [TargetPlatform.iOS, TargetPlatform.macOS]) {
    group('S3 flag off (${os.name}): Open with on the declared types', () {
      setUp(() {
        installIncomingDocumentOpen(appNavigatorKey, openEntry: (_, __, ___) async => fail('nothing opens with the flag off'), platform: os);
      });

      testWidgets('videos and streams keep the 1.1 path', (tester) async {
        final engine = await _pumpApp(tester);
        IncomingMediaBridge.emitMockMedia('https://example.com/s3q_flag_off.mp4');
        await pumpFrames(tester, count: 10);
        expect(find.byType(DanaviewPlayerScreen), findsOneWidget);
        expect(engine.currentSnapshot.status, PlaybackStatus.playing);
        await _tearDown(tester, engine);
      }, skip: _filesHome);

      for (final path in _declaredNonVideo) {
        final ext = path.substring(path.lastIndexOf('.'));
        testWidgets('a $ext file never reaches the player (FIX-S3Q-6)', (tester) async {
          final engine = await _pumpApp(tester);
          IncomingMediaBridge.emitMockMedia(path);
          await pumpFrames(tester, count: 10);
          expect(find.byType(DanaviewPlayerScreen), findsNothing);
          expect(find.text(incomingNotSupportedMessage), findsOneWidget);
          final container = ProviderScope.containerOf(tester.element(find.byType(DanaviewApp)));
          expect(container.read(playerControllerProvider).currentMediaRef, isNull);
          await _tearDown(tester, engine);
        }, skip: _filesHome);
      }
    });
  }
}
