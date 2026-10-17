// OWNER: UX-18
//
// Fullscreen preview (ARCH §17.5, ux.md §7.7): a pushed page route with a fade transition that
// shows the editor's live preview texture (same texture id; the editor surface unmounts its own
// `Texture` while this route is up), the same text overlay (UX-19) and the same status overlays.
//
// * Controls: play/pause, the kit's `DanaviewSeekBar` (markers as chapters), the time, close, rotate
//   on phones (`ScreenOrientationPolicy.toggle`) and the quality menu. Tap toggles the controls;
//   they hide after 3 s while playing, like the player overlay. Double-tap on the left or right half
//   seeks −1 s / +1 s.
// * `SystemUiMode.immersiveSticky` while shown; edge-to-edge again on close. The route follows how
//   the device is held (`OrientationMode.followDevice`) while it is the top orientation owner.
// * Entering and leaving keeps the playback state: the route never pauses or seeks; it only reads
//   the playhead and transport.
// * Back (Android back, Esc, the close button) pops the route; the preview region resets the
//   transport's `fullscreen` flag when the route completes (UX-14's `F` shortcut and button toggle
//   that flag, and the region pushes/pops the route to match).
// * The route carries the editor's ProviderContainer (`UncontrolledProviderScope`) and EditorScope,
//   so it works from any navigator.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_domain/danaview_domain.dart' show Chapter;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' show PreviewQuality;
import 'package:danaview_features/orientation.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../app/editor_providers.dart';
import '../editor_scope.dart';
import '../state/editor_state.dart';
import '../transport/timecode_text.dart';
import '../transport/transport_strings.dart';
import 'canvas_geometry.dart';
import 'preview_status.dart';
import 'preview_surface.dart';
import 'text_overlay_layer.dart';

/// Fullscreen route reusing the texture (ARCH §17.5).
class FullscreenPreview extends ConsumerStatefulWidget {
  /// Creates the fullscreen preview of [projectId].
  const FullscreenPreview(
      {super.key, required this.projectId, this.controlsHideDelay = const Duration(seconds: 3), this.doubleTapWindow = kDoubleTapTimeout});

  /// The project.
  final ProjectId projectId;

  /// How long controls stay up while playing.
  final Duration controlsHideDelay;

  /// Double-tap window.
  final Duration doubleTapWindow;

  /// Route name (tests and analytics-free logging).
  static const String routeName = 'editor/fullscreen-preview';

  /// Fade duration.
  static const Duration transition = Duration(milliseconds: 200);

  /// The page route of the fullscreen preview of [projectId], reading providers from [container].
  static Route<void> route({required ProviderContainer container, required ProjectId projectId}) => PageRouteBuilder<void>(
        settings: const RouteSettings(name: routeName),
        opaque: true,
        transitionDuration: transition,
        reverseTransitionDuration: transition,
        pageBuilder: (context, animation, secondary) => UncontrolledProviderScope(
          container: container,
          child: EditorScope(projectId: projectId, child: FullscreenPreview(projectId: projectId)),
        ),
        transitionsBuilder: (context, animation, secondary, child) => FadeTransition(opacity: animation, child: child),
      );

  @override
  ConsumerState<FullscreenPreview> createState() => FullscreenPreviewState();
}

/// State of [FullscreenPreview] (public for tests).
class FullscreenPreviewState extends ConsumerState<FullscreenPreview> {
  bool _controls = true;
  Timer? _hideTimer;
  Timer? _tapTimer;
  Offset? _pendingTap;
  ValueListenable<bool>? _playing;

  /// Whether the controls are shown.
  bool get controlsVisible => _controls;

