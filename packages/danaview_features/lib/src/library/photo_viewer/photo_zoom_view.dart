// OWNER: HOM-11
//
// One page of the fullscreen photo viewer (ARCH v1.2 V2-106, V2-28; BUILD_PLAN HOM-11): the photo
// fitted to the screen with pinch-to-zoom (also a trackpad pinch), double-tap to zoom in at the
// tapped point and double-tap again to fit, and panning while zoomed. It draws the thumbnail
// cache's large class (`l`, the native thumbnailer: PhotoKit / ImageIO / MediaStore, so HEIC and
// RAW display wherever the platform reads them) and, once zoomed, a full-resolution layer decoded
// from the file itself (read-only, capped at [photoViewerFullResolutionCap] px so a 48 MP photo
// never decodes at full size) for formats the engine decodes; a decode failure leaves the large
// thumbnail in place. The page reports whether it is zoomed so the viewer stops page swipes while
// the user pans a zoomed photo.

import 'dart:io' show File;
import 'dart:math' as math;

import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';

import '../thumbs/library_thumbnail.dart';
import '../thumbs/thumb_key.dart';
import 'photo_viewer_entry.dart';

/// Longest side, in pixels, of the full-resolution layer.
const int photoViewerFullResolutionCap = 4096;

/// The largest zoom.
const double photoViewerMaxScale = 8;

/// The zoom a double tap goes to.
const double photoViewerDoubleTapScale = 2.5;

/// One zoomable photo.
class PhotoZoomView extends StatefulWidget {
  /// A page for [entry]. [onZoomChanged] reports when the photo leaves or returns to fit; [onTap]
  /// is a single tap (the viewer toggles its chrome).
  const PhotoZoomView({
    super.key,
    required this.entry,
    this.onZoomChanged,
    this.onTap,
    this.fullResolution = true,
  });

  /// The photo.
  final PhotoViewerEntry entry;

  /// Called with true when zoomed in, false when back at fit.
  final ValueChanged<bool>? onZoomChanged;

  /// A single tap.
  final VoidCallback? onTap;

  /// Whether the full-resolution layer may load once zoomed.
  final bool fullResolution;

  @override
  State<PhotoZoomView> createState() => PhotoZoomViewState();
}

/// The state of a [PhotoZoomView] (public so the viewer and tests can read and reset the zoom).
class PhotoZoomViewState extends State<PhotoZoomView> with SingleTickerProviderStateMixin {
  final TransformationController _transform = TransformationController();
  late final AnimationController _animation;
  Animation<Matrix4>? _tween;
  Offset? _doubleTapAt;
  bool _zoomed = false;
  bool _wantFull = false;

  /// The current zoom (1 at fit).
  double get scale => _transform.value.getMaxScaleOnAxis();

  /// Whether the photo is zoomed in.
  bool get isZoomed => _zoomed;

  /// The transformation (tests).
  TransformationController get transformation => _transform;

  @override
  void initState() {
    super.initState();
    _animation = AnimationController(vsync: this, duration: DanaviewMotion.normal)
      ..addListener(() {
        final t = _tween;
        if (t != null) _transform.value = t.value;
      });
    _transform.addListener(_onTransform);
  }

  @override
  void dispose() {
    _transform.removeListener(_onTransform);
    _transform.dispose();
    _animation.dispose();
    super.dispose();
  }

  void _onTransform() {
    final zoomed = scale > 1.01;
    if (zoomed == _zoomed) return;
    setState(() {
      _zoomed = zoomed;
      if (zoomed) _wantFull = true;
    });
    widget.onZoomChanged?.call(zoomed);
  }

  void _animateTo(Matrix4 target) {
    _animation.stop();
    if (!mounted) return;
    final disable = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (disable) {
      _transform.value = target;
      return;
    }
    _tween = Matrix4Tween(begin: _transform.value.clone(), end: target)
        .animate(CurvedAnimation(parent: _animation, curve: DanaviewMotion.curve));
    _animation.forward(from: 0);
  }

  /// Back to fit.
  void reset() => _animateTo(Matrix4.identity());

  /// Zooms to [targetScale] keeping [focal] (in the view's coordinates) under the finger.
  void zoomTo(double targetScale, Offset focal) {
    final s = targetScale.clamp(1.0, photoViewerMaxScale);
    final x = -focal.dx * (s - 1);
    final y = -focal.dy * (s - 1);
    _animateTo(Matrix4.identity()
      ..translateByDouble(x, y, 0, 1)
      ..scaleByDouble(s, s, 1, 1));
  }

  /// A double tap: zoom in at the last double-tap point, or back to fit.
  void toggleZoom([Offset? at]) {
    if (_zoomed) {
      reset();
      return;
    }
    final box = context.findRenderObject() as RenderBox?;
    final centre = box == null ? Offset.zero : box.size.center(Offset.zero);
    zoomTo(photoViewerDoubleTapScale, at ?? _doubleTapAt ?? centre);
  }

  @override
  void didUpdateWidget(PhotoZoomView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.id != widget.entry.id) {
      _transform.value = Matrix4.identity();
      _wantFull = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.entry.item;
    final platform = Theme.of(context).platform;
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    final full = widget.fullResolution && _wantFull && widget.entry.canDecodeFullResolution(platform);
    final base = LibraryThumbnail(
      key: ValueKey('photo-viewer-image-${item.id.value}'),
      itemId: item.id.value,
      source: item.thumbSource,
      modifiedAt: item.modifiedAt,
      sizeClass: ThumbSizeClass.l,
      fit: BoxFit.contain,
      placeholder: const Icon(Icons.image_outlined, color: DanaviewColors.textMuted, size: 40),
    );
    return LayoutBuilder(builder: (context, constraints) {
      Widget? fullLayer;
      if (full) {
        final longest = math.max(item.width, item.height);
        final screen = (math.max(constraints.maxWidth, constraints.maxHeight) * dpr * photoViewerDoubleTapScale).ceil();
        final cap = math.min(photoViewerFullResolutionCap, math.max(screen, 1));
        final resize = longest <= 0 || longest > cap;
        final ImageProvider provider = FileImage(File(widget.entry.filePath!));
        final ImageProvider image = resize
            ? ResizeImage(provider,
                width: item.width >= item.height ? cap : null,
                height: item.width >= item.height ? null : cap,
                policy: ResizeImagePolicy.fit)
            : provider;
        fullLayer = Image(
          key: const ValueKey('photo-viewer-full'),
          image: image,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          filterQuality: FilterQuality.medium,
          excludeFromSemantics: true,
          // A file the engine can't decode keeps the large thumbnail underneath.
          errorBuilder: (context, error, stack) => const SizedBox.shrink(),
          frameBuilder: (context, child, frame, sync) => frame == null && !sync ? const SizedBox.shrink() : child,
        );
      }
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onDoubleTapDown: (d) => _doubleTapAt = d.localPosition,
        onDoubleTap: toggleZoom,
        child: InteractiveViewer(
          transformationController: _transform,
          minScale: 1,
          maxScale: photoViewerMaxScale,
          panEnabled: _zoomed,
          clipBehavior: Clip.none,
          child: SizedBox(
            width: constraints.maxWidth,
            height: constraints.maxHeight,
            child: Stack(fit: StackFit.expand, children: [
              base,
              if (fullLayer != null) fullLayer,
            ]),
          ),
        ),
      );
    });
  }
}
