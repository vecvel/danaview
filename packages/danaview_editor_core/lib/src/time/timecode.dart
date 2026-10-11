// OWNER: CORE-02
//
// Display and entry of timeline times (ARCH §5 "Display"). Timecodes count frame indices
// (non-drop-frame).

import 'time.dart';

/// Formats and parses frame-based timecodes.
abstract final class Timecode {
  /// Formats [t] as `mm:ss:ff`, or `h:mm:ss:ff` from one hour, where `ff` is the frame index
  /// within the second on [rate]'s grid.
  static String format(TimeUs t, FrameRate rate) {
    final negative = t < 0;
    final k = rate.frameIndexOf(negative ? -t : t);
    final perSecond = (rate.num / rate.den).round();
    final totalSeconds = k ~/ perSecond;
    final ff = k % perSecond;
    final h = totalSeconds ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    final s = totalSeconds % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    final body = h > 0 ? '$h:${two(m)}:${two(s)}:${two(ff)}' : '${two(m)}:${two(s)}:${two(ff)}';
    return negative ? '-$body' : body;
  }

  /// Formats [t] as a clock `m:ss` (or `h:mm:ss`), without frames.
  static String clock(TimeUs t) {
    final totalSeconds = t ~/ microsPerSecond;
    final h = totalSeconds ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    final s = totalSeconds % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
  }

  /// Parses user input into a time on [rate]'s grid, or `null` when it is not a timecode.
  ///
  /// Accepted forms (ARCH §5): `1:23` (m:ss), `1:23:12` (m:ss:ff), `h:mm:ss:ff`, `83.5s`
  /// (seconds), and relative `+2s`, `-10f` (seconds or frames relative to [base]).
  /// Absolute results are floored to the grid with [FrameRate.quantize]; relative results move
  /// by whole frames from `quantize(base)`.
  static TimeUs? parse(String input, FrameRate rate, {TimeUs base = 0}) {
    final s = input.trim();
    if (s.isEmpty) return null;
    final relative = RegExp(r'^([+-])(\d+(?:\.\d+)?)([sf])$').firstMatch(s);
    if (relative != null) {
      final sign = relative[1] == '-' ? -1 : 1;
      final amount = double.parse(relative[2]!);
      final baseFrame = rate.frameIndexOf(base);
      final deltaFrames = relative[3] == 'f'
          ? amount.round()
          : (amount * rate.num / rate.den).round();
      final k = baseFrame + sign * deltaFrames;
      return rate.timeOfFrame(k < 0 ? 0 : k);
    }
    final seconds = RegExp(r'^(\d+(?:\.\d+)?)s$').firstMatch(s);
    if (seconds != null) {
      final us = (double.parse(seconds[1]!) * microsPerSecond).round();
      return rate.quantize(us);
    }
    final parts = s.split(':');
    if (parts.length < 2 || parts.length > 4) return null;
    final numbers = <int>[];
    for (final p in parts) {
      final v = int.tryParse(p);
      if (v == null || v < 0) return null;
      numbers.add(v);
    }
    final perSecond = (rate.num / rate.den).round();
    int h = 0, m, sec, ff = 0;
    switch (numbers.length) {
      case 2:
        m = numbers[0];
        sec = numbers[1];
      case 3:
        m = numbers[0];
        sec = numbers[1];
        ff = numbers[2];
      default:
        h = numbers[0];
        m = numbers[1];
        sec = numbers[2];
        ff = numbers[3];
    }
    if (sec >= 60 || (numbers.length > 2 && ff >= perSecond)) return null;
    final k = ((h * 60 + m) * 60 + sec) * perSecond + ff;
    return rate.timeOfFrame(k);
  }
}
