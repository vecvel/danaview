// OWNER: HOM-23
//
// Test support for HOM-23's widget tests: the ARCH §1.4 surface matrix (280–1280 px × text scale
// 0.85–1.35), a dark Danaview app around a surface, a recording FileOutPort, generated text
// fixtures in a temp dir, and the overflow / tap-target / semantics checks.

import 'dart:io';

import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart' show MaterialApp;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// One surface of the matrix.
final class DocSurface {
  /// A surface.
  const DocSurface(this.size, this.textScale);

  /// Logical size (DPR 1).
  final Size size;

  /// Text scale.
  final double textScale;

  @override
  String toString() => '${size.width.toInt()}x${size.height.toInt()}@$textScale';
}

/// Sizes of ARCH §1.4's range (phones, landscape, tablets, desktop).
const List<Size> docSizes = [
  Size(280, 500),
  Size(320, 568),
  Size(390, 844),
  Size(568, 320),
  Size(834, 1194),
  Size(1280, 800),
];

/// Text scales of ARCH §1.4.
const List<double> docTextScales = [0.85, 1.0, 1.35];

/// The full matrix (18 surfaces).
List<DocSurface> get docMatrix => [
      for (final s in docSizes)
        for (final t in docTextScales) DocSurface(s, t),
    ];

/// Sizes the test view like [surface] until the test ends.
void applyDocSurface(WidgetTester tester, DocSurface surface) {
  tester.view.physicalSize = surface.size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// A dark Danaview app showing [home] at [textScale] on [platform].
Widget docApp(Widget home, {double textScale = 1, TargetPlatform platform = TargetPlatform.iOS}) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: DanaviewTheme.darkTheme.copyWith(platform: platform),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: home,
        ),
      ),
    );

/// Records every call; answers as configured.
final class RecordingPort implements FileOutPort {
  /// A port with [platform]'s capabilities.
  RecordingPort([FileOutPlatform platform = FileOutPlatform.iOS]) : capabilities = FileOutCapabilities.of(platform);

  @override
  final FileOutCapabilities capabilities;

  /// (action, files) per call.
  final List<(String, List<OutFile>)> calls = [];

  /// What openIn answers.
  bool openInAnswer = true;

  /// Thrown by every call when set.
  Object? fail;

  @override
  Future<SaveOutOutcome> saveOut(List<OutFile> files, SaveOutTarget target, {OutAnchor? anchor}) async {
    calls.add(('save', files));
    if (fail case final f?) throw f;
    return const SaveOutOutcome(cancelled: false, saved: 1, failed: 0);
  }

  @override
  Future<ShareOutcome> share(List<OutFile> files, {String? subject, OutAnchor? anchor}) async {
    calls.add(('share', files));
    if (fail case final f?) throw f;
    return const ShareOutcome(completed: true);
  }

  @override
  Future<bool> openIn(OutFile file, {OutAnchor? anchor}) async {
    calls.add(('open', [file]));
    if (fail case final f?) throw f;
    return openInAnswer;
  }
}

/// A temp directory removed when the test ends.
Directory docTempDir() {
  final dir = Directory.systemTemp.createTempSync('hom23_');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

/// Fails on any overflow or other exception the last pumps reported.
void expectNoLayoutErrors(WidgetTester tester, Object surface) {
  final errors = <Object>[];
  Object? e;
  while ((e = tester.takeException()) != null) {
    errors.add(e!);
  }
  expect(errors, isEmpty, reason: 'layout errors at $surface');
}

/// Every tappable control on screen is at least 44 × 44 and labelled.
Future<void> expectTargetsAndLabels(WidgetTester tester) async {
  await expectLater(tester, meetsGuideline(const MinimumTapTargetGuideline(size: Size(44, 44), link: 'ARCH v1.2 §1.4')));
  await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
}
