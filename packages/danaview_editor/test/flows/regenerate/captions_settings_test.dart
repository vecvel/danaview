// OWNER: UX-38
//
// Settings › Video editor › Auto captions and Settings › Storage "Speech model" (ai.md §5.6, §11.5,
// ARCH §17.10): model status and size per tier, Delete behind a destructive confirmation, delete
// blocked while a job runs (in the section and in the storage row), the default layout preference,
// the storage usage and its updates.

import 'package:flutter/material.dart' show Scaffold;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/editor_prefs.dart';
import 'package:danaview_editor/src/app/speech_storage_contributor.dart';
import 'package:danaview_editor/src/app/strings/captions_strings.dart';
import 'package:danaview_editor/src/settings/captions_settings_section.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_features/storage.dart';
import 'package:danaview_transcription/danaview_transcription.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../support/support.dart';
import 'regenerate_rig.dart';

FakeTranscriptionService _fake({int ram = 8 * gib}) => FakeTranscriptionService(physicalRamBytes: ram, clock: () => DateTime.utc(2026, 10, 15));

void _install(FakeTranscriptionService f, SpeechModelSpec spec) =>
    f.statuses[spec.id] = SpeechModelReady(InstalledSpeechModel(spec: spec, installedAt: DateTime.utc(2026, 10, 1)));

