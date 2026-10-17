// OWNER: UX-15
//
// EditorActionRegistry (ARCH §17.6, ux.md §15): one table that feeds every way of invoking an
// action, so tool tiles, context menus, keyboard shortcuts, semantics custom actions and the
// shortcuts sheet cannot drift apart.
//
//   EditorActionId ──► metadata table (label, icon, key combos, text-field and repeat rules)
//   per-feature bindings (wiring/action_bindings.dart) ──► handler, enabled/visible predicates,
//                                                          disabled reason, label/icon overrides
//   built-ins (below) ──► handlers for actions no feature ticket binds (undo, redo, save, zoom,
//                         the shortcuts sheet); a feature binding always wins.
//   ═► EditorActionSpec per id ═► EditorActionRegistry
//
// * Key combos are written once, for `⌘` = Command on Apple platforms and Ctrl elsewhere
//   (`SingleActivator(key, meta: apple, control: !apple)`); the registry resolves them for the
//   platform it is built for (`forPlatform`), so tests cover iOS, Android and macOS.
// * `invoke` never throws: a handler's sync or async error is reported to `FlutterError` and
//   the action reports `failed` (ARCH §19 rule 1: no editor action crashes the app).
// * Disabled actions explain themselves: `disabledReason` is the binding's reason, or a generic
//   one; an action nobody binds yet reads "Not available yet".
// * `EditorActionContext` is implemented here over the editor's `WidgetRef`
//   ([WidgetActionContext]) for widgets, and over a `ProviderContainer` for tests and tools.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/model.dart' show ProjectId;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../app/editor_providers.dart';
import '../contracts/contracts.dart';
import '../state/editor_state.dart';
import '../wiring/action_bindings.dart';
import 'bindings/render_preview_bindings.dart' show renderPreviewMeta;
import 'shortcuts_sheet.dart';

// -------------------------------------------------------------------------------------------------
// Copy
// -------------------------------------------------------------------------------------------------

/// Copy of the action registry and the shortcuts sheet.
abstract final class EditorActionStrings {
  /// Title of the shortcuts sheet.
  static const String sheetTitle = 'Keyboard shortcuts';

  /// Note under the sheet's list.
  static const String sheetNote = 'Shortcuts work when a hardware keyboard is connected.';

  /// Reason shown for an action no feature provides yet.
  static const String notAvailableYet = 'Not available yet';

  /// Generic reason for a disabled action.
  static const String notAvailableNow = 'Not available right now';

  /// Undo with nothing to undo.
  static const String nothingToUndo = 'Nothing to undo';

  /// Redo with nothing to redo.
  static const String nothingToRedo = 'Nothing to redo';

  /// Save in a read-only project.
  static const String readOnly = 'This project is read-only';

  /// Zoom at the limit.
  static const String zoomLimit = 'Can\'t zoom further';

  /// The editor is not open yet.
  static const String notOpen = 'The project is still opening';

  /// Title of a shortcut group.
  static String group(EditorActionGroup group) => switch (group) {
        EditorActionGroup.playback => 'Playback',
        EditorActionGroup.editing => 'Editing',
        EditorActionGroup.timeline => 'Timeline',
        EditorActionGroup.markers => 'Markers',
        EditorActionGroup.tools => 'Help',
      };

  /// Semantics label of a shortcut row ("Split, S").
  static String rowSemantics(String label, List<String> keys, String? reason) {
    final shortcut = keys.isEmpty ? '' : ', ${keys.join(' or ')}';
    return reason == null ? '$label$shortcut' : '$label$shortcut, unavailable: $reason';
  }
}

// -------------------------------------------------------------------------------------------------
// Key combos
// -------------------------------------------------------------------------------------------------

/// One key combination of an action, written once for every platform.
@immutable
final class EditorKeyCombo {
  /// A combo on [key]. [command] means `⌘` (Command on Apple platforms, Ctrl elsewhere).
  const EditorKeyCombo(
    LogicalKeyboardKey this.key, {
    this.command = false,
    this.shift = false,
    this.rootOnly = false,
    this.hidden = false,
    this.appleOnly = false,
    this.otherOnly = false,
  }) : character = null;

  /// A combo on the typed [character] (layout independent, for `?`).
  const EditorKeyCombo.character(String this.character, {this.hidden = false})
      : key = null,
        command = false,
        shift = false,
        rootOnly = false,
        appleOnly = false,
        otherOnly = false;

  /// The key, or null for a character combo.
  final LogicalKeyboardKey? key;

