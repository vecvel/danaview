// OWNER: UX-37
//
// Placeholder (D-33) created by UX-01. UX-37 replaces this file:
// the Auto captions state machine (ux.md §12.1).
// Until then it declares only the public names other files compile against.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/model.dart' show ProjectId;

/// State of the Auto captions flow (ux.md §12.1).
@immutable
class AutoCaptionsState {
  /// Creates the placeholder state.
  const AutoCaptionsState();
}

/// The Auto captions state machine (ux.md §12.1).
class AutoCaptionsController extends StateNotifier<AutoCaptionsState> {
  /// Creates the placeholder controller.
  AutoCaptionsController([super.state = const AutoCaptionsState()]);
}

/// Builds the value of `autoCaptionsControllerProvider` for [id]. Implemented by UX-37; it may call
/// `ref.keepAlive()` and close the link when the editor has closed.
AutoCaptionsController createAutoCaptionsController(Ref<Object?> ref, ProjectId id) =>
    throw UnimplementedError('createAutoCaptionsController is implemented by UX-37');
