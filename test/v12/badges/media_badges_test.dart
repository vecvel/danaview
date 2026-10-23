// OWNER: HOM-13
//
// BUILD_PLAN HOM-13 (V2-110): which badges an item gets (duration pill, 4K/1080p, frame rate >= 50,
// RAW, HDR, Live) from library items and entry_meta rows; the computed contrast of the badge text
// over the scrim is >= 4.5:1 over light and dark thumbnails (computed over a colour sweep and
// measured on rendered pixels); and the overlay never overflows in cells from 40 to 1280 px wide at
// text scale 0.85–1.35, with a semantics label.

// The root package reaches danaview_library through danaview_features.
// ignore_for_file: depend_on_referenced_packages

import 'dart:ui' as ui;

import 'package:danaview_features/src/library/badges/media_badge_overlay.dart';
import 'package:danaview_features/src/library/badges/media_badges.dart';
import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'badges_support.dart';

final _t = DateTime.utc(2026, 10, 1);

VideoMediaItem _video({int? w, int? h, double fps = 0, Duration d = Duration.zero}) => VideoMediaItem(
      id: ItemId.parse('lk:root/video.mp4'),
      uri: '/v.mp4',
      name: 'v.mp4',
      modifiedAt: _t,
      mimeType: 'video/mp4',
      width: w,
      height: h,
      frameRate: fps,
      duration: d,
    );

