// OWNER: API-01
//
// A stand-in for the preview `Texture` widget in widget tests (ARCH §12.7). The real `Texture`
// paints nothing in `flutter_test`; this placeholder paints a deterministic colour per texture id
// so goldens and finders can tell sessions apart. Plain widgets only (no Material chrome).

import 'package:flutter/widgets.dart';

/// Placeholder for `Texture(textureId: …)` backed by a `FakePreviewSession` (ARCH §12.7).
///
/// One id may back two placeholders (editor and fullscreen), like the real texture.
class FakeTexturePlaceholder extends StatelessWidget {
  /// Creates a placeholder for [textureId].
  const FakeTexturePlaceholder({required this.textureId, this.size, super.key});

  /// The fake session's texture id.
  final int textureId;

  /// The rendered frame size (the session's `frameSize`); the widget fills its parent when null.
  final Size? size;

  /// Deterministic colour for [textureId].
  static Color colorOf(int textureId) => Color(0xFF000000 | ((textureId * 0x9E3779B1) & 0xFFFFFF)).withValues(alpha: 1);

  @override
  Widget build(BuildContext context) {
    final box = ColoredBox(color: colorOf(textureId));
    final s = size;
    return Semantics(
      label: 'Preview texture $textureId',
      child: s == null ? box : SizedBox(width: s.width, height: s.height, child: box),
    );
  }
}
