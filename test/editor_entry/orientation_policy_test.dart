import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_features/orientation.dart';
import 'package:danaview_features/danaview_features.dart';

const _portrait = ['DeviceOrientation.portraitUp'];
const _landscape = ['DeviceOrientation.landscapeLeft', 'DeviceOrientation.landscapeRight'];
const _any = <String>[];

/// Records every `setPreferredOrientations` call and the iPhone device-orientation stream.
class _Platform {
  _Platform(WidgetTester tester) {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setPreferredOrientations') {
        calls.add(List<String>.from(call.arguments as List));
      }
      return null;
    });
    messenger.setMockStreamHandler(
      const EventChannel('danaview/device_orientation'),
      MockStreamHandler.inline(
        onListen: (_, sink) {
          _sink = sink;
          listening = true;
          listens++;
        },
        onCancel: (_) => listening = false,
      ),
    );
    addTearDown(() {
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      messenger.setMockStreamHandler(const EventChannel('danaview/device_orientation'), null);
    });
  }

  final calls = <List<String>>[];
  MockStreamHandlerEventSink? _sink;
  bool listening = false;
  int listens = 0;

  Future<void> hold(WidgetTester tester, String orientation) async {
    _sink!.success(orientation);
    await tester.pump();
  }

  List<String>? get last => calls.isEmpty ? null : calls.last;
}

void _useSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

const _phone = Size(402, 874);
const _tablet = Size(820, 1180);