  /// The typed character, or null for a key combo.
  final String? character;

  /// Needs `⌘` (Command on Apple platforms, Ctrl elsewhere).
  final bool command;

  /// Needs Shift.
  final bool shift;

  /// Works only when no control holds focus (Enter: playPause, so a focused button still
  /// activates with Enter).
  final bool rootOnly;

  /// Not listed on the shortcuts sheet or in tooltips (an alias such as numpad Enter).
  final bool hidden;

  /// Only on Apple platforms.
  final bool appleOnly;

  /// Only on non-Apple platforms (Ctrl+Y).
  final bool otherOnly;

  /// Whether the combo exists on a platform with [apple].
  bool appliesTo(bool apple) => apple ? !otherOnly : !appleOnly;

  /// The activator on a platform with [apple].
  ShortcutActivator activator(bool apple) {
    final c = character;
    if (c != null) return CharacterActivator(c);
    return SingleActivator(key!, meta: command && apple, control: command && !apple, shift: shift);
  }

  /// The label on a platform with [apple] ("⌘Z", "Ctrl+Shift+Z", "←").
  String label(bool apple) {
    final c = character;
    if (c != null) return c;
    final name = _keyName(key!);
    if (apple) return '${shift ? '⇧' : ''}${command ? '⌘' : ''}$name';
    return [if (command) 'Ctrl', if (shift) 'Shift', name].join('+');
  }

  static String _keyName(LogicalKeyboardKey k) {
    if (k == LogicalKeyboardKey.space) return 'Space';
    if (k == LogicalKeyboardKey.arrowLeft) return '←';
    if (k == LogicalKeyboardKey.arrowRight) return '→';
    if (k == LogicalKeyboardKey.arrowUp) return '↑';
    if (k == LogicalKeyboardKey.arrowDown) return '↓';
    if (k == LogicalKeyboardKey.escape) return 'Esc';
    if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) return 'Enter';
    if (k == LogicalKeyboardKey.equal || k == LogicalKeyboardKey.numpadAdd) return '=';
    if (k == LogicalKeyboardKey.minus || k == LogicalKeyboardKey.numpadSubtract) return '−';
    if (k == LogicalKeyboardKey.slash) return '/';
    final label = k.keyLabel;
    return label.length == 1 ? label.toUpperCase() : label;
  }

  @override
  bool operator ==(Object other) =>
      other is EditorKeyCombo &&
      other.key == key &&
      other.character == character &&
      other.command == command &&
      other.shift == shift &&
      other.rootOnly == rootOnly &&
      other.hidden == hidden &&
      other.appleOnly == appleOnly &&
      other.otherOnly == otherOnly;

  @override
  int get hashCode => Object.hash(key, character, command, shift, rootOnly, hidden, appleOnly, otherOnly);
}

/// Static facts of one action: label, icon, key combos and keyboard rules.
@immutable
final class EditorActionMeta {
  /// Creates the metadata.
  const EditorActionMeta(
    this.label,
    this.icon, {
    this.combos = const <EditorKeyCombo>[],
    this.worksInTextFields = false,
    this.repeatable = false,
  });

  /// Default label (a binding may override it).
  final String label;

  /// Default icon (a binding may override it).
  final IconData icon;

  /// Keyboard shortcuts.
  final List<EditorKeyCombo> combos;

  /// Keeps working while a text field has focus (only save and escape).
  final bool worksInTextFields;

  /// Runs again on key repeat (frame steps, undo, zoom); other actions run once per key press.
  final bool repeatable;
}

