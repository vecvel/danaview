// OWNER: HOM-13
//
// Shared fixtures of the HOM-13 badge tests: a thumbnail-sized cell of a solid colour (the light
// and dark frames) with the badge overlay on top, inside the kit's dark theme.

import 'package:danaview_features/src/library/badges/media_badge_overlay.dart';
import 'package:danaview_features/src/library/badges/media_badges.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';

/// The light frame (worst case for white text).
const Color lightThumb = Color(0xFFFFFFFF);

/// The dark frame.
const Color darkThumb = Color(0xFF000000);

/// The named badge combinations of the goldens and the matrix.
final Map<String, MediaBadges> badgeCombinations = {
  'duration': const MediaBadges(duration: Duration(minutes: 1, seconds: 23)),
  'duration_long': const MediaBadges(duration: Duration(hours: 1, minutes: 2, seconds: 3)),
  'video_4k_60': const MediaBadges(
    duration: Duration(seconds: 42),
    resolution: MediaResolution.uhd4k,
    frameRate: 59.94,
  ),
  'video_1080p_hdr_50': const MediaBadges(
    duration: Duration(minutes: 12, seconds: 5),
    resolution: MediaResolution.fullHd,
    frameRate: 50,
    isHdr: true,
  ),
  'video_1080p_30': const MediaBadges(
    duration: Duration(minutes: 3),
    resolution: MediaResolution.fullHd,
    frameRate: 29.97,
  ),
  'photo_raw': const MediaBadges(isRaw: true),
  'photo_hdr': const MediaBadges(isHdr: true),
  'photo_live': const MediaBadges(isLive: true),
  'photo_live_raw_hdr': const MediaBadges(isLive: true, isRaw: true, isHdr: true),
  'everything': const MediaBadges(
    duration: Duration(minutes: 9, seconds: 59),
    resolution: MediaResolution.uhd4k,
    frameRate: 120,
    isHdr: true,
    isRaw: true,
    isLive: true,
  ),
};

/// A [width] × [height] cell of [thumb] with [badges] on it.
Widget badgeCell(MediaBadges badges, {required Color thumb, double width = 160, double height = 120}) {
  return SizedBox(
    width: width,
    height: height,
    child: ClipRRect(
      borderRadius: DanaviewRadius.xsAll,
      child: Stack(fit: StackFit.expand, children: [
        ColoredBox(color: thumb),
        MediaBadgeOverlay(badges: badges),
      ]),
    ),
  );
}

/// [child] in the kit's dark theme at [textScale], centred on the app background.
Widget badgeApp(Widget child, {double textScale = 1.0}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: DanaviewTheme.darkTheme,
    builder: (context, c) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
      child: c!,
    ),
    home: ColoredBox(
      color: DanaviewColors.background,
      child: Center(child: RepaintBoundary(key: const ValueKey('badge-golden'), child: child)),
    ),
  );
}
