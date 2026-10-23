// OWNER: S3-W
//
// The S3 privacy and terms text (BUILD_PLAN v1.2 §1A S3-W; ARCH v1.2 §3, §5.2, §5.6, §9.3):
// documents stay on the device and open read-only (Quick Look editing off), files opened with or
// shared to Danaview are copies into Danaview folders, the iOS Share Extension's App Group area is
// app-only, emptied on import, cleared of interrupted shares after 24 hours, holds folder names
// only and is outside backups; linked-folder documents are only read. The blocks are in the
// documents exactly when the build has DANAVIEW_FILES_HOME. Run once plain and once with
// `--dart-define=DANAVIEW_FILES_HOME=true`.

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

String _text(Iterable<LegalBullet> bullets) => bullets.map((b) => '${b.lead ?? ''} ${b.text}').join('\n');

void main() {
  final stored = _text(documentsStoredBullets);
  final permissions = _text(documentsPermissionBullets);
  final terms = documentsTermsSection.blocks.map((b) => b.text ?? '').join('\n');

  test('shared and opened files are copies into Danaview folders; the original is never changed', () {
    expect(stored, contains('Files shared with Danaview'));
    expect(stored, contains('copy'));
    expect(stored, contains('Imported'));
    expect(stored, contains('never changed'));
  });

  test('the Share Extension area: app-only, emptied on import, 24 hours, folder names only, no backup', () {
    expect(stored, contains('Share extension (iPhone and iPad)'));
    expect(stored, contains('only Danaview and its extension'));
    expect(stored, contains('removes it'));
    expect(stored, contains('24 hours'));
    expect(stored, contains('names of your Danaview folders'));
    expect(stored, contains('no file names'));
    expect(stored, contains('not included in backups'));
  });

  test('documents open on the device, read-only, Quick Look read-only, linked documents only read', () {
    expect(permissions, contains('on your device'));
    expect(permissions, contains('read-only previews'));
    expect(permissions, contains('never changes the file'));
    expect(permissions, contains('Open in another app'));
    expect(permissions, contains('folders you added'));
    expect(permissions, contains('never renames, moves or deletes'));
    expect(permissions, contains('play as before'));
    expect(terms, contains('never changes them'));
  });

  test('the S3 text names no host and no third party (documents are offline, ARCH v1.2 §9.1)', () {
    for (final text in [stored, permissions, terms]) {
      expect(text, isNot(matches(RegExp(r'https?://|\.(com|net|org|co)\b'))));
      expect(text, isNot(contains('upload')));
    }
  });

  test('the text is in the policy and the terms exactly when the build has the Files & Media Home', () {
    final policyBullets = _bulletsOf(privacyPolicyText).toList();
    for (final bullet in [...documentsStoredBullets, ...documentsPermissionBullets]) {
      expect(policyBullets.contains(bullet), FeatureFlags.filesHome, reason: bullet.lead ?? bullet.text);
    }
    final headings = termsOfUseText.sections.map((s) => s.heading).toList();
    expect(headings.contains(documentsTermsSection.heading), FeatureFlags.filesHome);
    if (FeatureFlags.filesHome) {
      String sectionOf(LegalBullet b) =>
          privacyPolicyText.sections.firstWhere((s) => s.blocks.any((x) => x.bullets?.contains(b) ?? false)).heading;
      expect(sectionOf(documentsStoredBullets.first), 'What Danaview stores on your device');
      expect(sectionOf(documentsPermissionBullets.first), 'Files and permissions');
      // Right after the Home's own blocks.
      expect(headings.indexOf(documentsTermsSection.heading), headings.indexOf(filesHomeTermsSection.heading) + 1);
    }
  });
}