/// The metadata of every action (exhaustive: adding an [EditorActionId] fails to compile here).
EditorActionMeta editorActionMeta(EditorActionId id) {
  EditorKeyCombo key(LogicalKeyboardKey logical, {bool command = false, bool shift = false, bool hidden = false, bool rootOnly = false, bool appleOnly = false, bool otherOnly = false}) =>
      EditorKeyCombo(logical, command: command, shift: shift, hidden: hidden, rootOnly: rootOnly, appleOnly: appleOnly, otherOnly: otherOnly);
  return switch (id) {
    // Playback.
    EditorActionId.playPause => EditorActionMeta('Play / Pause', Icons.play_arrow_rounded, combos: [
        key(LogicalKeyboardKey.space),
        key(LogicalKeyboardKey.keyK),
        key(LogicalKeyboardKey.enter, hidden: true, rootOnly: true),
        key(LogicalKeyboardKey.numpadEnter, hidden: true, rootOnly: true),
      ]),
    EditorActionId.prevFrame => EditorActionMeta('Previous frame', Icons.keyboard_arrow_left_rounded, combos: [key(LogicalKeyboardKey.arrowLeft)], repeatable: true),
    EditorActionId.nextFrame => EditorActionMeta('Next frame', Icons.keyboard_arrow_right_rounded, combos: [key(LogicalKeyboardKey.arrowRight)], repeatable: true),
    EditorActionId.back1s => EditorActionMeta('Back 1 second', Icons.replay_rounded, combos: [key(LogicalKeyboardKey.arrowLeft, shift: true)], repeatable: true),
    EditorActionId.forward1s => EditorActionMeta('Forward 1 second', Icons.forward_rounded, combos: [key(LogicalKeyboardKey.arrowRight, shift: true)], repeatable: true),
    EditorActionId.prevEdit => EditorActionMeta('Previous edit point', Icons.first_page_rounded, combos: [key(LogicalKeyboardKey.arrowUp)], repeatable: true),
    EditorActionId.nextEdit => EditorActionMeta('Next edit point', Icons.last_page_rounded, combos: [key(LogicalKeyboardKey.arrowDown)], repeatable: true),
    EditorActionId.goStart => EditorActionMeta('Go to start', Icons.skip_previous_rounded, combos: [key(LogicalKeyboardKey.home)]),
    EditorActionId.goEnd => EditorActionMeta('Go to end', Icons.skip_next_rounded, combos: [key(LogicalKeyboardKey.end)]),
    EditorActionId.fullscreenPreview => EditorActionMeta('Fullscreen preview', Icons.fullscreen_rounded, combos: [key(LogicalKeyboardKey.keyF)]),
    // Editing.
    EditorActionId.split => EditorActionMeta('Split', Icons.content_cut_rounded, combos: [key(LogicalKeyboardKey.keyS)]),
    EditorActionId.delete => EditorActionMeta('Delete', Icons.delete_outline_rounded, combos: [key(LogicalKeyboardKey.delete), key(LogicalKeyboardKey.backspace)]),
    EditorActionId.rippleDelete => EditorActionMeta('Ripple delete', Icons.playlist_remove_rounded, combos: [
        key(LogicalKeyboardKey.delete, shift: true),
        key(LogicalKeyboardKey.backspace, shift: true),
      ]),
    EditorActionId.deleteGap => const EditorActionMeta('Delete gap', Icons.space_bar_rounded),
    EditorActionId.undo => EditorActionMeta('Undo', Icons.undo_rounded, combos: [key(LogicalKeyboardKey.keyZ, command: true)], repeatable: true),
    EditorActionId.redo => EditorActionMeta('Redo', Icons.redo_rounded, combos: [
        key(LogicalKeyboardKey.keyZ, command: true, shift: true),
        key(LogicalKeyboardKey.keyY, command: true, otherOnly: true),
      ], repeatable: true),
    EditorActionId.save => EditorActionMeta('Save', Icons.save_rounded, combos: [key(LogicalKeyboardKey.keyS, command: true)], worksInTextFields: true),
    EditorActionId.copy => EditorActionMeta('Copy', Icons.content_copy_rounded, combos: [key(LogicalKeyboardKey.keyC, command: true)]),
    EditorActionId.cut => EditorActionMeta('Cut', Icons.content_cut_rounded, combos: [key(LogicalKeyboardKey.keyX, command: true)]),
    EditorActionId.paste => EditorActionMeta('Paste', Icons.content_paste_rounded, combos: [key(LogicalKeyboardKey.keyV, command: true)]),
    EditorActionId.duplicate => EditorActionMeta('Duplicate', Icons.control_point_duplicate_rounded, combos: [key(LogicalKeyboardKey.keyD, command: true)]),
    EditorActionId.selectAll => EditorActionMeta('Select all', Icons.select_all_rounded, combos: [key(LogicalKeyboardKey.keyA, command: true)]),
    EditorActionId.escape => EditorActionMeta('Cancel or close', Icons.close_rounded, combos: [key(LogicalKeyboardKey.escape)], worksInTextFields: true),
    EditorActionId.multiSelect => const EditorActionMeta('Select several', Icons.checklist_rounded),
    EditorActionId.moveToTrack => const EditorActionMeta('Move to track', Icons.drive_file_move_rounded),
    // Timeline.
    EditorActionId.toggleSnapping => EditorActionMeta('Snapping', Icons.vertical_align_center_rounded, combos: [key(LogicalKeyboardKey.keyN)]),
    EditorActionId.toggleRipple => EditorActionMeta('Ripple editing', Icons.swap_horiz_rounded, combos: [key(LogicalKeyboardKey.keyR)]),
    EditorActionId.zoomIn => EditorActionMeta('Zoom in', Icons.zoom_in_rounded, combos: [
        key(LogicalKeyboardKey.equal, command: true),
        key(LogicalKeyboardKey.numpadAdd, command: true, hidden: true),
      ], repeatable: true),
    EditorActionId.zoomOut => EditorActionMeta('Zoom out', Icons.zoom_out_rounded, combos: [
        key(LogicalKeyboardKey.minus, command: true),
        key(LogicalKeyboardKey.numpadSubtract, command: true, hidden: true),
      ], repeatable: true),
    EditorActionId.zoomFit => EditorActionMeta('Zoom to fit', Icons.fit_screen_rounded, combos: [key(LogicalKeyboardKey.keyZ, shift: true)]),
    EditorActionId.centerPlayhead => const EditorActionMeta('Center playhead', Icons.center_focus_strong_rounded),
    EditorActionId.laneHeight => const EditorActionMeta('Track height', Icons.height_rounded),
    EditorActionId.safeGuides => const EditorActionMeta('Safe area guides', Icons.grid_on_rounded),
    EditorActionId.addTrack => const EditorActionMeta('Add track', Icons.add_rounded),
    // Markers.
    EditorActionId.addMarker => EditorActionMeta('Add marker', Icons.bookmark_add_rounded, combos: [key(LogicalKeyboardKey.keyM)]),
    EditorActionId.editMarker => const EditorActionMeta('Edit marker', Icons.edit_rounded),
    EditorActionId.deleteMarker => const EditorActionMeta('Delete marker', Icons.bookmark_remove_rounded),
    // Tools.
    EditorActionId.media => const EditorActionMeta('Media', Icons.video_library_rounded),
    EditorActionId.addMusic => const EditorActionMeta('Add music', Icons.music_note_rounded),
    EditorActionId.recordVoiceover => const EditorActionMeta('Record voiceover', Icons.mic_rounded),
    EditorActionId.extractAudio => const EditorActionMeta('Extract audio', Icons.audiotrack_rounded),
    EditorActionId.addText => const EditorActionMeta('Add text', Icons.title_rounded),
    EditorActionId.captions => const EditorActionMeta('Captions', Icons.subtitles_rounded),
    EditorActionId.autoCaptions => const EditorActionMeta('Auto captions', Icons.auto_awesome_rounded),
    EditorActionId.addCaption => const EditorActionMeta('Add caption', Icons.add_comment_rounded),
    EditorActionId.importSubtitles => const EditorActionMeta('Import subtitles', Icons.file_download_rounded),
    EditorActionId.exportSubtitles => const EditorActionMeta('Export subtitles', Icons.file_upload_rounded),
    EditorActionId.regenerateCaptions => const EditorActionMeta('Regenerate captions', Icons.refresh_rounded),
    EditorActionId.addOverlay => const EditorActionMeta('Add overlay', Icons.layers_rounded),
    EditorActionId.adjust => const EditorActionMeta('Adjust', Icons.tune_rounded),
    EditorActionId.filters => const EditorActionMeta('Filters', Icons.filter_vintage_rounded),
    EditorActionId.transitions => const EditorActionMeta('Transitions', Icons.compare_rounded),
    EditorActionId.format => const EditorActionMeta('Format', Icons.aspect_ratio_rounded),
    EditorActionId.transform => const EditorActionMeta('Transform', Icons.open_with_rounded),
    EditorActionId.crop => const EditorActionMeta('Crop', Icons.crop_rounded),
    EditorActionId.mask => const EditorActionMeta('Mask', Icons.vignette_rounded),
    EditorActionId.chromaKey => const EditorActionMeta('Chroma key', Icons.gradient_rounded),
    EditorActionId.speed => const EditorActionMeta('Speed', Icons.speed_rounded),
    EditorActionId.volume => const EditorActionMeta('Volume', Icons.volume_up_rounded),
    EditorActionId.fades => const EditorActionMeta('Fades', Icons.show_chart_rounded),
    EditorActionId.keyframes => const EditorActionMeta('Keyframes', Icons.diamond_rounded),
    EditorActionId.keyframeAtPlayhead => const EditorActionMeta('Keyframe at playhead', Icons.add_circle_outline_rounded),
    EditorActionId.resetTransform => const EditorActionMeta('Reset transform', Icons.restart_alt_rounded),
    EditorActionId.bringForward => const EditorActionMeta('Bring forward', Icons.flip_to_front_rounded),
    EditorActionId.sendBackward => const EditorActionMeta('Send backward', Icons.flip_to_back_rounded),
    EditorActionId.reverse => const EditorActionMeta('Reverse', Icons.fast_rewind_rounded),
    EditorActionId.freeze => const EditorActionMeta('Freeze frame', Icons.ac_unit_rounded),
    EditorActionId.replace => const EditorActionMeta('Replace media', Icons.swap_calls_rounded),
    EditorActionId.clipInfo => const EditorActionMeta('Clip info', Icons.info_outline_rounded),
    EditorActionId.export => const EditorActionMeta('Export', Icons.ios_share_rounded),
    EditorActionId.renderPreview => renderPreviewMeta,
    EditorActionId.showShortcuts => EditorActionMeta('Keyboard shortcuts', Icons.keyboard_rounded, combos: [
        key(LogicalKeyboardKey.slash, command: true),
        const EditorKeyCombo.character('?'),
      ]),
    EditorActionId.projectSheet => const EditorActionMeta('Project options', Icons.expand_more_rounded),
    EditorActionId.history => const EditorActionMeta('History', Icons.history_rounded),
    EditorActionId.tasks => const EditorActionMeta('Background tasks', Icons.pending_actions_rounded),
    EditorActionId.relink => const EditorActionMeta('Relink media', Icons.link_rounded),
  };
}

