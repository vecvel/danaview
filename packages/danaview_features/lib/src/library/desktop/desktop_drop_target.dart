// OWNER: HOM-03
//
// The desktop browser's drag-and-drop target (ARCH v1.2 V2-109, HOM plan D-94): folders dropped
// on the photo sidebar become photo roots, dropped files are handed to a callback. It wraps only
// the new sidebar; the player's drop target and `danaview://` links stay exactly as in 1.1 (P-8).
// Dropped paths are only stat'ed, never opened for writing (rule 27).

import 'dart:io' show FileSystemEntity;

import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/widgets.dart';

/// Dropped [paths] split into folders and files by [isDirectory]; paths that cannot be stat'ed
/// count as files.
Future<({List<String> folders, List<String> files})> splitDroppedPaths(
  List<String> paths, {
  Future<bool> Function(String path) isDirectory = FileSystemEntity.isDirectory,
}) async {
  final folders = <String>[];
  final files = <String>[];
  for (final path in paths) {
    bool dir;
    try {
      dir = await isDirectory(path);
    } on Exception {
      dir = false;
    }
    (dir ? folders : files).add(path);
  }
  return (folders: folders, files: files);
}

/// A drop target for folders (and optionally files) with a highlighted outline while dragging.
class DesktopFolderDropTarget extends StatefulWidget {
  /// Wraps [child]; [onDropFolders] gets dropped folders, [onDropFiles] (when set) dropped files.
  const DesktopFolderDropTarget({
    super.key,
    required this.child,
    required this.onDropFolders,
    this.onDropFiles,
    this.enabled = true,
    this.isDirectory = FileSystemEntity.isDirectory,
  });

  /// The wrapped content.
  final Widget child;

  /// Receives the dropped folders.
  final Future<void> Function(List<String> paths) onDropFolders;

  /// Receives the dropped files; dropped files are ignored when null.
  final ValueChanged<List<String>>? onDropFiles;

  /// False ignores drops.
  final bool enabled;

  /// Whether a dropped path is a folder (injectable for tests).
  final Future<bool> Function(String path) isDirectory;

  @override
  State<DesktopFolderDropTarget> createState() => DesktopFolderDropTargetState();
}

/// The state of [DesktopFolderDropTarget]; [handleDrop] is what a drop does.
class DesktopFolderDropTargetState extends State<DesktopFolderDropTarget> {
  bool _dragging = false;

  /// True while something is dragged over the target.
  bool get dragging => _dragging;

  void _setDragging(bool value) {
    if (mounted && _dragging != value) setState(() => _dragging = value);
  }

  /// Splits [paths] and calls the callbacks.
  Future<void> handleDrop(List<String> paths) async {
    _setDragging(false);
    if (!widget.enabled || paths.isEmpty) return;
    final split = await splitDroppedPaths(paths, isDirectory: widget.isDirectory);
    if (split.folders.isNotEmpty) await widget.onDropFolders(split.folders);
    if (split.files.isNotEmpty) widget.onDropFiles?.call(split.files);
  }

  @override
  Widget build(BuildContext context) {
    return DropTarget(
      enable: widget.enabled,
      onDragEntered: (_) => _setDragging(true),
      onDragExited: (_) => _setDragging(false),
      onDragDone: (details) => handleDrop([for (final f in details.files) f.path]),
      child: Stack(
        children: [
          widget.child,
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedContainer(
                key: const ValueKey('desktop-drop-outline'),
                duration: DanaviewMotion.fast,
                decoration: BoxDecoration(
                  color: _dragging ? DanaviewColors.primarySoft : const Color(0x00000000),
                  borderRadius: DanaviewRadius.mdAll,
                  border: Border.all(
                    color: _dragging ? DanaviewColors.primaryLight : const Color(0x00000000),
                    width: 1.5,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
