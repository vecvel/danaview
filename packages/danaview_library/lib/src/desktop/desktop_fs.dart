// OWNER: HOM-03
//
// The read-only file-system surface desktop discovery uses (ARCH v1.2 V2-109, rule 27). The
// interface has no write, rename, delete or create member, so nothing built on it can change a
// scanned path; `IoDesktopFs` implements it with `dart:io` stat, list, resolve and a bounded
// read-only text read (rule 20 allows `dart:io` in lib/src/desktop/). Every failure (a missing
// path, a removed drive, a permission error) is reported as null, never thrown.

import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';

/// The type of a file-system entry as desktop discovery sees it.
enum DesktopEntryType {
  /// A regular file.
  file,

  /// A directory.
  directory,

  /// A symbolic link (only reported by [DesktopFs.list] and [DesktopFs.statLink]).
  link,

  /// Anything else (sockets, pipes, devices).
  other,
}

/// The stat of one path.
@immutable
final class DesktopStat {
  /// A stat of [type], last modified at [modified], [size] bytes long.
  const DesktopStat({required this.type, required this.modified, required this.size});

  /// What the path is.
  final DesktopEntryType type;

  /// Last modification time.
  final DateTime modified;

  /// Size in bytes (directories report the platform value).
  final int size;

  @override
  bool operator ==(Object other) =>
      other is DesktopStat && other.type == type && other.modified == modified && other.size == size;

  @override
  int get hashCode => Object.hash(type, modified, size);

  @override
  String toString() => 'DesktopStat(${type.name}, $modified, $size)';
}

/// One child of a listed directory.
@immutable
final class DesktopDirEntry {
  /// A child called [name] of [type] (links are reported as [DesktopEntryType.link]).
  const DesktopDirEntry(this.name, this.type);

  /// The child's file name (no directory part).
  final String name;

  /// The child's type, without following links.
  final DesktopEntryType type;

  @override
  bool operator ==(Object other) => other is DesktopDirEntry && other.name == name && other.type == type;

  @override
  int get hashCode => Object.hash(name, type);

  @override
  String toString() => 'DesktopDirEntry($name, ${type.name})';
}

/// Read-only access to the file system (rule 27). Implementations never write, and report every
/// failure as null.
abstract interface class DesktopFs {
  /// The stat of [path], following links; null when it does not exist or cannot be read.
  Future<DesktopStat?> stat(String path);

  /// The stat of [path] itself, without following a link; null when it does not exist.
  Future<DesktopStat?> statLink(String path);

  /// The children of the directory [path], without following links; null when it is missing, not
  /// a directory or unreadable.
  Future<List<DesktopDirEntry>?> list(String path);

  /// The canonical path of [path] with every link resolved; null when it cannot be resolved.
  Future<String?> resolve(String path);

  /// The text of the file [path] (UTF-8, malformed bytes replaced) when it is at most [maxBytes]
  /// long; null otherwise.
  Future<String?> readText(String path, {int maxBytes = 64 * 1024});
}

/// [DesktopFs] over `dart:io`. Opens nothing for writing.
final class IoDesktopFs implements DesktopFs {
  /// The `dart:io` file system.
  const IoDesktopFs();

  static DesktopEntryType _type(FileSystemEntityType type) => switch (type) {
        FileSystemEntityType.file => DesktopEntryType.file,
        FileSystemEntityType.directory => DesktopEntryType.directory,
        FileSystemEntityType.link => DesktopEntryType.link,
        _ => DesktopEntryType.other,
      };

  static DesktopStat? _toStat(FileStat s) => s.type == FileSystemEntityType.notFound
      ? null
      : DesktopStat(type: _type(s.type), modified: s.modified, size: s.size);

  @override
  Future<DesktopStat?> stat(String path) async {
    try {
      return _toStat(await FileStat.stat(path));
    } on FileSystemException {
      return null;
    }
  }

  @override
  Future<DesktopStat?> statLink(String path) async {
    try {
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.notFound) return null;
      if (type != FileSystemEntityType.link) return stat(path);
      final s = await Link(path).stat();
      return DesktopStat(type: DesktopEntryType.link, modified: s.modified, size: s.size);
    } on FileSystemException {
      return null;
    }
  }

  @override
  Future<List<DesktopDirEntry>?> list(String path) async {
    final out = <DesktopDirEntry>[];
    try {
      await for (final entity in Directory(path).list(followLinks: false)) {
        final type = switch (entity) {
          Link() => DesktopEntryType.link,
          Directory() => DesktopEntryType.directory,
          File() => DesktopEntryType.file,
          _ => DesktopEntryType.other,
        };
        out.add(DesktopDirEntry(_baseName(entity.path), type));
      }
    } on FileSystemException {
      return null;
    }
    return out;
  }

  static String _baseName(String path) {
    var end = path.length;
    while (end > 0 && (path[end - 1] == '/' || path[end - 1] == r'\')) {
      end--;
    }
    var start = end;
    while (start > 0 && path[start - 1] != '/' && path[start - 1] != r'\') {
      start--;
    }
    return path.substring(start, end);
  }

  @override
  Future<String?> resolve(String path) async {
    try {
      return await Directory(path).resolveSymbolicLinks();
    } on FileSystemException {
      return null;
    }
  }

  @override
  Future<String?> readText(String path, {int maxBytes = 64 * 1024}) async {
    try {
      final file = File(path);
      if (await file.length() > maxBytes) return null;
      final bytes = <int>[];
      await for (final chunk in file.openRead(0, maxBytes)) {
        bytes.addAll(chunk);
      }
      return utf8.decode(bytes, allowMalformed: true);
    } on FileSystemException {
      return null;
    }
  }
}
