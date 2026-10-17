// OWNER: CORE-03
//
// Timeline items (ARCH §6.3): media clips, text overlays and subtitle cues. Every start and
// duration lies on the project frame grid; durations are ≥ 1 frame.

import 'package:meta/meta.dart';

import '../ids/ids.dart';
import '../time/time.dart';
import 'audio_props.dart';
import 'keyframes/keyframe_data.dart';
import 'speed_spec.dart';
import 'subtitle.dart';
import 'text_style.dart';
import 'visual_props.dart';

const Object _keep = Object();

/// An item on a track. Sealed: [MediaClip], [TextItem], [SubtitleCue].
@immutable
sealed class TimelineItem {
  const TimelineItem({required this.id, required this.start, required this.duration, this.link, this.label});

  /// Stable id (never re-identified except by paste/duplicate).
  final ItemId id;

  /// Timeline start (on grid).
  final TimeUs start;

  /// Timeline duration (whole frames, ≥ 1 frame).
  final TimeUs duration;

  /// Link group shared with partners (extracted audio, freeze-frame partners).
  final LinkId? link;

  /// Optional user label shown on the clip.
  final String? label;

  /// `start + duration`.
  TimeUs get end => start + duration;

  /// `[start, end)`.
  TimeRange get range => TimeRange(start, start + duration);
}

/// A clip of a pool asset (video, image, still or audio stream).
///
/// Duration authority: the clip stores `(sourceIn, duration, speed)`; `sourceOut` is derived from
/// the time map (CORE-06). A speed change keeps the source range and recomputes `duration`.
final class MediaClip extends TimelineItem {
  /// Creates a media clip.
  const MediaClip({
    required super.id,
    required super.start,
    required super.duration,
    super.link,
    super.label,
    required this.media,
    this.sourceIn = 0,
    this.speed = SpeedSpec.normal,
    this.maintainPitch = true,
    this.reversed = false,
    this.audioStream,
    this.visual,
    this.audio = AudioProps.unity,
    this.detachedAudio = false,
    this.keyframes = KeyframeSet.empty,
  });

  /// Pool asset.
  final MediaId media;

  /// Source time at the clip start (µs on the source's presentation timeline; 0 for images).
  final TimeUs sourceIn;

  /// Constant speed or ramp; ignored for images and stills.
  final SpeedSpec speed;

  /// Time-stretch keeping pitch (true) or varispeed (false).
  final bool maintainPitch;

  /// Plays a reversed rendition of the source range (derived asset, ARCH §15).
  final bool reversed;

  /// Audio stream index; null = first audio stream.
  final int? audioStream;

  /// Visual properties; null on audio lanes.
  final VisualProps? visual;

  /// Audio properties.
  final AudioProps audio;

  /// True after "Extract audio": this clip's own audio is not rendered (a linked audio clip is).
  final bool detachedAudio;

  /// Item-local keyframes.
  final KeyframeSet keyframes;

  /// A copy with the given fields replaced; pass null to clear `link`, `label`, `audioStream`
  /// or `visual`.
  MediaClip copyWith({
    TimeUs? start,
    TimeUs? duration,
    Object? link = _keep,
    Object? label = _keep,
    MediaId? media,
    TimeUs? sourceIn,
    SpeedSpec? speed,
    bool? maintainPitch,
    bool? reversed,
    Object? audioStream = _keep,
    Object? visual = _keep,
    AudioProps? audio,
    bool? detachedAudio,
    KeyframeSet? keyframes,
  }) =>
      MediaClip(
        id: id,
        start: start ?? this.start,
        duration: duration ?? this.duration,
        link: identical(link, _keep) ? this.link : link as LinkId?,
        label: identical(label, _keep) ? this.label : label as String?,
        media: media ?? this.media,
        sourceIn: sourceIn ?? this.sourceIn,
        speed: speed ?? this.speed,
        maintainPitch: maintainPitch ?? this.maintainPitch,
        reversed: reversed ?? this.reversed,
        audioStream: identical(audioStream, _keep) ? this.audioStream : audioStream as int?,
        visual: identical(visual, _keep) ? this.visual : visual as VisualProps?,
        audio: audio ?? this.audio,
        detachedAudio: detachedAudio ?? this.detachedAudio,
        keyframes: keyframes ?? this.keyframes,
      );

  /// A copy with a new id (paste, duplicate).
  MediaClip withId(ItemId newId) => MediaClip(
        id: newId,
        start: start,
        duration: duration,
        link: link,
        label: label,
        media: media,
        sourceIn: sourceIn,
        speed: speed,
        maintainPitch: maintainPitch,
        reversed: reversed,
        audioStream: audioStream,
        visual: visual,
        audio: audio,
        detachedAudio: detachedAudio,
        keyframes: keyframes,
      );

