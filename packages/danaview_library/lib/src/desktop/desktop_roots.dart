// OWNER: HOM-03
//
// Desktop photo roots (ARCH v1.2 V2-109, HOM plan D-94): the Pictures folder of each desktop OS
// and the mounted external volumes, as the sidebar shortcuts of the Photos tab on macOS, Windows
// and Linux.
//
//   macOS    ~/Pictures (the Photos library package inside it is skipped by the scanner; PhotoKit
//            comes from HOM-02), external volumes under /Volumes (the boot volume link to / is
//            not a drive).
//   Windows  the Pictures Known Folder from the environment (%USERPROFILE%\Pictures, plus
//            %OneDrive%\Pictures when OneDrive redirects it), mounted drive letters other than
//            %SystemDrive%.
//   Linux    XDG PICTURES ($XDG_PICTURES_DIR, else XDG_PICTURES_DIR in
//            $XDG_CONFIG_HOME/user-dirs.dirs, else ~/Pictures; a value equal to $HOME means
//            "disabled"), removable media under /media, /media/$USER and /run/media/$USER.
//
// Discovery is pure over a [DesktopFs] and an environment map, so every platform's rules are
// tested on any host. A root id is a stable token derived from the root's canonical path, so the
// `lk:<rootId>/<relativePath>` item ids (V2-09) survive rescans and restarts.

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import 'desktop_fs.dart';

/// The desktop OS whose conventions discovery follows.
enum DesktopPlatform {
  /// macOS.
  macos,

  /// Windows.
  windows,

  /// Linux (and other XDG desktops).
  linux;

  /// The path style of this platform.
  p.Context get pathContext => this == windows ? p.windows : p.posix;
}

/// What a [DesktopRoot] is (the sidebar groups by it).
enum DesktopRootKind {
  /// The OS Pictures folder.
  pictures,

  /// A mounted external volume or drive.
  volume,

  /// A folder the user added (dropped on the sidebar).
  custom,
}

/// One scanned root: a sidebar shortcut.
@immutable
final class DesktopRoot {
  /// A root of [kind] at [path] labelled [label]; [id] is the V2-09 linked root token.
  const DesktopRoot({required this.id, required this.kind, required this.path, required this.label});

  /// A root of [kind] at [path] with an id derived from [path] ([rootIdFor]).
  factory DesktopRoot.at(DesktopRootKind kind, String path, {required String label}) =>
      DesktopRoot(id: rootIdFor(kind, path), kind: kind, path: path, label: label);

  /// The linked root id (`[A-Za-z0-9_-]`, at most 64 characters) of item ids under this root.
  final String id;

  /// Pictures folder, volume or user folder.
  final DesktopRootKind kind;

  /// The absolute (canonical when discovered) path of the root directory.
  final String path;

  /// The name the sidebar shows (folder or volume name; never a full path).
  final String label;

  @override
  bool operator ==(Object other) =>
      other is DesktopRoot && other.id == id && other.kind == kind && other.path == path && other.label == label;

  @override
  int get hashCode => Object.hash(id, kind, path, label);

  @override
  String toString() => 'DesktopRoot($id, ${kind.name})';
}

/// The stable linked root id of a root of [kind] at [path]: a kind prefix and the first 20 hex
/// digits of the SHA-1 of the path.
String rootIdFor(DesktopRootKind kind, String path) {
  final prefix = switch (kind) {
    DesktopRootKind.pictures => 'pic',
    DesktopRootKind.volume => 'vol',
    DesktopRootKind.custom => 'usr',
  };
  return '$prefix-${sha1.convert(utf8.encode(path)).toString().substring(0, 20)}';
}

