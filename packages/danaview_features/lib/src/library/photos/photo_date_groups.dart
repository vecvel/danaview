// OWNER: HOM-10
//
// Date groups of the Photos tab (BUILD_PLAN HOM-10): Today, Yesterday, This month, then one group
// per earlier month ("September" within the current year, "September 2025" before it). The input
// is newest first, so every group is one contiguous run and grouping is a single pass. Dates in
// the future (a camera clock set ahead) count as Today. Times are compared in local time.

import 'package:flutter/foundation.dart';

import 'photo_grid_item.dart';

/// What a date group covers.
enum PhotoDateGroupKind {
  /// Since local midnight (and anything later).
  today,

  /// The local day before today.
  yesterday,

  /// Earlier this month.
  thisMonth,

  /// One calendar month before this one.
  month,
}

/// One contiguous run of photos sharing a date group.
@immutable
final class PhotoDateGroup {
  /// A group of [count] photos starting at [start] of the list.
  const PhotoDateGroup({required this.kind, required this.label, required this.start, required this.count, this.year, this.month});

  /// What it covers.
  final PhotoDateGroupKind kind;

  /// The header text.
  final String label;

  /// Index of its first photo.
  final int start;

  /// How many photos it holds (≥ 1).
  final int count;

  /// The year of a [PhotoDateGroupKind.month] group.
  final int? year;

  /// The month (1–12) of a [PhotoDateGroupKind.month] group.
  final int? month;

  /// One past its last photo.
  int get end => start + count;

  @override
  bool operator ==(Object other) =>
      other is PhotoDateGroup && other.kind == kind && other.label == label && other.start == start && other.count == count;

  @override
  int get hashCode => Object.hash(kind, label, start, count);

  @override
  String toString() => 'PhotoDateGroup($label, $start+$count)';
}

const _months = [
  'January', 'February', 'March', 'April', 'May', 'June', //
  'July', 'August', 'September', 'October', 'November', 'December',
];

/// The English name of [month] (1–12).
String photoMonthName(int month) => _months[(month - 1).clamp(0, 11)];

/// Groups [photos] (newest first) relative to [now] (local time).
List<PhotoDateGroup> groupPhotosByDate(List<PhotoGridItem> photos, DateTime now) {
  final local = now.toLocal();
  final startToday = DateTime(local.year, local.month, local.day).millisecondsSinceEpoch;
  final startYesterday = DateTime(local.year, local.month, local.day - 1).millisecondsSinceEpoch;
  final startMonth = DateTime(local.year, local.month).millisecondsSinceEpoch;
  final groups = <PhotoDateGroup>[];
  var runStart = 0;
  PhotoDateGroupKind? runKind;
  int? runYear, runMonth;

  void close(int end) {
    final kind = runKind;
    if (kind == null || end <= runStart) return;
    final label = switch (kind) {
      PhotoDateGroupKind.today => 'Today',
      PhotoDateGroupKind.yesterday => 'Yesterday',
      PhotoDateGroupKind.thisMonth => 'This month',
      PhotoDateGroupKind.month => runYear == local.year ? photoMonthName(runMonth!) : '${photoMonthName(runMonth!)} $runYear',
    };
    groups.add(PhotoDateGroup(kind: kind, label: label, start: runStart, count: end - runStart, year: runYear, month: runMonth));
  }

  for (var i = 0; i < photos.length; i++) {
    final ms = photos[i].date.millisecondsSinceEpoch;
    PhotoDateGroupKind kind;
    int? year, month;
    if (ms >= startToday) {
      kind = PhotoDateGroupKind.today;
    } else if (ms >= startYesterday) {
      kind = PhotoDateGroupKind.yesterday;
    } else if (ms >= startMonth) {
      kind = PhotoDateGroupKind.thisMonth;
    } else {
      kind = PhotoDateGroupKind.month;
      final d = photos[i].date.toLocal();
      year = d.year;
      month = d.month;
    }
    if (kind != runKind || year != runYear || month != runMonth) {
      close(i);
      runStart = i;
      runKind = kind;
      runYear = year;
      runMonth = month;
    }
  }
  close(photos.length);
  return groups;
}