// -------------------------------------------------------------------------------------------------
// Intent, outcome, context
// -------------------------------------------------------------------------------------------------

/// The Flutter `Intent` of an editor action (what the shortcut map yields).
@immutable
class EditorActionIntent extends Intent {
  /// Creates the intent for [id].
  const EditorActionIntent(this.id);

  /// The action.
  final EditorActionId id;

  @override
  String toStringShort() => 'EditorActionIntent(${id.name})';
}

/// What [EditorActionRegistry.invoke] did.
enum EditorActionResult {
  /// The handler ran (it may still be running when it is asynchronous).
  ran,

  /// No feature binds the action.
  unbound,

  /// The binding says the action is not visible now.
  hidden,

  /// The binding says the action is disabled now.
  disabled,

  /// The handler (or a predicate) threw; the error was reported.
  failed,
}

/// An [EditorActionContext] over a `WidgetRef` (or any provider reader).
final class WidgetActionContext implements EditorActionContext {
  /// Creates a context that reads providers through [ref].
  WidgetActionContext({required this.projectId, required this.context, required WidgetRef ref, this.source = EditorActionSource.button})
      : _read = ref.read;

  /// Creates a context that reads providers from [container] (tests, tools).
  WidgetActionContext.container({required this.projectId, required this.context, required ProviderContainer container, this.source = EditorActionSource.button})
      : _read = container.read;