/// Finds the [DesktopRoot]s of a desktop: Pictures folders, then volumes, each group in a
/// stable order, duplicates (same canonical path) removed.
final class DesktopRootResolver {
  /// A resolver for [platform] reading [environment] through [fs]. The mount directories default
  /// to the platform's; tests point them at temporary trees.
  DesktopRootResolver({
    required this.platform,
    required this.environment,
    this.fs = const IoDesktopFs(),
    List<String>? volumeMountDirs,
    List<String>? windowsDriveLetters,
  })  : volumeMountDirs = volumeMountDirs ?? _defaultMountDirs(platform, environment),
        windowsDriveLetters = windowsDriveLetters ?? _allDriveLetters;

  /// Whose conventions apply.
  final DesktopPlatform platform;

  /// The process environment (`Platform.environment` in the app).
  final Map<String, String> environment;

  /// The read-only file system.
  final DesktopFs fs;

  /// Directories whose children are mounted volumes (macOS `/Volumes`; Linux `/media`,
  /// `/media/$USER`, `/run/media/$USER`). Unused on Windows.
  final List<String> volumeMountDirs;

  /// Drive letters probed on Windows (`D` … `Z` and `A`…`C`, minus the system drive).
  final List<String> windowsDriveLetters;

  static final List<String> _allDriveLetters = [
    for (var c = 'A'.codeUnitAt(0); c <= 'Z'.codeUnitAt(0); c++) String.fromCharCode(c),
  ];

  static List<String> _defaultMountDirs(DesktopPlatform platform, Map<String, String> env) {
    final user = env['USER'] ?? env['LOGNAME'];
    return switch (platform) {
      DesktopPlatform.macos => const ['/Volumes'],
      DesktopPlatform.linux => [
          '/media',
          if (user != null && user.isNotEmpty) '/media/$user',
          if (user != null && user.isNotEmpty) '/run/media/$user',
        ],
      DesktopPlatform.windows => const [],
    };
  }

  p.Context get _p => platform.pathContext;

  String? get _home => switch (platform) {
        DesktopPlatform.windows => _nonEmpty(environment['USERPROFILE']) ??
            (_nonEmpty(environment['HOMEDRIVE']) != null && _nonEmpty(environment['HOMEPATH']) != null
                ? '${environment['HOMEDRIVE']}${environment['HOMEPATH']}'
                : null),
        _ => _nonEmpty(environment['HOME']),
      };

  static String? _nonEmpty(String? v) => v == null || v.trim().isEmpty ? null : v;

  /// Every root present now: [pictures] then [volumes].
  Future<List<DesktopRoot>> discover() async {
    final roots = <DesktopRoot>[...await pictures(), ...await volumes()];
    final seen = <String>{};
    return [
      for (final r in roots)
        if (seen.add(r.path)) r,
    ];
  }

  /// The Pictures folders that exist.
  Future<List<DesktopRoot>> pictures() async {
    final candidates = <String>[];
    final home = _home;
    switch (platform) {
      case DesktopPlatform.macos:
        if (home != null) candidates.add(_p.join(home, 'Pictures'));
      case DesktopPlatform.windows:
        if (home != null) candidates.add(_p.join(home, 'Pictures'));
        for (final key in const ['OneDrive', 'OneDriveConsumer', 'OneDriveCommercial']) {
          final od = _nonEmpty(environment[key]);
          if (od != null) candidates.add(_p.join(od, 'Pictures'));
        }
      case DesktopPlatform.linux:
        final xdg = await xdgPicturesDir();
        if (xdg != null) candidates.add(xdg);
    }
    final out = <DesktopRoot>[];
    for (final candidate in candidates) {
      final root = await _rootAt(DesktopRootKind.pictures, candidate, label: _p.basename(candidate));
      if (root != null) out.add(root);
    }
    return out;
  }

