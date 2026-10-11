// OWNER: UX-18
//
// PreviewRegion (ARCH §17.5, ux.md §7.1, §7.7): the editor's preview area. Layers, bottom → top:
//
//   PreviewSurface (black → letterboxed canvas → Texture)   UX-18
//   TextOverlayLayer (text items and cues at the playhead)  UX-19
//   ManipulationOverlay (selection, handles, gestures)      UX-22
//   PreviewStatusOverlay (starting, failed, offline, degraded, pending jobs)
//
// All of them map through one `CanvasGeometry` (the canvas fitted in the region), so the texture,
// text and handles line up.
//
// * Touch preview controls: the manipulation overlay reports taps that hit no item; a single tap
//   toggles play/pause, a double tap seeks −1 s / +1 s on the left / right half (with an item under
//   the finger the tap selects it instead).
// * Fullscreen: the transport's `fullscreen` flag (F, the transport button, the registry action)
//   pushes `FullscreenPreview.route` and pops it when cleared; when the route completes (back,
//   close, Esc) the flag is reset. While it is up the editor surface unmounts its own `Texture`
//   (the same texture id shows in the route), and the back order's "exit fullscreen" step closes
//   it. Entering and leaving never touches the play state.
// * Wakelock while playing (`PlatformBridge.setSleepInhibited`, injectable through
//   [previewWakelockProvider]); released when playback stops or the region goes away.
// * Refresh after resume: the controller redraws the preview (`refresh`) and this region re-creates
//   the `Texture` widget. Surface loss (`PreviewSurfaceLost`) also refreshes the session and
//   re-creates the texture widget.
// * Rebuilds: the region rebuilds for the canvas, the background, the preview session and the
//   fullscreen flag only (never per playback frame; the semantics timecode is a small listener).

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_engine_api/vwish_editor_engine_api.dart' show PreviewEvent, PreviewSession, PreviewSurfaceLost;
import 'package:vwish_platform/vwish_platform.dart' show PlatformBridge;

import '../../app/editor_providers.dart';
import '../../debug/rebuild_counters.dart';
import '../editor_lifecycle.dart';
import '../editor_scope.dart';
import '../state/editor_state.dart';
import '../state/transport_controller.dart';
import 'canvas_geometry.dart';
import 'fullscreen_preview.dart';
import 'manipulation_overlay.dart';
import 'preview_status.dart';
import 'preview_surface.dart';
import 'text_overlay_layer.dart';

/// Holds or releases the screen wakelock (ux.md §7.7: awake while playing).
typedef PreviewWakelock = void Function(bool on);

/// The wakelock used while the preview plays (overridden in tests).
///
/// See ARCH §17.5.
final previewWakelockProvider = Provider<PreviewWakelock>(
  (ref) => (on) => unawaited(PlatformBridge.setSleepInhibited(on)),
  name: 'previewWakelockProvider',
);

/// The slice of EditorState the region depends on.
@immutable
final class _RegionView {
  const _RegionView({required this.ready, required this.canvas, required this.background, required this.previewPhase});

  static _RegionView of(EditorState s) {
    final p = s.project;
    final c = p?.settings.canvas;
    final bg = p?.settings.background;
    return _RegionView(
      ready: s.isReady && p != null,
      canvas: c == null ? null : (c.widthPx, c.heightPx),
      background: bg is SolidBackground ? Color(bg.color) : const Color(0xFF000000),
      previewPhase: s.preview.phase,
    );
  }

  final bool ready;
  final (int, int)? canvas;
  final Color background;
  final PreviewPhase previewPhase;

  @override
  bool operator ==(Object other) =>
      other is _RegionView && other.ready == ready && other.canvas == canvas && other.background == background && other.previewPhase == previewPhase;

  @override
  int get hashCode => Object.hash(ready, canvas, background, previewPhase);
}

/// Preview surface, status overlays and preview controls (ARCH §17.5).
class PreviewRegion extends ConsumerStatefulWidget {
  /// Creates the region for the project of the nearest `EditorScope`.
  const PreviewRegion({super.key});

  @override
  ConsumerState<PreviewRegion> createState() => PreviewRegionState();
}

/// State of [PreviewRegion] (public for tests).
class PreviewRegionState extends ConsumerState<PreviewRegion> with WidgetsBindingObserver {
  late ProjectId _id;
  TransportController? _transport;
  ValueListenable<bool>? _playing;
  VoidCallback? _unregisterExit;
  EditorBackDispatcher? _dispatcher;
  Route<void>? _route;
  bool _wakelock = false;
  PreviewWakelock? _setWakelock;
  int _generation = 0;
  PreviewSession? _boundPreview;
  StreamSubscription<PreviewEvent>? _events;

  /// Whether the fullscreen route is up.
  bool get fullscreenOpen => _route != null;