  @override
  void initState() {
    super.initState();
    unawaited(_quietly(() => SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky)));
    unawaited(_quietly(() => ScreenOrientationPolicy.enter(this, OrientationMode.followDevice)));
    final playing = ref.read(playheadProvider(widget.projectId)).playing;
    _playing = playing;
    playing.addListener(_onPlaying);
    _onPlaying();
  }

  @override
  void dispose() {
    _playing?.removeListener(_onPlaying);
    _hideTimer?.cancel();
    _tapTimer?.cancel();
    unawaited(_quietly(() => SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge)));
    unawaited(_quietly(() => ScreenOrientationPolicy.release(this)));
    super.dispose();
  }

  static Future<void> _quietly(Future<void> Function() body) async {
    try {
      await body();
    } catch (_) {}
  }

  void _onPlaying() {
    _hideTimer?.cancel();
    _hideTimer = null;
    if (_playing?.value ?? false) {
      if (_controls) _hideTimer = Timer(widget.controlsHideDelay, _hide);
    } else if (!_controls && mounted) {
      setState(() => _controls = true);
    }
  }

  void _hide() {
    _hideTimer = null;
    if (mounted && (_playing?.value ?? false)) setState(() => _controls = false);
  }

  void _toggleControls() {
    setState(() => _controls = !_controls);
    _hideTimer?.cancel();
    _hideTimer = null;
    if (_controls && (_playing?.value ?? false)) _hideTimer = Timer(widget.controlsHideDelay, _hide);
  }

  /// Keeps the controls up for another hide delay (any control use).
  void _poke() {
    _hideTimer?.cancel();
    _hideTimer = null;
    if (_playing?.value ?? false) _hideTimer = Timer(widget.controlsHideDelay, _hide);
  }

  void _onTapUp(TapUpDetails d) {
    final p = d.localPosition;
    if (_pendingTap != null) {
      _tapTimer?.cancel();
      _tapTimer = null;
      _pendingTap = null;
      final width = context.size?.width ?? 0;
      unawaited(ref.read(transportProvider(widget.projectId)).stepSeconds(p.dx < width / 2 ? -1 : 1));
      return;
    }
    _pendingTap = p;
    _tapTimer = Timer(widget.doubleTapWindow, () {
      _tapTimer = null;
      _pendingTap = null;
      if (mounted) _toggleControls();
    });
  }

  void _close() {
    final nav = Navigator.of(context);
    if (nav.canPop()) nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.projectId;
    final view = ref.watch(editorControllerProvider(id).select(_FullscreenView.of));
    final session = ref.watch(editorSessionProvider(id));
    final textureId = session.preview?.textureId;
    final canvas = view.canvas;
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
        SingleActivator(LogicalKeyboardKey.keyF): DismissIntent(),
        SingleActivator(LogicalKeyboardKey.space): _TogglePlayIntent(),
        SingleActivator(LogicalKeyboardKey.keyK): _TogglePlayIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          DismissIntent: CallbackAction<DismissIntent>(onInvoke: (_) {
            _close();
            return null;
          }),
          _TogglePlayIntent: CallbackAction<_TogglePlayIntent>(onInvoke: (_) {
            unawaited(ref.read(transportProvider(id)).togglePlay());
            return null;
          }),
        },
        child: Focus(
          autofocus: true,
          child: DefaultTextStyle(
            style: previewChromeTextStyle,
            child: ColoredBox(
              color: PreviewSurface.letterbox,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final geometry = CanvasGeometry.letterbox(canvas ?? Size.zero, constraints.biggest);
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      PreviewSurface(geometry: geometry, textureId: textureId, background: view.background),
                      TextOverlayLayer(geometry: geometry, projectId: id),
                      GestureDetector(behavior: HitTestBehavior.opaque, onTapUp: _onTapUp),
                      PreviewStatusOverlay(projectId: id),
                      _Controls(
                        projectId: id,
                        visible: _controls,
                        view: view,
                        onClose: _close,
                        onUse: _poke,
                        orientationOwner: this,
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TogglePlayIntent extends Intent {
  const _TogglePlayIntent();
}

/// The slice of EditorState the fullscreen preview depends on.
@immutable
final class _FullscreenView {
  const _FullscreenView({
    required this.canvas,
    required this.background,
    required this.duration,
    required this.frameRate,
    required this.markers,
    required this.preview,
    required this.ready,
  });

  static _FullscreenView of(EditorState s) {
    final p = s.project;
    final c = p?.settings.canvas;
    final bg = p?.settings.background;
    return _FullscreenView(
      canvas: c == null ? null : Size(c.widthPx.toDouble(), c.heightPx.toDouble()),
      background: bg is SolidBackground ? Color(bg.color) : const Color(0xFF000000),
      duration: p?.duration ?? 0,
      frameRate: p?.settings.frameRate ?? FrameRate.fps30,
      markers: p?.markers ?? const [],
      preview: s.preview,
      ready: s.isReady,
    );
  }

  final Size? canvas;
  final Color background;
  final TimeUs duration;
  final FrameRate frameRate;
  final List<Marker> markers;
  final PreviewStatus preview;
  final bool ready;

  @override
  bool operator ==(Object other) =>
      other is _FullscreenView &&
      other.canvas == canvas &&
      other.background == background &&
      other.duration == duration &&
      other.frameRate == frameRate &&
      identical(other.markers, markers) &&
      other.preview == preview &&
      other.ready == ready;

  @override
  int get hashCode => Object.hash(canvas, background, duration, frameRate, identityHashCode(markers), preview, ready);
}

class _Controls extends ConsumerWidget {
  const _Controls({
    required this.projectId,
    required this.visible,
    required this.view,
    required this.onClose,
    required this.onUse,
    required this.orientationOwner,
  });

  final ProjectId projectId;
  final bool visible;
  final _FullscreenView view;
  final VoidCallback onClose;
  final VoidCallback onUse;
  final Object orientationOwner;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final transport = ref.watch(transportProvider(projectId));
    final playhead = ref.watch(playheadProvider(projectId));
    final editor = ref.read(editorControllerProvider(projectId).notifier);
    final size = MediaQuery.sizeOf(context);
    final phone = context.isTouchPlatform && size.shortestSide < 600;
    final compact = size.width < 420;
    final chapters = [
      for (var i = 0; i < view.markers.length; i++) Chapter(id: i, title: view.markers[i].name, start: Duration(microseconds: view.markers[i].time)),
    ];
    final duration = Duration(microseconds: view.duration);

    final top = Row(
      children: [
        DanaviewIconButton(
          icon: Icons.fullscreen_exit_rounded,
          tooltip: PreviewStrings.exitFullscreen,
          variant: DanaviewIconButtonVariant.tonal,
          onPressed: onClose,
        ),
        const Spacer(),
        if (phone)
          DanaviewIconButton(
            icon: Icons.screen_rotation_rounded,
            tooltip: PreviewStrings.rotate,
            variant: DanaviewIconButtonVariant.tonal,
            onPressed: () {
              onUse();
              unawaited(ScreenOrientationPolicy.toggle(orientationOwner, MediaQuery.orientationOf(context)));
            },
          ),
        const SizedBox(width: DanaviewSpacing.sm),
        DanaviewMenuIconTrigger(
          icon: Icons.hd_rounded,
          tooltip: TransportStrings.quality,
          semanticLabel: TransportStrings.quality,
          variant: DanaviewIconButtonVariant.tonal,
          selected: view.preview.quality != PreviewQuality.auto,
          enabled: view.ready,
          menuWidth: 280,
          entries: previewQualityEntries(editor, view.preview, enabled: view.ready),
        ),
      ],
    );

    final bottom = DanaviewSurface(
      color: DanaviewColors.overlayDark,
      shadow: DanaviewShadow.soft,
      padding: const EdgeInsets.fromLTRB(DanaviewSpacing.sm, DanaviewSpacing.xs, DanaviewSpacing.md, DanaviewSpacing.xs),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ValueListenableBuilder<TimeUs>(
            valueListenable: playhead,
            builder: (context, t, _) => DanaviewSeekBar(
              position: Duration(microseconds: t),
              duration: duration,
              buffer: duration,
              chapters: chapters,
              onSeeking: (d) {
                onUse();
                playhead.scrubTo(d.inMicroseconds);
              },
              onSeek: (d) {
                onUse();
                if (playhead.isScrubbing) {
                  playhead.scrubTo(d.inMicroseconds);
                  unawaited(playhead.endScrub());
                } else {
                  unawaited(transport.seekTo(d.inMicroseconds));
                }
              },
            ),
          ),
          Row(
            children: [
              ValueListenableBuilder<bool>(
                valueListenable: transport.playing,
                builder: (context, playing, _) => DanaviewIconButton(
                  icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  tooltip: playing ? PreviewStrings.pause : PreviewStrings.play,
                  iconSize: 28,
                  onPressed: transport.canPlay
                      ? () {
                          onUse();
                          unawaited(transport.togglePlay());
                        }
                      : null,
                ),
              ),
              const SizedBox(width: DanaviewSpacing.xs),
              Flexible(
                child: TimecodeText(playhead: playhead, duration: view.duration, frameRate: view.frameRate, compact: compact),
              ),
            ],
          ),
        ],
      ),
    );

    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: DanaviewMotion.fast,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(DanaviewSpacing.md),
            child: Column(
              children: [
                top,
                const Spacer(),
                bottom,
              ],
            ),
          ),
        ),
      ),
    );
  }
}