  @override
  final ProjectId projectId;

  @override
  final BuildContext context;

  @override
  final EditorActionSource source;

  final T Function<T>(ProviderListenable<T> provider) _read;

  @override
  T read<T>(ProviderListenable<T> provider) => _read<T>(provider);

  /// The same context for another trigger.
  WidgetActionContext withSource(EditorActionSource other) =>
      WidgetActionContext._(projectId, context, other, _read);

  WidgetActionContext._(this.projectId, this.context, this.source, this._read);
}

// -------------------------------------------------------------------------------------------------
// Spec
// -------------------------------------------------------------------------------------------------

/// One action as the UI sees it: label, icon, shortcuts and the live predicates of its binding.
@immutable
final class EditorActionSpec {
  EditorActionSpec._({
    required this.id,
    required this.label,
    required this.icon,
    required this.meta,
    required this.apple,
    required this.binding,
  })  : combos = List.unmodifiable([
          for (final c in meta.combos)
            if (c.appliesTo(apple)) c,
        ]),
        shortcuts = List.unmodifiable([
          for (final c in meta.combos)
            if (c.appliesTo(apple)) c.activator(apple),
        ]);

  /// The action.
  final EditorActionId id;

  /// Label (the binding's, else the default).
  final String label;

  /// Icon (the binding's, else the default).
  final IconData icon;

  /// Static facts (combos, keyboard rules).
  final EditorActionMeta meta;