Future<void> _pumpSection(WidgetTester tester, EditorTestHarness h, {EditorSurface surface = SurfaceMatrix.phone}) async {
  await h.pumpApp(
    tester,
    SafeAreaHost(child: const CaptionsSettingsSection()),
    surface: surface,
  );
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// A scrollable page around the section.
class SafeAreaHost extends StatelessWidget {
  const SafeAreaHost({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: DanaviewColors.background,
        body: SafeArea(child: ListView(padding: const EdgeInsets.all(16), children: [child])),
      );
}

Future<void> _tap(WidgetTester tester, String key) async {
  final f = find.byKey(ValueKey(key));
  await tester.ensureVisible(f);
  await tester.pump();
  await tester.tap(f);
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

String _statusText(WidgetTester tester, SpeechModelTier tier) =>
    tester.widget<Text>(find.byKey(ValueKey('captions-settings-status-${tier.name}'))).data!;

void main() {
  group('CaptionsSettingsSection', () {
    testWidgets('lists every tier with its size and status', (tester) async {
      final f = _fake();
      _install(f, SpeechModelCatalog.balanced);
      f.statuses[SpeechModelCatalog.fast.id] = const SpeechModelCorrupt();
      await _pumpSection(tester, EditorTestHarness(transcription: f));
      expect(find.text(CaptionsSettingsStrings.section), findsOneWidget);
      expect(_statusText(tester, SpeechModelTier.balanced), '${CaptionsStrings.megabytes(SpeechModelCatalog.balanced.bytes)} · Ready');
      expect(_statusText(tester, SpeechModelTier.fast), CaptionsSettingsStrings.corrupt);
      expect(_statusText(tester, SpeechModelTier.accurate), '${CaptionsStrings.megabytes(SpeechModelCatalog.accurate.bytes)} · Not downloaded');
      expect(find.byKey(const ValueKey('captions-settings-delete-balanced')), findsOneWidget);
      expect(find.byKey(const ValueKey('captions-settings-delete-fast')), findsOneWidget);
      expect(find.byKey(const ValueKey('captions-settings-delete-accurate')), findsNothing);
      expect(find.byKey(const ValueKey('captions-settings-privacy')), findsOneWidget);
      expectOwnerUiRules(tester);
    });

    testWidgets('Accurate is hidden when the device does not qualify', (tester) async {
      await _pumpSection(tester, EditorTestHarness(transcription: _fake(ram: 3 * gib)));
      expect(find.byKey(const ValueKey('captions-settings-model-accurate')), findsNothing);
      expect(find.byKey(const ValueKey('captions-settings-model-fast')), findsOneWidget);
    });

    testWidgets('Delete asks with destructive copy, then deletes the model', (tester) async {
      final f = _fake();
      _install(f, SpeechModelCatalog.balanced);
      await _pumpSection(tester, EditorTestHarness(transcription: f));
      await _tap(tester, 'captions-settings-delete-balanced');
      expect(find.text(SpeechStorageStrings.deleteTitle), findsOneWidget);
      expect(find.text(SpeechStorageStrings.deleteMessage(SpeechModelCatalog.balanced.bytes)), findsOneWidget);
      await tester.tap(find.text(SpeechStorageStrings.delete).last);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(f.statuses[SpeechModelCatalog.balanced.id], isNull);
      expect(_statusText(tester, SpeechModelTier.balanced), contains('Not downloaded'));
      expect(find.byKey(const ValueKey('captions-settings-delete-balanced')), findsNothing);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('Cancel in the confirmation keeps the model', (tester) async {
      final f = _fake();
      _install(f, SpeechModelCatalog.balanced);
      await _pumpSection(tester, EditorTestHarness(transcription: f));
      await _tap(tester, 'captions-settings-delete-balanced');
      await tester.tap(find.text('Cancel'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(f.statuses[SpeechModelCatalog.balanced.id], isA<SpeechModelReady>());
    });

    testWidgets('delete is blocked while a job runs, and comes back when it ends', (tester) async {
      final f = _fake();
      _install(f, SpeechModelCatalog.balanced);
      final job = f.start(rigRequest(const ProjectId('p'))) as FakeTranscriptionJob;
      await _pumpSection(tester, EditorTestHarness(transcription: f));
      expect(_statusText(tester, SpeechModelTier.balanced), SpeechStorageStrings.inUse);
      final button = tester.widget<DanaviewButton>(find.byKey(const ValueKey('captions-settings-delete-balanced')));
      expect(button.onPressed, isNull);
      await tester.tap(find.byKey(const ValueKey('captions-settings-delete-balanced')), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(SpeechStorageStrings.deleteTitle), findsNothing);
      expect(f.statuses[SpeechModelCatalog.balanced.id], isA<SpeechModelReady>());

      job.cancel();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.widget<DanaviewButton>(find.byKey(const ValueKey('captions-settings-delete-balanced'))).onPressed, isNotNull);
    });

    testWidgets('the default layout is stored as editor.captions.defaultPreset', (tester) async {
      final prefs = EditorPrefs.memory();
      final h = EditorTestHarness(transcription: _fake(), prefs: prefs);
      await _pumpSection(tester, h);
      final control = find.descendant(of: find.byKey(const ValueKey('captions-settings-layout')), matching: find.byType(DanaviewSegmentedControl<SegmentationPreset>));
      expect(tester.widget<DanaviewSegmentedControl<SegmentationPreset>>(control).value, SegmentationPreset.standard);
      final label = find.descendant(of: find.byKey(const ValueKey('captions-settings-layout')), matching: find.text(CaptionsStrings.presetName(SegmentationPreset.singleLine)));
      await tester.ensureVisible(label);
      await tester.tap(label);
      await tester.pump(const Duration(milliseconds: 100));
      expect(prefs.captionsDefaultPreset, 'singleLine');
      expect(prefs.readString(EditorPrefKeys.captionsDefaultPreset), 'singleLine');
      expect(tester.widget<DanaviewSegmentedControl<SegmentationPreset>>(control).value, SegmentationPreset.singleLine);
    });

    testWidgets('an unsupported device says so', (tester) async {
      final f = _fake()..supportState = const TranscriptionUnsupported('platform');
      await _pumpSection(tester, EditorTestHarness(transcription: f));
      expect(find.byKey(const ValueKey('captions-settings-unsupported')), findsOneWidget);
      expect(find.byKey(const ValueKey('captions-settings-layout')), findsNothing);
    });
  });

  group('SpeechStorageContributor', () {
    test('describes itself under the Video editor section with a destructive delete', () {
      final c = SpeechStorageContributor(service: _fake());
      expect(c.id, 'editor.speech');
      expect(c.section, 'Video editor');
      expect(c.title, 'Speech model');
      expect(c.ownedPaths, isEmpty);
      final a = c.clearAction;
      expect(a.label, SpeechStorageStrings.deleteAll);
      expect(a.destructive, isTrue);
      expect(a.confirmTitle, 'Delete speech model?');
      expect(a.confirmMessage, contains("Auto captions won't work until you download it again"));
      expect(a.confirmMessage, contains('Captions already in your projects stay.'));
    });

    test('measures models and partial downloads, lists installed tiers', () async {
      final f = _fake();
      _install(f, SpeechModelCatalog.fast);
      _install(f, SpeechModelCatalog.balanced);
      f.extraStorage = const SpeechStorageUsage(partialBytes: 1000, transcriptBytes: 5000);
      final usage = await SpeechStorageContributor(service: f).measure();
      expect(usage.bytes, SpeechModelCatalog.fast.bytes + SpeechModelCatalog.balanced.bytes + 1000);
      expect(usage.detail, 'Fast and Balanced');
      expect(usage.clearBlockedReason, isNull);
      final none = await SpeechStorageContributor(service: _fake()).measure();
      expect(none.bytes, 0);
      expect(none.detail, 'Not downloaded');
    });

    test('delete is blocked while a job runs', () async {
      final f = _fake();
      _install(f, SpeechModelCatalog.balanced);
      final job = f.start(rigRequest(const ProjectId('p')));
      final c = SpeechStorageContributor(service: f);
      expect((await c.measure()).clearBlockedReason, SpeechStorageStrings.inUse);
      final outcome = await c.clear();
      expect(outcome.done, isFalse);
      expect(outcome.blockedReason, SpeechStorageStrings.inUse);
      expect(f.statuses[SpeechModelCatalog.balanced.id], isA<SpeechModelReady>());
      job.cancel();
    });

    test('clear deletes every model and reports the bytes freed; usage updates', () async {
      final f = _fake();
      _install(f, SpeechModelCatalog.balanced);
      final c = SpeechStorageContributor(service: f);
      final seen = <StorageContributorUsage>[];
      final sub = c.watchUsage().listen(seen.add);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(seen.last.bytes, SpeechModelCatalog.balanced.bytes);
      final outcome = await c.clear();
      expect(outcome.done, isTrue);
      expect(outcome.freedBytes, SpeechModelCatalog.balanced.bytes);
      expect(f.statuses, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(seen.last.bytes, 0);
      expect(seen.last.detail, 'Not downloaded');
      await sub.cancel();

      final again = await c.clear();
      expect(again.done, isTrue);
      expect(again.message, SpeechStorageStrings.nothingToDelete);
    });

    test('usage re-measures when a job starts and ends', () async {
      final f = _fake();
      _install(f, SpeechModelCatalog.balanced);
      final c = SpeechStorageContributor(service: f);
      final seen = <StorageContributorUsage>[];
      final sub = c.watchUsage().listen(seen.add);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(seen.last.clearBlockedReason, isNull);
      final job = f.start(rigRequest(const ProjectId('p')));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(seen.last.clearBlockedReason, SpeechStorageStrings.inUse);
      job.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(seen.last.clearBlockedReason, isNull);
      await sub.cancel();
    });
  });
}
