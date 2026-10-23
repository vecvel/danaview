// OWNER: HOM-04
//
// A thumbnail cell image for the Files & Media Home (ARCH v1.2 V2-28, §1.4): picks the size class
// from its laid-out size and the device pixel ratio, paints from the memory tier in its first
// frame when it can, otherwise loads through the thumbnail service and paints when ready.
// Leaving the tree (a grid cell scrolled out of the viewport) cancels the request, so a fling
// never queues work for cells that are gone. Until a thumbnail exists — or when there is none
// (no service with the flag off, unsupported type, corrupt file) — it shows the dark kit surface
// with the caller's [placeholder] (a type icon). It fills whatever box its parent gives it, so it
// never overflows; it is decorative unless given a [semanticLabel].

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import 'thumb_key.dart';
import 'thumb_memory_cache.dart';
import 'thumbnail_providers.dart';
import 'thumbnail_service.dart';

/// The thumbnail of one library item.
class LibraryThumbnail extends ConsumerStatefulWidget {
  /// The thumbnail of [itemId] whose bytes are at [source], modified at [modifiedAt].
  const LibraryThumbnail({
    super.key,
    required this.itemId,
    required this.source,
    required this.modifiedAt,
    this.kind = ThumbSourceKind.media,
    this.sizeClass,
    this.fit = BoxFit.cover,
    this.placeholder,
    this.semanticLabel,
  });

  /// The library item id (V2-09).
  final String itemId;

  /// `ph:`/`ms:` id, absolute path or `content://` URI.
  final String source;

  /// The item's modification time (a newer one shows a new thumbnail).
  final DateTime modifiedAt;

  /// Media or document.
  final ThumbSourceKind kind;

  /// A fixed size class; null picks one from the laid-out size.
  final ThumbSizeClass? sizeClass;

  /// How the image fills the box.
  final BoxFit fit;

  /// Shown, centred on the kit surface, until (or instead of) the thumbnail.
  final Widget? placeholder;

  /// Accessibility label; null keeps the image out of the semantics tree (the cell labels itself).
  final String? semanticLabel;

  @override
  ConsumerState<LibraryThumbnail> createState() => _LibraryThumbnailState();
}

class _LibraryThumbnailState extends ConsumerState<LibraryThumbnail> {
  ThumbRequest? _request;
  ThumbnailService? _service;
  ThumbHandle? _handle;
  ThumbBitmap? _bitmap;

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  void _release() {
    _handle?.cancel();
    _handle = null;
    _bitmap?.dispose();
    _bitmap = null;
  }

  void _ensure(ThumbnailService? service, ThumbRequest request) {
    if (identical(service, _service) && request == _request) return;
    _release();
    _service = service;
    _request = request;
    if (service == null) return;
    final hit = service.peek(request);
    if (hit != null) {
      _bitmap = hit;
      return;
    }
    if (service.hasFailed(request)) return;
    final handle = service.load(request);
    _handle = handle;
    handle.result.then((b) {
      if (!mounted || !identical(_handle, handle)) {
        b?.dispose();
        return;
      }
      _handle = null;
      if (b == null) return;
      setState(() => _bitmap = b);
    });
  }

  ThumbSizeClass _classFor(BoxConstraints c) {
    final fixed = widget.sizeClass;
    if (fixed != null) return fixed;
    final w = c.hasBoundedWidth ? c.maxWidth : 0.0;
    final h = c.hasBoundedHeight ? c.maxHeight : 0.0;
    final side = w > h ? w : h;
    if (side <= 0) return ThumbSizeClass.m;
    return ThumbSizeClass.forBox(side, MediaQuery.maybeDevicePixelRatioOf(context) ?? 1);
  }

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(thumbnailServiceProvider);
    return LayoutBuilder(builder: (context, constraints) {
      final request = ThumbRequest(
        itemId: widget.itemId,
        source: widget.source,
        modifiedAt: widget.modifiedAt,
        sizeClass: _classFor(constraints),
        kind: widget.kind,
        // Documents render at the screen's pixel ratio so L tiles are sharp on 2-3x screens.
        scale: widget.kind == ThumbSourceKind.document ? (MediaQuery.maybeDevicePixelRatioOf(context) ?? 1) : 1,
      );
      _ensure(service, request);
      final image = _bitmap?.image;
      final Widget content = image != null
          ? RawImage(image: image, fit: widget.fit, filterQuality: FilterQuality.medium)
          : ColoredBox(
              color: DanaviewColors.surfaceElevated,
              child: widget.placeholder == null ? null : Center(child: widget.placeholder),
            );
      // Fills a bounded box; an unbounded side takes the other side (square), or 96 logical px.
      final w = constraints.hasBoundedWidth ? constraints.maxWidth : (constraints.hasBoundedHeight ? constraints.maxHeight : 96.0);
      final h = constraints.hasBoundedHeight ? constraints.maxHeight : w;
      final sized = SizedBox(width: w, height: h, child: ClipRect(child: content));
      final label = widget.semanticLabel;
      return label == null ? ExcludeSemantics(child: sized) : Semantics(label: label, image: true, child: sized);
    });
  }
}
