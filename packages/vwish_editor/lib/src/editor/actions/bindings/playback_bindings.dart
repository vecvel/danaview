// OWNER: UX-14
//
// The playback action bindings (merged by wiring/action_bindings.dart, ARCH §17.6): playPause,
// prevFrame, nextFrame, back1s, forward1s, prevEdit, nextEdit, goStart, goEnd and
// fullscreenPreview. Labels, icons and shortcuts come from the registry (UX-15); every handler
// goes through the project's `TransportController`.

import '../../../app/editor_providers.dart';
import '../../contracts/contracts.dart';
import '../../state/transport_controller.dart';
import '../../transport/transport_strings.dart';

TransportController _transport(EditorActionContext ctx) => ctx.read(transportProvider(ctx.projectId));

bool _canSeek(EditorActionContext ctx) => _transport(ctx).canSeek;

String? _seekReason(EditorActionContext ctx) => TransportStrings.notOpen;

EditorActionBinding _seek(EditorActionId id, void Function(TransportController t) run) =>
    EditorActionBinding(id: id, handler: (ctx) => run(_transport(ctx)), isEnabled: _canSeek, disabledReason: _seekReason);

/// The playback actions bound by UX-14 (ARCH §17.6). The same instances on every read, so two
/// merges of the bindings compare equal (the wiring test relies on it).
List<EditorActionBinding> get playbackBindings => _playback;

final List<EditorActionBinding> _playback = List.unmodifiable(<EditorActionBinding>[
      EditorActionBinding(
        id: EditorActionId.playPause,
        handler: (ctx) => _transport(ctx).togglePlay(),
        isEnabled: (ctx) => _transport(ctx).canPlay,
        disabledReason: (ctx) {
          final t = _transport(ctx);
          if (!t.canSeek) return TransportStrings.notOpen;
          return t.playhead.preview == null ? TransportStrings.noPreview : TransportStrings.emptyProject;
        },
      ),
      _seek(EditorActionId.prevFrame, (t) => t.stepFrames(-1)),
      _seek(EditorActionId.nextFrame, (t) => t.stepFrames(1)),
      _seek(EditorActionId.back1s, (t) => t.stepSeconds(-1)),
      _seek(EditorActionId.forward1s, (t) => t.stepSeconds(1)),
      _seek(EditorActionId.prevEdit, (t) => t.previousEditPoint()),
      _seek(EditorActionId.nextEdit, (t) => t.nextEditPoint()),
      _seek(EditorActionId.goStart, (t) => t.goStart()),
      _seek(EditorActionId.goEnd, (t) => t.goEnd()),
      EditorActionBinding(
        id: EditorActionId.fullscreenPreview,
        handler: (ctx) => _transport(ctx).toggleFullscreen(),
        isEnabled: (ctx) => _transport(ctx).playhead.preview != null,
        disabledReason: (ctx) => TransportStrings.noPreview,
      ),
    ]);
