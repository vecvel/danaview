// OWNER: AI-12
//
// `DomainTimelineView`: the read-only [TimelineView] adapter over an [EditProject] (ai.md §10.1).
// A fresh adapter is built for the plan and again for the mapping, so edits made during a job are
// honoured. Clip time maps are `ClipTimeMap` (CORE-06), so `timelineTimeOf` inverts constant speeds
// and ramps exactly.

import 'dart:ui' show Size;

import 'package:danaview_editor_core/eval.dart';
import 'package:danaview_editor_core/model.dart';

import '../contracts/timeline_view.dart';
import 'transcription_planner.dart';

/// Adapts an [EditProject] to [TimelineView] and [TimelineMediaInfo].
final class DomainTimelineView implements TimelineView, TimelineMediaInfo {
  /// Creates the view of [project]. [access] resolves pool assets for audio extraction; without
  /// it [resolveMedia] returns null.
  DomainTimelineView(this.editProject, {MediaAccessPort? access}) : _access = access {
    _anySolo = editProject.tracks.any((t) => t.solo && t.kind != TrackKind.subtitle && t.kind != TrackKind.text);
    _tracks = [for (final t in editProject.tracks) _DomainTrack(t)];
  }

  /// The project being read.
  final EditProject editProject;

  final MediaAccessPort? _access;
  late final bool _anySolo;
  late final List<_DomainTrack> _tracks;
  List<AudibleClipView>? _clips;

  @override
  ProjectId get project => editProject.id;

  @override
  FrameRate get frameRate => editProject.settings.frameRate;

  @override
  Size get canvasSize => Size(editProject.settings.canvas.widthPx.toDouble(), editProject.settings.canvas.heightPx.toDouble());

  @override
  TimeUs get duration => editProject.duration;

  @override
  Iterable<TrackView> get tracks => _tracks;

  @override
  Iterable<AudibleClipView> audibleClips() => _clips ??= _buildClips();

  @override
  Iterable<SubtitleTrackView> get subtitleTracks => [
        for (final t in editProject.tracks)
          if (t.kind == TrackKind.subtitle) _DomainSubtitleTrack(t),
      ];

  @override
  List<TimeUs> get cutPoints {
    final cuts = <TimeUs>{};
    for (final c in audibleClips()) {
      if (c.effectiveVolume <= 0) continue;
      cuts
        ..add(c.timelineRange.start)
        ..add(c.timelineRange.end);
    }
    return cuts.where((t) => t > 0).toList()..sort();
  }

  @override
  Future<ResolvedMedia?> resolveMedia(MediaId media) async {
    final asset = editProject.pool[media];
    final access = _access;
    if (asset == null || access == null) return null;
    try {
      return await access.resolve(asset.locator);
    } on Object {
      return null;
    }
  }

  @override
  MediaAudioInfo? audioInfo(MediaId media) {
    final asset = editProject.pool[media];
    if (asset == null) return null;
    final still = asset.kind == MediaKind.image || asset.kind == MediaKind.still || asset.derived is StillSpec;
    final duration = asset.probe.duration > 0 ? asset.probe.duration : (asset.fingerprint.duration > 0 ? asset.fingerprint.duration : null);
    return MediaAudioInfo(hasAudio: asset.probe.hasAudio, duration: duration, isStill: still);
  }

  List<AudibleClipView> _buildClips() {
    final out = <AudibleClipView>[];
    for (final track in editProject.tracks) {
      if (track.kind == TrackKind.subtitle || track.kind == TrackKind.text) continue;
      final trackAudible = !track.muted && (!_anySolo || track.solo);
      for (final item in track.items) {
        if (item is! MediaClip) continue;
        final asset = editProject.pool[item.media];
        if (asset != null && (asset.kind == MediaKind.image || asset.kind == MediaKind.lut)) continue;
        // "Extract audio" moved this clip's sound to a linked audio clip, which is listed itself.
        if (item.detachedAudio) continue;
        final freeze = asset != null && (asset.kind == MediaKind.still || asset.derived is StillSpec);
        final volume = !trackAudible || item.audio.muted ? 0.0 : item.audio.volume;
        out.add(_DomainClip(item, track.id, asset?.fingerprint.quickHash ?? '', volume, freeze, frameRate));
      }
    }
    return List.unmodifiable(out);
  }
}

final class _DomainTrack implements TrackView {
  _DomainTrack(this._t);
  final Track _t;

  @override
  TrackId get id => _t.id;
  @override
  TrackKind get kind => _t.kind;
  @override
  AudioRole? get role => _t.audioRole;
  @override
  bool get muted => _t.muted;
  @override
  bool get solo => _t.solo;
  @override
  bool get hidden => _t.hidden;
  @override
  bool get locked => _t.locked;
  @override
  bool get isMain => _t.isMain;
}

final class _DomainClip implements AudibleClipView {
  _DomainClip(this._clip, this.track, this.mediaQuickHash, this.effectiveVolume, this.isFreeze, FrameRate rate)
      : _rate = rate;

  final MediaClip _clip;
  final FrameRate _rate;
  late final ClipTimeMap _map = ClipTimeMap.forClip(_clip, _rate);

  @override
  final TrackId track;
  @override
  final String mediaQuickHash;
  @override
  final double effectiveVolume;
  @override
  final bool isFreeze;

  @override
  ItemId get id => _clip.id;
  @override
  MediaId get media => _clip.media;
  @override
  int? get audioStream => _clip.audioStream;
  @override
  TimeRange get timelineRange => _clip.range;
  @override
  TimeRange get sourceRange => _map.sourceRange;
  @override
  bool get reversed => _clip.reversed;

  @override
  TimeUs? timelineTimeOf(TimeUs s) => _map.timelineTimeOf(s);
}

final class _DomainCue implements CueView {
  const _DomainCue(this._cue);
  final SubtitleCue _cue;

  @override
  ItemId get id => _cue.id;
  @override
  TimeRange get range => _cue.range;
  @override
  String get text => _cue.text;
  @override
  CueOrigin get origin => _cue.origin;
  @override
  bool get editedAfterGeneration => _cue.editedAfterGeneration;
}

final class _DomainSubtitleTrack implements SubtitleTrackView {
  _DomainSubtitleTrack(this._t);
  final Track _t;

  @override
  TrackId get id => _t.id;
  @override
  String get name => _t.name;
  @override
  String? get language => _t.subtitle?.language;
  @override
  CaptionProvenance? get provenance => _t.subtitle?.provenance;
  @override
  List<CueView> get cues => [
        for (final i in _t.items)
          if (i is SubtitleCue) _DomainCue(i),
      ];
}
