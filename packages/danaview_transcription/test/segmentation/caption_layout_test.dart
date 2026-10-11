// OWNER: AI-11

import 'dart:ui' show Size, TextDirection;

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_transcription/danaview_transcription.dart';

CaptionLayout layout(SegmentationPreset preset, ScriptProfile script, {bool portrait = false, SegmentationSettings? settings}) =>
    CaptionLayout.resolve((settings ?? const SegmentationSettings()).copyWith(preset: settings == null ? preset : settings.preset), script, portrait: portrait);

void main() {
  group('ai.md §9.2 table', () {
    test('Standard: 2 lines x 42, CPS 17, 0.83 s .. 7 s, 2-frame gap, 0.2 s linger, chain < 0.5 s', () {
      final l = layout(SegmentationPreset.standard, ScriptProfile.spaceDelimited);
      expect((l.maxLines, l.maxCharsPerLine, l.maxCps), (2, 42, 17));
      expect((l.minDurationUs, l.maxDurationUs), (830000, 7000000));
      expect((l.minGapFrames, l.lingerUs, l.chainGapUs), (2, 200000, 500000));
    });

    test('Single line: 1 line x 42, max 5 s', () {
      final l = layout(SegmentationPreset.singleLine, ScriptProfile.spaceDelimited);
      expect((l.maxLines, l.maxCharsPerLine, l.maxCps), (1, 42, 17));
      expect((l.minDurationUs, l.maxDurationUs, l.minGapFrames), (830000, 5000000, 2));
    });

    test('Short phrases: 1 line x 20, CPS 20, 0.4 s .. 2.5 s, no gap, 0.1 s linger, chain < 0.3 s', () {
      final l = layout(SegmentationPreset.shortPhrases, ScriptProfile.spaceDelimited);
      expect((l.maxLines, l.maxCharsPerLine, l.maxCps), (1, 20, 20));
      expect((l.minDurationUs, l.maxDurationUs), (400000, 2500000));
      expect((l.minGapFrames, l.lingerUs, l.chainGapUs), (0, 100000, 300000));
    });

    test('script profiles: CJK 16 / CPS 9, Korean 18 / CPS 12, no-space 35', () {
      final cjk = layout(SegmentationPreset.standard, ScriptProfile.cjk);
      final ko = layout(SegmentationPreset.standard, ScriptProfile.korean);
      final th = layout(SegmentationPreset.standard, ScriptProfile.noSpace);
      expect((cjk.maxCharsPerLine, cjk.maxCps), (16, 9));
      expect((ko.maxCharsPerLine, ko.maxCps), (18, 12));
      expect(th.maxCharsPerLine, 35);
      expect(layout(SegmentationPreset.singleLine, ScriptProfile.cjk).maxCharsPerLine, 16);
      expect(layout(SegmentationPreset.shortPhrases, ScriptProfile.cjk).maxCharsPerLine, 8);
      expect(layout(SegmentationPreset.shortPhrases, ScriptProfile.cjk).maxCps, 10);
      expect(layout(SegmentationPreset.shortPhrases, ScriptProfile.korean).maxCharsPerLine, 10);
      expect(layout(SegmentationPreset.shortPhrases, ScriptProfile.noSpace).maxCharsPerLine, 16);
    });
  });

  group('9:16 defaults', () {
    test('space-delimited scripts use 32 characters per line on portrait canvases', () {
      expect(layout(SegmentationPreset.standard, ScriptProfile.spaceDelimited, portrait: true).maxCharsPerLine, 32);
      expect(layout(SegmentationPreset.singleLine, ScriptProfile.spaceDelimited, portrait: true).maxCharsPerLine, 32);
      expect(layout(SegmentationPreset.shortPhrases, ScriptProfile.spaceDelimited, portrait: true).maxCharsPerLine, 20);
      expect(layout(SegmentationPreset.standard, ScriptProfile.cjk, portrait: true).maxCharsPerLine, 16);
    });

    test('the default preset is Standard for landscape and Single line for 9:16, 4:5 and 1:1', () {
      expect(CaptionLayout.defaultPresetFor(portrait: false), SegmentationPreset.standard);
      expect(CaptionLayout.defaultPresetFor(portrait: true), SegmentationPreset.singleLine);
    });

    test('SegmentationContext.forProject applies them from the canvas size and the language', () {
      SegmentationContext ctx(double w, double h, [String lang = 'en']) => SegmentationContext.forProject(
            languageCode: lang,
            settings: const SegmentationSettings(),
            frameRate: FrameRate.fps30,
            canvasSize: Size(w, h),
          );
      expect(ctx(1080, 1920).portrait, isTrue); // 9:16
      expect(ctx(1080, 1350).portrait, isTrue); // 4:5
      expect(ctx(1080, 1080).portrait, isTrue); // 1:1
      expect(ctx(1920, 1080).portrait, isFalse);
      expect(ctx(1920, 1080, 'ja').script, ScriptProfile.cjk);
      expect(ctx(1920, 1080, 'ko').script, ScriptProfile.korean);
      expect(ctx(1920, 1080, 'th').script, ScriptProfile.noSpace);
      expect(ctx(1920, 1080, 'ar').direction, TextDirection.rtl);
      expect(ctx(1920, 1080, 'xx').script, ScriptProfile.spaceDelimited);
    });
  });

  test('user overrides win over the preset', () {
    final l = layout(
      SegmentationPreset.standard,
      ScriptProfile.spaceDelimited,
      settings: const SegmentationSettings(maxLines: 3, maxCharsPerLine: 30, maxCharsPerSecond: 12),
    );
    expect((l.maxLines, l.maxCharsPerLine, l.maxCps), (3, 30, 12));
  });
}