  /// The XDG Pictures directory (Linux): `$XDG_PICTURES_DIR`, else `XDG_PICTURES_DIR` in
  /// `user-dirs.dirs`, else `~/Pictures`. Null when unset and there is no home, or when it is
  /// set to the home directory itself (XDG's "disabled").
  Future<String?> xdgPicturesDir() async {
    final home = _home;
    String? value = _nonEmpty(environment['XDG_PICTURES_DIR']);
    if (value == null) {
      final configHome = _nonEmpty(environment['XDG_CONFIG_HOME']) ?? (home == null ? null : _p.join(home, '.config'));
      if (configHome != null) {
        final text = await fs.readText(_p.join(configHome, 'user-dirs.dirs'));
        if (text != null) value = parseUserDirs(text)['XDG_PICTURES_DIR'];
      }
    }
    if (value == null) return home == null ? null : _p.join(home, 'Pictures');
    var path = value;
    if (home != null) {
      path = path.replaceAll(r'${HOME}', home);
      if (path == r'$HOME' || path.startsWith(r'$HOME/')) path = home + path.substring(5);
    } else if (path.contains(r'$HOME') || path.contains(r'${HOME}')) {
      return null;
    }
    if (!_p.isAbsolute(path)) return null;
    path = _p.normalize(path);
    if (home != null && _p.equals(path, home)) return null;
    return path;
  }

  /// The `KEY="value"` lines of an XDG `user-dirs.dirs` file (comments and malformed lines
  /// skipped; the shell escapes `\"`, `\\`, `\$` and `` \` `` undone).
  static Map<String, String> parseUserDirs(String text) {
    final out = <String, String>{};
    final line = RegExp(r'^\s*([A-Z_][A-Z0-9_]*)\s*=\s*"((?:[^"\\]|\\.)*)"\s*$');
    for (final raw in const LineSplitter().convert(text)) {
      if (raw.trimLeft().startsWith('#')) continue;
      final m = line.firstMatch(raw);
      if (m == null) continue;
      out[m[1]!] = m[2]!.replaceAllMapped(RegExp(r'\\(.)'), (e) => e[1]!);
    }
    return out;
  }

  /// The mounted external volumes and drives present now.
  Future<List<DesktopRoot>> volumes() async {
    final out = <DesktopRoot>[];
    switch (platform) {
      case DesktopPlatform.windows:
        final system = _nonEmpty(environment['SystemDrive'] ?? environment['SYSTEMDRIVE'])?.toUpperCase();
        for (final letter in windowsDriveLetters) {
          final drive = '${letter.toUpperCase()}:';
          if (drive == system) continue;
          final root = await _rootAt(DesktopRootKind.volume, '$drive\\', label: drive, canonicalize: false);
          if (root != null) out.add(root);
        }
      case DesktopPlatform.macos:
      case DesktopPlatform.linux:
        final user = environment['USER'] ?? environment['LOGNAME'];
        final mountDirs = volumeMountDirs.map(_p.normalize).toSet();
        for (final dir in volumeMountDirs) {
          final children = await fs.list(dir);
          if (children == null) continue;
          children.sort((a, b) => a.name.compareTo(b.name));
          for (final child in children) {
            if (child.name.startsWith('.')) continue;
            final path = _p.join(dir, child.name);
            // /media/$USER is a mount directory, not a volume.
            if (mountDirs.contains(_p.normalize(path)) || (platform == DesktopPlatform.linux && child.name == user)) continue;
            final root = await _rootAt(DesktopRootKind.volume, path, label: child.name);
            if (root == null) continue;
            // The macOS boot volume (/Volumes/Macintosh HD -> /) is not an external drive.
            if (root.path == '/' || _isUnder(root.path, _home)) continue;
            out.add(root);
          }
        }
    }
    return out;
  }

  bool _isUnder(String path, String? dir) => dir != null && (_p.equals(path, dir) || _p.isWithin(dir, path));

  Future<DesktopRoot?> _rootAt(DesktopRootKind kind, String path, {required String label, bool canonicalize = true}) async {
    final st = await fs.stat(path);
    if (st == null || st.type != DesktopEntryType.directory) return null;
    final canonical = canonicalize ? (await fs.resolve(path) ?? path) : path;
    return DesktopRoot.at(kind, canonical, label: label.isEmpty ? canonical : label);
  }
}