  /// Whether the registry was built for an Apple platform (`⌘` is Command).
  final bool apple;

  /// The feature's binding, or null.
  final EditorActionBinding? binding;

  /// The combos that exist on this platform.
  final List<EditorKeyCombo> combos;

  /// The activators of [combos], same order. `ShortcutActivator`s compare by identity, so these
  /// instances are the ones in `EditorActionRegistry.activators`.
  final List<ShortcutActivator> shortcuts;

  /// Whether a feature provides the action.
  bool get isBound => binding != null;

  /// Runs while a text field has focus (save, escape).
  bool get worksInTextFields => meta.worksInTextFields;

  /// Runs again on key repeat.
  bool get repeatable => meta.repeatable;

  /// Labels of the combos to show ("Space", "K"; aliases are left out).
  List<String> get shortcutLabels => [
        for (final c in combos)
          if (!c.hidden) c.label(apple),
      ];

  /// The first shortcut label ("⌘Z"), or null.
  String? get primaryShortcut {
    final labels = shortcutLabels;
    return labels.isEmpty ? null : labels.first;
  }

  /// Whether the action is shown in [ctx] (unbound actions are not "hidden": they show disabled).
  bool isVisible(EditorActionContext ctx) {
    final b = binding;
    if (b == null) return true;
    return _guard(() => b.isVisible?.call(ctx) ?? true, fallback: false);
  }

  /// Whether the action can run in [ctx].
  bool isEnabled(EditorActionContext ctx) {
    final b = binding;
    if (b == null) return false;
    return _guard(() => b.isEnabled?.call(ctx) ?? true, fallback: false);
  }

  /// Why the action is disabled in [ctx], or null when it is enabled.
  String? disabledReason(EditorActionContext ctx) {
    final b = binding;
    if (b == null) return EditorActionStrings.notAvailableYet;
    if (isEnabled(ctx)) return null;
    final reason = _guard<String?>(() => b.disabledReason?.call(ctx), fallback: null);
    return reason ?? EditorActionStrings.notAvailableNow;
  }

  static T _guard<T>(T Function() body, {required T fallback}) {
    try {
      return body();
    } catch (e, s) {
      FlutterError.reportError(FlutterErrorDetails(exception: e, stack: s, library: 'danaview_editor', context: ErrorDescription('evaluating an action predicate')));
      return fallback;
    }
  }
}

// -------------------------------------------------------------------------------------------------
// Built-in bindings
// -------------------------------------------------------------------------------------------------

/// Handlers for actions no feature ticket binds. A binding from `wiring/action_bindings.dart`
/// always wins over these.
Map<EditorActionId, EditorActionBinding> _builtInBindings() {
  EditorState stateOf(EditorActionContext ctx) => ctx.read(editorControllerProvider(ctx.projectId));
  bool ready(EditorActionContext ctx) => stateOf(ctx).phase == EditorPhase.ready;
  return {
    EditorActionId.undo: EditorActionBinding(
      id: EditorActionId.undo,
      handler: (ctx) => ctx.read(editorControllerProvider(ctx.projectId).notifier).undo(),
      isEnabled: (ctx) => ready(ctx) && stateOf(ctx).history.canUndo,
      disabledReason: (ctx) => ready(ctx) ? EditorActionStrings.nothingToUndo : EditorActionStrings.notOpen,
    ),
    EditorActionId.redo: EditorActionBinding(
      id: EditorActionId.redo,
      handler: (ctx) => ctx.read(editorControllerProvider(ctx.projectId).notifier).redo(),
      isEnabled: (ctx) => ready(ctx) && stateOf(ctx).history.canRedo,
      disabledReason: (ctx) => ready(ctx) ? EditorActionStrings.nothingToRedo : EditorActionStrings.notOpen,
    ),
    EditorActionId.save: EditorActionBinding(
      id: EditorActionId.save,
      handler: (ctx) => ctx.read(editorControllerProvider(ctx.projectId).notifier).saveNow(manual: true),
      isEnabled: (ctx) => ready(ctx) && stateOf(ctx).save.phase != SavePhase.readOnly,
      disabledReason: (ctx) => ready(ctx) ? EditorActionStrings.readOnly : EditorActionStrings.notOpen,
    ),
    EditorActionId.zoomIn: EditorActionBinding(
      id: EditorActionId.zoomIn,
      handler: (ctx) => ctx.read(viewportProvider(ctx.projectId)).zoomIn(),
      isEnabled: (ctx) => ctx.read(viewportProvider(ctx.projectId)).canZoomIn,
      disabledReason: (ctx) => EditorActionStrings.zoomLimit,
    ),
    EditorActionId.zoomOut: EditorActionBinding(
      id: EditorActionId.zoomOut,
      handler: (ctx) => ctx.read(viewportProvider(ctx.projectId)).zoomOut(),
      isEnabled: (ctx) => ctx.read(viewportProvider(ctx.projectId)).canZoomOut,
      disabledReason: (ctx) => EditorActionStrings.zoomLimit,
    ),
    EditorActionId.zoomFit: EditorActionBinding(
      id: EditorActionId.zoomFit,
      handler: (ctx) => ctx.read(viewportProvider(ctx.projectId)).zoomToFit(),
      isEnabled: (ctx) => ctx.read(viewportProvider(ctx.projectId)).hasLayout,
      disabledReason: (ctx) => EditorActionStrings.notOpen,
    ),
    EditorActionId.showShortcuts: EditorActionBinding(
      id: EditorActionId.showShortcuts,
      handler: (ctx) => ShortcutsSheet.show(ctx.context, projectId: ctx.projectId),
    ),
  };
}