void main() {
  setUp(ScreenOrientationPolicy.resetForTesting);
  tearDown(ScreenOrientationPolicy.resetForTesting);

  group('on Android phones', () {
    testWidgets('a phone follows the app default until an owner enters, and gets it back when the stack empties',
        (tester) async {
      _useSize(tester, _phone);
      final platform = _Platform(tester);
      final player = Object();
      expect(ScreenOrientationPolicy.topMode, OrientationMode.appDefault);

      await ScreenOrientationPolicy.enter(player, OrientationMode.followDevice);
      expect(platform.calls, [_any]);
      expect(ScreenOrientationPolicy.topOwner, same(player));
      expect(ScreenOrientationPolicy.topMode, OrientationMode.followDevice);

      await ScreenOrientationPolicy.release(player);
      expect(platform.calls, [_any, _portrait]);
      expect(ScreenOrientationPolicy.depth, 0);
      expect(ScreenOrientationPolicy.topOwner, isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('editor over player: popping the editor restores the player mode, pinned landscape included',
        (tester) async {
      _useSize(tester, _phone);
      final platform = _Platform(tester);
      final player = Object();
      final editor = Object();

      await ScreenOrientationPolicy.enter(player, OrientationMode.followDevice);
      await ScreenOrientationPolicy.toggle(player, Orientation.portrait);
      expect(platform.last, _landscape);

      await ScreenOrientationPolicy.enter(editor, OrientationMode.free);
      expect(platform.last, _any);
      expect(ScreenOrientationPolicy.topOwner, same(editor));

      await ScreenOrientationPolicy.release(editor);
      // The player is the owner again, still pinned to landscape, and nothing snapped to portrait.
      expect(platform.last, _landscape);
      expect(ScreenOrientationPolicy.topOwner, same(player));
      expect(platform.calls.where((c) => c.length == 1 && c.single == _portrait.single), isEmpty);

      await ScreenOrientationPolicy.release(player);
      expect(platform.last, _portrait);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('editor over an unpinned player restores the free player; the editor can rotate itself',
        (tester) async {
      _useSize(tester, _phone);
      final platform = _Platform(tester);
      final player = Object();
      final editor = Object();
      await ScreenOrientationPolicy.enter(player, OrientationMode.followDevice);
      await ScreenOrientationPolicy.enter(editor, OrientationMode.free);
      await ScreenOrientationPolicy.toggle(editor, Orientation.portrait);
      expect(platform.last, _landscape);
      await ScreenOrientationPolicy.release(editor);
      expect(platform.last, _any);
      expect(ScreenOrientationPolicy.topOwner, same(player));
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('releasing a non-top owner keeps the top owner and applies nothing', (tester) async {
      _useSize(tester, _phone);
      final platform = _Platform(tester);
      final player = Object();
      final editor = Object();
      await ScreenOrientationPolicy.enter(player, OrientationMode.followDevice);
      await ScreenOrientationPolicy.enter(editor, OrientationMode.free);
      final before = platform.calls.length;

      await ScreenOrientationPolicy.release(player);
      expect(platform.calls, hasLength(before));
      expect(ScreenOrientationPolicy.topOwner, same(editor));
      expect(ScreenOrientationPolicy.depth, 1);

      // The editor leaves last: the app default returns (the player is already gone).
      await ScreenOrientationPolicy.release(editor);
      expect(platform.last, _portrait);
      expect(ScreenOrientationPolicy.depth, 0);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('releasing an owner that is not stacked, or twice, does nothing', (tester) async {
      _useSize(tester, _phone);
      final platform = _Platform(tester);
      final player = Object();
      await ScreenOrientationPolicy.release(Object());
      expect(platform.calls, isEmpty);
      await ScreenOrientationPolicy.enter(player, OrientationMode.followDevice);
      await ScreenOrientationPolicy.release(player);
      final count = platform.calls.length;
      await ScreenOrientationPolicy.release(player);
      expect(platform.calls, hasLength(count));
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('toggle flips the top owner, remembers it for a buried owner, and ignores unknown owners',
        (tester) async {
      _useSize(tester, _phone);
      final platform = _Platform(tester);
      final player = Object();
      final editor = Object();
      await ScreenOrientationPolicy.enter(player, OrientationMode.followDevice);

      await ScreenOrientationPolicy.toggle(player, Orientation.portrait);
      expect(platform.last, _landscape);
      // The current orientation is irrelevant once something is pinned: the pin flips back.
      await ScreenOrientationPolicy.toggle(player, Orientation.landscape);
      expect(platform.last, _portrait);
      await ScreenOrientationPolicy.toggle(player, Orientation.portrait);
      expect(platform.last, _landscape);

      await ScreenOrientationPolicy.enter(editor, OrientationMode.free);
      final before = platform.calls.length;
      await ScreenOrientationPolicy.toggle(player, Orientation.landscape);
      expect(platform.calls, hasLength(before), reason: 'a buried owner is not applied');
      await ScreenOrientationPolicy.release(editor);
      expect(platform.last, _portrait, reason: 'the buried toggle was remembered');

      await ScreenOrientationPolicy.toggle(Object(), Orientation.portrait);
      expect(platform.last, _portrait);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('entering again moves the owner to the top with a fresh state', (tester) async {
      _useSize(tester, _phone);
      final platform = _Platform(tester);
      final player = Object();
      final editor = Object();
      await ScreenOrientationPolicy.enter(player, OrientationMode.followDevice);
      await ScreenOrientationPolicy.toggle(player, Orientation.portrait);
      await ScreenOrientationPolicy.enter(editor, OrientationMode.free);
      await ScreenOrientationPolicy.enter(player, OrientationMode.followDevice);
      expect(ScreenOrientationPolicy.depth, 2);
      expect(ScreenOrientationPolicy.topOwner, same(player));
      expect(platform.last, _any, reason: 'the old pin was dropped');
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('an appDefault owner puts the phone upright over a free one', (tester) async {
      _useSize(tester, _phone);
      final platform = _Platform(tester);
      final player = Object();
      final dialog = Object();
      await ScreenOrientationPolicy.enter(player, OrientationMode.followDevice);
      await ScreenOrientationPolicy.enter(dialog, OrientationMode.appDefault);
      expect(platform.last, _portrait);
      await ScreenOrientationPolicy.toggle(dialog, Orientation.portrait);
      expect(platform.last, _portrait, reason: 'appDefault never rotates');
      await ScreenOrientationPolicy.release(dialog);
      expect(platform.last, _any);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('PlayerOrientation stays a thin wrapper over the owner stack', (tester) async {
      _useSize(tester, _phone);
      final platform = _Platform(tester);
      final player = Object();
      await PlayerOrientation.toggle(Orientation.portrait);
      expect(platform.calls, isEmpty, reason: 'no player, nothing to rotate');

      await PlayerOrientation.enter(player);
      expect(ScreenOrientationPolicy.topOwner, same(player));
      expect(ScreenOrientationPolicy.topMode, OrientationMode.followDevice);
      await PlayerOrientation.toggle(Orientation.portrait);
      expect(platform.last, _landscape);

      final editor = Object();
      await ScreenOrientationPolicy.enter(editor, OrientationMode.free);
      await ScreenOrientationPolicy.release(editor);
      expect(ScreenOrientationPolicy.topOwner, same(player));
      expect(platform.last, _landscape);

      await PlayerOrientation.release(player);
      expect(platform.last, _portrait);
      await PlayerOrientation.applyAppDefault();
      expect(platform.last, _portrait);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  });

  group('on tablets', () {
    testWidgets('the app default is free and every mode stays free', (tester) async {
      _useSize(tester, _tablet);
      final platform = _Platform(tester);
      final player = Object();
      final editor = Object();
      await ScreenOrientationPolicy.enter(player, OrientationMode.followDevice);
      await ScreenOrientationPolicy.enter(editor, OrientationMode.free);
      expect(platform.calls, [_any, _any]);
      await ScreenOrientationPolicy.release(editor);
      await ScreenOrientationPolicy.release(player);
      expect(platform.last, _any);
      expect(ScreenOrientationPolicy.depth, 0);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  });

  group('on iPhone', () {
    testWidgets('editor over a pinned player follows the device, and popping restores the pin', (tester) async {
      _useSize(tester, _phone);
      final platform = _Platform(tester);
      final player = Object();
      final editor = Object();

      await ScreenOrientationPolicy.enter(player, OrientationMode.followDevice);
      expect(platform.calls, isEmpty, reason: 'never hands iOS several orientations at once');
      expect(platform.listening, isTrue);
      await platform.hold(tester, 'portraitUp');
      await ScreenOrientationPolicy.toggle(player, Orientation.portrait);
      expect(platform.last, ['DeviceOrientation.landscapeLeft']);

      await ScreenOrientationPolicy.enter(editor, OrientationMode.free);
      // The editor is not pinned: it follows how the phone is held (upright).
      expect(platform.last, ['DeviceOrientation.portraitUp']);
      expect(platform.listens, 1, reason: 'one subscription is shared across owners');
      expect(platform.listening, isTrue);
      await platform.hold(tester, 'landscapeRight');
      expect(platform.last, ['DeviceOrientation.landscapeRight']);
      await platform.hold(tester, 'portraitDown');
      expect(platform.last, ['DeviceOrientation.landscapeRight']);
      await platform.hold(tester, 'portraitUp');
      expect(platform.last, ['DeviceOrientation.portraitUp']);

      await ScreenOrientationPolicy.release(editor);
      expect(platform.last, ['DeviceOrientation.landscapeLeft'], reason: 'the player pin is back');
      expect(platform.listening, isTrue);
      expect(ScreenOrientationPolicy.topOwner, same(player));

      // Turning the phone to match the pin hands control back to the device.
      await platform.hold(tester, 'landscapeLeft');
      await platform.hold(tester, 'portraitUp');
      expect(platform.last, ['DeviceOrientation.portraitUp']);

      await ScreenOrientationPolicy.release(player);
      expect(platform.last, _portrait);
      expect(platform.listening, isFalse);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('editor over a free player restores the held orientation when it pops', (tester) async {
      _useSize(tester, _phone);
      final platform = _Platform(tester);
      final player = Object();
      final editor = Object();
      await ScreenOrientationPolicy.enter(player, OrientationMode.followDevice);
      await platform.hold(tester, 'landscapeRight');
      await ScreenOrientationPolicy.enter(editor, OrientationMode.free);
      expect(platform.last, ['DeviceOrientation.landscapeRight']);
      await platform.hold(tester, 'portraitUp');
      await ScreenOrientationPolicy.release(editor);
      expect(platform.last, ['DeviceOrientation.portraitUp']);
      expect(platform.listening, isTrue);
      await ScreenOrientationPolicy.release(player);
      expect(platform.listening, isFalse);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('releasing a buried owner leaves the device subscription to the top owner', (tester) async {
      _useSize(tester, _phone);
      final platform = _Platform(tester);
      final player = Object();
      final editor = Object();
      await ScreenOrientationPolicy.enter(player, OrientationMode.followDevice);
      await ScreenOrientationPolicy.enter(editor, OrientationMode.free);
      final before = platform.calls.length;
      await ScreenOrientationPolicy.release(player);
      expect(platform.calls, hasLength(before));
      expect(platform.listening, isTrue);
      await platform.hold(tester, 'landscapeLeft');
      expect(platform.last, ['DeviceOrientation.landscapeLeft']);
      await ScreenOrientationPolicy.release(editor);
      expect(platform.listening, isFalse);
      expect(platform.last, _portrait);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('an iPad never uses the device subscription', (tester) async {
      _useSize(tester, _tablet);
      final platform = _Platform(tester);
      final player = Object();
      await ScreenOrientationPolicy.enter(player, OrientationMode.followDevice);
      expect(platform.calls, [_any]);
      expect(platform.listens, 0);
      await ScreenOrientationPolicy.release(player);
      expect(platform.last, _any);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  });

  group('on desktop', () {
    for (final target in [TargetPlatform.macOS, TargetPlatform.windows, TargetPlatform.linux]) {
      testWidgets('$target is a no-op: nothing reaches the platform', (tester) async {
        _useSize(tester, const Size(1280, 800));
        final platform = _Platform(tester);
        final player = Object();
        final editor = Object();
        await ScreenOrientationPolicy.enter(player, OrientationMode.followDevice);
        await ScreenOrientationPolicy.enter(editor, OrientationMode.free);
        await ScreenOrientationPolicy.toggle(editor, Orientation.landscape);
        await ScreenOrientationPolicy.release(player);
        await ScreenOrientationPolicy.release(editor);
        await ScreenOrientationPolicy.applyAppDefault();
        await PlayerOrientation.enter(player);
        await PlayerOrientation.toggle(Orientation.landscape);
        await PlayerOrientation.release(player);
        expect(platform.calls, isEmpty);
        expect(platform.listens, 0);
        expect(ScreenOrientationPolicy.depth, 0);
      }, variant: TargetPlatformVariant.only(target));
    }
  });

  group('cold start before the first real size (QA-02 tablet observation)', () {
    void zeroSize(WidgetTester tester) {
      tester.view.physicalSize = Size.zero;
      tester.view.devicePixelRatio = 2.0;
      tester.view.display.size = Size.zero;
      addTearDown(tester.view.reset);
      addTearDown(tester.view.display.reset);
    }

    for (final target in [TargetPlatform.android, TargetPlatform.iOS]) {
      testWidgets('a 0x0 view locks nothing; the tablet size that follows stays free', (tester) async {
        zeroSize(tester);
        final platform = _Platform(tester);
        expect(ScreenOrientationPolicy.phoneOrUnknown(), isNull);
        await PlayerOrientation.applyAppDefault();
        expect(platform.calls, isEmpty, reason: 'no portrait lock from a 0x0 view');
        expect(ScreenOrientationPolicy.waitingForSize, isTrue);

        tester.view.physicalSize = const Size(2560, 1600); // Pixel Tablet, 1280x800 logical
        await tester.pump();
        expect(platform.calls, [_any]);
        expect(ScreenOrientationPolicy.waitingForSize, isFalse);
      }, variant: TargetPlatformVariant.only(target));

      testWidgets('a 0x0 view then a phone size locks portrait as before', (tester) async {
        zeroSize(tester);
        final platform = _Platform(tester);
        await PlayerOrientation.applyAppDefault();
        expect(platform.calls, isEmpty);

        tester.view.physicalSize = const Size(804, 1748); // 402x874 logical
        await tester.pump();
        expect(platform.calls, [_portrait]);
      }, variant: TargetPlatformVariant.only(target));
    }

    testWidgets('an iPad size is never locked (iOS)', (tester) async {
      _useSize(tester, _tablet);
      final platform = _Platform(tester);
      await PlayerOrientation.applyAppDefault();
      expect(platform.calls, [_any]);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('with a 0x0 view the display size decides', (tester) async {
      zeroSize(tester);
      tester.view.display.size = const Size(2560, 1600);
      final platform = _Platform(tester);
      await PlayerOrientation.applyAppDefault();
      expect(platform.calls, [_any]);
      expect(ScreenOrientationPolicy.waitingForSize, isFalse);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('an owner that entered before the size arrived keeps its orientation', (tester) async {
      zeroSize(tester);
      final platform = _Platform(tester);
      await PlayerOrientation.applyAppDefault();
      final editor = Object();
      await ScreenOrientationPolicy.enter(editor, OrientationMode.free);
      expect(platform.calls, [_any]);

      tester.view.physicalSize = const Size(804, 1748);
      await tester.pump();
      expect(platform.calls, [_any], reason: 'the late size does not put the app default over the editor');

      await ScreenOrientationPolicy.release(editor);
      expect(platform.last, _portrait);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  });
}