void main() {
  group('resolution class', () {
    test('4K, 1080p and below', () {
      expect(MediaResolution.of(3840, 2160), MediaResolution.uhd4k);
      expect(MediaResolution.of(4096, 2160), MediaResolution.uhd4k);
      expect(MediaResolution.of(2160, 3840), MediaResolution.uhd4k, reason: 'portrait 4K');
      expect(MediaResolution.of(3840, 1600), MediaResolution.uhd4k, reason: 'scope crop');
      expect(MediaResolution.of(1920, 1080), MediaResolution.fullHd);
      expect(MediaResolution.of(1080, 1920), MediaResolution.fullHd, reason: 'portrait 1080p');
      expect(MediaResolution.of(1920, 800), MediaResolution.fullHd, reason: 'scope crop');
      expect(MediaResolution.of(2560, 1440), MediaResolution.fullHd);
      expect(MediaResolution.of(1280, 720), isNull);
      expect(MediaResolution.of(null, 1080), isNull);
      expect(MediaResolution.of(0, 0), isNull);
    });
  });

  group('frame rate and duration', () {
    test('frame rate shown from 50 fps, rounded', () {
      expect(const MediaBadges(frameRate: 59.94).roundedFrameRate, 60);
      expect(const MediaBadges(frameRate: 50).roundedFrameRate, 50);
      expect(const MediaBadges(frameRate: 119.88).roundedFrameRate, 120);
      expect(const MediaBadges(frameRate: 48).roundedFrameRate, isNull);
      expect(const MediaBadges(frameRate: 29.97).roundedFrameRate, isNull);
      expect(const MediaBadges(frameRate: 0).roundedFrameRate, isNull);
      expect(const MediaBadges(frameRate: double.nan).roundedFrameRate, isNull);
      expect(const MediaBadges(frameRate: 60).labels.single.label, '60 fps');
    });

    test('duration pill only for a positive duration', () {
      expect(const MediaBadges(duration: Duration(minutes: 1, seconds: 23)).durationLabel, '1:23');
      expect(const MediaBadges(duration: Duration(hours: 1, minutes: 2, seconds: 3)).durationLabel, '1:02:03');
      expect(const MediaBadges(duration: Duration(seconds: 5)).durationLabel, '0:05');
      expect(const MediaBadges(duration: Duration.zero).durationLabel, isNull);
      expect(const MediaBadges(duration: Duration.zero).isEmpty, isTrue);
      expect(MediaBadges.none.isEmpty, isTrue);
    });
  });

  group('from library items', () {
    test('video: duration, resolution, frame rate', () {
      final b = MediaBadges.ofItem(_video(w: 3840, h: 2160, fps: 59.94, d: const Duration(seconds: 90)));
      expect(b.durationLabel, '1:30');
      expect([for (final l in b.labels) l.label], ['4K', '60 fps']);
      expect(b.semanticsLabel, '4K, 60 frames per second, 1:30');
      expect(MediaBadges.ofItem(_video(w: 640, h: 480, fps: 25)).isEmpty, isTrue);
    });

    test('photo: Live, RAW, HDR in that order; no resolution or duration', () {
      final p = PhotoMediaItem(
        id: ItemId.parse('ph:1'),
        uri: 'ph://1',
        name: 'IMG.HEIC',
        modifiedAt: _t,
        mimeType: 'image/heic',
        width: 8064,
        height: 6048,
        isRaw: true,
        isHdr: true,
        isLivePhoto: true,
      );
      final b = MediaBadges.ofItem(p);
      expect([for (final l in b.labels) l.label], ['LIVE', 'RAW', 'HDR']);
      expect(b.durationLabel, isNull);
      expect(b.semanticsLabel, 'Live Photo, RAW, HDR');
    });

    test('entry_meta rows of Danaview videos and photos', () {
      const flags = EntryMeta.flagRaw | EntryMeta.flagHdr | EntryMeta.flagLive;
      final video = MediaBadges.ofMeta(
        FileKind.video,
        const EntryMeta(width: 1920, height: 1080, fps: 50, duration: Duration(minutes: 2), flags: EntryMeta.flagHdr),
      );
      expect([for (final l in video.labels) l.label], ['HDR', '1080p', '50 fps']);
      expect(video.durationLabel, '2:00');
      final photo = MediaBadges.ofMeta(FileKind.photo, const EntryMeta(width: 4000, height: 3000, flags: flags));
      expect([for (final l in photo.labels) l.kind], [MediaBadgeKind.live, MediaBadgeKind.raw, MediaBadgeKind.hdr]);
      expect(MediaBadges.ofMeta(FileKind.photo, const EntryMeta(flags: EntryMeta.flagRaw)).labels.single.label, 'RAW');
      expect(MediaBadges.ofMeta(FileKind.video, null), MediaBadges.none);
      expect(MediaBadges.ofMeta(FileKind.document, const EntryMeta(pageCount: 3, flags: flags)).isEmpty, isTrue);
    });

    test('equality is by what is shown', () {
      expect(const MediaBadges(frameRate: 59.94), const MediaBadges(frameRate: 60.0));
      expect(const MediaBadges(frameRate: 30), MediaBadges.none);
      expect(const MediaBadges(isRaw: true) == const MediaBadges(isHdr: true), isFalse);
    });
  });

  group('contrast >= 4.5:1 over light and dark thumbnails', () {
    test('computed over a sweep of thumbnail colours', () {
      var worst = double.infinity;
      for (var r = 0; r <= 255; r += 17) {
        for (var g = 0; g <= 255; g += 17) {
          for (var b = 0; b <= 255; b += 17) {
            final c = mediaBadgeContrastOver(Color.fromARGB(255, r, g, b));
            if (c < worst) worst = c;
          }
        }
      }
      expect(mediaBadgeContrastOver(lightThumb), greaterThanOrEqualTo(mediaBadgeMinContrast));
      expect(mediaBadgeContrastOver(darkThumb), greaterThanOrEqualTo(mediaBadgeMinContrast));
      expect(worst, greaterThanOrEqualTo(mediaBadgeMinContrast));
      // The worst case is the white frame; translucent thumbnail pixels composite over black.
      expect(worst, closeTo(mediaBadgeContrastOver(lightThumb), 1e-9));
      expect(mediaBadgeContrastOver(const Color(0x80FFFFFF)), greaterThanOrEqualTo(mediaBadgeMinContrast));
    });

    for (final (name, thumb) in [('light', lightThumb), ('dark', darkThumb), ('mid grey', const Color(0xFF808080)), ('yellow', const Color(0xFFFFEB3B))]) {
      testWidgets('measured on the rendered pill over a $name thumbnail', (tester) async {
        await tester.pumpWidget(badgeApp(badgeCell(const MediaBadges(isHdr: true, duration: Duration(minutes: 1)), thumb: thumb)));
        final pill = find.byKey(const ValueKey('media-badge-duration'));
        final box = tester.renderObject<RenderBox>(pill);
        final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('badge-golden')));
        final origin = box.localToGlobal(Offset.zero, ancestor: boundary);
        final pixel = await tester.runAsync(() async {
          final image = await boundary.toImage();
          final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
          // One pixel inside the pill's padding (scrim only, no glyph).
          final x = (origin.dx + 2).round(), y = (origin.dy + box.size.height / 2).round();
          final i = (y * image.width + x) * 4;
          final c = Color.fromARGB(255, data.getUint8(i), data.getUint8(i + 1), data.getUint8(i + 2));
          image.dispose();
          return c;
        });
        final measured = DanaviewColors.contrastRatio(mediaBadgeForeground, pixel!);
        expect(measured, greaterThanOrEqualTo(mediaBadgeMinContrast), reason: 'pill pixel $pixel');
        expect(measured, closeTo(mediaBadgeContrastOver(thumb), 0.25));
      });
    }
  });

  group('layout matrix', () {
    for (final scale in [0.85, 1.0, 1.35]) {
      testWidgets('no overflow in 40–1280 px cells at text scale $scale', (tester) async {
        tester.view.physicalSize = const Size(1400, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        for (final width in [40.0, 64.0, 96.0, 119.0, 120.0, 160.0, 280.0, 402.0, 1280.0]) {
          for (final MapEntry(key: name, value: badges) in badgeCombinations.entries) {
            await tester.pumpWidget(badgeApp(
              badgeCell(badges, thumb: darkThumb, width: width, height: width * 0.75),
              textScale: scale,
            ));
            expect(tester.takeException(), isNull, reason: '$name at $width px');
            final cell = tester.getRect(find.byKey(const ValueKey('badge-golden')));
            for (final pill in tester.widgetList<MediaBadgePill>(find.byType(MediaBadgePill))) {
              final r = tester.getRect(find.byWidget(pill));
              expect(r.left >= cell.left - 0.01 && r.right <= cell.right + 0.01, isTrue, reason: '$name at $width px: $r in $cell');
            }
            final pills = tester.widgetList(find.byType(MediaBadgePill)).length;
            final top = badges.labels.length;
            final expected = (width < mediaBadgeCompactWidth && top > 1 ? 1 : top) + (badges.durationLabel == null ? 0 : 1);
            expect(pills, expected, reason: '$name at $width px');
          }
        }
      });
    }

    testWidgets('semantics label, and none when the cell speaks it', (tester) async {
      final handle = tester.ensureSemantics();
      const badges = MediaBadges(resolution: MediaResolution.uhd4k, duration: Duration(seconds: 42), isHdr: true);
      await tester.pumpWidget(badgeApp(badgeCell(badges, thumb: darkThumb)));
      expect(find.bySemanticsLabel('HDR, 4K, 0:42'), findsOneWidget);
      await tester.pumpWidget(badgeApp(const SizedBox(
        width: 160,
        height: 120,
        child: MediaBadgeOverlay(badges: badges, excludeSemantics: true),
      )));
      expect(find.bySemanticsLabel('HDR, 4K, 0:42'), findsNothing);
      await tester.pumpWidget(badgeApp(badgeCell(MediaBadges.none, thumb: darkThumb)));
      expect(find.byType(MediaBadgePill), findsNothing);
      handle.dispose();
    });
  });
}
