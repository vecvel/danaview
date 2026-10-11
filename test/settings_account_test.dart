import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:danaview_data/danaview_data.dart';
import 'package:danaview_domain/danaview_domain.dart';
import 'package:danaview_features/danaview_features.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import 'library_test_utils.dart';

const _longName = 'Maximilian Alexander Konstantin Wolfeschlegelsteinhausen Jr';
const _longEmail = 'maximilian.alexander.konstantin.wolfeschlegelsteinhausen@a-very-long-domain-example.com';
const _longPhone = '+44 (020) 7946-0958 12';
const _longSupportEmail = 'customer.support.and.privacy.questions@a-very-long-domain-example.com';

final _longProfile = UserProfile(
  name: _longName,
  email: _longEmail,
  phone: _longPhone,
  dateOfBirth: DateTime(1990, 3, 14),
);

/// [librarySurfaces] plus the narrowest phone widths.
final List<TestSurface> _surfaces = [
  for (final scale in [1.0, 1.35]) TestSurface(const Size(280, 560), scale, padding: const EdgeInsets.only(top: 20)),
  ...librarySurfaces,
];

Future<void> _scrollThrough(WidgetTester tester, {Finder? scrollable}) async {
  scrollable ??= find.byType(Scrollable).first;
  for (var i = 0; i < 40; i++) {
    final position = tester.state<ScrollableState>(scrollable).position;
    if (position.pixels >= position.maxScrollExtent) break;
    await tester.drag(scrollable, const Offset(0, -400));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
  }
  await pumpFrames(tester);
  expect(tester.takeException(), isNull);
}

/// Scrolls the page down to [finder] when it isn't built yet (lists build lazily), then taps it.
Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(finder, 200, scrollable: find.byType(Scrollable).first);
  }
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await pumpFrames(tester);
}

Future<void> _finish(WidgetTester tester, LibraryTestEnv env) async {
  DanaviewToast.dismiss();
  await tester.pumpWidget(const SizedBox());
  await env.dispose();
}

/// Scrolls the page to the button first; list pages build lazily.
Future<DanaviewButton> _button(WidgetTester tester, String label) async {
  final finder = find.widgetWithText(DanaviewButton, label);
  await tester.scrollUntilVisible(finder, 200, scrollable: find.byType(Scrollable).first);
  return tester.widget<DanaviewButton>(finder);
}

const _fieldLabels = ['Name', 'Email', 'Phone'];

/// The editable text of a profile field ([index] into [_fieldLabels]), scrolled into view.
Future<Finder> _scrollToField(WidgetTester tester, int index) async {
  final field = find.descendant(
    of: find.byWidgetPredicate((w) => w is DanaviewTextField && w.semanticLabel == _fieldLabels[index]),
    matching: find.byType(EditableText),
  );
  await tester.scrollUntilVisible(field, 200, scrollable: find.byType(Scrollable).first);
  return field;
}

Future<void> _enter(WidgetTester tester, int index, String text) async {
  await tester.enterText(await _scrollToField(tester, index), text);
}

