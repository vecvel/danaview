// OWNER: S2-W
//
// The S2 privacy and terms text (BUILD_PLAN v1.2 §1A S2-W; ARCH v1.2 §5.2–§5.4, §9.4, §9.5): the
// Files & Media Home bullets name Danaview folders, the library database, Recently deleted, backups
// (with the Android 25 MB limit), photo library access, getting files out and how to remove it
// all, and they are in the documents exactly when the build has DANAVIEW_FILES_HOME. Run once
// plain and once with `--dart-define=DANAVIEW_FILES_HOME=true`.

// ignore_for_file: implementation_imports

import 'package:danaview_features/src/flags.dart';
import 'package:danaview_features/src/more/legal_texts.dart';
import 'package:flutter_test/flutter_test.dart';

Iterable<LegalBullet> _bulletsOf(LegalDocumentText doc) sync* {
  for (final section in doc.sections) {
    for (final block in section.blocks) {
      yield* block.bullets ?? const <LegalBullet>[];
    }
  }
}

Iterable<String> _paragraphsOf(LegalDocumentText doc) sync* {
  for (final section in doc.sections) {
    for (final block in section.blocks) {
      if (block.text != null) yield block.text!;
    }
  }
}

String _text(Iterable<LegalBullet> bullets) => bullets.map((b) => '${b.lead ?? ''} ${b.text}').join('\n');

void main() {
  final stored = _text(filesHomeStoredBullets);
  final permissions = _text(filesHomePermissionBullets);
  final choices = _text(filesHomeChoiceBullets);
  final terms = filesHomeTermsSection.blocks.map((b) => b.text ?? '').join('\n');

  test('what the Home stores: Danaview folders as copies, the database, Recently deleted, thumbnails', () {
    expect(stored, contains('Danaview folders'));
    expect(stored, contains('copy'));
    expect(stored, contains('never changed, moved or deleted'));
    expect(stored, contains('Library database'));
    expect(stored, contains('last 50 files'));
    expect(stored, contains('Recently deleted'));
    expect(stored, contains('30 days'));
    expect(stored, contains('Thumbnails'));
    expect(stored, contains('not included in backups'));
  });

  test('backups: Apple device and iCloud, Android with the 25 MB cloud limit, computers', () {
    expect(filesHomeBackupText, contains('iCloud'));
    expect(filesHomeBackupText, contains('25 MB'));
    expect(filesHomeBackupText, contains('phone-to-phone'));
    expect(filesHomeBackupText, contains('On computers'));
  });

  test('photo library access is opt-in, read-only and honours limited access; files leave as copies', () {
    expect(permissions, contains('Show my photo library'));
    expect(permissions, contains('only selected photos'));
    expect(permissions, contains('only reads'));
    expect(permissions, contains('needs no access'));
    expect(permissions, contains('Pictures folder'));
    expect(permissions, contains('copy'));
    expect(permissions, contains('temporary'));
  });

  test('choices: Recently deleted, Library storage, Recents, photo access, uninstall removes the folders', () {
    expect(choices, contains('Empty now'));
    expect(choices, contains('Settings › Library storage'));
    expect(choices, contains('Recents'));
    expect(choices, contains("device's settings"));
    expect(choices, contains('uninstalling Danaview'));
    expect(terms, contains('permanent'));
    expect(terms, contains('Keep your own backups'));
  });

  test('the Home text names no host and no third party (the Home is offline, ARCH v1.2 §9.1)', () {
    for (final text in [stored, permissions, choices, terms, filesHomeBackupText]) {
      expect(text, isNot(matches(RegExp(r'https?://|\.(com|net|org|co)\b'))));
    }
  });

  test('the text is in the policy and the terms exactly when the build has the Files & Media Home', () {
    final policyBullets = _bulletsOf(privacyPolicyText).toList();
    final paragraphs = _paragraphsOf(privacyPolicyText).toList();
    final headings = termsOfUseText.sections.map((s) => s.heading).toList();
    for (final bullet in [...filesHomeStoredBullets, ...filesHomePermissionBullets, ...filesHomeChoiceBullets]) {
      expect(policyBullets.contains(bullet), FeatureFlags.filesHome, reason: bullet.lead ?? bullet.text);
    }
    expect(paragraphs.contains(filesHomeBackupText), FeatureFlags.filesHome);
    expect(headings.contains(filesHomeTermsSection.heading), FeatureFlags.filesHome);
    if (FeatureFlags.filesHome) {
      // In the sections the reader looks for them.
      String sectionOf(LegalBullet b) =>
          privacyPolicyText.sections.firstWhere((s) => s.blocks.any((x) => x.bullets?.contains(b) ?? false)).heading;
      expect(sectionOf(filesHomeStoredBullets.first), 'What Danaview stores on your device');
      expect(sectionOf(filesHomePermissionBullets.first), 'Files and permissions');
      expect(sectionOf(filesHomeChoiceBullets.first), 'Your choices');
    }
  });
}
