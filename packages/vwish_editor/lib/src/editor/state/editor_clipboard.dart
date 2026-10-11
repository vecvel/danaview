// OWNER: UX-13
//
// The in-app clipboard (ux.md §14.4, D-16).
//
// * `EditorClipboard` wraps core's self-contained `ClipboardPayload` (items with their lane kinds
//   and offsets, transitions between copied clips, and every pool asset they use) with the time it
//   was copied. It lives in `editorClipboardProvider`, an app-level provider, so a paste may land
//   in another project (the payload re-adds its media to that project's pool).
// * Copy is read-only (no history entry). Cut = copy + delete as **one** history entry "Cut"
//   (core `cutItems`); the clipboard is only replaced when the delete is applied. Paste inserts at
//   the playhead on the selected lane when compatible, else on the first free lane of each kind
//   (core `PasteItems`). Duplicate (core `DuplicateItems`) does not touch the clipboard.
// * The system clipboard is untouched, except subtitle cue text, which is also copied as plain
//   text for convenience.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/ops.dart';

/// The in-app clipboard contents (ux.md §14.4).
@immutable
class EditorClipboard {
  /// Creates the clipboard contents.
  EditorClipboard(this.payload, {DateTime? copiedAt}) : copiedAt = copiedAt ?? DateTime.now();

  /// The copied items, lanes, transitions and media.
  final ClipboardPayload payload;

  /// When the items were copied.
  final DateTime copiedAt;

  /// The copied items (serialized items, lane index and offset from the first start).
  List<ClipboardItem> get items => payload.items;

  /// The project the items were copied from.
  ProjectId get sourceProject => payload.source;

  /// Whether there is nothing to paste.
  bool get isEmpty => payload.isEmpty;

  /// Number of copied items.
  int get length => payload.items.length;

  /// The text of the copied subtitle cues, one cue per paragraph (null when none were copied).
  String? get cueText {
    final cues = [
      for (final i in payload.items)
        if (i.item case final SubtitleCue cue) cue,
    ]..sort((a, b) => a.start.compareTo(b.start));
    if (cues.isEmpty) return null;
    return cues.map((c) => c.text).join('\n\n');
  }

  @override
  bool operator ==(Object other) => other is EditorClipboard && other.payload == payload && other.copiedAt == copiedAt;

  @override
  int get hashCode => Object.hash(payload, copiedAt);

  @override
  String toString() => 'EditorClipboard(${payload.items.length} items from ${payload.source})';
}

/// Holds the in-app clipboard of the running app.
class EditorClipboardController extends StateNotifier<EditorClipboard?> {
  /// Creates an empty clipboard; [systemText] receives cue text for the system clipboard.
  EditorClipboardController({void Function(String text)? systemText})
      : _systemText = systemText ?? _toSystemClipboard,
        super(null);

  final void Function(String text) _systemText;

  /// The contents, or null when nothing was copied.
  EditorClipboard? get contents => state;

  /// Whether there is something to paste.
  bool get hasContent => !(state?.isEmpty ?? true);

  /// Replaces the contents with [payload] (ignored when empty); cue text also goes to the system
  /// clipboard.
  void put(ClipboardPayload payload) {
    if (payload.isEmpty) return;
    final next = EditorClipboard(payload);
    state = next;
    final text = next.cueText;
    if (text != null) _systemText(text);
  }

  /// Empties the clipboard.
  void clear() => state = null;

  static void _toSystemClipboard(String text) {
    unawaited(Clipboard.setData(ClipboardData(text: text)).catchError((Object _) {}));
  }
}

/// The app-level in-app clipboard (ux.md §14.4).
final editorClipboardProvider = StateNotifierProvider<EditorClipboardController, EditorClipboard?>(
  (ref) => EditorClipboardController(),
  name: 'editorClipboardProvider',
);
