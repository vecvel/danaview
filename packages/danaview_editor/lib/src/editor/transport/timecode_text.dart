// OWNER: UX-14
//
// TimecodeText (ux.md §7.6, §7.8): the playhead time and the project duration ("00:12:15 / 01:30:00",
// compact "0:12 / 1:30"). It is the only widget of the transport bar that rebuilds per playback
// frame: it listens to the playhead and rebuilds one `Text` when the frame index changes.

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:danaview_editor_core/model.dart' show FrameRate, TimeUs, Timecode;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../debug/rebuild_counters.dart';
import 'transport_strings.dart';

/// The current time over the project duration.
class TimecodeText extends StatelessWidget {
  /// Creates the readout. [compact] drops the frame digits (`m:ss / m:ss`).
  const TimecodeText({
    super.key,
    required this.playhead,
    required this.duration,
    required this.frameRate,
    this.compact = false,
    this.semanticsLabel = true,
  });

  /// The playhead (rebuilds this widget when its frame changes).
  final ValueListenable<TimeUs> playhead;

  /// The project duration.
  final TimeUs duration;

  /// The project frame rate (the digits after the last colon are frames on this grid).
  final FrameRate frameRate;

  /// Whether to show the short form.
  final bool compact;

  /// Whether the readout names itself ("Playhead position"); false under a control that already
  /// carries that label (the transport's readout button), so a screen reader says it once.
  final bool semanticsLabel;

  /// The text style of the readout: Figtree with tabular figures so the digits don't jitter.
  static const TextStyle style = TextStyle(
    fontFamily: DanaviewFonts.family,
    fontSize: 13,
    fontWeight: FontWeight.w600,
    color: DanaviewColors.textPrimary,
    decoration: TextDecoration.none,
    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
  );

  /// Muted style of the "/ duration" part.
  static const TextStyle durationStyle = TextStyle(
    fontFamily: DanaviewFonts.family,
    fontSize: 13,
    fontWeight: FontWeight.w500,
    color: DanaviewColors.textSecondary,
    decoration: TextDecoration.none,
    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
  );

  /// The position text for [t].
  static String position(TimeUs t, FrameRate rate, {bool compact = false}) => compact ? Timecode.clock(t) : Timecode.format(t, rate);

  /// The widest text this readout shows for [duration]: both halves in the duration's width, used
  /// to measure the room it needs.
  static String widest(TimeUs duration, FrameRate rate, {bool compact = false}) {
    final d = position(duration, rate, compact: compact);
    return '$d / $d';
  }

  @override
  Widget build(BuildContext context) {
    final total = position(duration, frameRate, compact: compact);
    return ValueListenableBuilder<TimeUs>(
      valueListenable: playhead,
      builder: (context, t, _) {
        EditorRebuildCounters.count('TimecodeText');
        final now = position(t, frameRate, compact: compact);
        return Semantics(
          label: semanticsLabel ? TransportStrings.time : null,
          value: TransportStrings.timeValue(now, total),
          excludeSemantics: true,
          child: Text.rich(
            TextSpan(
              style: style,
              children: [
                TextSpan(text: now),
                TextSpan(text: ' / $total', style: durationStyle),
              ],
            ),
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.fade,
          ),
        );
      },
    );
  }
}
