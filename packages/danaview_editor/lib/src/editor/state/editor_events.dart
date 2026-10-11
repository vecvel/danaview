// OWNER: UX-08
//
// One-shot editor events (ux.md §16.3): toasts, haptics, screen-reader announcements and the
// notifications other controllers react to (a commit landed, history moved, recovery or limits on
// open). `EditorController.events` is a broadcast stream; the editor screen turns toasts into
// `DanaviewToast`s, haptics into `HapticFeedback` calls and announcements into
// `SemanticsService.sendAnnouncement`. Events carry no media paths and no user text beyond labels.

import 'package:flutter/foundation.dart';
import 'package:danaview_editor_core/model.dart' show ItemId, TrackId;
import 'package:danaview_editor_core/ops.dart' show EditNotice, EditRejection, HistoryDirection, LimitExceeded;
import 'package:danaview_editor_core/store.dart' show RecoverableSession;

import '../../app/editor_messages.dart';

/// A one-shot UI effect (toast, haptic, announcement; ux.md §16.3).
@immutable
sealed class EditorEvent {
  /// Creates an event.
  const EditorEvent();
}

/// How a toast looks (maps to `DanaviewToastKind`).
enum EditorToastKind {
  /// Informational (rejections, notices; ARCH §19 rule 4).
  info,

  /// Success ("Saved").
  success,

  /// Error (save failure, preview stopped).
  error,
}

/// A toast with [message].
final class EditorToast extends EditorEvent {
  /// Creates a toast.
  const EditorToast(this.message, {this.kind = EditorToastKind.info, this.touchOnly = false});

  /// Copy (title, detail, next action).
  final EditorMessage message;

  /// Look.
  final EditorToastKind kind;

  /// Shown only when the last input was touch (undo/redo toasts, ux.md §14.1: on a keyboard the
  /// label is already in the tooltip).
  final bool touchOnly;

  @override
  String toString() => 'EditorToast(${kind.name}, "${message.title}")';
}

/// Haptic feedback kinds.
enum EditorHapticKind {
  /// Selection tick.
  selection,

  /// Light impact (a gesture committed).
  light,

  /// A refused action.
  warning,
}

/// A haptic tap.
final class EditorHaptic extends EditorEvent {
  /// Creates a haptic event.
  const EditorHaptic(this.kind);

  /// Kind.
  final EditorHapticKind kind;

  @override
  String toString() => 'EditorHaptic(${kind.name})';
}

/// A screen-reader announcement.
final class EditorAnnouncement extends EditorEvent {
  /// Creates an announcement.
  const EditorAnnouncement(this.text);

  /// Text to announce.
  final String text;

  @override
  String toString() => 'EditorAnnouncement("$text")';
}

/// A command (or a gesture transaction) was committed as one history entry.
final class EditorCommitted extends EditorEvent {
  /// Creates the event.
  EditorCommitted({required this.label, Set<ItemId> affected = const {}, Set<TrackId> changedTracks = const {}, this.notices = const []})
      : affected = Set.unmodifiable(affected),
        changedTracks = Set.unmodifiable(changedTracks);

  /// History label.
  final String label;

  /// Items the command touched (the viewport may `ensureVisible` them).
  final Set<ItemId> affected;

  /// Lanes that changed.
  final Set<TrackId> changedTracks;

  /// Notices of the outcome.
  final List<EditNotice> notices;

  @override
  String toString() => 'EditorCommitted("$label", ${affected.length} items)';
}

/// A command was refused (the toast is emitted separately).
final class EditorRejected extends EditorEvent {
  /// Creates the event.
  const EditorRejected(this.label, this.rejection);

  /// Label of the refused command.
  final String label;

  /// Why.
  final EditRejection rejection;

  @override
  String toString() => 'EditorRejected("$label", $rejection)';
}

/// Undo, redo or a history jump moved the project (one plan patch).
final class EditorHistoryMoved extends EditorEvent {
  /// Creates the event.
  EditorHistoryMoved({required this.direction, required this.labels, Set<ItemId> affected = const {}})
      : affected = Set.unmodifiable(affected);

  /// Undo or redo.
  final HistoryDirection direction;

  /// Labels of the entries crossed, in the order they were applied or reverted.
  final List<String> labels;

  /// Items affected (the viewport `ensureVisible`s them; the playhead does not move).
  final Set<ItemId> affected;

  @override
  String toString() => 'EditorHistoryMoved(${direction.name}, $labels)';
}

/// The opened project has a journal newer than its main document (UX-40 shows the banner).
final class EditorRecoveryAvailable extends EditorEvent {
  /// Creates the event.
  const EditorRecoveryAvailable(this.session);

  /// The recoverable journal.
  final RecoverableSession session;
}

/// The opened project already exceeds a device limit (D-14 banner; export preflight refuses).
final class EditorLimitsExceeded extends EditorEvent {
  /// Creates the event.
  EditorLimitsExceeded(List<LimitExceeded> limits) : limits = List.unmodifiable(limits);

  /// The exceeded limits.
  final List<LimitExceeded> limits;
}