void main() {
  group('UserProfile', () {
    test('initials come from the first and last name, else the email', () {
      expect(const UserProfile(name: 'Ada Lovelace').initials, 'AL');
      expect(const UserProfile(name: '  ada  ').initials, 'A');
      expect(const UserProfile(name: 'jean claude van damme').initials, 'JD');
      expect(const UserProfile(email: 'zed@example.com').initials, 'Z');
      expect(const UserProfile(phone: '+1 555 010 0199').initials, '');
      expect(UserProfile.empty.initials, '');
    });

    test('isEmpty ignores whitespace', () {
      expect(const UserProfile(name: '   ', email: ' ').isEmpty, isTrue);
      expect(UserProfile(dateOfBirth: DateTime(2000)).isEmpty, isFalse);
    });

    test('copyWith keeps or clears the date of birth', () {
      final profile = UserProfile(name: 'Ada', dateOfBirth: DateTime(1990, 3, 14));
      expect(profile.copyWith(name: 'Grace').dateOfBirth, DateTime(1990, 3, 14));
      expect(profile.copyWith(clearDateOfBirth: true).dateOfBirth, isNull);
      expect(profile.copyWith(clearDateOfBirth: true).name, 'Ada');
      expect(profile.copyWith(dateOfBirth: DateTime(2001)).dateOfBirth, DateTime(2001));
    });

    test('JSON round-trips and tolerates bad values', () {
      final profile = UserProfile(
        name: 'Ada',
        email: 'ada@example.com',
        phone: '+44 20',
        dateOfBirth: DateTime(1990, 3, 4),
      );
      final json = profile.toJson();
      expect(json['dateOfBirth'], '1990-03-04');
      expect(UserProfile.fromJson(json), profile);
      expect(UserProfile.fromJson(const {}), UserProfile.empty);
      expect(UserProfile.fromJson(const {'name': 4, 'dateOfBirth': '2023-02-30'}), UserProfile.empty);
      expect(UserProfile.fromJson(const {'dateOfBirth': 19900304}).dateOfBirth, isNull);
      expect(UserProfile.fromJson(const {'dateOfBirth': '2024-02-29'}).dateOfBirth, DateTime(2024, 2, 29));
    });

    test('normalized trims text and drops the time of day', () {
      final profile = UserProfile(
        name: ' Ada ',
        email: ' a@b.co ',
        phone: ' 0123456 ',
        dateOfBirth: DateTime(1990, 3, 4, 13, 5),
      );
      expect(
        profile.normalized(),
        UserProfile(name: 'Ada', email: 'a@b.co', phone: '0123456', dateOfBirth: DateTime(1990, 3, 4)),
      );
    });
  });

  group('ProfileValidation', () {
    test('name is optional and at most 60 characters', () {
      expect(ProfileValidation.name(''), isNull);
      expect(ProfileValidation.name('a' * 60), isNull);
      expect(ProfileValidation.name('  ${'a' * 60}  '), isNull, reason: 'surrounding spaces are trimmed');
      expect(ProfileValidation.name('a' * 61), isNotNull);
      expect(ProfileValidation.name('😀' * 60), isNull, reason: 'counted in characters, not UTF-16 units');
    });

    test('email', () {
      const validEmails = ['', 'a@b.co', 'first.last+tag@mail.example.org', "o'brien@example.ie", ' x@y.io ', _longEmail];
      for (final valid in validEmails) {
        expect(ProfileValidation.email(valid), isNull, reason: valid);
      }
      for (final invalid in [
        'plainaddress',
        'a@b',
        'a@b.c',
        '.a@b.com',
        'a.@b.com',
        'a..b@c.com',
        'a@-b.com',
        'a@b-.com',
        'a b@c.com',
        'a@b.com.',
        'a@@b.com',
        '${'a' * 65}@b.com',
      ]) {
        expect(ProfileValidation.email(invalid), isNotNull, reason: invalid);
      }
    });

    test('phone', () {
      for (final valid in ['', '+1 (555) 010-0199', '0123456', '+44 20 7946 0958', '555.010.0199', _longPhone]) {
        expect(ProfileValidation.phone(valid), isNull, reason: valid);
      }
      for (final invalid in ['12345', '+1 23 45', '1234567890123456', '++123456789', '123+4567890', '555-CALL-NOW']) {
        expect(ProfileValidation.phone(invalid), isNotNull, reason: invalid);
      }
    });

    test('date of birth is not in the future and at most 120 years ago', () {
      final now = DateTime(2026, 10, 3, 9);
      expect(ProfileValidation.dateOfBirth(null, now: now), isNull);
      expect(ProfileValidation.dateOfBirth(DateTime(2026, 10, 3, 23), now: now), isNull, reason: 'today is fine');
      expect(ProfileValidation.dateOfBirth(DateTime(2026, 10, 4), now: now), isNotNull);
      expect(ProfileValidation.dateOfBirth(DateTime(1905, 10, 4), now: now), isNull, reason: 'age 120');
      expect(ProfileValidation.dateOfBirth(DateTime(1905, 10, 3), now: now), isNotNull, reason: 'age 121');
      expect(ProfileValidation.earliestDateOfBirth(now: now), DateTime(1905, 10, 4));
    });

    test('the earliest date of birth matches the age rule on a leap day', () {
      final leapDay = DateTime(2028, 2, 29);
      final earliest = ProfileValidation.earliestDateOfBirth(now: leapDay);
      expect(earliest, DateTime(1907, 3, 1));
      expect(ProfileValidation.dateOfBirth(earliest, now: leapDay), isNull);
      expect(ProfileValidation.dateOfBirth(DateTime(1907, 2, 28), now: leapDay), isNotNull);
    });

    test('ageOn counts completed years', () {
      expect(ProfileValidation.ageOn(DateTime(1990, 3, 14), DateTime(2026, 3, 13)), 35);
      expect(ProfileValidation.ageOn(DateTime(1990, 3, 14), DateTime(2026, 3, 14)), 36);
      expect(ProfileValidation.ageOn(DateTime(2024, 2, 29), DateTime(2025, 2, 28)), 0);
    });

    test('isValid checks every field', () {
      expect(ProfileValidation.isValid(_longProfile), isTrue);
      expect(ProfileValidation.isValid(const UserProfile(email: 'nope')), isFalse);
      expect(ProfileValidation.isValid(UserProfile(dateOfBirth: DateTime.now().add(const Duration(days: 2)))), isFalse);
    });
  });

  group('ProfileRepository', () {
    test('saves, loads and clears one stored value', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final repository = ProfileRepository(prefs);
      expect(repository.load(), UserProfile.empty);

      final saved = await repository.save(
        UserProfile(name: ' Ada Lovelace ', email: 'ada@example.com', dateOfBirth: DateTime(1815, 12, 10, 8)),
      );
      expect(saved, UserProfile(name: 'Ada Lovelace', email: 'ada@example.com', dateOfBirth: DateTime(1815, 12, 10)));
      expect(ProfileRepository(prefs).load(), saved);
      expect(prefs.getKeys().where((k) => k.contains('profile')), hasLength(1));

      expect(await repository.save(const UserProfile(name: '  ')), UserProfile.empty);
      expect(
        prefs.getKeys().where((k) => k.contains('profile')),
        isEmpty,
        reason: 'an empty profile removes the value',
      );

      await repository.save(const UserProfile(phone: '0123456'));
      await repository.clear();
      expect(repository.load(), UserProfile.empty);
    });

    test('unreadable values load as empty', () async {
      SharedPreferences.setMockInitialValues({'danaview_profile': '{not json'});
      expect(ProfileRepository(await SharedPreferences.getInstance()).load(), UserProfile.empty);
      SharedPreferences.setMockInitialValues({'danaview_profile': '[1, 2]'});
      expect(ProfileRepository(await SharedPreferences.getInstance()).load(), UserProfile.empty);
    });
  });

  test('app version matches pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(r'^version:\s*([\d.]+)\+(\d+)\s*$', multiLine: true).firstMatch(pubspec);
    expect(match, isNotNull);
    expect(danaviewAppVersion, match![1]);
    expect(danaviewBuildNumber, int.parse(match[2]!));
  });

  group('Settings', () {
    testWidgets('rows navigate to their destinations', (tester) async {
      useSurface(tester, librarySurfaces[2]);
      final env = await LibraryTestEnv.create();
      final opened = <SettingsDestination>[];
      var backs = 0;
      await tester.pumpWidget(libraryTestApp(
        env,
        DanaviewSettingsScreen(onBack: () => backs++, onNavigate: opened.add),
      ));
      await pumpFrames(tester);
      expect(find.text('Set up your profile'), findsOneWidget);

      const rows = {
        'Set up your profile': SettingsDestination.profile,
        'Speed test': SettingsDestination.speedTest,
        'Stream check': SettingsDestination.streamCheck,
        'Media info': SettingsDestination.mediaInfo,
        'Data usage': SettingsDestination.dataUsage,
        'Storage & history': SettingsDestination.storage,
        'About Danaview': SettingsDestination.about,
        'Privacy Policy': SettingsDestination.privacy,
        'Terms of Use': SettingsDestination.terms,
      };
      for (final MapEntry(key: label, value: destination) in rows.entries) {
        opened.clear();
        await _tapVisible(tester, find.text(label));
        expect(opened, [destination], reason: label);
      }

      await tester.scrollUntilVisible(find.text('Danaview 1.0.0 (1)'), 200);
      await tester.tap(find.byTooltip('Back'));
      expect(backs, 1);
      expect(tester.takeException(), isNull);
      await _finish(tester, env);
    });

    testWidgets('the profile card shows the saved profile', (tester) async {
      useSurface(tester, librarySurfaces[2]);
      final env = await LibraryTestEnv.create();
      await ProfileRepository(env.prefs).save(const UserProfile(name: 'Ada Lovelace', email: 'ada@example.com'));
      await tester.pumpWidget(libraryTestApp(env, DanaviewSettingsScreen(onBack: () {}, onNavigate: (_) {})));
      await pumpFrames(tester);
      expect(find.text('Ada Lovelace'), findsOneWidget);
      expect(find.text('ada@example.com'), findsOneWidget);
      expect(find.text('AL'), findsOneWidget);
      expect(find.text('Set up your profile'), findsNothing);
      await _finish(tester, env);
    });

    testWidgets('an email in the profile card stays on one line instead of breaking mid-word', (tester) async {
      useSurface(tester, const TestSurface(Size(320, 568), 1.35, padding: EdgeInsets.only(top: 20)));
      final env = await LibraryTestEnv.create();
      await ProfileRepository(env.prefs).save(const UserProfile(name: 'Ada', email: _longEmail));
      await tester.pumpWidget(libraryTestApp(
        env,
        DanaviewSettingsScreen(onBack: () {}, onNavigate: (_) {}),
        textScale: 1.35,
      ));
      await pumpFrames(tester);
      final email = tester.widget<Text>(find.text(_longEmail));
      expect(email.maxLines, 1);
      expect(email.softWrap, isFalse);
      expect(email.overflow, TextOverflow.ellipsis);
      expect(tester.takeException(), isNull);
      await _finish(tester, env);
    });

    testWidgets('double-tap seek is offered only on touch screens', (tester) async {
      useSurface(tester, librarySurfaces[4]);
      final env = await LibraryTestEnv.create();
      await tester.pumpWidget(libraryTestApp(
        env,
        DanaviewSettingsScreen(onBack: () {}, onNavigate: (_) {}),
        platform: TargetPlatform.macOS,
      ));
      await pumpFrames(tester);
      await tester.scrollUntilVisible(find.text('Danaview 1.0.0 (1)'), 200);
      expect(find.text('Playback'), findsNothing);
      expect(find.byType(DanaviewSegmentedControl<int>), findsNothing);
      expect(tester.takeException(), isNull);
      await _finish(tester, env);
    });

    testWidgets('double-tap seek is chosen with a segmented control', (tester) async {
      useSurface(tester, librarySurfaces[2]);
      final env = await LibraryTestEnv.create();
      await tester.pumpWidget(libraryTestApp(env, DanaviewSettingsScreen(onBack: () {}, onNavigate: (_) {})));
      await pumpFrames(tester);
      final control = find.byType(DanaviewSegmentedControl<int>);
      expect(tester.widget<DanaviewSegmentedControl<int>>(control).value, SessionRepository.defaultDoubleTapSeekSeconds);
      expect(find.textContaining('by 10 seconds'), findsOneWidget);

      await _tapVisible(tester, find.descendant(of: control, matching: find.text('30s')));
      expect(env.session.getDoubleTapSeekSeconds(), 30);
      expect(tester.widget<DanaviewSegmentedControl<int>>(control).value, 30);
      expect(find.textContaining('by 30 seconds'), findsOneWidget);
      final container = ProviderScope.containerOf(tester.element(control));
      expect(container.read(doubleTapSeekProvider), 30);
      await _finish(tester, env);
    });
  });

  group('Profile', () {
    Future<int Function()> pumpProfile(WidgetTester tester, LibraryTestEnv env) async {
      var backs = 0;
      await tester.pumpWidget(libraryTestApp(env, DanaviewProfileScreen(onBack: () => backs++)));
      await pumpFrames(tester);
      return () => backs;
    }

    testWidgets('validates live, saves and clears', (tester) async {
      useSurface(tester, librarySurfaces[4]);
      final env = await LibraryTestEnv.create();
      await pumpProfile(tester, env);
      expect(find.textContaining('Stored only on this device'), findsOneWidget);
      expect((await _button(tester, 'Save')).onPressed, isNull, reason: 'nothing changed yet');

      await _enter(tester, 0, 'Ada Lovelace');
      await _enter(tester, 1, 'ada@example');
      await tester.pump();
      const emailError = 'Enter an email like name@example.com';
      expect(find.text(emailError), findsNothing, reason: 'errors wait for a pause in typing');
      await pumpFrames(tester, count: 8);
      expect(find.text(emailError), findsOneWidget);
      await tester.scrollUntilVisible(find.text('AL'), -200, scrollable: find.byType(Scrollable).first);
      expect(find.text('AL'), findsOneWidget, reason: 'the avatar previews the initials');
      expect((await _button(tester, 'Save')).onPressed, isNull);

      await _enter(tester, 1, 'ada@example.com');
      await tester.pump();
      expect(find.text(emailError), findsNothing, reason: 'fixed values clear at once');
      await _enter(tester, 2, '123');
      await pumpFrames(tester, count: 8);
      expect(find.text('Phone numbers have 7 to 15 digits'), findsOneWidget);
      await _enter(tester, 2, '+44 20 7946 0958');
      await tester.pump();
      expect((await _button(tester, 'Save')).onPressed, isNotNull);

      await _tapVisible(tester, find.widgetWithText(DanaviewButton, 'Save'));
      expect(find.text('Profile saved'), findsOneWidget);
      expect(
        ProfileRepository(env.prefs).load(),
        const UserProfile(name: 'Ada Lovelace', email: 'ada@example.com', phone: '+44 20 7946 0958'),
      );
      expect((await _button(tester, 'Save')).onPressed, isNull, reason: 'saved, so unchanged');

      await _tapVisible(tester, find.widgetWithText(DanaviewButton, 'Clear profile'));
      expect(find.widgetWithText(DanaviewDialog, 'Clear profile'), findsOneWidget);
      await tester.tap(find.widgetWithText(DanaviewButton, 'Clear'));
      await pumpFrames(tester);
      expect(ProfileRepository(env.prefs).load(), UserProfile.empty);
      expect(find.text('Profile cleared'), findsOneWidget);
      expect(find.text('Ada Lovelace'), findsNothing);
      expect((await _button(tester, 'Clear profile')).onPressed, isNull);
      expect(tester.takeException(), isNull);
      await _finish(tester, env);
    });

    testWidgets('the name length limit shows when typing pauses', (tester) async {
      useSurface(tester, librarySurfaces[4]);
      final env = await LibraryTestEnv.create();
      await pumpProfile(tester, env);
      await _enter(tester, 0, 'a' * 61);
      await pumpFrames(tester, count: 8);
      expect(find.text('Use 60 characters or fewer (61 now)'), findsOneWidget);
      expect((await _button(tester, 'Save')).onPressed, isNull);
      await _finish(tester, env);
    });

    testWidgets('date of birth is picked with the custom picker and cleared', (tester) async {
      useSurface(tester, librarySurfaces[2]);
      final env = await LibraryTestEnv.create();
      await pumpProfile(tester, env);
      expect(find.byType(DanaviewDateWheels), findsNothing);

      await _tapVisible(tester, find.text('Add date of birth'));
      expect(find.byType(DanaviewDateWheels), findsOneWidget);
      expect(find.text('Date of birth'), findsWidgets);
      await tester.tap(find.text('Done'));
      await pumpFrames(tester);

      final now = DateTime.now();
      final expected = DateTime(now.year - 25);
      expect(find.text(danaviewFormatDate(expected)), findsOneWidget);
      expect(find.text('Age ${ProfileValidation.ageOn(expected, now)}'), findsOneWidget);
      await _tapVisible(tester, find.widgetWithText(DanaviewButton, 'Save'));
      expect(ProfileRepository(env.prefs).load().dateOfBirth, expected);

      await _tapVisible(tester, find.byTooltip('Clear date of birth'));
      expect(find.text('Add date of birth'), findsOneWidget);
      expect((await _button(tester, 'Save')).onPressed, isNotNull);
      await _tapVisible(tester, find.widgetWithText(DanaviewButton, 'Undo changes'));
      expect(find.text(danaviewFormatDate(expected)), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _finish(tester, env);
    });

    testWidgets('leaving with unsaved changes asks first', (tester) async {
      useSurface(tester, librarySurfaces[2]);
      final env = await LibraryTestEnv.create();
      final backs = await pumpProfile(tester, env);

      await tester.tap(find.byTooltip('Back'));
      await pumpFrames(tester);
      expect(backs(), 1, reason: 'nothing to lose');

      await _enter(tester, 0, 'Grace');
      await tester.pump();
      await tester.tap(find.byTooltip('Back'));
      await pumpFrames(tester);
      expect(find.widgetWithText(DanaviewDialog, 'Discard changes'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await pumpFrames(tester);
      expect(backs(), 1);
      expect(find.text('Grace'), findsWidgets);

      await tester.tap(find.byTooltip('Back'));
      await pumpFrames(tester);
      await tester.tap(find.widgetWithText(DanaviewButton, 'Discard'));
      await pumpFrames(tester);
      expect(backs(), 2);
      expect(ProfileRepository(env.prefs).load(), UserProfile.empty);
      await _finish(tester, env);
    });

    testWidgets('loads the saved profile into the form', (tester) async {
      useSurface(tester, librarySurfaces[2]);
      final env = await LibraryTestEnv.create();
      await ProfileRepository(env.prefs).save(_longProfile);
      await pumpProfile(tester, env);
      expect(find.text(_longName), findsWidgets);
      expect(find.text(_longEmail), findsWidgets);
      expect(find.text(_longPhone), findsOneWidget);
      expect(find.text('14 March 1990'), findsOneWidget);
      expect((await _button(tester, 'Save')).onPressed, isNull);
      expect((await _button(tester, 'Clear profile')).onPressed, isNotNull);
      await _finish(tester, env);
    });
  });

  group('About and legal', () {
    testWidgets('About shows the version and opens the legal pages', (tester) async {
      useSurface(tester, librarySurfaces[2]);
      final env = await LibraryTestEnv.create();
      final opened = <String>[];
      await tester.pumpWidget(libraryTestApp(
        env,
        DanaviewAboutScreen(
          onBack: () {},
          onOpenPrivacy: () => opened.add('privacy'),
          onOpenTerms: () => opened.add('terms'),
        ),
      ));
      await pumpFrames(tester);
      expect(find.text('Danaview'), findsOneWidget);
      expect(find.text('Version 1.0.0 (build 1)'), findsOneWidget);
      expect(find.text('Open-source licenses'), findsNothing);
      expect(find.textContaining('Flutter'), findsNothing);

      await _tapVisible(tester, find.text('Privacy Policy'));
      await _tapVisible(tester, find.text('Terms of Use'));
      expect(opened, ['privacy', 'terms']);
      await tester.scrollUntilVisible(find.text('Copyright © 2026 vecvel. All rights reserved.'), 200);
      expect(tester.takeException(), isNull);
      await _finish(tester, env);
    });

    testWidgets('About shows the support address only when one is set, and copies it', (tester) async {
      useSurface(tester, librarySurfaces[4]);
      final env = await LibraryTestEnv.create();
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final about = DanaviewAboutScreen(onBack: () {}, onOpenPrivacy: () {}, onOpenTerms: () {});
      await tester.pumpWidget(libraryTestApp(env, about, overrides: [supportEmailProvider.overrideWithValue(null)]));
      await pumpFrames(tester);
      await tester.scrollUntilVisible(find.text('Copyright © 2026 vecvel. All rights reserved.'), 200);
      expect(find.text('Contact support'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(libraryTestApp(
        env,
        about,
        overrides: [supportEmailProvider.overrideWithValue('help@example.com')],
      ));
      await pumpFrames(tester);
      await _tapVisible(tester, find.text('Contact support'));
      expect(copied, ['help@example.com']);
      expect(find.text('Email address copied'), findsOneWidget);
      await _finish(tester, env);
    });

    testWidgets('legal pages describe on-device storage and the network tools', (tester) async {
      useSurface(tester, librarySurfaces[4]);
      final env = await LibraryTestEnv.create();
      final noEmail = [supportEmailProvider.overrideWithValue(null)];
      await tester.pumpWidget(libraryTestApp(
        env,
        DanaviewLegalScreen(document: LegalDocument.privacy, onBack: () {}),
        overrides: noEmail,
      ));
      await pumpFrames(tester);
      expect(find.text('Privacy Policy'), findsOneWidget);
      expect(find.text('Effective 3 October 2026'), findsOneWidget);
      expect(find.textContaining('keeps everything on your device'), findsOneWidget);
      await tester.scrollUntilVisible(find.textContaining('speed.cloudflare.com'), 300);
      expect(find.textContaining('speed.cloudflare.com'), findsOneWidget);
      // The stream check also follows redirects and loads a playlist's first quality level.
      expect(find.textContaining('any address it redirects to'), findsOneWidget);
      await _scrollThrough(tester);
      expect(find.textContaining('On computers, uninstalling may leave'), findsOneWidget);
      expect(find.text('Contact'), findsNothing, reason: 'no support email is set');

      await tester.pumpWidget(libraryTestApp(
        env,
        DanaviewLegalScreen(document: LegalDocument.privacy, onBack: () {}),
        overrides: [supportEmailProvider.overrideWithValue('help@example.com')],
      ));
      await pumpFrames(tester);
      await _scrollThrough(tester);
      expect(find.text('Contact'), findsOneWidget);
      expect(find.textContaining('Email help@example.com.'), findsOneWidget);

      await tester.pumpWidget(libraryTestApp(
        env,
        DanaviewLegalScreen(document: LegalDocument.terms, onBack: () {}),
        overrides: noEmail,
      ));
      await pumpFrames(tester);
      expect(find.text('Terms of Use'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Limitation of liability'), 300);
      expect(find.text('No warranty'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _finish(tester, env);
    });
  });

  group('no overflow', () {
    for (final surface in _surfaces) {
      testWidgets('account pages at $surface', (tester) async {
        useSurface(tester, surface);
        final env = await LibraryTestEnv.create();
        Future<void> show(Widget screen, {String? expectText, bool scroll = true}) async {
          // A fresh ProviderScope, so the profile is read again from storage.
          await tester.pumpWidget(const SizedBox());
          await tester.pumpWidget(libraryTestApp(
            env,
            screen,
            textScale: surface.textScale,
            overrides: [supportEmailProvider.overrideWithValue(_longSupportEmail)],
          ));
          await pumpFrames(tester);
          expect(tester.takeException(), isNull);
          if (expectText != null) expect(find.text(expectText), findsWidgets);
          if (scroll) await _scrollThrough(tester);
        }

        await show(DanaviewSettingsScreen(onBack: () {}, onNavigate: (_) {}), expectText: 'Set up your profile');
        await show(DanaviewProfileScreen(onBack: () {}), expectText: 'Your profile');

        await ProfileRepository(env.prefs).save(_longProfile);
        await show(DanaviewSettingsScreen(onBack: () {}, onNavigate: (_) {}), expectText: _longName);
        await show(DanaviewProfileScreen(onBack: () {}), expectText: _longName, scroll: false);
        // Errors under long values.
        await _enter(tester, 1, '$_longEmail.');
        await _enter(tester, 2, '+44 (020) 7946-0958 1234');
        await pumpFrames(tester, count: 8);
        expect(find.text('Enter an email like name@example.com'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await _scrollThrough(tester);
        await _tapVisible(tester, find.widgetWithText(DanaviewButton, 'Clear profile'));
        expect(find.widgetWithText(DanaviewDialog, 'Clear profile'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.widgetWithText(DanaviewButton, 'Cancel'));
        await pumpFrames(tester);
        await tester.scrollUntilVisible(find.text('14 March 1990'), -200, scrollable: find.byType(Scrollable).first);
        await _tapVisible(tester, find.text('14 March 1990'));
        expect(find.byType(DanaviewDateWheels), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('Close'));
        await pumpFrames(tester);

        await show(DanaviewAboutScreen(onBack: () {}, onOpenPrivacy: () {}, onOpenTerms: () {}));
        await _scrollThrough(tester, scrollable: find.byType(Scrollable).first);
        expect(tester.takeException(), isNull);
        await show(DanaviewLegalScreen(document: LegalDocument.privacy, onBack: () {}));
        await show(DanaviewLegalScreen(document: LegalDocument.terms, onBack: () {}));
        await _finish(tester, env);
      });
    }
  });
}
