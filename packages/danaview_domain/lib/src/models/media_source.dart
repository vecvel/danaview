import 'package:meta/meta.dart';

@immutable
class MediaSource {
  final String uri;
  final String? title;
  final Duration? startAt;
  final Map<String, String>? httpHeaders;
  final bool isLocalFile;
  final Map<String, dynamic>? extra;

  const MediaSource({
    required this.uri,
    this.title,
    this.startAt,
    this.httpHeaders,
    this.isLocalFile = true,
    this.extra,
  });

  factory MediaSource.file(String path, {String? title, Duration? startAt}) {
    return MediaSource(
      uri: path,
      title: title ?? path.split(RegExp(r'[/\\]')).last,
      startAt: startAt,
      isLocalFile: true,
    );
  }

  factory MediaSource.network(String url, {String? title, Duration? startAt, Map<String, String>? headers}) {
    return MediaSource(
      uri: url,
      title: title ?? url,
      startAt: startAt,
      httpHeaders: headers,
      isLocalFile: false,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MediaSource &&
          runtimeType == other.runtimeType &&
          uri == other.uri &&
          title == other.title &&
          startAt == other.startAt;

  @override
  int get hashCode => uri.hashCode ^ (title?.hashCode ?? 0) ^ (startAt?.hashCode ?? 0);
}

@immutable
class MediaRef {
  final String id;
  final String title;
  final String pathOrUri;
  final bool isRemote;
  final Duration duration;
  final int? width;
  final int? height;
  final String? videoCodec;
  final String? audioCodec;
  final String? container;
  final int? fileSize;
  final String? quickHash;
  final String? posterPath;
  final int seasonNumber;
  final int episodeNumber;

  const MediaRef({
    required this.id,
    required this.title,
    required this.pathOrUri,
    this.isRemote = false,
    this.duration = Duration.zero,
    this.width,
    this.height,
    this.videoCodec,
    this.audioCodec,
    this.container,
    this.fileSize,
    this.quickHash,
    this.posterPath,
    this.seasonNumber = 0,
    this.episodeNumber = 0,
  });

  MediaRef copyWith({
    String? id,
    String? title,
    String? pathOrUri,
    bool? isRemote,
    Duration? duration,
    int? width,
    int? height,
    String? videoCodec,
    String? audioCodec,
    String? container,
    int? fileSize,
    String? quickHash,
    String? posterPath,
    int? seasonNumber,
    int? episodeNumber,
  }) {
    return MediaRef(
      id: id ?? this.id,
      title: title ?? this.title,
      pathOrUri: pathOrUri ?? this.pathOrUri,
      isRemote: isRemote ?? this.isRemote,
      duration: duration ?? this.duration,
      width: width ?? this.width,
      height: height ?? this.height,
      videoCodec: videoCodec ?? this.videoCodec,
      audioCodec: audioCodec ?? this.audioCodec,
      container: container ?? this.container,
      fileSize: fileSize ?? this.fileSize,
      quickHash: quickHash ?? this.quickHash,
      posterPath: posterPath ?? this.posterPath,
      seasonNumber: seasonNumber ?? this.seasonNumber,
      episodeNumber: episodeNumber ?? this.episodeNumber,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MediaRef && runtimeType == other.runtimeType && id == other.id && pathOrUri == other.pathOrUri;

  @override
  int get hashCode => id.hashCode ^ pathOrUri.hashCode;
}
