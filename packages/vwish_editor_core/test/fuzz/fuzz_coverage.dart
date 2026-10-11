// OWNER: CORE-34
//
// The command coverage report of the model fuzzer: which `EditCommand` subtypes ran and how they
// ended (applied, no-op, refused).
//
// [commandName] is an exhaustive switch over the sealed `EditCommand` hierarchy, with no default
// case. A new command subtype therefore fails to compile here until it is listed in
// [allCommandNames], and the coverage test then requires the generator to exercise it.

import 'package:vwish_editor_core/ops.dart';

/// Every `EditCommand` subtype, grouped by owner ticket.
const List<String> allCommandNames = [
  // CORE-09 framework
  'CompositeCommand', 'RawEditCommand',
  // CORE-10 clips
  'InsertMedia', 'MoveItems', 'TrimItem', 'SplitItems', 'DeleteItems', 'DeleteGap',
  // CORE-11 clipboard and links
  'DuplicateItems', 'PasteItems', 'ReplaceMedia', 'ExtractAudio', 'LinkItems', 'UnlinkItems',
  // CORE-12 speed
  'SetSpeed', 'SetReversed', 'FreezeFrame',
  // CORE-13 properties and keyframes
  'SetProperty', 'SetVisual', 'SetAudio', 'SetLook', 'SetChroma', 'SetMask', 'SetCrop', 'ResetTransform',
  'AddKeyframe', 'RemoveKeyframe', 'MoveKeyframe', 'SetKeyframeValue', 'ClearKeyframes',
  // CORE-14 text
  'AddText', 'SetText', 'SetTextStyle', 'SetTextAnimation',
  // CORE-15 subtitles and captions
  'AddCue', 'SetCueText', 'SetCueRange', 'SplitCue', 'MergeCues', 'DeleteCues', 'ShiftCues', 'ImportSubtitles',
  'SetSubtitleStyle', 'SetSubtitlePosition', 'SetBurnIn', 'SetSubtitleLanguage',
  'AddGeneratedCaptionTrack', 'ReplaceGeneratedCaptions',
  // CORE-16 transitions
  'SetTransition', 'ApplyTransitionToAll',
  // CORE-17 tracks, markers, project
  'AddTrack', 'DeleteTrack', 'MoveTrack', 'RenameTrack', 'SetTrackFlags', 'SetAudioRole',
  'AddMarker', 'UpdateMarker', 'DeleteMarker',
  'SetCanvas', 'SetFrameRate', 'SetBackground',
];

/// The subtype name of [c]. The switch is exhaustive, so adding a command breaks the build here.
String commandName(EditCommand c) => switch (c) {
      CompositeCommand() => 'CompositeCommand',
      RawEditCommand() => 'RawEditCommand',
      InsertMedia() => 'InsertMedia',
      MoveItems() => 'MoveItems',
      TrimItem() => 'TrimItem',
      SplitItems() => 'SplitItems',
      DeleteItems() => 'DeleteItems',
      DeleteGap() => 'DeleteGap',
      DuplicateItems() => 'DuplicateItems',
      PasteItems() => 'PasteItems',
      ReplaceMedia() => 'ReplaceMedia',
      ExtractAudio() => 'ExtractAudio',
      LinkItems() => 'LinkItems',
      UnlinkItems() => 'UnlinkItems',
      SetSpeed() => 'SetSpeed',
      SetReversed() => 'SetReversed',
      FreezeFrame() => 'FreezeFrame',
      SetProperty() => 'SetProperty',
      SetVisual() => 'SetVisual',
      SetAudio() => 'SetAudio',
      SetLook() => 'SetLook',
      SetChroma() => 'SetChroma',
      SetMask() => 'SetMask',
      SetCrop() => 'SetCrop',
      ResetTransform() => 'ResetTransform',
      AddKeyframe() => 'AddKeyframe',
      RemoveKeyframe() => 'RemoveKeyframe',
      MoveKeyframe() => 'MoveKeyframe',
      SetKeyframeValue() => 'SetKeyframeValue',
      ClearKeyframes() => 'ClearKeyframes',
      AddText() => 'AddText',
      SetText() => 'SetText',
      SetTextStyle() => 'SetTextStyle',
      SetTextAnimation() => 'SetTextAnimation',
      AddCue() => 'AddCue',
      SetCueText() => 'SetCueText',
      SetCueRange() => 'SetCueRange',
      SplitCue() => 'SplitCue',
      MergeCues() => 'MergeCues',
      DeleteCues() => 'DeleteCues',
      ShiftCues() => 'ShiftCues',
      ImportSubtitles() => 'ImportSubtitles',
      SetSubtitleStyle() => 'SetSubtitleStyle',
      SetSubtitlePosition() => 'SetSubtitlePosition',
      SetBurnIn() => 'SetBurnIn',
      SetSubtitleLanguage() => 'SetSubtitleLanguage',
      AddGeneratedCaptionTrack() => 'AddGeneratedCaptionTrack',
      ReplaceGeneratedCaptions() => 'ReplaceGeneratedCaptions',
      SetTransition() => 'SetTransition',
      ApplyTransitionToAll() => 'ApplyTransitionToAll',
      AddTrack() => 'AddTrack',
      DeleteTrack() => 'DeleteTrack',
      MoveTrack() => 'MoveTrack',
      RenameTrack() => 'RenameTrack',
      SetTrackFlags() => 'SetTrackFlags',
      SetAudioRole() => 'SetAudioRole',
      AddMarker() => 'AddMarker',
      UpdateMarker() => 'UpdateMarker',
      DeleteMarker() => 'DeleteMarker',
      SetCanvas() => 'SetCanvas',
      SetFrameRate() => 'SetFrameRate',
      SetBackground() => 'SetBackground',
    };