  /// Generation of the texture widget (bumped on surface loss and resume).
  int get textureGeneration => _generation;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _id = EditorScope.idOf(context);
    final transport = ref.read(transportProvider(_id));
    if (!identical(transport, _transport)) {
      _transport?.fullscreen.removeListener(_onFullscreen);
      _playing?.removeListener(_onPlaying);
      _transport = transport;
      transport.fullscreen.addListener(_onFullscreen);
      _playing = transport.playing;
      transport.playing.addListener(_onPlaying);
      _setWakelock = ref.read(previewWakelockProvider);
      _onPlaying();
    }
    final d = EditorBackDispatcher.maybeOf(context);
    if (!identical(d, _dispatcher)) {
      _unregisterExit?.call();
      _dispatcher = d;
      _unregisterExit = d?.register(EditorBackStep.exitFullscreen, _exitForBack);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _transport?.fullscreen.removeListener(_onFullscreen);
    _playing?.removeListener(_onPlaying);
    _unregisterExit?.call();
    unawaited(_events?.cancel());
    if (_wakelock) _setWakelock?.call(false);
    _wakelock = false;
    final route = _route;
    _route = null;
    if (route != null && route.isActive) route.navigator?.removeRoute(route);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) setState(() => _generation++);
  }

  // ---- Wakelock ---------------------------------------------------------------------------------

  void _onPlaying() {
    final on = _playing?.value ?? false;
    if (on == _wakelock) return;
    _wakelock = on;
    _setWakelock?.call(on);
  }

  // ---- Fullscreen -------------------------------------------------------------------------------

  void _onFullscreen() {
    final want = _transport?.fullscreen.value ?? false;
    if (want && _route == null) {
      _push();
    } else if (!want && _route != null) {
      final route = _route!;
      if (route.isActive) route.navigator?.removeRoute(route);
      _route = null;
      if (mounted) setState(() {});
    }
  }

  void _push() {
    if (!mounted) return;
    final nav = Navigator.maybeOf(context);
    if (nav == null) {
      _transport?.setFullscreen(false);
      return;
    }
    final route = FullscreenPreview.route(container: ProviderScope.containerOf(context, listen: false), projectId: _id);
    _route = route;
    setState(() {});
    unawaited(nav.push(route).then((_) {
      if (!identical(_route, route)) return;
      _route = null;
      _transport?.setFullscreen(false);
      if (mounted) setState(() {});
    }));
  }

  bool _exitForBack() {
    final route = _route;
    if (route == null) return false;
    if (route.isActive) route.navigator?.removeRoute(route);
    _route = null;
    _transport?.setFullscreen(false);
    if (mounted) setState(() {});
    return true;
  }

  // ---- Preview events ---------------------------------------------------------------------------

  void _bind(PreviewSession? preview) {
    if (identical(preview, _boundPreview)) return;
    unawaited(_events?.cancel());
    _events = null;
    _boundPreview = preview;
    if (preview == null) return;
    _events = preview.events.listen(_onPreviewEvent, onError: (Object _) {});
  }

  void _onPreviewEvent(PreviewEvent event) {
    if (event is! PreviewSurfaceLost) return;
    final preview = _boundPreview;
    if (preview != null) unawaited(_quietly(preview.refresh));
    if (mounted) setState(() => _generation++);
  }

  static Future<void> _quietly(Future<void> Function() body) async {
    try {
      await body();
    } catch (_) {}
  }

  // ---- Touch preview controls ------------------------------------------------------------------

  void _togglePlay() {
    final t = _transport;
    if (t == null || !t.canPlay) return;
    unawaited(t.togglePlay());
  }

  void _seekBy(int direction) {
    final t = _transport;
    if (t == null || !t.canSeek) return;
    unawaited(t.stepSeconds(direction));
  }

  @override
  Widget build(BuildContext context) {
    EditorRebuildCounters.count('PreviewRegion');
    final id = EditorScope.idOf(context);
    final view = ref.watch(editorControllerProvider(id).select(_RegionView.of));
    final session = ref.watch(editorSessionProvider(id));
    final preview = session.preview;
    _bind(preview);
    final canvas = view.canvas;
    final fullscreen = _route != null;
    return LayoutBuilder(
      builder: (context, constraints) {
        final geometry = CanvasGeometry.letterbox(
          canvas == null ? Size.zero : Size(canvas.$1.toDouble(), canvas.$2.toDouble()),
          constraints.biggest,
        );
        final stack = Stack(
          fit: StackFit.expand,
          children: [
            PreviewSurface(
              geometry: geometry,
              textureId: preview?.textureId,
              background: view.background,
              showTexture: !fullscreen,
              generation: _generation,
            ),
            if (view.ready && !fullscreen) ...[
              TextOverlayLayer(geometry: geometry),
              ManipulationOverlay(geometry: geometry, onEmptyTap: _togglePlay, onEmptyDoubleTap: _seekBy),
              const PreviewStatusOverlay(),
            ],
          ],
        );
        if (canvas == null) return stack;
        return _PreviewSemantics(projectId: id, width: canvas.$1, height: canvas.$2, child: stack);
      },
    );
  }
}

/// "Preview, 1080 by 1920, 00:01:12" (ux.md §7.1); only this wrapper follows the playhead.
class _PreviewSemantics extends ConsumerWidget {
  const _PreviewSemantics({required this.projectId, required this.width, required this.height, required this.child});

  final ProjectId projectId;
  final int width;
  final int height;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playhead = ref.watch(playheadProvider(projectId));
    return ValueListenableBuilder<TimeUs>(
      valueListenable: playhead,
      builder: (context, t, child) => Semantics(
        label: PreviewStrings.preview(width, height, Timecode.format(t, playhead.frameRate)),
        image: true,
        child: child,
      ),
      child: child,
    );
  }
}
