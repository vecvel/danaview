import 'package:meta/meta.dart';

enum TrackType {
  video,
  audio,
  subtitle,
}

@immutable
class MediaTrack {
  final String id;
  final TrackType type;
  final String? title;
  final String? language;
  final String? codec;
  final bool isDefault;
  final bool isForced;
  final int? channels;
  final int? width;
  final int? height;
  final double? fps;
  final int? bitrate;

  const MediaTrack({
    required this.id,
    required this.type,
    this.title,
    this.language,
    this.codec,
    this.isDefault = false,
    this.isForced = false,
    this.channels,
    this.width,
    this.height,
    this.fps,
    this.bitrate,
  });

  String get displayName {
    if (title != null && title!.isNotEmpty) return title!;
    if (language != null && language!.isNotEmpty) return language!.toUpperCase();
    if (id == 'auto') return 'Auto';
    if (id == 'no') return 'Off';
    final kind = switch (type) {
      TrackType.video => 'Video',
      TrackType.audio => 'Audio',
      TrackType.subtitle => 'Subtitle',
    };
    return '$kind $id';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MediaTrack &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          type == other.type;

  @override
  int get hashCode => id.hashCode ^ type.hashCode;
}

@immutable
class TrackSelection {
  final List<MediaTrack> videoTracks;
  final List<MediaTrack> audioTracks;
  final List<MediaTrack> subtitleTracks;
  final String? selectedVideoTrackId;
  final String? selectedAudioTrackId;
  final String? selectedSubtitleTrackId;
  final String? selectedSecondarySubtitleTrackId;

  const TrackSelection({
    this.videoTracks = const [],
    this.audioTracks = const [],
    this.subtitleTracks = const [],
    this.selectedVideoTrackId,
    this.selectedAudioTrackId,
    this.selectedSubtitleTrackId,
    this.selectedSecondarySubtitleTrackId,
  });

  const TrackSelection.empty()
      : videoTracks = const [],
        audioTracks = const [],
        subtitleTracks = const [],
        selectedVideoTrackId = null,
        selectedAudioTrackId = null,
        selectedSubtitleTrackId = null,
        selectedSecondarySubtitleTrackId = null;

  TrackSelection copyWith({
    List<MediaTrack>? videoTracks,
    List<MediaTrack>? audioTracks,
    List<MediaTrack>? subtitleTracks,
    Object? selectedVideoTrackId = _sentinel,
    Object? selectedAudioTrackId = _sentinel,
    Object? selectedSubtitleTrackId = _sentinel,
    Object? selectedSecondarySubtitleTrackId = _sentinel,
  }) {
    return TrackSelection(
      videoTracks: videoTracks ?? this.videoTracks,
      audioTracks: audioTracks ?? this.audioTracks,
      subtitleTracks: subtitleTracks ?? this.subtitleTracks,
      selectedVideoTrackId: selectedVideoTrackId == _sentinel
          ? this.selectedVideoTrackId
          : selectedVideoTrackId as String?,
      selectedAudioTrackId: selectedAudioTrackId == _sentinel
          ? this.selectedAudioTrackId
          : selectedAudioTrackId as String?,
      selectedSubtitleTrackId: selectedSubtitleTrackId == _sentinel
          ? this.selectedSubtitleTrackId
          : selectedSubtitleTrackId as String?,
      selectedSecondarySubtitleTrackId: selectedSecondarySubtitleTrackId == _sentinel
          ? this.selectedSecondarySubtitleTrackId
          : selectedSecondarySubtitleTrackId as String?,
    );
  }
}

const Object _sentinel = Object();