/// How one command run ended.
enum CommandResult {
  /// The command changed the project.
  applied,

  /// The command changed nothing.
  noop,

  /// The command was refused (a rejection value).
  rejected,
}

/// Counts of command runs by subtype and result, plus rejection codes.
final class CommandCoverage {
  final Map<String, List<int>> _counts = {};
  final Map<String, Map<String, int>> _rejections = {};

  /// Records one top-level run of [c] (children of a composite are not counted separately: the
  /// generator also emits every subtype on its own).
  void record(EditCommand c, CommandResult result, {String? rejectionCode}) {
    final counts = _counts.putIfAbsent(commandName(c), () => List<int>.filled(CommandResult.values.length, 0));
    counts[result.index]++;
    if (rejectionCode != null) {
      final byCode = _rejections.putIfAbsent(commandName(c), () => {});
      byCode[rejectionCode] = (byCode[rejectionCode] ?? 0) + 1;
    }
  }

  /// Adds every count of [other].
  void addAll(CommandCoverage other) {
    other._counts.forEach((name, counts) {
      final mine = _counts.putIfAbsent(name, () => List<int>.filled(CommandResult.values.length, 0));
      for (var i = 0; i < counts.length; i++) {
        mine[i] += counts[i];
      }
    });
    other._rejections.forEach((name, codes) {
      final mine = _rejections.putIfAbsent(name, () => {});
      codes.forEach((code, n) => mine[code] = (mine[code] ?? 0) + n);
    });
  }

  /// Runs of [name] that ended with [result].
  int count(String name, CommandResult result) => _counts[name]?[result.index] ?? 0;

  /// Runs of [name] in total.
  int total(String name) => _counts[name]?.fold<int>(0, (a, b) => a + b) ?? 0;

  /// Subtypes never run.
  List<String> get unexercised => [for (final n in allCommandNames) if (total(n) == 0) n];

  /// Subtypes that never changed the project.
  List<String> get neverApplied => [for (final n in allCommandNames) if (count(n, CommandResult.applied) == 0) n];

  /// The report as JSON (stable key order).
  Map<String, Object?> toJson() => {
        'commands': {
          for (final n in allCommandNames)
            n: {
              'applied': count(n, CommandResult.applied),
              'noop': count(n, CommandResult.noop),
              'rejected': count(n, CommandResult.rejected),
              if (_rejections[n] != null) 'rejections': Map.fromEntries(_rejections[n]!.entries.toList()..sort((a, b) => a.key.compareTo(b.key))),
            },
        },
        'unexercised': unexercised,
        'neverApplied': neverApplied,
      };

  /// A plain-text table: one line per subtype with its applied, no-op and refused counts.
  String table() {
    final b = StringBuffer('command                     applied     noop  refused\n');
    for (final n in allCommandNames) {
      b.writeln('${n.padRight(26)}${'${count(n, CommandResult.applied)}'.padLeft(9)}'
          '${'${count(n, CommandResult.noop)}'.padLeft(9)}${'${count(n, CommandResult.rejected)}'.padLeft(9)}');
    }
    final missing = unexercised;
    b.write(missing.isEmpty ? 'every EditCommand subtype was exercised' : 'NOT exercised: ${missing.join(', ')}');
    return b.toString();
  }
}