// -------------------------------------------------------------------------------------------------
// Registry
// -------------------------------------------------------------------------------------------------

/// Feeds tool tiles, menus, shortcuts, semantics and the shortcuts sheet (ARCH §17.6).
class EditorActionRegistry {
  /// Creates the registry over [bindings] for a platform with [apple] (`⌘` is Command).
  /// [builtIns] are the fallbacks for ids [bindings] lacks (default: undo, redo, save, zoom and
  /// the shortcuts sheet).
  EditorActionRegistry({
    required Map<EditorActionId, EditorActionBinding> bindings,
    this.apple = false,
    Map<EditorActionId, EditorActionBinding>? builtIns,
  })  : _bindings = bindings,
        _builtIns = builtIns ?? _builtInBindings() {
    final all = <EditorActionId, EditorActionSpec>{};
    for (final id in EditorActionId.values) {
      final meta = editorActionMeta(id);
      final binding = _bindings[id] ?? _builtIns[id];
      all[id] = EditorActionSpec._(
        id: id,
        label: binding?.label ?? meta.label,
        icon: binding?.icon ?? meta.icon,
        meta: meta,
        apple: apple,
        binding: binding,
      );
    }
    _specs = Map.unmodifiable(all);
  }

  /// Creates the registry for [platform] over the merged feature bindings.
  factory EditorActionRegistry.forPlatform(TargetPlatform platform, Map<EditorActionId, EditorActionBinding> bindings) =>
      EditorActionRegistry(bindings: bindings, apple: isApplePlatform(platform));

  /// Whether `⌘` is Command on [platform].
  static bool isApplePlatform(TargetPlatform platform) => platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;

  /// Whether `⌘` means Command (iOS, macOS) rather than Ctrl.
  final bool apple;

  final Map<EditorActionId, EditorActionBinding> _bindings;
  final Map<EditorActionId, EditorActionBinding> _builtIns;
  late final Map<EditorActionId, EditorActionSpec> _specs;
  EditorActionRegistry? _sibling;

  /// The same registry for [platform] (cached; shares bindings).
  EditorActionRegistry forPlatformOf(TargetPlatform platform) {
    final wantApple = isApplePlatform(platform);
    if (wantApple == apple) return this;
    return _sibling ??= EditorActionRegistry(bindings: _bindings, apple: wantApple, builtIns: _builtIns);
  }

  /// The spec of [id].
  EditorActionSpec spec(EditorActionId id) => _specs[id]!;

  /// Every action, in declaration order.
  Iterable<EditorActionSpec> get specs => _specs.values;

  /// The actions that have a keyboard shortcut on this platform, in declaration order.
  Iterable<EditorActionSpec> get shortcutSpecs => _specs.values.where((s) => s.combos.isNotEmpty);

  /// The shortcut map for `Shortcuts`: every combo of this platform to its intent.
  late final Map<ShortcutActivator, Intent> activators = Map.unmodifiable({
    for (final s in _specs.values)
      for (final a in s.shortcuts) a: EditorActionIntent(s.id),
  });

  late final Map<ShortcutActivator, EditorKeyCombo> _comboOf = {
    for (final s in _specs.values)
      for (var i = 0; i < s.shortcuts.length; i++) s.shortcuts[i]: s.combos[i],
  };

