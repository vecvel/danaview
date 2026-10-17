// OWNER: UX-07
//
// A scriptable EditorShellDelegate for the shell tests: status set by the test, a call log,
// per-step dismiss results and a controllable close flush.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/editor_screen.dart';
import 'package:danaview_editor/src/editor/layout/editor_layout.dart';
import 'package:danaview_editor/src/editor/layout/editor_layout_scope.dart';
import 'package:danaview_editor_core/model.dart' show TimeUs;

/// A fake open editor.
class FakeEditorShell implements EditorShellDelegate {
  /// Creates the fake in [status] (default: ready, "Goa trip", saved).
  FakeEditorShell({EditorShellStatus status = const EditorShellStatus(phase: EditorShellPhase.ready, projectName: 'Goa trip')})
      : status = ValueNotifier<EditorShellStatus>(status);

  /// The status the shell shows; tests assign `status.value`.
  final ValueNotifier<EditorShellStatus> status;

  /// Every call, in order (`open`, `dismiss:<step>`, `flush`, `close`, `undo`, `redo`,
  /// `save:<manual>`, `inactive`, `hidden`, `resumed`, `memory`).
  final List<String> calls = <String>[];

  /// Steps that dismiss something when asked (each is removed once dismissed).
  final Set<EditorBackStep> dismissible = <EditorBackStep>{};

  /// The steps this fake dismissed, in order.
  final List<EditorBackStep> dismissed = <EditorBackStep>[];

  /// The initial playhead passed to [open].
  TimeUs? openedAt;

  /// Result of [flushBeforeClose]; null makes it wait on [flushCompleter].
  bool? flushResult = true;

  /// Completes a pending flush when [flushResult] is null.
  Completer<bool> flushCompleter = Completer<bool>();

  /// Result of [undo] and [redo].
  bool historyResult = true;

  @override
  ValueListenable<EditorShellStatus> get shellStatus => status;

  /// The calls named [name] (prefix match for `dismiss:` and `save:`).
  int count(String name) => calls.where((c) => c == name || c.startsWith('$name:')).length;

  @override
  Future<void> open({TimeUs? initialPlayhead}) async {
    openedAt = initialPlayhead;
    calls.add('open');
  }

  @override
  bool dismissForBack(EditorBackStep step) {
    calls.add('dismiss:${step.name}');
    final done = dismissible.remove(step);
    if (done) dismissed.add(step);
    return done;
  }

  @override
  Future<bool> flushBeforeClose() {
    calls.add('flush');
    final result = flushResult;
    return result == null ? flushCompleter.future : Future<bool>.value(result);
  }

  @override
  Future<void> close() async => calls.add('close');

  @override
  bool undo() {
    calls.add('undo');
    return historyResult;
  }

  @override
  bool redo() {
    calls.add('redo');
    return historyResult;
  }

  @override
  Future<void> saveNow({bool manual = false}) async => calls.add('save:$manual');

  @override
  void onAppInactive() => calls.add('inactive');

  @override
  void onAppHidden() => calls.add('hidden');

  @override
  void onAppResumed() => calls.add('resumed');

  @override
  void onMemoryPressure() => calls.add('memory');
}

/// Overrides `editorShellProvider` so every project id resolves to [shell].
Override overrideShell(FakeEditorShell shell) => editorShellProvider.overrideWith((ref, id) => shell);

/// The layout the pumped editor resolved.
EditorLayoutSpec specOf(WidgetTester tester) => tester.widget<EditorLayoutScope>(find.byType(EditorLayoutScope)).spec;
