// OWNER: CORE-09
//
// `CompositeCommand` (ARCH §7.1, domain.md §6.1): applies its children in sequence as one atomic
// command (one history entry). Each child runs on the normalized result of the previous one; if
// any child is refused the whole command is refused with that rejection and nothing changes.
// Limits and validation run once, on the final result. Apply-to-all, Cut (copy + delete), Freeze
// and the AI caption commands are built from it.

part of '../edit_command.dart';

/// Several commands applied atomically as one.
final class CompositeCommand extends EditCommand {
  /// Creates a composite labelled [label] running [commands] in order.
  CompositeCommand(this.label, List<EditCommand> commands) : commands = List.unmodifiable(commands);

  @override
  final String label;

  /// The children, in order.
  final List<EditCommand> commands;

  @override
  void _apply(_Draft d) {
    for (final c in commands) {
      final child = _Draft(d.snapshot(), d.ctx);
      c._apply(child);
      d.absorb(child, child.finish());
    }
  }

  @override
  String toString() => 'CompositeCommand($label, $commands)';
}

/// A command that replaces the project with the result of [edit] (tests of the framework only:
/// post-step validation, exception handling and limits on arbitrary edits). Lanes [edit] returns
/// as different objects count as changed; pool, settings and markers are adopted as returned.
///
/// Production code never uses it: every user edit is a named command of a group part.
@visibleForTesting
final class RawEditCommand extends EditCommand {
  /// Creates a raw edit labelled [label].
  const RawEditCommand(this.label, this.edit);

  @override
  final String label;

  /// The edit: the working project in, the edited project out (may throw).
  final EditProject Function(EditProject project) edit;

  @override
  void _apply(_Draft d) {
    final before = d.snapshot();
    final next = edit(before);
    if (identical(next, before)) return;
    final old = {for (final t in d.tracks) t.id: t};
    final ids = {for (final t in next.tracks) t.id};
    for (final t in next.tracks) {
      final o = old[t.id];
      if (o == null) d.created.add(t.id);
      if (!identical(o, t)) {
        d.changed.add(t.id);
        for (final i in t.items) {
          if (o == null || !o.items.contains(i)) d.affected.add(i.id);
        }
      }
    }
    for (final id in old.keys) {
      if (!ids.contains(id)) d.changed.add(id);
    }
    d.tracks
      ..clear()
      ..addAll(next.tracks);
    d.pool = next.pool;
    d.settings = next.settings;
    d.markers = next.markers;
    d._invalidate();
  }

  @override
  String toString() => 'RawEditCommand($label)';
}