  /// The combo behind [activator] (an instance of [activators]), for the keyboard rules of the
  /// combo.
  EditorKeyCombo? comboOf(ShortcutActivator activator) => _comboOf[activator];

  /// "Split (S)"-style tooltip text: [label] and the primary shortcut of [id], if any.
  String tooltip(EditorActionId id, [String? label]) {
    final s = spec(id);
    final shortcut = s.primaryShortcut;
    final text = label ?? s.label;
    return shortcut == null ? text : '$text ($shortcut)';
  }

  /// Runs [id] in [ctx] when it is bound, visible and enabled. Never throws.
  EditorActionResult invoke(EditorActionId id, EditorActionContext ctx) {
    final s = spec(id);
    final binding = s.binding;
    if (binding == null) return EditorActionResult.unbound;
    if (!s.isVisible(ctx)) return EditorActionResult.hidden;
    if (!s.isEnabled(ctx)) return EditorActionResult.disabled;
    try {
      final result = binding.handler(ctx);
      if (result is Future<void>) unawaited(result.catchError((Object e, StackTrace st) => _report(id, e, st)));
      return EditorActionResult.ran;
    } catch (e, st) {
      _report(id, e, st);
      return EditorActionResult.failed;
    }
  }

  static void _report(EditorActionId id, Object e, StackTrace s) => FlutterError.reportError(FlutterErrorDetails(
        exception: e,
        stack: s,
        library: 'danaview_editor',
        context: ErrorDescription('running the ${id.name} action'),
      ));

  /// Custom semantics actions (VoiceOver and TalkBack) for [ids] that are enabled in [ctx]:
  /// attach them to a `Semantics.customSemanticsActions`.
  Map<CustomSemanticsAction, VoidCallback> semanticsActions(EditorActionContext ctx, Iterable<EditorActionId> ids) {
    final out = <CustomSemanticsAction, VoidCallback>{};
    for (final id in ids) {
      final s = spec(id);
      if (!s.isVisible(ctx) || !s.isEnabled(ctx)) continue;
      out[CustomSemanticsAction(label: s.label)] = () => invoke(id, ctx.source == EditorActionSource.semantics ? ctx : _asSemantics(ctx));
    }
    return out;
  }

  static EditorActionContext _asSemantics(EditorActionContext ctx) => ctx is WidgetActionContext ? ctx.withSource(EditorActionSource.semantics) : ctx;

  /// Menu entries for [ids] (a context menu or a "more" menu): enabled state, icon, the shortcut as
  /// the trailing text, and [onRun] after the action ran. Hidden actions are left out.
  List<DanaviewMenuEntry> menuEntries(
    EditorActionContext ctx,
    Iterable<EditorActionId> ids, {
    bool Function(EditorActionId id)? selected,
    bool Function(EditorActionId id)? destructive,
    VoidCallback? onRun,
  }) {
    final out = <DanaviewMenuEntry>[];
    for (final id in ids) {
      final s = spec(id);
      if (!s.isVisible(ctx)) continue;
      final enabled = s.isEnabled(ctx);
      final shortcut = s.primaryShortcut;
      out.add(DanaviewMenuItem(
        label: s.label,
        icon: s.icon,
        enabled: enabled,
        selected: selected?.call(id) ?? false,
        destructive: destructive?.call(id) ?? false,
        subtitle: enabled ? null : s.disabledReason(ctx),
        trailing: shortcut == null ? null : Text(shortcut, style: DanaviewTextStyles.caption.copyWith(fontFamily: DanaviewFonts.family)),
        onTap: () {
          invoke(id, ctx);
          onRun?.call();
        },
      ));
    }
    return out;
  }
}

/// The registry over the merged feature bindings (`editorActionBindingsProvider`) for the
/// platform the app runs on. Widgets read it through `EditorActionRegistry.of` so the registry
/// matches the theme's platform (⌘ on Apple, Ctrl elsewhere).
final editorActionRegistryProvider = Provider<EditorActionRegistry>(
  (ref) => EditorActionRegistry.forPlatform(defaultTargetPlatform, ref.watch(editorActionBindingsProvider)),
  name: 'editorActionRegistryProvider',
);

/// Reads the registry for the theme's platform.
extension EditorActionRegistryRef on WidgetRef {
  /// The registry for [platform] (the theme's platform in widgets).
  EditorActionRegistry actionRegistry(TargetPlatform platform) => read(editorActionRegistryProvider).forPlatformOf(platform);
}
