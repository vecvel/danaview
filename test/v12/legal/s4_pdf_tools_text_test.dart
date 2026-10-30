// OWNER: S4-W
//
// The S4 privacy, terms and licence text (BUILD_PLAN v1.2 §1A S4-W; HOM plan §8.5, ARCH v1.2 §5.2,
// §9.1): the PDF tools run on the device and upload nothing, save new files (Replace only for a
// Danaview folder file), signatures are pictures, not certificates; saved signatures stay on this
// device in app-private storage, out of backups and device transfer (the Android rules say so too),
// deletable in Settings › Privacy. The blocks are in the documents exactly when the build has
// DANAVIEW_FILES_HOME. Licences: PdfBox-Android (Apache-2.0) with its NOTICE, and the OFL fonts of
// typed signatures are bundled fonts whose licences the licences screen registers. Run once plain
// and once with `--dart-define=DANAVIEW_FILES_HOME=true`.

// ignore_for_file: implementation_imports, depend_on_referenced_packages

import 'dart:io';

import 'package:danaview/wiring/pdf_tools_wiring.dart' show pdfSignatureFonts;
import 'package:danaview_editor_fonts/danaview_editor_fonts.dart' show contentFontFamilies, contentFontsPackage;
import 'package:danaview_features/src/flags.dart';
import 'package:danaview_features/src/more/danaview_licenses_screen.dart';
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

/// `<exclude domain="file" path="…"/>` paths of [section] in the app's Android rule file [file].
List<String> _excluded(String file, String section) {
  final xml = File('android/app/src/main/res/xml/$file').readAsStringSync().replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
  final body = RegExp('<$section>(.*?)</$section>', dotAll: true).firstMatch(xml)?[1] ?? xml;
  return [for (final m in RegExp(r'<exclude\s+domain="file"\s+path="([^"]*)"\s*/>').allMatches(body)) m[1]!];
}

void main() {
  final stored = _text(pdfToolsStoredBullets);
  final permissions = _text(pdfToolsPermissionBullets);
  final choices = _text(pdfToolsChoiceBullets);
  final terms = pdfToolsTermsSection.blocks.map((b) => b.text ?? '').join('\n');

  test('saved signatures: this device only, app-private, out of backups, deletable in Settings', () {
    expect(stored, contains('Saved signatures'));
    expect(stored, contains('only on this device'));
    expect(stored, contains("app's private storage"));
    expect(stored, contains('not in your Danaview folders'));
    expect(stored, contains('not included in backups'));
    expect(stored, contains('moved to a new device'));
    expect(stored, contains('up to 10'));
    expect(stored, contains('Settings › Privacy'));
    expect(stored, contains('then deleted'), reason: 'the picked photo is not kept');
    expect(choices, contains('Settings › Privacy'));
  });

  test('the PDF tools run on the device, upload nothing and keep the original', () {
    for (final tool in ['Organise pages', 'Merge', 'Annotate', 'Sign', 'Compress']) {
      expect(permissions, contains(tool));
    }
    expect(permissions, contains('on your device'));
    expect(permissions, contains('nothing is uploaded'));
    expect(permissions, contains('new file'));
    expect(permissions, contains('original is never changed'));
    expect(permissions, contains('Replace'));
    expect(permissions, contains('not a certificate-based digital signature'));
    expect(permissions, contains('only the photo you pick'));
    expect(terms, contains('not a certificate-based digital signature'));
    expect(terms, contains('Replace'));
  });

  test('the S4 text names no host and no third party (the tools are offline, ARCH v1.2 §9.1)', () {
    for (final text in [stored, permissions, choices, terms]) {
      expect(text, isNot(matches(RegExp(r'https?://|\.(com|net|org|co)\b'))));
    }
  });

  test('the S3 terms stay true next to Replace: viewing never changes a document', () {
    final s3 = documentsTermsSection.blocks.map((b) => b.text ?? '').join('\n');
    expect(s3, contains('viewing never changes them'));
  });

  test('the text is in the policy and the terms exactly when the build has the Files & Media Home', () {
    final policyBullets = _bulletsOf(privacyPolicyText).toList();
    for (final bullet in [...pdfToolsStoredBullets, ...pdfToolsPermissionBullets, ...pdfToolsChoiceBullets]) {
      expect(policyBullets.contains(bullet), FeatureFlags.filesHome, reason: bullet.lead ?? bullet.text);
    }
    final headings = termsOfUseText.sections.map((s) => s.heading).toList();
    expect(headings.contains(pdfToolsTermsSection.heading), FeatureFlags.filesHome);
    if (FeatureFlags.filesHome) {
      String sectionOf(LegalBullet b) =>
          privacyPolicyText.sections.firstWhere((s) => s.blocks.any((x) => x.bullets?.contains(b) ?? false)).heading;
      expect(sectionOf(pdfToolsStoredBullets.first), 'What Danaview stores on your device');
      expect(sectionOf(pdfToolsPermissionBullets.first), 'Files and permissions');
      expect(sectionOf(pdfToolsChoiceBullets.first), 'Your choices');
      // Right after the S3 documents section.
      expect(headings.indexOf(pdfToolsTermsSection.heading), headings.indexOf(documentsTermsSection.heading) + 1);
    }
  });

  test('Android keeps saved signatures (files/signatures) out of every backup and transfer', () {
    expect(_excluded('danaview_backup_rules.xml', 'full-backup-content'), contains('signatures'));
    expect(_excluded('danaview_data_extraction_rules.xml', 'cloud-backup'), contains('signatures'));
    expect(_excluded('danaview_data_extraction_rules.xml', 'device-transfer'), contains('signatures'));
  });

  test('licences: PdfBox-Android under Apache-2.0 with its NOTICE, Bouncy Castle, the signature fonts', () {
    final pdfBox = danaviewBundledNotices.singleWhere((n) => n.name == 'PdfBox-Android');
    expect(pdfBox.licence, 'Apache-2.0');
    expect(pdfBox.usedFor, contains('PDF tools'));
    expect(pdfBox.text, contains('Licensed under the Apache License, Version 2.0'));
    expect(pdfBox.text, contains('NOTICE'));
    expect(pdfBox.text, contains('This product includes software developed at The Apache Software Foundation'));
    expect(pdfBox.text, contains('Adobe Glyph List'));
    expect(danaviewBundledNotices.where((n) => n.name == 'Bouncy Castle'), hasLength(1));

    // Typed signatures use only bundled OFL content fonts; the licences screen registers the OFL
    // text of every bundled one (registerContentFontLicenses, "<family> (video editor content font)").
    final bundled = {for (final f in contentFontFamilies) if (f.isBundled) f.family};
    for (final font in pdfSignatureFonts) {
      expect(font.package, contentFontsPackage, reason: font.family);
      expect(bundled, contains(font.family), reason: '${font.family} is bundled, so its OFL text is listed');
    }
    for (final dir in ['caveat', 'pacifico', 'playfairdisplay']) {
      expect(File('packages/danaview_editor_fonts/fonts/$dir/OFL.txt').existsSync(), isTrue, reason: dir);
    }
  });
}
