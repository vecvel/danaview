import 'package:meta/meta.dart';
import 'media_source.dart';

/// A library root: a user-granted folder, or the app's own on-device folder on mobile.
@immutable
class LibraryFolder {
  final String path;
  final String label;
  final DateTime? addedAt;

  /// True for the app's Documents folder on iOS/Android; always present and not removable.
  final bool isDevice;

  const LibraryFolder({
    required this.path,
    required this.label,
    this.addedAt,
    this.isDevice = false,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LibraryFolder &&
          path == other.path &&
          label == other.label &&
          addedAt == other.addedAt &&
          isDevice == other.isDevice;

  @override
  int get hashCode => Object.hash(path, label, addedAt, isDevice);
}

@immutable
class LibraryFolderEntry {
  final String name;
  final String path;

  /// Video files directly inside this folder; null when not counted.
  final int? mediaCount;

  const LibraryFolderEntry({
    required this.name,
    required this.path,
    this.mediaCount,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LibraryFolderEntry && path == other.path && name == other.name && mediaCount == other.mediaCount;

  @override
  int get hashCode => Object.hash(name, path, mediaCount);
}

/// One non-recursive level of a folder, naturally sorted.
@immutable
class DirectoryListing {
  final String path;
  final String name;
  final List<LibraryFolderEntry> folders;
  final List<MediaRef> media;

  /// User-facing reason the folder could not be read; null on success.
  final String? error;

  const DirectoryListing({
    required this.path,
    required this.name,
    this.folders = const [],
    this.media = const [],
    this.error,
  });

  bool get hasError => error != null;
  bool get isEmpty => folders.isEmpty && media.isEmpty;
}

@immutable
class PlaylistSummary {
  final String name;
  final int itemCount;

  const PlaylistSummary({required this.name, required this.itemCount});

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is PlaylistSummary && name == other.name && itemCount == other.itemCount;

  @override
  int get hashCode => Object.hash(name, itemCount);
}

@immutable
class ResumeInfo {
  final Duration position;

  /// Zero when the duration was not known at save time.
  final Duration duration;

  const ResumeInfo({required this.position, this.duration = Duration.zero});

  /// Watched fraction in [0, 1]; 0 when the duration is unknown.
  double get progress {
    if (duration <= Duration.zero) return 0;
    return (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
  }

  Duration get remaining => duration > position ? duration - position : Duration.zero;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ResumeInfo && position == other.position && duration == other.duration;

  @override
  int get hashCode => Object.hash(position, duration);
}
