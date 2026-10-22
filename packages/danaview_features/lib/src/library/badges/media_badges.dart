// OWNER: HOM-13
//
// The media badge facts of one item (ARCH v1.2 V2-110, HOM plan D-95; BUILD_PLAN HOM-13): a video's
// duration pill, its resolution class (4K, 1080p) and a high frame rate (>= 50 fps), and a photo's
// RAW, HDR and Live Photo indicators (HDR applies to videos too). Pure data: no widgets, no I/O,
// derived from what the library already stores (MediaItem fields or an entry_meta row), so a grid
// cell computes its badges with a few comparisons and never decodes anything.

import 'package:danaview_library/danaview_library.dart';
import 'package:flutter/foundation.dart';

import '../library_format.dart';

/// A video's resolution class, as its badge shows it.
enum MediaResolution {
  /// 3840 px on the long side or 2160 px on the short side and up (UHD, DCI 4K, wider crops).
  uhd4k('4K', '4K'),

  /// 1920 px on the long side or 1080 px on the short side and up (portrait 1080 × 1920 too).
  fullHd('1080p', '1080p');

  const MediaResolution(this.label, this.spoken);

  /// The badge text.
  final String label;

  /// The semantics text.
  final String spoken;

  /// The class of a [width] × [height] video; null below 1080p or when the size is unknown.
  static MediaResolution? of(int? width, int? height) {
    if (width == null || height == null || width <= 0 || height <= 0) return null;
    final long = width > height ? width : height;
    final short = width > height ? height : width;
    if (long >= 3840 || short >= 2160) return uhd4k;
    if (long >= 1920 || short >= 1080) return fullHd;
    return null;
  }
}

/// The lowest frame rate that earns a badge (V2-110: "frame rate (>= 50)").
const double mediaBadgeMinFrameRate = 50;

/// One indicator of the top row, in display order.
enum MediaBadgeKind {
  /// A Live Photo.
  live,

  /// A RAW capture.
  raw,

  /// An HDR photo or video.
  hdr,

  /// The resolution class of a video.
  resolution,

  /// A high frame rate.
  frameRate,
}

/// One indicator: its kind, badge text and semantics text.
@immutable
final class MediaBadgeLabel {
  /// An indicator.
  const MediaBadgeLabel(this.kind, this.label, this.spoken);

  /// What it marks.
  final MediaBadgeKind kind;

  /// The badge text.
  final String label;

  /// The semantics text.
  final String spoken;

  @override
  bool operator ==(Object other) =>
      other is MediaBadgeLabel && other.kind == kind && other.label == label && other.spoken == spoken;

  @override
  int get hashCode => Object.hash(kind, label, spoken);

  @override
  String toString() => 'MediaBadgeLabel(${kind.name}, $label)';
}

/// The badges of one item. Every field is optional; [isEmpty] badges draw nothing.
@immutable
final class MediaBadges {
  /// Badges. [duration] is shown only when positive, [frameRate] only when >= 50.
  const MediaBadges({
    this.duration,
    this.resolution,
    this.frameRate,
    this.isRaw = false,
    this.isHdr = false,
    this.isLive = false,
  });

  /// No badges.
  static const MediaBadges none = MediaBadges();

  /// The badges of a library item: duration, resolution, frame rate and HDR for a video; RAW, HDR
  /// and Live for a photo; none for a document.
  factory MediaBadges.ofItem(MediaItem item) => switch (item) {
        VideoMediaItem v => MediaBadges(
            duration: v.duration,
            resolution: MediaResolution.of(v.width, v.height),
            frameRate: v.frameRate,
          ),
        PhotoMediaItem p => MediaBadges(isRaw: p.isRaw, isHdr: p.isHdr, isLive: p.isLivePhoto),
        DocumentMediaItem() => none,
      };

  /// The badges of a Danaview entry of [kind] from its `entry_meta` row ([meta] null: none yet).
  factory MediaBadges.ofMeta(FileKind kind, EntryMeta? meta) {
    if (meta == null) return none;
    final hdr = meta.flags & EntryMeta.flagHdr != 0;
    return switch (kind) {
      FileKind.video => MediaBadges(
          duration: meta.duration,
          resolution: MediaResolution.of(meta.width, meta.height),
          frameRate: meta.fps,
          isHdr: hdr,
        ),
      FileKind.photo => MediaBadges(
          isRaw: meta.flags & EntryMeta.flagRaw != 0,
          isHdr: hdr,
          isLive: meta.flags & EntryMeta.flagLive != 0,
        ),
      _ => none,
    };
  }

  /// The badges of a Danaview entry ([meta] is its `entry_meta` row, if loaded).
  factory MediaBadges.ofEntry(FileEntry entry, EntryMeta? meta) => MediaBadges.ofMeta(entry.kind, meta);

  /// Video length; nothing is shown when null or not positive.
  final Duration? duration;

  /// Video resolution class.
  final MediaResolution? resolution;

  /// Frames per second; nothing is shown below [mediaBadgeMinFrameRate].
  final double? frameRate;

  /// A RAW capture.
  final bool isRaw;

  /// An HDR capture.
  final bool isHdr;

  /// A Live Photo.
  final bool isLive;

  /// The duration pill's text (`1:23`, `1:02:03`), or null when there is none.
  String? get durationLabel {
    final d = duration;
    if (d == null || d <= Duration.zero) return null;
    return formatClock(d);
  }

  /// The frame rate rounded to whole frames (59.94 → 60), or null when below 50 or unknown.
  int? get roundedFrameRate {
    final f = frameRate;
    if (f == null || f.isNaN || f.isInfinite) return null;
    final r = f.round();
    return r >= mediaBadgeMinFrameRate ? r : null;
  }

  /// The top-row indicators in display order: Live, RAW, HDR, resolution, frame rate.
  List<MediaBadgeLabel> get labels {
    final fps = roundedFrameRate;
    final res = resolution;
    return [
      if (isLive) const MediaBadgeLabel(MediaBadgeKind.live, 'LIVE', 'Live Photo'),
      if (isRaw) const MediaBadgeLabel(MediaBadgeKind.raw, 'RAW', 'RAW'),
      if (isHdr) const MediaBadgeLabel(MediaBadgeKind.hdr, 'HDR', 'HDR'),
      if (res != null) MediaBadgeLabel(MediaBadgeKind.resolution, res.label, res.spoken),
      if (fps != null) MediaBadgeLabel(MediaBadgeKind.frameRate, '$fps fps', '$fps frames per second'),
    ];
  }

  /// True when nothing would be drawn.
  bool get isEmpty => durationLabel == null && labels.isEmpty;

  /// What a screen reader says: the indicators, then the duration (`HDR, 4K, 60 frames per
  /// second, 1:23`); empty when there are no badges.
  String get semanticsLabel {
    final d = durationLabel;
    return [for (final l in labels) l.spoken, if (d != null) d].join(', ');
  }

  @override
  bool operator ==(Object other) =>
      other is MediaBadges &&
      other.durationLabel == durationLabel &&
      other.resolution == resolution &&
      other.roundedFrameRate == roundedFrameRate &&
      other.isRaw == isRaw &&
      other.isHdr == isHdr &&
      other.isLive == isLive;

  @override
  int get hashCode => Object.hash(durationLabel, resolution, roundedFrameRate, isRaw, isHdr, isLive);

  @override
  String toString() => 'MediaBadges(${[for (final l in labels) l.label, if (durationLabel != null) durationLabel].join(', ')})';
}