  @override
  bool operator ==(Object other) =>
      other is MediaClip &&
      other.id == id &&
      other.start == start &&
      other.duration == duration &&
      other.link == link &&
      other.label == label &&
      other.media == media &&
      other.sourceIn == sourceIn &&
      other.speed == speed &&
      other.maintainPitch == maintainPitch &&
      other.reversed == reversed &&
      other.audioStream == audioStream &&
      other.visual == visual &&
      other.audio == audio &&
      other.detachedAudio == detachedAudio &&
      other.keyframes == keyframes;

  @override
  int get hashCode => Object.hash(id, start, duration, link, label, media, sourceIn, speed, maintainPitch, reversed,
      audioStream, visual, audio, detachedAudio, keyframes);
}

/// A text overlay on a text lane.
final class TextItem extends TimelineItem {
  /// Creates a text item.
  const TextItem({
    required super.id,
    required super.start,
    required super.duration,
    super.link,
    super.label,
    required this.text,
    this.style = const TextStyleSpec(),
    this.animation = TextAnimation.none,
    this.transform = Transform2D.identity,
    this.keyframes = KeyframeSet.empty,
  });

  /// Text content (non-empty after trim; `\n` line breaks).
  final String text;

  /// Style.
  final TextStyleSpec style;

  /// In/out animation.
  final TextAnimation animation;

  /// Placement (flips ignored).
  final Transform2D transform;

  /// Item-local keyframes (position, scale, rotation, opacity).
  final KeyframeSet keyframes;

  /// A copy with the given fields replaced.
  TextItem copyWith({
    TimeUs? start,
    TimeUs? duration,
    Object? link = _keep,
    Object? label = _keep,
    String? text,
    TextStyleSpec? style,
    TextAnimation? animation,
    Transform2D? transform,
    KeyframeSet? keyframes,
  }) =>
      TextItem(
        id: id,
        start: start ?? this.start,
        duration: duration ?? this.duration,
        link: identical(link, _keep) ? this.link : link as LinkId?,
        label: identical(label, _keep) ? this.label : label as String?,
        text: text ?? this.text,
        style: style ?? this.style,
        animation: animation ?? this.animation,
        transform: transform ?? this.transform,
        keyframes: keyframes ?? this.keyframes,
      );

  @override
  bool operator ==(Object other) =>
      other is TextItem &&
      other.id == id &&
      other.start == start &&
      other.duration == duration &&
      other.link == link &&
      other.label == label &&
      other.text == text &&
      other.style == style &&
      other.animation == animation &&
      other.transform == transform &&
      other.keyframes == keyframes;

  @override
  int get hashCode =>
      Object.hash(id, start, duration, link, label, text, style, animation, transform, keyframes);
}

/// A subtitle cue on a subtitle lane. Cues on a track are sorted and never overlap.
final class SubtitleCue extends TimelineItem {
  /// Creates a cue.
  const SubtitleCue({
    required super.id,
    required super.start,
    required super.duration,
    super.link,
    super.label,
    required this.text,
    this.origin = CueOrigin.manual,
    this.editedAfterGeneration = false,
  });

  /// Text with `\n` line breaks and inline `<i>`/`<b>` only (ARCH §10.1).
  final String text;

  /// Where the cue came from.
  final CueOrigin origin;

  /// Set by any text or timing edit of a generated cue (Regenerate asks before replacing).
  final bool editedAfterGeneration;

  /// A copy with the given fields replaced.
  SubtitleCue copyWith({
    TimeUs? start,
    TimeUs? duration,
    String? text,
    CueOrigin? origin,
    bool? editedAfterGeneration,
  }) =>
      SubtitleCue(
        id: id,
        start: start ?? this.start,
        duration: duration ?? this.duration,
        link: link,
        label: label,
        text: text ?? this.text,
        origin: origin ?? this.origin,
        editedAfterGeneration: editedAfterGeneration ?? this.editedAfterGeneration,
      );

  @override
  bool operator ==(Object other) =>
      other is SubtitleCue &&
      other.id == id &&
      other.start == start &&
      other.duration == duration &&
      other.link == link &&
      other.label == label &&
      other.text == text &&
      other.origin == origin &&
      other.editedAfterGeneration == editedAfterGeneration;

  @override
  int get hashCode => Object.hash(id, start, duration, link, label, text, origin, editedAfterGeneration);
}
