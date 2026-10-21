// OWNER: ST-05
//
// V2-406 (ST plan D-ST6): the privacy policy names both speed-test providers in "When Danaview uses
// the internet": Cloudflare (default; sees connection details such as the IP) and M-Lab (only if
// you agree; results including the IP are published publicly). The hosts come from the provider
// code, so a host change there fails here (ARCH §9.2 rule 4). The store notes for AIS-41 exist.

// The policy text model and the M-Lab locate client are not exported by their packages.
// ignore_for_file: implementation_imports

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_data/danaview_data.dart';
import 'package:danaview_data/src/network/speed/mlab_locate.dart';
import 'package:danaview_features/danaview_features.dart';
import 'package:danaview_features/src/more/legal_texts.dart';
import 'package:danaview_features/src/more/settings_sections/privacy_section.dart' show PrivacySettingsSection;

import '../../library_test_utils.dart';

Iterable<String> _texts(Iterable<LegalBlock> blocks) sync* {
  for (final block in blocks) {
    if (block.text != null) yield block.text!;
    for (final bullet in block.bullets ?? const <LegalBullet>[]) {
      if (bullet.lead != null) yield bullet.lead!;
      yield bullet.text;
    }
  }
}

Iterable<LegalBullet> _bullets(LegalSection section) =>
    section.blocks.expand((b) => b.bullets ?? const <LegalBullet>[]);

void main() {
  final internet = privacyPolicyText.sections.singleWhere((s) => s.heading == 'When Danaview uses the internet');
  final internetText = _texts(internet.blocks).join('\n');
  final policy = [
    privacyPolicyText.summary,
    for (final s in privacyPolicyText.sections) ...[s.heading, ..._texts(s.blocks)],
  ].join('\n');

  final cloudflareHost = CloudflareSpeedProvider.defaultBase.host;
  final locateHost = MLabLocateClient.defaultEndpoint.host;

  group('speed-test providers in "When Danaview uses the internet" (V2-406)', () {
    test('the hosts the providers use are the ones ARCH §9.1 lists', () {
      expect(cloudflareHost, 'speed.cloudflare.com');
      expect(locateHost, 'locate.measurementlab.net');
      expect(MLabLocateClient.isMLabServerUrl(Uri.parse('wss://ndt-mlab1-abc0t.mlab-oti.measurement-lab.org/ndt/v7/download')),
          isTrue);
      expect(MLabLocateClient.isMLabServerUrl(Uri.parse('wss://measurement-lab.org.example.com/')), isFalse);
    });

    test('names both providers and every speed-test host', () {
      expect(internetText, contains('Cloudflare'));
      expect(internetText, contains(cloudflareHost));
      expect(internetText, contains('M-Lab'));
      expect(internetText, contains('Measurement Lab'));
      expect(internetText, contains(locateHost));
      expect(internetText, contains('measurement-lab.org'));
    });

    test('Cloudflare is the default and sees the connection details such as the IP', () {
      final bullet = _bullets(internet).singleWhere((b) => b.lead == 'Speed test');
      expect(bullet.text, contains(cloudflareHost));
      expect(bullet.text, contains('By default'));
      expect(bullet.text, contains('your IP address'));
      expect(bullet.text, contains('sends no personal data'));
      expect(bullet.text, isNot(contains('M-Lab')), reason: 'one provider per bullet');
    });

    test('M-Lab runs only if you agree and publishes results including the IP publicly', () {
      final bullet = _bullets(internet).singleWhere((b) => b.text.contains('M-Lab'));
      expect(bullet.lead, 'Speed test on the open measurement network');
      expect(bullet.text, contains('only if you agree'));
      expect(bullet.text, contains('publishes the results of every test publicly, including your IP address'));
      expect(bullet.text, contains('Settings › Privacy'));
      expect(bullet.text, contains('If you say no, the test never uses M-Lab'));
      expect(bullet.text, isNot(contains(cloudflareHost)), reason: 'the Cloudflare host appears once');
    });

    test('the open-network wording matches the in-app prompt and Settings › Privacy', () {
      // ST-04's Settings › Privacy row and prompt call it the open measurement network.
      expect(PrivacySettingsSection.explanation, contains('open measurement network'));
      expect(internetText, contains('open measurement network'));
      expect(policy, contains('Allow or stop speed tests on the open measurement network at any time in Settings › Privacy.'));
    });

    test('"no sharing" names the M-Lab exception instead of contradicting it', () {
      final doesnt = privacyPolicyText.sections.singleWhere((s) => s.heading == "What Danaview doesn't do");
      final sharing = _bullets(doesnt).singleWhere((b) => b.text.contains('sharing of personal data'));
      expect(sharing.text, contains('open measurement network'));
    });

    test('the Cloudflare host appears exactly once in the whole policy (the legal screen test finds one widget)', () {
      expect(cloudflareHost.allMatches(policy).length, 1);
    });
  });

  test('store answer notes for AIS-41 exist and cover both providers', () {
    final file = File('docs/v1.2/speed-test/store_answers.md');
    expect(file.existsSync(), isTrue);
    final text = file.readAsStringSync();
    for (final needle in [cloudflareHost, locateHost, 'measurement-lab.org', 'App Privacy', 'Data safety', 'AIS-41', 'Q-S1']) {
      expect(text, contains(needle), reason: needle);
    }
  });

  group('the privacy page renders the new text without overflow', () {
    for (final surface in [
      for (final scale in [0.85, 1.35]) ...[
        TestSurface(const Size(280, 560), scale, padding: const EdgeInsets.only(top: 20)),
        TestSurface(const Size(1280, 800), scale),
      ],
    ]) {
      testWidgets('$surface', (tester) async {
        useSurface(tester, surface);
        final env = await LibraryTestEnv.create();
        await tester.pumpWidget(libraryTestApp(
          env,
          DanaviewLegalScreen(document: LegalDocument.privacy, onBack: () {}),
          textScale: surface.textScale,
          overrides: [supportEmailProvider.overrideWithValue(null)],
        ));
        await pumpFrames(tester);
        final mlab = find.textContaining(locateHost);
        await tester.scrollUntilVisible(mlab, 300, scrollable: find.byType(Scrollable).first);
        await pumpFrames(tester, count: 2);
        expect(mlab, findsOneWidget);
        expect(find.textContaining(cloudflareHost), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await env.dispose();
      });
    }
  });
}
