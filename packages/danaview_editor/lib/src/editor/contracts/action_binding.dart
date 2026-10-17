// OWNER: UX-01
//
// The contract between per-feature binding files (`actions/bindings/<feature>_bindings.dart`, one
// per feature ticket), the merge in `wiring/action_bindings.dart` (UX-01) and the
// `EditorActionRegistry` (UX-15), which adds labels, icons and shortcuts where a binding doesn't.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/model.dart' show ProjectId;

import 'action_ids.dart';

/// What triggered an action.
///
/// See ARCH §17.6.
enum EditorActionSource {
  /// A hardware key.
  keyboard,

  /// A tool tile in the strip or rail.
  toolTile,

  /// A context menu (secondary click, long press).
  contextMenu,

  /// A semantics custom action (VoiceOver/TalkBack).
  semantics,

  /// The shortcuts sheet.
  shortcutsSheet,

  /// Any other button (top bar, panel, sheet).
  button,
}

/// What a handler can reach: the open project, a context for sheets and toasts, and providers.
///
/// The registry (UX-15) implements this over the editor's `WidgetRef`; tests implement it over a
/// `ProviderContainer`.
///
/// See ARCH §17.6.
abstract interface class EditorActionContext {
  /// The open project.
  ProjectId get projectId;

  /// A context below the editor's scope (for `showDanaviewSheet`, toasts, `EditorScope.idOf`).
  BuildContext get context;

  /// What triggered the action.
  EditorActionSource get source;

  /// Reads a provider once (no subscription).
  T read<T>(ProviderListenable<T> provider);
}

/// Runs an action.
///
/// See ARCH §17.6.
typedef EditorActionHandler = FutureOr<void> Function(EditorActionContext ctx);

/// Decides enablement or visibility.
///
/// See ARCH §17.6.
typedef EditorActionPredicate = bool Function(EditorActionContext ctx);

/// Explains why an action is disabled (shown when a disabled tile is tapped), or null.
///
/// See ARCH §17.6.
typedef EditorActionReason = String? Function(EditorActionContext ctx);

/// One feature's implementation of one [EditorActionId].
///
/// Each id is bound at most once across all binding files (`wiring/action_bindings.dart` rejects
/// duplicates). [label] and [icon] override the registry defaults when given; copy comes from the
/// feature's own `app/strings/<feature>_strings.dart`.
///
/// See ARCH §17.6.
@immutable
final class EditorActionBinding {
  /// Creates a binding.
  const EditorActionBinding({
    required this.id,
    required this.handler,
    this.isEnabled,
    this.isVisible,
    this.disabledReason,
    this.label,
    this.icon,
  });

  /// The action.
  final EditorActionId id;

  /// Runs it.
  final EditorActionHandler handler;

  /// Enablement (null: always enabled).
  final EditorActionPredicate? isEnabled;

  /// Visibility (null: always visible).
  final EditorActionPredicate? isVisible;

  /// Why it is disabled (null: no explanation).
  final EditorActionReason? disabledReason;

  /// Label override.
  final String? label;

  /// Icon override.
  final IconData? icon;
}
