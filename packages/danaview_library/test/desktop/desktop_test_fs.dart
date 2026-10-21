// OWNER: HOM-03
//
// Test file systems for desktop discovery: an in-memory tree in any path style (so Windows and
// Linux rules run on the Mac) and a wrapper that counts the calls of another DesktopFs.

import 'package:danaview_library/danaview_library.dart';
import 'package:path/path.dart' as p;

/// An in-memory [DesktopFs]: directories, files and links in [style].
final class MemoryDesktopFs implements DesktopFs {
  /// An empty tree using [context] for paths.
  MemoryDesktopFs(this.context);

  /// Path style of this tree.
  final p.Context context;

  final Map<String, _Node> _nodes = {};

  static final DateTime _t0 = DateTime.utc(2026, 1, 1);

  String _key(String path) {
    var n = context.normalize(path);
    if (context.style == p.Style.windows) n = n.toLowerCase();
    return n;
  }

  /// Adds directory [path] and its parents.
  void dir(String path) {
    var current = context.normalize(path);
    while (true) {
      _nodes.putIfAbsent(_key(current), () => _Node.dir(current));
      final parent = context.dirname(current);
      if (parent == current) break;
      current = parent;
    }
  }

  /// Adds file [path] with [content].
  void file(String path, [String content = '']) {
    dir(context.dirname(path));
    _nodes[_key(path)] = _Node.file(context.normalize(path), content);
  }

  /// Adds a link at [path] to [target].
  void link(String path, String target) {
    dir(context.dirname(path));
    _nodes[_key(path)] = _Node.link(context.normalize(path), target);
  }

  /// Removes [path] and everything below it.
  void remove(String path) {
    final k = _key(path);
    _nodes.removeWhere((key, _) => key == k || context.isWithin(k, key));
  }

  _Node? _follow(String path, [int hops = 0]) {
    final node = _nodes[_key(path)];
    if (node == null || hops > 32) return null;
    if (node.target != null) return _follow(node.target!, hops + 1);
    return node;
  }

  @override
  Future<DesktopStat?> stat(String path) async {
    final node = _follow(path);
    return node?.stat;
  }

  @override
  Future<DesktopStat?> statLink(String path) async {
    final node = _nodes[_key(path)];
    if (node == null) return null;
    if (node.target != null) return DesktopStat(type: DesktopEntryType.link, modified: _t0, size: 0);
    return node.stat;
  }

  @override
  Future<List<DesktopDirEntry>?> list(String path) async {
    final node = _follow(path);
    if (node == null || !node.isDir) return null;
    final k = _key(node.path);
    return [
      for (final n in _nodes.values)
        if (n.path != node.path && _key(context.dirname(n.path)) == k)
          DesktopDirEntry(
            context.basename(n.path),
            n.target != null ? DesktopEntryType.link : (n.isDir ? DesktopEntryType.directory : DesktopEntryType.file),
          ),
    ];
  }

  @override
  Future<String?> resolve(String path) async {
    final node = _follow(path);
    return node?.path;
  }

  @override
  Future<String?> readText(String path, {int maxBytes = 64 * 1024}) async {
    final node = _follow(path);
    if (node == null || node.isDir) return null;
    return node.content;
  }
}

final class _Node {
  _Node.dir(this.path)
      : isDir = true,
        content = null,
        target = null;
  _Node.file(this.path, this.content)
      : isDir = false,
        target = null;
  _Node.link(this.path, this.target)
      : isDir = false,
        content = null;

  final String path;
  final bool isDir;
  final String? content;
  final String? target;

  DesktopStat get stat => DesktopStat(
        type: isDir ? DesktopEntryType.directory : DesktopEntryType.file,
        modified: MemoryDesktopFs._t0,
        size: content?.length ?? 0,
      );
}

/// Counts the calls made to [inner].
final class CountingDesktopFs implements DesktopFs {
  /// Wraps [inner].
  CountingDesktopFs(this.inner);

  /// The wrapped file system.
  final DesktopFs inner;

  /// Calls per method name.
  final Map<String, int> calls = {};

  /// Paths passed to [list].
  final List<String> listed = [];

  void _count(String name) => calls[name] = (calls[name] ?? 0) + 1;

  /// Forgets the counts.
  void reset() {
    calls.clear();
    listed.clear();
  }

  @override
  Future<DesktopStat?> stat(String path) {
    _count('stat');
    return inner.stat(path);
  }

  @override
  Future<DesktopStat?> statLink(String path) {
    _count('statLink');
    return inner.statLink(path);
  }

  @override
  Future<List<DesktopDirEntry>?> list(String path) {
    _count('list');
    listed.add(path);
    return inner.list(path);
  }

  @override
  Future<String?> resolve(String path) {
    _count('resolve');
    return inner.resolve(path);
  }

  @override
  Future<String?> readText(String path, {int maxBytes = 64 * 1024}) {
    _count('readText');
    return inner.readText(path, maxBytes: maxBytes);
  }
}
