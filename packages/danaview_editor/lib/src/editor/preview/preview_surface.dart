// OWNER: UX-18
//
// PreviewSurface (ARCH §17.5, ux.md §7.1): black → the letterboxed canvas rect → the native
// preview `Texture(textureId, filterQuality: low)`. Native renders at the quality-dependent frame
// size and Flutter scales the texture into the canvas rect; the rect comes from the preview's
// `CanvasGeometry`, so the text overlay (UX-19) and the handles (UX-22) line up with the texture
// exactly. The canvas rect is filled with the project's background colour (a blurred background
// shows black until the first frame); the letterbox outside it is pure black so the canvas edge
// is visible.
//
// * [previewTextureBuilderProvider] builds the texture widget: `Texture` in the app, the engine
//   API's `FakeTexturePlaceholder` in widget tests (the real `Texture` paints nothing there).
// * The same texture id backs the editor surface and the fullscreen preview, but only one of them
//   mounts its `Texture` at a time (the editor hides its own while fullscreen is up), so the
//   preview never depends on one id backing two live widgets (V-U2's fallback by design).
// * V-U2 result (2026-10-11, iOS 26.5 simulator, iPhone 17 Pro, Flutter 3.44.2, Impeller): one
//   `FlutterTexture` id backs several `Texture` widgets. Probe (a throwaway copy of the IOS-01
//   texture host; screenshots sampled per step): two widgets with the same id both show each new
//   frame after a single `textureFrameAvailable`; unmounting one leaves the other live; a remounted
//   widget shows the last frame without a new one; an opaque pushed route with a second `Texture`
//   (the fullscreen flow) and a translucent route over both editor widgets (three at once) all
//   show the frame. `copyPixelBuffer` runs once per available frame however many widgets show it,
//   so a second widget costs no extra native copy. Android emulator: not run on this machine
//   (Android lane); the one-texture-at-a-time design above does not depend on it.
// * [PreviewSurface.generation] re-creates the `Texture` element: the region bumps it after a
//   surface loss and on resume so the platform view re-binds the (re-created) surface.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'canvas_geometry.dart';

/// Builds the widget that shows texture [textureId].
typedef PreviewTextureBuilder = Widget Function(BuildContext context, int textureId);

/// How the preview texture is shown (overridden in widget tests).
///
/// See ARCH §17.5.
final previewTextureBuilderProvider = Provider<PreviewTextureBuilder>(
  (ref) => (context, id) => Texture(textureId: id, filterQuality: FilterQuality.low),
  name: 'previewTextureBuilderProvider',
);

/// Black -> letterboxed canvas -> Texture (ARCH §17.5).
class PreviewSurface extends ConsumerWidget {
  /// Creates the surface of [textureId] (null: no live preview) mapped by [geometry].
  const PreviewSurface({
    super.key,
    required this.geometry,
    required this.textureId,
    this.background = const Color(0xFF000000),
    this.showTexture = true,
    this.generation = 0,
  });

  /// Letterbox mapping.
  final CanvasGeometry geometry;

  /// The preview session's texture, or null.
  final int? textureId;

  /// Canvas background (the project's solid background colour).
  final Color background;

  /// Whether the texture is mounted (false while the fullscreen preview shows it).
  final bool showTexture;

  /// Bumped to re-create the texture widget (surface loss, resume).
  final int generation;

  /// Letterbox colour.
  static const Color letterbox = Color(0xFF000000);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = textureId;
    final rect = geometry.viewRect;
    return ColoredBox(
      color: letterbox,
      child: geometry.isEmpty
          ? const SizedBox.expand()
          : Stack(
              fit: StackFit.expand,
              children: [
                Positioned.fromRect(
                  rect: rect,
                  child: ColoredBox(
                    color: background,
                    child: id != null && showTexture
                        ? KeyedSubtree(
                            key: ValueKey<(int, int)>((id, generation)),
                            child: ref.watch(previewTextureBuilderProvider)(context, id),
                          )
                        : const SizedBox.expand(),
                  ),
                ),
              ],
            ),
    );
  }
}
